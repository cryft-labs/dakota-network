#!/usr/bin/env python3
"""
tx_loop_safe_3acct.py

Block-paced ETH transfer loop across 3 accounts derived from a mnemonic.

Goals:
- Submit >= 1 transaction per new block (pace = per-block) when possible.
- Do NOT block on receipts; poll receipts asynchronously.
- Keep balances safe using a reserve and optional top-ups.
- Works on QBFT/PoA chains (injects POA extraData middleware).

Example:
  source ~/.venv/web3/bin/activate
  python3 tx_loop_safe_3acct.py --rpc http://100.111.32.1:8545 --prompt-mnemonic --indices 0,1,2 --topup-enabled
"""

import argparse
import sys
import time
from decimal import Decimal, getcontext
from getpass import getpass
from typing import Dict, Optional, Tuple, List

from web3 import Web3
from eth_account import Account

getcontext().prec = 50


# ----------------------------
# Web3 helpers
# ----------------------------

def setup_web3(rpc_url: str) -> Web3:
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        raise SystemExit(f"ERROR: cannot connect to RPC: {rpc_url}")

    # Inject PoA/QBFT middleware to strip extraData so web3.py is happy.
    # Works across multiple web3.py versions.
    injected = False
    try:
        from web3.middleware import geth_poa_middleware
        w3.middleware_onion.inject(geth_poa_middleware, layer=0)
        injected = True
    except Exception:
        pass

    if not injected:
        # Newer web3 versions may expose class-based middleware
        try:
            from web3.middleware import ExtraDataToPOAMiddleware
            w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
            injected = True
        except Exception:
            pass

    return w3


def eth_to_wei(eth: Decimal) -> int:
    return int(eth * Decimal(10**18))


def wei_to_eth(wei: int) -> Decimal:
    return Decimal(wei) / Decimal(10**18)


def safe_int(x) -> int:
    return int(x) if x is not None else 0


def get_fee_fields(w3: Web3, tip_wei: int, max_fee_multiplier: int) -> Tuple[Dict, int]:
    """
    Returns (tx_fee_fields, worst_fee_per_gas_wei).

    If chain has baseFeePerGas -> EIP-1559 type 2 tx.
    Otherwise -> legacy gasPrice tx.
    """
    latest = w3.eth.get_block("latest")
    base_fee = latest.get("baseFeePerGas", None)

    if base_fee is None:
        # Legacy-style chain
        gp = safe_int(w3.eth.gas_price)
        gas_price = max(gp, tip_wei)
        return ({"gasPrice": gas_price}, gas_price)

    base_fee_wei = safe_int(base_fee)
    # Conservative but still tiny on your chain:
    max_fee = base_fee_wei * max_fee_multiplier + tip_wei
    max_priority = tip_wei
    # "worst" per gas is maxFeePerGas (upper bound)
    return (
        {
            "type": 2,
            "maxFeePerGas": max_fee,
            "maxPriorityFeePerGas": max_priority,
        },
        max_fee,
    )


def sign_and_send(w3: Web3, acct, tx: Dict) -> str:
    signed = acct.sign_transaction(tx)
    raw = getattr(signed, "rawTransaction", None)
    if raw is None:
        raw = getattr(signed, "raw_transaction", None)
    if raw is None:
        raise RuntimeError("SignedTransaction missing raw tx bytes (rawTransaction/raw_transaction).")

    tx_hash = w3.eth.send_raw_transaction(raw)
    return tx_hash.hex()


# ----------------------------
# Derivation
# ----------------------------

def derive_accounts_from_mnemonic(mnemonic: str, indices: List[int]):
    # Required for eth-account mnemonic derivation
    Account.enable_unaudited_hdwallet_features()

    accounts = []
    for idx in indices:
        path = f"m/44'/60'/0'/0/{idx}"
        acct = Account.from_mnemonic(mnemonic, account_path=path)
        accounts.append((idx, acct))
    return accounts


# ----------------------------
# Core loop logic
# ----------------------------

