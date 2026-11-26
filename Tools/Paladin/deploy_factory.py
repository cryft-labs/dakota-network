#!/usr/bin/env python3
"""Deploy Paladin's PenteFactory on chain 113211 (runbook Phase E.2) with the dev deployer.

The factory is Paladin's own contract (v1.0.0, artifacts from Tools/Paladin/build.py, checked against
artifact-lock.json). It is deployed as an implementation behind an ERC1967Proxy whose constructor runs
initialize() in the same transaction, so nobody can take ownership first. The proxy address is the Pente
registryAddress for Tools/Paladin/install-runtime.py; the deploy block is its blockIndexer.fromBlock.

Guards: chain id 113211 and the pinned block-0 hash (Contracts/Genesis/genesis-block.json); the signer is the
dev deployer from the macOS Keychain; a journal makes reruns resume.

    python Tools/Paladin/deploy_factory.py --dry-run
    python Tools/Paladin/deploy_factory.py --execute
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from eth_account import Account
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

REPO = Path(__file__).resolve().parents[2]
OUT = Path.home() / "Cryft/codex-outputs/paladin-113211"
LOCK = json.loads((REPO / "Tools/Paladin/artifact-lock.json").read_text())
PLAN = json.loads((REPO / "Tools/Genesis/link-plan.json").read_text())
GENESIS_BLOCK = json.loads((REPO / "Contracts/Genesis/genesis-block.json").read_text())["genesisBlockHash"]
CHAIN_ID = 113211
GWEI = 10 ** 9


def artifact(name):
    path = OUT / "artifacts" / name / "artifact.json"
    blob = path.read_bytes()
    if hashlib.sha256(blob).hexdigest() != LOCK[name]["artifact_sha256"]:
        raise SystemExit(f"{path} does not match artifact-lock.json: run Tools/Paladin/build.py")
    return json.loads(blob)


class Deployer:
    def __init__(self, args):
        self.args = args
        self.w3 = Web3(Web3.HTTPProvider(args.rpc, request_kwargs={"timeout": 60}))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        self.journal_path = Path(args.journal)
        self.journal = json.loads(self.journal_path.read_text()) if self.journal_path.exists() else {"steps": {}}
        key = subprocess.run(["security", "find-generic-password", "-a", PLAN["keychain"]["account"], "-s",
                              PLAN["keychain"]["service"], "-w"], capture_output=True, text=True, check=True).stdout.strip()
        self.account = Account.from_key(key)
        del key
        if self.account.address != Web3.to_checksum_address(PLAN["deployer"]):
            raise SystemExit("The Keychain key is not the planned deployer")
        self.factory_art, self.proxy_art = artifact("PenteFactory"), artifact("ERC1967Proxy")

    def check(self, name, ok, detail=None):
        print(("PASS " if ok else "FAIL ") + name + ("" if detail is None else f"  {detail}"), flush=True)
        self.journal.setdefault("checks", []).append({"check": name, "ok": bool(ok)})
        if not ok:
            self.save()
            raise SystemExit("stopped: " + name)

    def save(self):
        self.journal_path.parent.mkdir(parents=True, exist_ok=True)
        self.journal_path.write_text(json.dumps(self.journal, indent=1) + "\n")

    def send(self, data, label):
        tx = {"from": self.account.address, "data": data, "chainId": CHAIN_ID,
              "nonce": self.w3.eth.get_transaction_count(self.account.address, "pending"),
              "maxFeePerGas": 2 * GWEI, "maxPriorityFeePerGas": GWEI}
        tx["gas"] = min(int(self.w3.eth.estimate_gas(tx) * 1.25) + 50_000, 16_000_000)
        signed = self.account.sign_transaction({k: v for k, v in tx.items() if k != "from"})
        receipt = self.w3.eth.wait_for_transaction_receipt(self.w3.eth.send_raw_transaction(signed.raw_transaction), timeout=300)
        tx_hash = "0x" + receipt.transactionHash.hex().removeprefix("0x")
        self.check(f"{label}: transaction succeeded", receipt.status == 1, tx_hash)
        self.journal["steps"][label] = {"address": receipt.contractAddress, "tx": tx_hash, "block": receipt.blockNumber}
        self.save()
        return receipt

    def reverts(self, fn):
        try:
            fn.call({"from": self.account.address})
            return False
        except Exception:
            return True

    def run(self):
        w3 = self.w3
        self.check("chain id is 113211", w3.eth.chain_id == CHAIN_ID)
        block0 = w3.eth.get_block(0)["hash"].hex()
        self.check("block 0 is the pinned 113211 genesis", ("0x" + block0.removeprefix("0x")) == GENESIS_BLOCK)
        self.check("deployer has gas", w3.eth.get_balance(self.account.address) >= 10 ** 17)
        impl_factory = w3.eth.contract(abi=self.factory_art["abi"], bytecode=self.factory_art["creation_bytecode"])
        step = self.journal["steps"].get("deploy:PenteFactory")
        if self.args.dry_run:
            gas = w3.eth.estimate_gas({"from": self.account.address, "data": impl_factory.constructor().data_in_transaction})
            self.check(f"PenteFactory deployable (estimate {gas} gas)", gas < 16_000_000)
            return
        impl = step["address"] if step else self.send(impl_factory.constructor().data_in_transaction, "deploy:PenteFactory").contractAddress
        implementation = w3.eth.contract(address=impl, abi=self.factory_art["abi"])
        init = implementation.functions.initialize()._encode_transaction_data()
        proxy_step = self.journal["steps"].get("deploy:PenteFactoryProxy")
        if not proxy_step:
            proxy_factory = w3.eth.contract(abi=self.proxy_art["abi"], bytecode=self.proxy_art["creation_bytecode"])
            self.send(proxy_factory.constructor(impl, bytes.fromhex(init[2:])).data_in_transaction, "deploy:PenteFactoryProxy")
            proxy_step = self.journal["steps"]["deploy:PenteFactoryProxy"]
        factory = w3.eth.contract(address=proxy_step["address"], abi=self.factory_art["abi"])
        self.check("factory owner is the deployer (set atomically)", factory.functions.owner().call() == self.account.address)
        self.check("implementation cannot be initialized", self.reverts(implementation.functions.initialize()))
        self.check("proxy cannot be initialized again", self.reverts(factory.functions.initialize()))
        self.journal["factory"] = proxy_step["address"]
        self.journal["fromBlock"] = self.journal["steps"]["deploy:PenteFactory"]["block"]
        self.save()
        print(json.dumps({"factory": self.journal["factory"], "fromBlock": self.journal["fromBlock"]}))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--rpc", default="http://100.111.69.2:8547")
    p.add_argument("--journal", default=str(OUT / "factory-journal.json"))
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    Deployer(p.parse_args()).run()
