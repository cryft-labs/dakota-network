#!/usr/bin/env python3
"""D.7 bootstrap: link the genesis system proxies with their first implementations (runbook D.7, audit N-11).

Replaces Tools/LiveGenesis/initialize.py. Every proxy is linked WITH init data in the same transaction
(audit X-16), and after every step the tool checks that the implementation's initializer is locked, that a
second initialization reverts, and that the proxy now reads back exactly the planned state.

Order:
  1. GasManager        -> 0x…cafE      initializeWithVoters(voters, executionDelay, outflowCap, outflowPeriod)
  2. CodeManager       -> 0x…c0DE      initializeWithVoters(voters); then the voter's voteToSetFeeVault(0x…cafE)
  3. CryftDelegation logic, CryftDelegationBeacon(logic), CryftBeaconDispatcher(beacon)  (beacon owned by 0x…de1E6A7E)
  4. ProgramGasSponsor -> 0x…FEeD      initialize(platformAdmin, voucherSigner, dispatcher, overhead)  (starts paused)
  5. CryftDelegationRegistry -> 0x…de1E6A7E  initializeWithAdmin(dispatcher, beacon, 0x…FEeD, admin, upgradeDelay)
0x…Face stays unlinked.

Modes:
  --dry-run   checks everything that can be checked without sending: chain id, genesis guard, signer is a root,
              proxies unlinked, balances, artifacts match Tools/Genesis/link-lock.json; estimates each deployment.
  --execute   sends. Re-running resumes from the journal (deployed code is re-verified against the lock).
  --lock      (re)writes link-lock.json from the current sources.

Signers:
  production  the dev deployer from the macOS Keychain (link-plan.json "keychain"); the chain must be the real
              113211 genesis (block 0 hash pinned in Contracts/Genesis/genesis-block.json).
  rehearsal   --rehearsal RUN uses the run folder's throwaway root and voter (Tools/Genesis/localnet.py). The real
              deployer key is never used on a local chain: its transactions would be valid on the real chain.

    python Tools/Genesis/link.py --rpc http://127.0.0.1:18545 --rehearsal RUN --execute --journal RUN/link-journal.json
    python Tools/Genesis/link.py --rpc <archive RPC> --dry-run --journal <path>
"""
import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
import time
from pathlib import Path

from eth_account import Account
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

REPO = Path(__file__).resolve().parents[2]
PLAN = REPO / "Tools/Genesis/link-plan.json"
LOCK = REPO / "Tools/Genesis/link-lock.json"
MANIFEST = REPO / "Contracts/Genesis/genesis-release.json"
GENESIS_BLOCK = REPO / "Contracts/Genesis/genesis-block.json"  # block 0 hash, recorded by rehearse.py --kind production
CHAIN_ID = 113211
GWEI = 10 ** 9
MAX_TX_GAS = 16_000_000  # under Osaka's per-transaction cap (EIP-7825)
A = Web3.to_checksum_address
REGISTRY_1111 = A("0x" + "0" * 36 + "1111")
PROXY_ADMIN = A("0x" + "0" * 34 + "facade")
CAFE, CODE, FEED, ENTRY, FACE = (A("0x" + "0" * 36 + "cafe"), A("0x" + "0" * 36 + "c0de"),
                                 A("0x" + "0" * 36 + "feed"), A("0x" + "0" * 32 + "de1e6a7e"),
                                 A("0x" + "0" * 36 + "face"))