class PendingTx:
    def __init__(self, tx_hash: str, kind: str, sender: str, to: str, value_wei: int, sent_at_block: int, nonce: int):
        self.tx_hash = tx_hash
        self.kind = kind
        self.sender = sender
        self.to = to
        self.value_wei = value_wei
        self.sent_at_block = sent_at_block
        self.nonce = nonce
        self.sent_at_time = time.time()


def choose_topup_action(
    w3: Web3,
    accounts,
    funder_idx: int,
    amount_wei_per_hop: int,
    reserve_wei: int,
    topup_target_wei: int,
    worst_fee_per_gas_wei: int,
    gas_limit_transfer: int,
) -> Optional[Tuple[int, int, int]]:
    """
    If any non-funder account is below "needed", top up to target.
    Returns (from_index_in_accounts, to_index_in_accounts, topup_amount_wei) or None.
    """
    fee_buffer_wei = worst_fee_per_gas_wei * gas_limit_transfer
    needed_min_wei = reserve_wei + amount_wei_per_hop + fee_buffer_wei

    # Identify funder (position in list)
    funder_pos = None
    for pos, (idx, acct) in enumerate(accounts):
        if idx == funder_idx:
            funder_pos = pos
            break
    if funder_pos is None:
        raise SystemExit(f"ERROR: funder index {funder_idx} not in indices list.")

    funder_addr = accounts[funder_pos][1].address
    funder_bal = w3.eth.get_balance(funder_addr)

    # Find first acct needing topup
    for pos, (idx, acct) in enumerate(accounts):
        if pos == funder_pos:
            continue
        bal = w3.eth.get_balance(acct.address)
        if bal < needed_min_wei:
            # top up to target
            if bal >= topup_target_wei:
                continue
            delta = topup_target_wei - bal
            # ensure funder can afford
            if funder_bal < (delta + fee_buffer_wei + reserve_wei):
                print(f"TOPUP wanted for acct[{idx}] but funder lacks balance (funder={wei_to_eth(funder_bal)} ETH).")
                return None
            return (funder_pos, pos, delta)

    return None


def choose_ring_action(
    w3: Web3,
    accounts,
    hop_cursor: int,
    amount_wei_per_hop: int,
    reserve_wei: int,
    worst_fee_per_gas_wei: int,
    gas_limit_transfer: int,
) -> Optional[Tuple[int, int, int, int]]:
    """
    Round-robin: acct[i] -> acct[i+1]
    Returns (from_pos, to_pos, amount_wei, next_hop_cursor) or None.
    """
    n = len(accounts)
    fee_buffer_wei = worst_fee_per_gas_wei * gas_limit_transfer

    for _ in range(n):
        from_pos = hop_cursor % n
        to_pos = (from_pos + 1) % n
        from_acct = accounts[from_pos][1]

        bal = w3.eth.get_balance(from_acct.address)
        needed = reserve_wei + amount_wei_per_hop + fee_buffer_wei

        if bal >= needed:
            return (from_pos, to_pos, amount_wei_per_hop, (from_pos + 1) % n)

        hop_cursor = (hop_cursor + 1) % n

    return None


