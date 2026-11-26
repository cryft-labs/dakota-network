#!/usr/bin/env python3
"""Fund settlement@paladin01 from the dev deployer (runbook Phase E.3). Start at 0.03 CRYFT; alert below 0.01.

The recipient is never typed in: it is what Paladin itself resolves for settlement@paladin01 (asked through
Backend-01, the only host its RPC allows). Guards: chain id 113211, the pinned block-0 hash, the Keychain dev
deployer, and a top-up only up to the target (never above it).

    python Tools/Paladin/fund_settlement.py --target-wei 30000000000000000 [--execute]
"""
import argparse, json, subprocess
from pathlib import Path

from eth_account import Account
from web3 import Web3

REPO = Path(__file__).resolve().parents[2]
PLAN = json.loads((REPO / "Tools/Genesis/link-plan.json").read_text())
GENESIS_BLOCK = json.loads((REPO / "Contracts/Genesis/genesis-block.json").read_text())["genesisBlockHash"]
SSH = ["ssh", "-F", str(Path.home() / "Cryft/codex-outputs/cryft-ssh/mac-ssh-config"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=25"]


def settlement_address():
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ptx_resolveVerifier",
                       "params": ["settlement@paladin01", "ecdsa:secp256k1", "eth_address"]})
    out = subprocess.run(SSH + ["Backend-01", f"curl -s -m 20 -X POST -H 'Content-Type: application/json' --data '{body}' "
                                "http://100.111.32.201:8550"], capture_output=True, text=True, check=True).stdout
    return Web3.to_checksum_address(json.loads(out)["result"])


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rpc", default="http://100.111.69.2:8547")
    p.add_argument("--target-wei", type=int, default=3 * 10 ** 16)
    p.add_argument("--execute", action="store_true")
    a = p.parse_args()
    assert 0 < a.target_wei <= 10 ** 18, "target is 0.03 CRYFT to start; never above 1 CRYFT here"
    w3 = Web3(Web3.HTTPProvider(a.rpc))
    assert w3.eth.chain_id == 113211
    assert "0x" + w3.eth.get_block(0)["hash"].hex().removeprefix("0x") == GENESIS_BLOCK
    recipient = settlement_address()
    balance = w3.eth.get_balance(recipient)
    amount = max(0, a.target_wei - balance)
    print(json.dumps({"settlement": recipient, "balance_wei": balance, "top_up_wei": amount}))
    if not amount or not a.execute:
        return
    key = subprocess.run(["security", "find-generic-password", "-a", PLAN["keychain"]["account"], "-s",
                          PLAN["keychain"]["service"], "-w"], capture_output=True, text=True, check=True).stdout.strip()
    account = Account.from_key(key)
    del key
    assert account.address == Web3.to_checksum_address(PLAN["deployer"])
    tx = {"to": recipient, "value": amount, "chainId": 113211, "gas": 21000, "maxFeePerGas": 2 * 10 ** 9,
          "maxPriorityFeePerGas": 10 ** 9, "nonce": w3.eth.get_transaction_count(account.address, "pending")}
    receipt = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(account.sign_transaction(tx).raw_transaction), timeout=300)
    assert receipt.status == 1
    print(json.dumps({"tx": "0x" + receipt.transactionHash.hex().removeprefix("0x"), "balance_wei": w3.eth.get_balance(recipient)}))


if __name__ == "__main__":
    main()