SOURCES = {
    "GasManager": "Contracts/Genesis/GasManager/GasManager.sol",
    "CodeManager": "Contracts/CodeManagement/CodeManager.sol",
    "CryftDelegation": "Contracts/Genesis/7702/CryftDelegation.sol",
    "CryftDelegationBeacon": "Contracts/Genesis/7702/CryftDelegationBeacon.sol",
    "CryftBeaconDispatcher": "Contracts/Genesis/7702/CryftBeaconDispatcher.sol",
    "ProgramGasSponsor": "Contracts/Genesis/7702/ProgramGasSponsor.sol",
    "CryftDelegationRegistry": "Contracts/Genesis/7702/CryftDelegationRegistry.sol",
    "TransparentUpgradeableProxy": "Contracts/Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol",
    "ProxyAdmin": "Contracts/Genesis/Upgradeable/Proxy/Transparent/ProxyAdmin.sol",
}
INITIALIZABLE = ("GasManager", "CodeManager", "ProgramGasSponsor", "CryftDelegationRegistry")
VALIDATOR_ABI = [{"type": "function", "name": n, "stateMutability": "view", "inputs": i, "outputs": o} for n, i, o in [
    ("isRootOverlord", [{"name": "a", "type": "address"}], [{"name": "", "type": "bool"}]),
    ("getVoters", [], [{"name": "", "type": "address[]"}]),
    ("getRootOverlords", [], [{"name": "", "type": "address[]"}])]]


def compile_all():
    spec = importlib.util.spec_from_file_location("compiler", REPO / "Tools/SolcCompiler/compile.py")
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)
    out = {}
    for name, path in SOURCES.items():
        result = compiler.compile_contract(REPO / path, solc_version="0.8.37", evm_version="osaka")
        out[name] = {"abi": result[name]["abi"], "creation": result[name]["creation_bytecode"],
                     "runtime": result[name]["runtime_bytecode"]}
    return out


def runtime_hash(hexcode):
    return "0x" + Web3.keccak(hexstr=hexcode).hex().removeprefix("0x")