def main():
    p = argparse.ArgumentParser(description="Block-paced 3-account ETH transfer loop (QBFT/PoA friendly).")

    p.add_argument("--rpc", required=True, help="RPC URL, e.g. http://100.111.32.1:8545")
    p.add_argument("--mnemonic", default=None, help="BIP39 seed phrase (avoid passing in shell history).")
    p.add_argument("--prompt-mnemonic", action="store_true", help="Prompt for mnemonic via hidden input.")
    p.add_argument("--indices", default="0,1,2", help="Comma-separated derivation indices, e.g. 0,1,2")

    p.add_argument("--amount-eth", default="0.0001", help="ETH per hop transfer (default 0.0001)")
    p.add_argument("--reserve-eth", default="0.001", help="Reserve ETH to keep in each account (default 0.001)")

    p.add_argument("--pace", choices=["per-block"], default="per-block", help="Sending pace (per-block recommended).")
    p.add_argument("--poll-interval", type=float, default=0.2, help="Loop sleep/poll interval seconds (default 0.2)")

    p.add_argument("--tip-wei", type=int, default=1000, help="Tip (priority fee) in wei (default 1000)")
    p.add_argument("--max-fee-multiplier", type=int, default=2, help="maxFee = baseFee*multiplier + tip (default 2)")

    p.add_argument("--topup-enabled", action="store_true", help="Enable topups so accounts can keep sending.")
    p.add_argument("--topup-from-index", type=int, default=0, help="Derivation index used as funder (default 0)")
    p.add_argument("--topup-target-eth", default="0.01", help="Top up accounts to this ETH target (default 0.01)")

    p.add_argument("--max-inflight", type=int, default=64, help="Max pending txs tracked before pausing sends (default 64)")

    args = p.parse_args()

    # Mnemonic input
    mnemonic = args.mnemonic
    if args.prompt_mnemonic:
        mnemonic = getpass("mnemonic> ").strip()
    if not mnemonic:
        raise SystemExit("ERROR: provide --mnemonic or --prompt-mnemonic")

    indices = []
    for x in args.indices.split(","):
        x = x.strip()
        if not x:
            continue
        indices.append(int(x))
    if len(indices) < 3:
        print("WARNING: fewer than 3 indices provided; ring will still run but may be less useful.")

    amount_eth = Decimal(args.amount_eth)
    reserve_eth = Decimal(args.reserve_eth)
    topup_target_eth = Decimal(args.topup_target_eth)

    amount_wei = eth_to_wei(amount_eth)
    reserve_wei = eth_to_wei(reserve_eth)
    topup_target_wei = eth_to_wei(topup_target_eth)

    w3 = setup_web3(args.rpc)
    chain_id = int(w3.eth.chain_id)

    accounts = derive_accounts_from_mnemonic(mnemonic, indices)

    print(f"Connected: {args.rpc}")
    print(f"chainId: {chain_id}")
    print("Accounts (derived):")
    for pos, (idx, acct) in enumerate(accounts):
        print(f"  [{pos}] index={idx}  {acct.address}")

    # Track nonces locally using "pending" count (so we can send without waiting for mining)
    nonces: Dict[str, int] = {}
    for _, acct in accounts:
        nonces[acct.address] = w3.eth.get_transaction_count(acct.address, "pending")

    pending: Dict[str, PendingTx] = {}
    hop_cursor = 0

    gas_limit_transfer = 21000

    # For per-block pacing: send once per observed new block
    last_seen_block = w3.eth.block_number
    last_send_block = last_seen_block - 1

    print("\nLoop starting. Ctrl+C to stop.")
    print(f"amount per hop: {amount_eth} ETH | reserve: {reserve_eth} ETH | topup_enabled={args.topup_enabled}")
    print(f"pace={args.pace} | poll_interval={args.poll_interval}s\n")

    try:
        while True:
            # Always poll latest block quickly
            current_block = w3.eth.block_number

            if current_block != last_seen_block:
                # New block observed
                last_seen_block = current_block

            # Poll receipts for all pending txs (non-blocking)
            done_hashes = []
            for h, meta in pending.items():
                try:
                    r = w3.eth.get_transaction_receipt(h)
                except Exception:
                    r = None
                if r is not None:
                    mined_block = r.get("blockNumber", None)
                    status = r.get("status", None)
                    gas_used = r.get("gasUsed", None)
                    delta_blocks = (mined_block - meta.sent_at_block) if mined_block is not None else None
                    print(
                        f"[MINED] kind={meta.kind} hash={h[:10]}.. "
                        f"from={meta.sender[:10]}.. -> {meta.to[:10]}.. "
                        f"value={wei_to_eth(meta.value_wei)} ETH "
                        f"sent_at_block={meta.sent_at_block} mined_in={mined_block} delta_blocks={delta_blocks} "
                        f"status={status} gasUsed={gas_used}"
                    )
                    done_hashes.append(h)

            for h in done_hashes:
                pending.pop(h, None)

            # Safety: if too many inflight, pause sending until we clear
            if len(pending) >= args.max_inflight:
                time.sleep(args.poll_interval)
                continue

            # Only send on new block boundary (per-block pacing)
            if args.pace == "per-block" and current_block <= last_send_block:
                time.sleep(args.poll_interval)
                continue

            # Compute fee fields fresh each send (baseFee can change)
            fee_fields, worst_fee_per_gas_wei = get_fee_fields(w3, args.tip_wei, args.max_fee_multiplier)
            fee_buffer_wei = worst_fee_per_gas_wei * gas_limit_transfer

            # Decide action: topups first (if enabled), else ring hop
            action = None

            if args.topup_enabled:
                topup = choose_topup_action(
                    w3=w3,
                    accounts=accounts,
                    funder_idx=args.topup_from_index,
                    amount_wei_per_hop=amount_wei,
                    reserve_wei=reserve_wei,
                    topup_target_wei=topup_target_wei,
                    worst_fee_per_gas_wei=worst_fee_per_gas_wei,
                    gas_limit_transfer=gas_limit_transfer,
                )
                if topup is not None:
                    from_pos, to_pos, delta_wei = topup
                    action = ("topup", from_pos, to_pos, delta_wei)

            if action is None:
                ring = choose_ring_action(
                    w3=w3,
                    accounts=accounts,
                    hop_cursor=hop_cursor,
                    amount_wei_per_hop=amount_wei,
                    reserve_wei=reserve_wei,
                    worst_fee_per_gas_wei=worst_fee_per_gas_wei,
                    gas_limit_transfer=gas_limit_transfer,
                )
                if ring is not None:
                    from_pos, to_pos, amt, hop_cursor = ring
                    action = ("hop", from_pos, to_pos, amt)

            if action is None:
                # Nothing safe to send this block
                last_send_block = current_block
                time.sleep(args.poll_interval)
                continue

            kind, from_pos, to_pos, value_wei = action
            from_acct = accounts[from_pos][1]
            to_acct = accounts[to_pos][1]

            sender = from_acct.address
            recipient = to_acct.address

            sender_bal = w3.eth.get_balance(sender)

            worst_total_cost = value_wei + fee_buffer_wei
            if sender_bal < (worst_total_cost + reserve_wei):
                # Shouldn't happen if chooser logic is correct, but keep it safe.
                print(
                    f"[SKIP] insufficient balance for {kind}: sender={sender} "
                    f"bal={wei_to_eth(sender_bal)} ETH need≈{wei_to_eth(worst_total_cost + reserve_wei)} ETH"
                )
                last_send_block = current_block
                time.sleep(args.poll_interval)
                continue

            nonce = nonces[sender]

            tx = {
                "chainId": chain_id,
                "nonce": nonce,
                "to": recipient,
                "value": int(value_wei),
                "gas": gas_limit_transfer,
            }
            tx.update(fee_fields)

            print(
                f"[SEND@block {current_block}] kind={kind}  "
                f"{sender} -> {recipient}  "
                f"value={wei_to_eth(value_wei)} ETH  "
                f"nonce={nonce}  "
                f"worst_fee/gas={worst_fee_per_gas_wei} wei  "
                f"worst_total_cost≈{wei_to_eth(worst_total_cost)} ETH"
            )

            try:
                tx_hash = sign_and_send(w3, from_acct, tx)
            except Exception as e:
                print(f"[ERROR] send failed: {e}")
                # Do not advance nonce; retry next block
                last_send_block = current_block
                time.sleep(args.poll_interval)
                continue

            # Advance local nonce immediately (we're not waiting for mining)
            nonces[sender] += 1

            pending[tx_hash] = PendingTx(
                tx_hash=tx_hash,
                kind=kind,
                sender=sender,
                to=recipient,
                value_wei=int(value_wei),
                sent_at_block=current_block,
                nonce=nonce,
            )

            print(f"  txHash: {tx_hash}")

            # Mark we sent this block
            last_send_block = current_block

            # Small sleep to avoid busy looping
            time.sleep(args.poll_interval)

    except KeyboardInterrupt:
        print("\nStopping (Ctrl+C).")
        if pending:
            print(f"Pending txs still tracked: {len(pending)}")
            for h, meta in list(pending.items())[:10]:
                print(f"  {h} kind={meta.kind} sent_at_block={meta.sent_at_block} nonce={meta.nonce}")
        print("Done.")


if __name__ == "__main__":
    main()
