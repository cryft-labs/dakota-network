#!/usr/bin/env python3
# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.
# This software is part of a patented system. See LICENSE and PATENT NOTICE.

"""
tx_simulator.py — Configurable Transaction Simulator
=====================================================

Block-paced (or rate-paced) ETH transfer loop for QBFT/PoA chains.

Four independent knobs control traffic shape:

  1) --sender-mode     : who originates each tx
  2) --recipient-mode  : who receives each tx
  3) --amount-mode     : how much value moves
  4) --timing-mode     : when txs are emitted

Account sourcing (combine any):

  --mnemonic / --prompt-mnemonic  with  --indices 0,1,2  or  --num-accounts 5
  --private-keys key1,key2,...
  --private-keys-file path/to/file.txt

Defaults match the original round-robin ring behavior:

  sender=round-robin  recipient=ring  amount=fixed  timing=per-block

Examples:

  # Original 3-account ring (all defaults)
  python3 tx_simulator.py --rpc http://100.111.32.1:8545 --prompt-mnemonic

  # 10 HD accounts, weighted senders, random recipients, Poisson timing
  python3 tx_simulator.py --rpc http://100.111.32.1:8545 \\
    --prompt-mnemonic --num-accounts 10 \\
    --sender-mode weighted --sender-weights 50,20,10,5,5,3,3,2,1,1 \\
    --recipient-mode random-uniform \\
    --amount-mode log-normal --amount-min-eth 0.00001 --amount-max-eth 0.1 \\
    --timing-mode poisson --target-tps 5

  # Private keys + burst timing + star fan-out
  python3 tx_simulator.py --rpc http://100.111.32.1:8545 \\
    --private-keys-file keys.txt \\
    --recipient-mode star-fan-out \\
    --timing-mode bursts --burst-size 20 --burst-pause 5
"""

import argparse
import math
import random
import sys
import time
from decimal import Decimal, getcontext
from getpass import getpass
from typing import Dict, List, Optional, Tuple

from web3 import Web3
from eth_account import Account

getcontext().prec = 50


# ══════════════════════════════════════════════════════════════════════
# Web3 helpers
# ══════════════════════════════════════════════════════════════════════