def lock_of(art):
    return {name: {"runtime_keccak256": runtime_hash(a["runtime"]), "creation_sha256":
                   hashlib.sha256(bytes.fromhex(a["creation"][2:])).hexdigest(), "runtime_bytes": len(a["runtime"]) // 2 - 1}
            for name, a in art.items()}


class Linker:
    def __init__(self, args):
        self.args = args
        self.plan = json.loads(PLAN.read_text())
        self.w3 = Web3(Web3.HTTPProvider(args.rpc, request_kwargs={"timeout": 60}))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        self.journal_path = Path(args.journal)
        self.journal = json.loads(self.journal_path.read_text()) if self.journal_path.exists() else {"steps": {}}
        self.checks = []
        print("compiling…", flush=True)
        self.art = compile_all()
        lock = json.loads(LOCK.read_text())
        mismatch = [n for n, v in lock_of(self.art).items() if lock.get(n) != v]
        if mismatch:
            raise SystemExit("Sources differ from link-lock.json (run --lock after review): " + ", ".join(mismatch))
        self._signers()

    # ── setup ──────────────────────────────────────────────────────────────────────────────────────

    def _signers(self):
        if self.args.rehearsal:
            keys = json.loads((Path(self.args.rehearsal) / "accounts.json").read_text())
            self.root = Account.from_key("0x" + keys["root1"])
            self.voter = Account.from_key("0x" + keys["voter1"])
            me, vote = self.root.address, self.voter.address
            self.plan["gasManager"]["voters"] = [vote]
            self.plan["codeManager"]["voters"] = [vote]
            self.plan["gasSponsor"]["platformAdmin"] = me
            self.plan["gasSponsor"]["voucherSigner"] = me
            self.plan["registry"]["admin"] = me
        else:
            key = subprocess.run(["security", "find-generic-password", "-a", self.plan["keychain"]["account"],
                                  "-s", self.plan["keychain"]["service"], "-w"],
                                 capture_output=True, text=True, check=True).stdout.strip()
            self.root = Account.from_key(key)
            del key
            if self.root.address != A(self.plan["deployer"]):
                raise SystemExit("The Keychain key is not the planned deployer")
            self.voter = self.root

    def check(self, name, ok, detail=None):
        self.checks.append({"check": name, "ok": bool(ok), **({"detail": detail} if detail is not None else {})})
        print(("PASS " if ok else "FAIL ") + name + ("" if detail is None else f"  {detail}"), flush=True)
        if not ok:
            self.save()
            raise SystemExit(f"stopped: {name}")

    def save(self):
        self.journal["checks"] = self.checks
        self.journal_path.write_text(json.dumps(self.journal, indent=1) + "\n")

    def contract(self, name, address):
        return self.w3.eth.contract(address=address, abi=self.art[name]["abi"])

    def preflight(self):
        w3 = self.w3
        self.check("chain id is 113211", w3.eth.chain_id == CHAIN_ID, w3.eth.chain_id)
        genesis = w3.eth.get_block(0)["hash"].hex()
        genesis = genesis if genesis.startswith("0x") else "0x" + genesis
        if self.args.rehearsal:
            run_manifest = json.loads((Path(self.args.rehearsal) / "manifest.json").read_text())
            reg = w3.eth.contract(REGISTRY_1111, abi=VALIDATOR_ABI)
            self.check("rehearsal chain: roots are the run's throwaway roots",
                       reg.functions.getRootOverlords().call() == run_manifest["roots"])
            self.check("rehearsal chain is not the real genesis",
                       genesis != json.loads(GENESIS_BLOCK.read_text())["genesisBlockHash"])
        else:
            pinned = json.loads(GENESIS_BLOCK.read_text())
            if pinned["genesis_sha256"] != json.loads(MANIFEST.read_text())["genesis_sha256"]:
                raise SystemExit("genesis-block.json was recorded for a different genesis file")
            pinned = pinned["genesisBlockHash"]
            self.check("genesis block hash is the pinned 113211 genesis", pinned and genesis == pinned, genesis)
        reg = w3.eth.contract(REGISTRY_1111, abi=VALIDATOR_ABI)
        self.check("signer is a root of 0x…1111", reg.functions.isRootOverlord(self.root.address).call(), self.root.address)
        self.check("CodeManager voter signs the fee-vault ballot",
                   [self.voter.address] == self.plan["codeManager"]["voters"])
        for address in (CAFE, CODE, FEED, ENTRY, FACE):
            self.check(f"{address} carries the genesis proxy code",
                       runtime_hash("0x" + w3.eth.get_code(address).hex().removeprefix("0x"))
                       == json.loads(MANIFEST.read_text())["runtimes"]["TransparentUpgradeableProxy"]["runtime_keccak256"])
        balance = w3.eth.get_balance(self.root.address)
        self.check("signer has at least 1 CRYFT for gas", balance >= 10 ** 18, balance)
        self.journal["chain"] = {"chainId": CHAIN_ID, "genesis": genesis, "signer": self.root.address,
                                 "rehearsal": bool(self.args.rehearsal)}

    # ── sending ────────────────────────────────────────────────────────────────────────────────────

    def send(self, account, tx, label):
        tx = dict(tx, chainId=CHAIN_ID, nonce=self.w3.eth.get_transaction_count(account.address, "pending"),
                  **{"from": account.address},
                  maxFeePerGas=2 * GWEI, maxPriorityFeePerGas=GWEI)
        tx["gas"] = min(int(self.w3.eth.estimate_gas({k: v for k, v in tx.items() if k != "gas"}) * 1.25) + 50_000, MAX_TX_GAS)
        signed = account.sign_transaction({k: v for k, v in tx.items() if k != "from"})
        h = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(h, timeout=300)
        hexhash = "0x" + receipt.transactionHash.hex().removeprefix("0x")
        self.journal["steps"].setdefault(label, {})["tx"] = hexhash
        self.check(f"{label}: transaction succeeded", receipt.status == 1, hexhash)
        return receipt

    def deploy(self, name, *args):
        label = "deploy:" + name
        recorded = self.journal["steps"].get(label, {}).get("address")
        lock = json.loads(LOCK.read_text())[name]["runtime_keccak256"]
        if recorded:
            code = "0x" + self.w3.eth.get_code(recorded).hex().removeprefix("0x")
            immutable = name in ("CryftDelegation", "CryftDelegationBeacon", "CryftBeaconDispatcher")
            if code != "0x" and (immutable or runtime_hash(code) == lock):
                print(f"skip {label} (journal {recorded})")
                return self.contract(name, recorded)
        factory = self.w3.eth.contract(abi=self.art[name]["abi"], bytecode=self.art[name]["creation"])
        data = factory.constructor(*args).data_in_transaction
        if self.args.dry_run:
            gas = self.w3.eth.estimate_gas({"from": self.root.address, "data": data})
            self.check(f"{label}: deployable (estimate {gas} gas)", gas < MAX_TX_GAS, gas)
            return None
        receipt = self.send(self.root, {"data": data}, label)
        address = receipt.contractAddress
        self.journal["steps"][label]["address"] = address
        self.save()
        code = "0x" + self.w3.eth.get_code(address).hex().removeprefix("0x")
        if name not in ("CryftDelegation", "CryftDelegationBeacon", "CryftBeaconDispatcher"):  # these embed immutables
            self.check(f"{name}: deployed runtime matches link-lock.json", runtime_hash(code) == lock)
        if name in INITIALIZABLE:
            slot0 = int.from_bytes(self.w3.eth.get_storage_at(address, 0), "big")
            self.check(f"{name}: implementation initializer locked (Initializable._initialized == 255)", slot0 & 0xff == 0xff, hex(slot0))
        return self.contract(name, address)

    def link(self, proxy_address, logic, init_fn, label):
        proxy = self.contract("TransparentUpgradeableProxy", proxy_address)
        admin = self.contract("ProxyAdmin", PROXY_ADMIN)
        if proxy.functions.proxy_getIsInit().call():
            current = admin.functions.getProxyImplementation(proxy_address).call()
            self.check(f"{label}: already linked to the journal's implementation", current == logic.address, current)
            print(f"skip link:{label}")
            return
        data = init_fn._encode_transaction_data()
        self.check(f"{label}: init data present", len(data) > 10)
        self.send(self.root, {"to": proxy_address, "data": proxy.functions.proxy_linkLogicAdmin(logic.address, data)._encode_transaction_data()},
                  "link:" + label)
        self.check(f"{label}: proxy reports linked", proxy.functions.proxy_getIsInit().call())
        self.check(f"{label}: implementation is the deployed logic",
                   admin.functions.getProxyImplementation(proxy_address).call() == logic.address)

    def reverts(self, fn, sender):
        try:
            fn.call({"from": sender})
            return False
        except Exception:
            return True

    # ── the plan ───────────────────────────────────────────────────────────────────────────────────

    def run(self):
        self.preflight()
        p = self.plan
        gm_plan, cm_plan, gs_plan, rg_plan = p["gasManager"], p["codeManager"], p["gasSponsor"], p["registry"]
        voters_gm = [A(v) for v in gm_plan["voters"]]
        voters_cm = [A(v) for v in cm_plan["voters"]]

        gm_logic = self.deploy("GasManager")
        cm_logic = self.deploy("CodeManager")
        delegation = self.deploy("CryftDelegation")
        if self.args.dry_run:
            self.check("dry run: deployments estimated; links, votes and init checks run in --execute", True)
            return
        gm_init = gm_logic.functions.initializeWithVoters(voters_gm, gm_plan["executionDelaySeconds"],
                                                          int(gm_plan["outflowCapWei"]), gm_plan["outflowPeriodSeconds"])
        self.link(CAFE, gm_logic, gm_init, "GasManager@cafE")
        gm = self.contract("GasManager", CAFE)
        self.check("GasManager: voters as planned", gm.functions.getVoters().call() == voters_gm)
        self.check("GasManager: second initialization reverts", self.reverts(gm_init, self.root.address))
        self.check("GasManager: implementation cannot be initialized", self.reverts(
            self.contract("GasManager", gm_logic.address).functions.initializeWithVoters(voters_gm, 0, 1, 3600), self.root.address))

        cm_init = cm_logic.functions.initializeWithVoters(voters_cm)
        self.link(CODE, cm_logic, cm_init, "CodeManager@c0DE")
        cm = self.contract("CodeManager", CODE)
        self.check("CodeManager: voters as planned", cm.functions.getVoters().call() == voters_cm)
        self.check("CodeManager: second initialization reverts", self.reverts(cm_init, self.root.address))
        if cm.functions.feeVault().call() != A(cm_plan["feeVault"]):
            self.send(self.voter, {"to": CODE, "data": cm.functions.voteToSetFeeVault(A(cm_plan["feeVault"]))._encode_transaction_data()},
                      "vote:CodeManager.feeVault")
        self.check("CodeManager: fee vault is GasManager", cm.functions.feeVault().call() == A(cm_plan["feeVault"]))

        beacon = self.deploy("CryftDelegationBeacon", delegation.address)
        self.check("Beacon: owned by the registry entry 0x…de1E6A7E", beacon.functions.owner().call() == ENTRY)
        self.check("Beacon: points at the delegation logic", beacon.functions.implementation().call() == delegation.address)
        dispatcher = self.deploy("CryftBeaconDispatcher", beacon.address)

        gs_logic = self.deploy(gs_plan["logic"])
        gs_init = gs_logic.functions.initialize(A(gs_plan["platformAdmin"]), A(gs_plan["voucherSigner"]),
                                                dispatcher.address, gs_plan["fixedOverheadGas"])
        self.link(FEED, gs_logic, gs_init, "GasSponsor@FEeD")
        gs = self.contract(gs_plan["logic"], FEED)
        self.check("GasSponsor: starts paused", gs.functions.paused().call())
        self.check("GasSponsor: platform admin as planned", gs.functions.platformAdmin().call() == A(gs_plan["platformAdmin"]))
        self.check("GasSponsor: approved delegate is the dispatcher", gs.functions.approvedDelegate().call() == dispatcher.address)
        self.check("GasSponsor: version 1.5.2", gs.functions.implementationVersion().call() == "1.5.2")
        self.check("GasSponsor: second initialization reverts", self.reverts(gs_init, self.root.address))

        rg_logic = self.deploy("CryftDelegationRegistry")
        rg_init = rg_logic.functions.initializeWithAdmin(dispatcher.address, beacon.address, FEED, A(rg_plan["admin"]),
                                                         rg_plan["upgradeDelaySeconds"])
        self.link(ENTRY, rg_logic, rg_init, "CryftDelegationRegistry@de1E6A7E")
        rg = self.contract("CryftDelegationRegistry", ENTRY)
        self.check("Registry: admin as planned", rg.functions.registryAdmin().call() == A(rg_plan["admin"]))
        self.check("Registry: upgrade delay as planned", rg.functions.upgradeDelay().call() == rg_plan["upgradeDelaySeconds"])
        self.check("Registry: second initialization reverts", self.reverts(rg_init, self.root.address))

        face = self.contract("TransparentUpgradeableProxy", FACE)
        self.check("0x…Face stays unlinked", not face.functions.proxy_getIsInit().call())
        self.journal["addresses"] = {"GasManagerLogic": gm_logic.address, "CodeManagerLogic": cm_logic.address,
                                     "CryftDelegation": delegation.address, "CryftDelegationBeacon": beacon.address,
                                     "CryftBeaconDispatcher": dispatcher.address, "GasSponsorLogic": gs_logic.address,
                                     "CryftDelegationRegistryLogic": rg_logic.address}
        self.journal["completed"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rpc")
    p.add_argument("--journal")
    p.add_argument("--rehearsal", help="run folder from localnet.py --kind rehearsal (throwaway signers)")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    mode.add_argument("--lock", action="store_true")
    a = p.parse_args()
    if a.lock:
        LOCK.write_text(json.dumps(lock_of(compile_all()), indent=1, sort_keys=True) + "\n")
        print("wrote", LOCK)
        return
    if not (a.rpc and a.journal):
        raise SystemExit("--rpc and --journal are required")
    linker = Linker(a)
    try:
        linker.run()
    finally:
        linker.save()
    print("ALL CHECKS PASSED" if all(c["ok"] for c in linker.checks) else "SOME CHECKS FAILED")


if __name__ == "__main__":
    main()