def setup_web3(rpc_url: str) -> Web3:
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        raise SystemExit(f"ERROR: cannot connect to RPC: {rpc_url}")

    # Inject PoA/QBFT middleware — works across multiple web3.py versions.
    injected = False
    try:
        from web3.middleware import geth_poa_middleware
        w3.middleware_onion.inject(geth_poa_middleware, layer=0)
        injected = True
    except Exception:
        pass
    if not injected:
        try:
            from web3.middleware import ExtraDataToPOAMiddleware
            w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
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
    EIP-1559 type-2 when baseFeePerGas is present, legacy gasPrice otherwise.
    """
    latest = w3.eth.get_block("latest")
    base_fee = latest.get("baseFeePerGas", None)

    if base_fee is None:
        gp = safe_int(w3.eth.gas_price)
        gas_price = max(gp, tip_wei)
        return ({"gasPrice": gas_price}, gas_price)

    base_fee_wei = safe_int(base_fee)
    max_fee = base_fee_wei * max_fee_multiplier + tip_wei
    return (
        {"type": 2, "maxFeePerGas": max_fee, "maxPriorityFeePerGas": tip_wei},
        max_fee,
    )


def sign_and_send(w3: Web3, acct, tx: Dict) -> str:
    signed = acct.sign_transaction(tx)
    raw = getattr(signed, "rawTransaction", None) or getattr(signed, "raw_transaction", None)
    if raw is None:
        raise RuntimeError("SignedTransaction missing raw tx bytes.")
    return w3.eth.send_raw_transaction(raw).hex()


# ══════════════════════════════════════════════════════════════════════
# Account sourcing
# ══════════════════════════════════════════════════════════════════════

def load_accounts(args) -> List[Tuple[str, object]]:
    """
    Build accounts list from mnemonic and/or private keys.

    Sources (combinable):
      --mnemonic / --prompt-mnemonic  with  --indices or --num-accounts
      --private-keys  key1,key2,...
      --private-keys-file  path

    Returns [(label, eth_account.Account)].
    """
    accounts: List[Tuple[str, object]] = []

    # ── Mnemonic-derived accounts ──
    mnemonic = args.mnemonic
    if args.prompt_mnemonic:
        mnemonic = getpass("mnemonic> ").strip()

    if mnemonic:
        Account.enable_unaudited_hdwallet_features()

        if args.num_accounts is not None:
            indices = list(range(args.num_accounts))
        elif args.indices is not None:
            indices = [int(x.strip()) for x in args.indices.split(",") if x.strip()]
        else:
            indices = [0, 1, 2]

        for idx in indices:
            path = f"m/44'/60'/0'/0/{idx}"
            acct = Account.from_mnemonic(mnemonic, account_path=path)
            accounts.append((f"hd/{idx}", acct))

    # ── Inline private keys ──
    if args.private_keys:
        for i, key in enumerate(args.private_keys.split(",")):
            key = key.strip()
            if not key:
                continue
            if not key.startswith("0x"):
                key = "0x" + key
            accounts.append((f"pk/{i}", Account.from_key(key)))

    # ── Private keys from file (one per line, # comments OK) ──
    if args.private_keys_file:
        with open(args.private_keys_file, encoding="utf-8") as f:
            for i, line in enumerate(f):
                key = line.strip()
                if not key or key.startswith("#"):
                    continue
                if not key.startswith("0x"):
                    key = "0x" + key
                accounts.append((f"file/{i}", Account.from_key(key)))

    if not accounts:
        raise SystemExit(
            "ERROR: provide accounts via --mnemonic / --prompt-mnemonic "
            "and/or --private-keys / --private-keys-file"
        )

    return accounts


# ══════════════════════════════════════════════════════════════════════
# 1) Sender selection
# ══════════════════════════════════════════════════════════════════════

SENDER_MODES = ["round-robin", "single", "weighted", "multi-hot", "random"]


class SenderSelector:
    """
    round-robin  — A0, A1, A2, … rotate each tx (default)
    single       — one hot account sends every tx
    weighted     — accounts chosen with configurable probability weights
    multi-hot    — first K accounts send, rest are recipient-only
    random       — sender picked uniformly at random
    """

    def __init__(self, mode: str, n: int, **kw):
        self.mode = mode
        self.n = n
        self._cursor = 0
        self._single_pos = kw.get("single_pos", 0) % n
        self._hot_count = min(kw.get("hot_count", 1), n)

        self._weights = kw.get("weights")
        if self._weights:
            # Pad or truncate to match account count
            if len(self._weights) < n:
                self._weights += [0.0] * (n - len(self._weights))
            elif len(self._weights) > n:
                self._weights = self._weights[:n]
            if sum(self._weights) == 0:
                raise SystemExit("ERROR: --sender-weights sum to zero.")

    def next(self, exclude: Optional[int] = None) -> int:
        """Return next sender position.  *exclude* is skipped (e.g. hub in fan-in)."""
        for _ in range(self.n * 2):
            pos = self._pick()
            if exclude is not None and pos == exclude and self.n > 1:
                continue
            return pos
        return self._pick()

    def _pick(self) -> int:
        if self.mode == "round-robin":
            pos = self._cursor % self.n
            self._cursor = (self._cursor + 1) % self.n
            return pos
        if self.mode == "single":
            return self._single_pos
        if self.mode == "weighted":
            return random.choices(range(self.n), weights=self._weights, k=1)[0]
        if self.mode == "multi-hot":
            return random.randint(0, self._hot_count - 1)
        # random
        return random.randint(0, self.n - 1)


# ══════════════════════════════════════════════════════════════════════
# 2) Recipient selection
# ══════════════════════════════════════════════════════════════════════

RECIPIENT_MODES = [
    "ring", "star-fan-out", "star-fan-in",
    "random-uniform", "random-no-repeat",
    "partitioned", "bursty",
]


class RecipientSelector:
    """
    ring             — A[i] -> A[i+1 mod n]  (default)
    star-fan-out     — hub -> random other  (overrides sender to hub)
    star-fan-in      — any non-hub -> hub
    random-uniform   — random pair, no self-send
    random-no-repeat — like uniform but no immediate repeat of same pair
    partitioned      — only send within same partition group
    bursty           — for T seconds target a random subset, then switch
    """

    def __init__(self, mode: str, n: int, **kw):
        self.mode = mode
        self.n = n
        self.hub_pos: int = kw.get("hub_pos", 0) % n
        self.partition_size: int = max(2, kw.get("partition_size", 2))
        self.campaign_duration: float = kw.get("campaign_duration", 30.0)
        self.campaign_subset: int = kw.get("campaign_subset") or max(2, n // 2)

        self._last_pair: Tuple[int, int] = (-1, -1)
        self._campaign_targets: Optional[List[int]] = None
        self._campaign_switch: float = 0.0

    # -- Sender interaction helpers --

    def overrides_sender(self) -> bool:
        """star-fan-out forces the sender to be the hub."""
        return self.mode == "star-fan-out"

    def forced_sender(self) -> int:
        return self.hub_pos

    def sender_exclude(self) -> Optional[int]:
        """Position to exclude from sender pool (fan-in excludes hub)."""
        if self.mode == "star-fan-in":
            return self.hub_pos
        return None

    # -- Core --

    def next(self, sender_pos: int) -> int:
        if self.mode == "ring":
            return (sender_pos + 1) % self.n

        if self.mode == "star-fan-out":
            others = [i for i in range(self.n) if i != self.hub_pos]
            return random.choice(others) if others else 0

        if self.mode == "star-fan-in":
            return self.hub_pos

        if self.mode == "random-uniform":
            others = [i for i in range(self.n) if i != sender_pos]
            return random.choice(others) if others else 0

        if self.mode == "random-no-repeat":
            others = [
                i for i in range(self.n)
                if i != sender_pos and (sender_pos, i) != self._last_pair
            ]
            if not others:
                others = [i for i in range(self.n) if i != sender_pos]
            chosen = random.choice(others) if others else 0
            self._last_pair = (sender_pos, chosen)
            return chosen

        if self.mode == "partitioned":
            g_start = (sender_pos // self.partition_size) * self.partition_size
            g_end = min(g_start + self.partition_size, self.n)
            others = [i for i in range(g_start, g_end) if i != sender_pos]
            return random.choice(others) if others else sender_pos

        if self.mode == "bursty":
            now = time.time()
            if self._campaign_targets is None or now >= self._campaign_switch:
                pool = [i for i in range(self.n) if i != sender_pos]
                k = min(self.campaign_subset, len(pool))
                self._campaign_targets = random.sample(pool, k) if pool else [0]
                self._campaign_switch = now + self.campaign_duration
            candidates = [t for t in self._campaign_targets if t != sender_pos]
            return random.choice(candidates) if candidates else self._campaign_targets[0]

        # fallback: ring
        return (sender_pos + 1) % self.n


# ══════════════════════════════════════════════════════════════════════
# 3) Amount distribution
# ══════════════════════════════════════════════════════════════════════

AMOUNT_MODES = ["fixed", "uniform-random", "log-normal", "step-schedule", "balance-aware"]


class AmountSelector:
    """
    fixed          — constant amount every tx  (default)
    uniform-random — uniform random in [min, max]
    log-normal     — many small, occasional large (clamped to [min, max])
    step-schedule  — cycle through a list of amounts on a timer
    balance-aware  — send half of (balance - reserve), clamped to [min, max]
    """

    def __init__(self, mode: str, **kw):
        self.mode = mode
        self.fixed_wei: int = kw.get("fixed_wei", 0)
        self.min_wei: int = kw.get("min_wei", 0)
        self.max_wei: int = kw.get("max_wei", 0)
        self.log_sigma: float = kw.get("log_sigma", 1.0)
        self.step_amounts: List[int] = kw.get("step_amounts", [])
        self.step_duration: float = kw.get("step_duration", 60.0)
        self.reserve_wei: int = kw.get("reserve_wei", 0)
        self._start = time.time()

    def next(self, sender_balance_wei: int = 0) -> int:
        if self.mode == "fixed":
            return self.fixed_wei

        if self.mode == "uniform-random":
            lo = self.min_wei
            hi = max(self.min_wei, self.max_wei)
            return random.randint(lo, hi)

        if self.mode == "log-normal":
            # Median of the lognormal maps to geometric mean of [min, max].
            lo_eth = max(Decimal(self.min_wei) / Decimal(10**18), Decimal("1e-18"))
            hi_eth = max(Decimal(self.max_wei) / Decimal(10**18), lo_eth)
            median_eth = float((lo_eth * hi_eth).sqrt())
            raw = random.lognormvariate(0, self.log_sigma)
            amount_eth = raw * median_eth
            amount_eth = max(float(lo_eth), min(float(hi_eth), amount_eth))
            return int(Decimal(str(amount_eth)) * Decimal(10**18))

        if self.mode == "step-schedule":
            if not self.step_amounts:
                return self.fixed_wei
            elapsed = time.time() - self._start
            idx = int(elapsed / self.step_duration) % len(self.step_amounts)
            return self.step_amounts[idx]

        if self.mode == "balance-aware":
            available = max(0, sender_balance_wei - self.reserve_wei)
            amount = available // 2
            if self.max_wei > 0:
                amount = min(amount, self.max_wei)
            amount = max(amount, self.min_wei)
            return amount

        return self.fixed_wei


# ══════════════════════════════════════════════════════════════════════
# 4) Timing / rate distribution
# ══════════════════════════════════════════════════════════════════════

TIMING_MODES = ["per-block", "fixed-tps", "poisson", "bursts", "ramp", "jittered"]


class TimingController:
    """
    per-block  — one tx per new block  (default)
    fixed-tps  — constant transactions per second
    poisson    — exponential inter-arrival times (average = target TPS)
    bursts     — send N rapidly, pause, repeat
    ramp       — linearly increase TPS over a duration
    jittered   — base interval +/- random uniform jitter
    """

    def __init__(self, mode: str, **kw):
        self.mode = mode
        self.tps: float = kw.get("target_tps", 1.0)
        self.burst_size: int = kw.get("burst_size", 50)
        self.burst_pause: float = kw.get("burst_pause", 10.0)
        self.ramp_start: float = kw.get("ramp_start_tps", 1.0)
        self.ramp_end: float = kw.get("ramp_end_tps", 50.0)
        self.ramp_dur: float = kw.get("ramp_duration", 300.0)
        self.jitter_base: float = kw.get("jitter_base", 1.0)
        self.jitter_range: float = kw.get("jitter_range", 0.5)

        self._start = time.time()
        self._last_send = 0.0
        self._last_block = -1
        self._next_send = 0.0
        self._burst_rem = self.burst_size
        self._burst_pause_until = 0.0

        self._schedule_next()

    def _schedule_next(self):
        now = time.time()
        if self.mode == "fixed-tps":
            self._next_send = now + (1.0 / self.tps if self.tps > 0 else 1.0)
        elif self.mode == "poisson":
            self._next_send = now + (random.expovariate(self.tps) if self.tps > 0 else 1.0)
        elif self.mode == "jittered":
            jitter = random.uniform(-self.jitter_range, self.jitter_range)
            self._next_send = now + max(0.01, self.jitter_base + jitter)

    def should_send(self, current_block: int) -> bool:
        now = time.time()

        if self.mode == "per-block":
            return current_block > self._last_block

        if self.mode in ("fixed-tps", "poisson", "jittered"):
            return now >= self._next_send

        if self.mode == "bursts":
            if self._burst_rem > 0:
                return True
            # Burst exhausted — check if pause is over
            if now >= self._burst_pause_until:
                self._burst_rem = self.burst_size
                return True
            return False

        if self.mode == "ramp":
            elapsed = now - self._start
            progress = min(1.0, elapsed / self.ramp_dur) if self.ramp_dur > 0 else 1.0
            cur_tps = self.ramp_start + (self.ramp_end - self.ramp_start) * progress
            interval = 1.0 / cur_tps if cur_tps > 0 else 1.0
            return (now - self._last_send) >= interval

        return True

    def record_send(self, current_block: int):
        self._last_send = time.time()
        self._last_block = current_block

        if self.mode == "bursts":
            self._burst_rem -= 1
            if self._burst_rem <= 0:
                self._burst_rem = 0
                self._burst_pause_until = time.time() + self.burst_pause
        else:
            self._schedule_next()

    def in_burst(self) -> bool:
        """True if mid-burst and should skip the poll-interval sleep."""
        return self.mode == "bursts" and self._burst_rem > 0


# ══════════════════════════════════════════════════════════════════════
# Pending-tx tracker
# ══════════════════════════════════════════════════════════════════════

class PendingTx:
    __slots__ = ("tx_hash", "kind", "sender", "to", "value_wei",
                 "sent_at_block", "nonce", "sent_at_time")

    def __init__(self, tx_hash, kind, sender, to, value_wei, sent_at_block, nonce):
        self.tx_hash = tx_hash
        self.kind = kind
        self.sender = sender
        self.to = to
        self.value_wei = value_wei
        self.sent_at_block = sent_at_block
        self.nonce = nonce
        self.sent_at_time = time.time()


# ══════════════════════════════════════════════════════════════════════
# Top-up logic
# ══════════════════════════════════════════════════════════════════════

def choose_topup(w3, accounts, funder_pos, amount_hint_wei, reserve_wei,
                 topup_target_wei, worst_fee_gas, gas_limit):
    """
    If any non-funder account is below the minimum needed to operate,
    return (funder_pos, target_pos, topup_amount_wei), else None.
    """
    n = len(accounts)
    if funder_pos >= n:
        return None

    fee_buf = worst_fee_gas * gas_limit
    needed_min = reserve_wei + amount_hint_wei + fee_buf

    funder_addr = accounts[funder_pos][1].address
    funder_bal = w3.eth.get_balance(funder_addr)

    for pos in range(n):
        if pos == funder_pos:
            continue
        bal = w3.eth.get_balance(accounts[pos][1].address)
        if bal < needed_min and bal < topup_target_wei:
            delta = topup_target_wei - bal
            if funder_bal < (delta + fee_buf + reserve_wei):
                print(
                    f"  TOPUP wanted for [{pos}] but funder lacks balance "
                    f"(funder={wei_to_eth(funder_bal)} ETH)."
                )
                return None
            return (funder_pos, pos, delta)

    return None


# ══════════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════════

def build_parser():
    p = argparse.ArgumentParser(
        description="Configurable transaction simulator for QBFT/PoA chains.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # — Account sourcing —
    g = p.add_argument_group("Account sourcing")
    g.add_argument("--rpc", required=True,
                   help="RPC endpoint URL")
    g.add_argument("--mnemonic", default=None,
                   help="BIP-39 seed phrase (caution: visible in shell history)")
    g.add_argument("--prompt-mnemonic", action="store_true",
                   help="Prompt for mnemonic via hidden input")
    g.add_argument("--indices", default=None,
                   help="Comma-separated HD derivation indices (default: 0,1,2)")
    g.add_argument("--num-accounts", type=int, default=None,
                   help="Derive N accounts (indices 0..N-1); overrides --indices")
    g.add_argument("--private-keys", default=None,
                   help="Comma-separated hex private keys (with or without 0x)")
    g.add_argument("--private-keys-file", default=None,
                   help="File with one hex private key per line (# comments OK)")

    # — Sender selection —
    g = p.add_argument_group("Sender selection")
    g.add_argument("--sender-mode", choices=SENDER_MODES, default="round-robin",
                   help="How the sender is chosen each tx (default: round-robin)")
    g.add_argument("--single-sender-pos", type=int, default=0,
                   help="Account position for 'single' mode (default: 0)")
    g.add_argument("--sender-weights", default=None,
                   help="Comma-separated weights for 'weighted' mode (e.g. 70,20,10)")
    g.add_argument("--hot-senders", type=int, default=1,
                   help="Number of hot senders for 'multi-hot' mode (default: 1)")

    # — Recipient selection —
    g = p.add_argument_group("Recipient selection")
    g.add_argument("--recipient-mode", choices=RECIPIENT_MODES, default="ring",
                   help="How the recipient is chosen each tx (default: ring)")
    g.add_argument("--hub-pos", type=int, default=0,
                   help="Hub account position for star-fan-out / star-fan-in (default: 0)")
    g.add_argument("--partition-size", type=int, default=2,
                   help="Group size for 'partitioned' mode (default: 2)")
    g.add_argument("--campaign-duration", type=float, default=30.0,
                   help="Seconds per target subset for 'bursty' recipient mode (default: 30)")
    g.add_argument("--campaign-subset", type=int, default=None,
                   help="Target subset size for 'bursty' mode (default: half of accounts)")

    # — Amount distribution —
    g = p.add_argument_group("Amount distribution")
    g.add_argument("--amount-mode", choices=AMOUNT_MODES, default="fixed",
                   help="How transfer amounts are determined (default: fixed)")
    g.add_argument("--amount-eth", default="0.0001",
                   help="Fixed ETH per tx (default: 0.0001)")
    g.add_argument("--amount-min-eth", default="0.00001",
                   help="Min ETH for random / log-normal / balance-aware (default: 0.00001)")
    g.add_argument("--amount-max-eth", default="0.01",
                   help="Max ETH for random / log-normal / balance-aware (default: 0.01)")
    g.add_argument("--log-sigma", type=float, default=1.0,
                   help="Sigma for log-normal (higher = heavier tail) (default: 1.0)")
    g.add_argument("--step-amounts", default=None,
                   help="Comma-separated ETH amounts for step-schedule (e.g. 0.0001,0.001,0.01)")
    g.add_argument("--step-duration", type=float, default=60.0,
                   help="Seconds per step for step-schedule (default: 60)")

    # — Timing —
    g = p.add_argument_group("Timing / rate")
    g.add_argument("--timing-mode", choices=TIMING_MODES, default="per-block",
                   help="When txs are emitted (default: per-block)")
    g.add_argument("--target-tps", type=float, default=5.0,
                   help="Target TPS for fixed-tps / poisson (default: 5)")
    g.add_argument("--burst-size", type=int, default=50,
                   help="Txs per burst for 'bursts' timing (default: 50)")
    g.add_argument("--burst-pause", type=float, default=10.0,
                   help="Pause seconds between bursts (default: 10)")
    g.add_argument("--ramp-start-tps", type=float, default=1.0,
                   help="Starting TPS for 'ramp' mode (default: 1)")
    g.add_argument("--ramp-end-tps", type=float, default=50.0,
                   help="Target TPS for 'ramp' mode (default: 50)")
    g.add_argument("--ramp-duration", type=float, default=300.0,
                   help="Ramp duration in seconds (default: 300)")
    g.add_argument("--jitter-base", type=float, default=1.0,
                   help="Base interval seconds for 'jittered' mode (default: 1.0)")
    g.add_argument("--jitter-range", type=float, default=0.5,
                   help="Plus/minus jitter range seconds (default: 0.5)")
    g.add_argument("--poll-interval", type=float, default=0.2,
                   help="Loop sleep when idle (default: 0.2)")

    # — Fee / gas —
    g = p.add_argument_group("Fee / gas")
    g.add_argument("--tip-wei", type=int, default=1000,
                   help="Priority fee (tip) in wei (default: 1000)")
    g.add_argument("--max-fee-multiplier", type=int, default=2,
                   help="maxFee = baseFee * multiplier + tip (default: 2)")

    # — Top-up —
    g = p.add_argument_group("Top-up")
    g.add_argument("--topup-enabled", action="store_true",
                   help="Auto-replenish underfunded accounts from a funder")
    g.add_argument("--topup-funder-pos", type=int, default=0,
                   help="Funder account position in the accounts list (default: 0)")
    g.add_argument("--topup-target-eth", default="0.01",
                   help="Top up accounts to this ETH balance (default: 0.01)")

    # — General —
    g = p.add_argument_group("General")
    g.add_argument("--reserve-eth", default="0.001",
                   help="Reserve ETH kept in each account to avoid bricking (default: 0.001)")
    g.add_argument("--max-inflight", type=int, default=64,
                   help="Max pending txs before pausing sends (default: 64)")

    return p


# ══════════════════════════════════════════════════════════════════════
# Main loop
# ══════════════════════════════════════════════════════════════════════

def main():
    args = build_parser().parse_args()

    # ── Load accounts ──
    accounts = load_accounts(args)
    n = len(accounts)

    if n < 2:
        raise SystemExit("ERROR: need at least 2 accounts.")

    # ── Connect ──
    w3 = setup_web3(args.rpc)
    chain_id = int(w3.eth.chain_id)

    print(f"\nConnected: {args.rpc}  chainId={chain_id}")
    print(f"Accounts ({n}):")
    for pos, (label, acct) in enumerate(accounts):
        bal = w3.eth.get_balance(acct.address)
        print(f"  [{pos}] {label:>8s}  {acct.address}  bal={wei_to_eth(bal)} ETH")

    # ── Parse numeric params ──
    amount_eth = Decimal(args.amount_eth)
    amount_min_eth = Decimal(args.amount_min_eth)
    amount_max_eth = Decimal(args.amount_max_eth)
    reserve_eth = Decimal(args.reserve_eth)
    topup_target_eth = Decimal(args.topup_target_eth)

    amount_wei = eth_to_wei(amount_eth)
    amount_min_wei = eth_to_wei(amount_min_eth)
    amount_max_wei = eth_to_wei(amount_max_eth)
    reserve_wei = eth_to_wei(reserve_eth)
    topup_target_wei = eth_to_wei(topup_target_eth)

    step_amounts_wei: List[int] = []
    if args.step_amounts:
        step_amounts_wei = [
            eth_to_wei(Decimal(x.strip()))
            for x in args.step_amounts.split(",") if x.strip()
        ]

    sender_weights: Optional[List[float]] = None
    if args.sender_weights:
        sender_weights = [float(x.strip()) for x in args.sender_weights.split(",") if x.strip()]

    gas_limit = 21_000

    # ── Build selectors ──
    sender_sel = SenderSelector(
        args.sender_mode, n,
        single_pos=args.single_sender_pos,
        weights=sender_weights,
        hot_count=args.hot_senders,
    )

    recip_sel = RecipientSelector(
        args.recipient_mode, n,
        hub_pos=args.hub_pos,
        partition_size=args.partition_size,
        campaign_duration=args.campaign_duration,
        campaign_subset=args.campaign_subset,
    )

    amount_sel = AmountSelector(
        args.amount_mode,
        fixed_wei=amount_wei,
        min_wei=amount_min_wei,
        max_wei=amount_max_wei,
        log_sigma=args.log_sigma,
        step_amounts=step_amounts_wei,
        step_duration=args.step_duration,
        reserve_wei=reserve_wei,
    )

    timing = TimingController(
        args.timing_mode,
        target_tps=args.target_tps,
        burst_size=args.burst_size,
        burst_pause=args.burst_pause,
        ramp_start_tps=args.ramp_start_tps,
        ramp_end_tps=args.ramp_end_tps,
        ramp_duration=args.ramp_duration,
        jitter_base=args.jitter_base,
        jitter_range=args.jitter_range,
    )

    # ── State ──
    nonces: Dict[str, int] = {}
    for _, acct in accounts:
        nonces[acct.address] = w3.eth.get_transaction_count(acct.address, "pending")

    pending: Dict[str, PendingTx] = {}
    last_seen_block = w3.eth.block_number

    # ── Banner ──
    print(f"\nDistribution:")
    print(f"  sender    = {args.sender_mode}")
    print(f"  recipient = {args.recipient_mode}")
    print(f"  amount    = {args.amount_mode}")
    print(f"  timing    = {args.timing_mode}")
    if recip_sel.overrides_sender():
        print(f"  (star-fan-out overrides sender to hub position {recip_sel.hub_pos})")
    print(f"reserve={reserve_eth} ETH  topup={args.topup_enabled}  "
          f"max_inflight={args.max_inflight}  poll={args.poll_interval}s")
    print(f"\nLoop starting. Ctrl+C to stop.\n")

    # ── Main loop ──
    try:
        while True:
            current_block = w3.eth.block_number
            if current_block != last_seen_block:
                last_seen_block = current_block

            # ── Poll receipts ──
            done = []
            for h, meta in pending.items():
                try:
                    r = w3.eth.get_transaction_receipt(h)
                except Exception:
                    r = None
                if r is not None:
                    mb = r.get("blockNumber")
                    st = r.get("status")
                    gu = r.get("gasUsed")
                    db = (mb - meta.sent_at_block) if mb is not None else None
                    print(
                        f"[MINED] kind={meta.kind} hash={h[:10]}.. "
                        f"{meta.sender[:10]}..→{meta.to[:10]}.. "
                        f"val={wei_to_eth(meta.value_wei)} sent@{meta.sent_at_block} "
                        f"mined@{mb} Δ={db} status={st} gas={gu}"
                    )
                    done.append(h)
            for h in done:
                pending.pop(h, None)

            # ── Inflight cap ──
            if len(pending) >= args.max_inflight:
                time.sleep(args.poll_interval)
                continue

            # ── Timing gate ──
            if not timing.should_send(current_block):
                time.sleep(args.poll_interval)
                continue

            # ── Fee fields (fresh each send — baseFee can change) ──
            fee_fields, worst_fee_gas = get_fee_fields(w3, args.tip_wei, args.max_fee_multiplier)
            fee_buf = worst_fee_gas * gas_limit

            # ── Choose action ──
            action = None  # (kind, from_pos, to_pos, value_wei)

            # Top-up takes priority
            if args.topup_enabled:
                tu = choose_topup(
                    w3, accounts, args.topup_funder_pos, amount_wei,
                    reserve_wei, topup_target_wei, worst_fee_gas, gas_limit,
                )
                if tu:
                    action = ("topup", tu[0], tu[1], tu[2])

            # Normal distribution-chosen tx
            if action is None:
                # Sender
                if recip_sel.overrides_sender():
                    sender_pos = recip_sel.forced_sender()
                else:
                    sender_pos = sender_sel.next(exclude=recip_sel.sender_exclude())

                # Recipient
                recip_pos = recip_sel.next(sender_pos)

                # Amount
                sender_bal = w3.eth.get_balance(accounts[sender_pos][1].address)
                value = amount_sel.next(sender_balance_wei=sender_bal)

                # Balance check
                if sender_bal >= (value + fee_buf + reserve_wei) and value > 0:
                    action = ("tx", sender_pos, recip_pos, value)

            if action is None:
                timing.record_send(current_block)
                time.sleep(args.poll_interval)
                continue

            kind, from_pos, to_pos, value_wei = action
            from_acct = accounts[from_pos][1]
            to_addr = accounts[to_pos][1].address
            sender_addr = from_acct.address

            # Final balance guard
            sender_bal = w3.eth.get_balance(sender_addr)
            if sender_bal < (value_wei + fee_buf + reserve_wei):
                print(f"[SKIP] {sender_addr[:10]}.. insufficient for {kind}")
                timing.record_send(current_block)
                time.sleep(args.poll_interval)
                continue

            nonce = nonces[sender_addr]

            tx = {
                "chainId": chain_id,
                "nonce": nonce,
                "to": to_addr,
                "value": int(value_wei),
                "gas": gas_limit,
            }
            tx.update(fee_fields)

            print(
                f"[SEND@{current_block}] {kind}  "
                f"{sender_addr[:10]}.. → {to_addr[:10]}..  "
                f"val={wei_to_eth(value_wei)}  nonce={nonce}"
            )

            try:
                tx_hash = sign_and_send(w3, from_acct, tx)
            except Exception as e:
                print(f"[ERROR] send failed: {e}")
                timing.record_send(current_block)
                time.sleep(args.poll_interval)
                continue

            # Advance local nonce immediately (not waiting for mining)
            nonces[sender_addr] += 1

            pending[tx_hash] = PendingTx(
                tx_hash, kind, sender_addr, to_addr,
                int(value_wei), current_block, nonce,
            )
            print(f"  txHash: {tx_hash}")

            timing.record_send(current_block)

            # During bursts, skip sleep to fire next tx immediately
            if not timing.in_burst():
                time.sleep(args.poll_interval)

    except KeyboardInterrupt:
        print(f"\nStopping. {len(pending)} pending txs.")
        for h, m in list(pending.items())[:10]:
            print(f"  {h} kind={m.kind} sent@{m.sent_at_block} nonce={m.nonce}")
        print("Done.")


if __name__ == "__main__":
    main()
