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

Phases (Chad 2026-11-26: his root wallet signs the links, so he goes through the steps of maintaining the chain):
  --phase deploy  --execute   the dev deployer deploys the implementations, beacon and dispatcher (no authority).
  --phase guide   --dry-run   writes Contracts/Genesis/root-link-guide.md: numbered steps for the root wallet with
                              the exact proxy, logic address, init data and raw calldata of each link.
  (Chad signs steps 1-4 from his wallet.)
  --phase verify  --execute   checks every link that is in, sends the CodeManager fee-vault ballot from the dev
                              deployer (the genesis voter) once CodeManager is linked, and lists what is pending.
  --phase links   --execute   REHEARSAL ONLY: a throwaway root signs exactly the guide's calldata.
  --dry-run on deploy estimates the deployments; --lock rewrites link-lock.json from the current sources.

Guards: chain id 113211; on the real chain the block 0 hash must equal Contracts/Genesis/genesis-block.json;
the link signer is a 0x…1111 root; artifacts match link-lock.json. The real root key never touches this tool,
and the real deployer key is never used on a local chain (its transactions would be valid on the real chain).

    python Tools/Genesis/link.py --rpc RPC --phase deploy --execute --journal J
    python Tools/Genesis/link.py --rpc RPC --phase guide  --dry-run --journal J
    python Tools/Genesis/link.py --rpc RPC --phase verify --execute --journal J
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
        """deployer: deploys implementations and sends the voter's ballot. root: signs the four links."""
        if self.args.rehearsal:
            keys = json.loads((Path(self.args.rehearsal) / "accounts.json").read_text())
            self.root_signer = Account.from_key("0x" + keys["root1"])   # stands in for Chad's root wallet
            self.deployer = Account.from_key("0x" + keys["voter1"])     # stands in for 0x6333 (deployer + voter)
            root, vote = self.root_signer.address, self.deployer.address
            self.plan["root"] = root
            self.plan["gasManager"]["voters"] = [vote]
            self.plan["codeManager"]["voters"] = [vote]
            self.plan["gasSponsor"]["platformAdmin"] = root
            self.plan["gasSponsor"]["voucherSigner"] = vote
            self.plan["registry"]["admin"] = root
        else:
            self.root_signer = None  # the real root key never touches this tool: Chad signs from his wallet
            if self.args.phase in ("deploy", "verify"):
                key = subprocess.run(["security", "find-generic-password", "-a", self.plan["keychain"]["account"],
                                      "-s", self.plan["keychain"]["service"], "-w"],
                                     capture_output=True, text=True, check=True).stdout.strip()
                self.deployer = Account.from_key(key)
                del key
                if self.deployer.address != A(self.plan["deployer"]):
                    raise SystemExit("The Keychain key is not the planned deployer")
            else:
                self.deployer = None
        self.root_address = A(self.plan["root"])

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
        self.check("link signer is a root of 0x…1111", reg.functions.isRootOverlord(self.root_address).call(), self.root_address)
        self.check("root has gas for the four links", w3.eth.get_balance(self.root_address) >= 10 ** 17,
                   w3.eth.get_balance(self.root_address))
        if self.deployer:
            self.check("deployer is the CodeManager voter (fee-vault ballot)",
                       [self.deployer.address] == [A(v) for v in self.plan["codeManager"]["voters"]])
        for address in (CAFE, CODE, FEED, ENTRY, FACE):
            self.check(f"{address} carries the genesis proxy code",
                       runtime_hash("0x" + w3.eth.get_code(address).hex().removeprefix("0x"))
                       == json.loads(MANIFEST.read_text())["runtimes"]["TransparentUpgradeableProxy"]["runtime_keccak256"])
        if self.deployer:
            balance = w3.eth.get_balance(self.deployer.address)
            self.check("deployer has at least 1 CRYFT for gas", balance >= 10 ** 18, balance)
        self.journal["chain"] = {"chainId": CHAIN_ID, "genesis": genesis, "root": self.root_address,
                                 "deployer": self.deployer.address if self.deployer else None,
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
            gas = self.w3.eth.estimate_gas({"from": self.deployer.address, "data": data})
            self.check(f"{label}: deployable (estimate {gas} gas)", gas < MAX_TX_GAS, gas)
            return None
        receipt = self.send(self.deployer, {"data": data}, label)
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

    def link_call(self, proxy_address, logic, init_fn):
        proxy = self.contract("TransparentUpgradeableProxy", proxy_address)
        init_data = init_fn._encode_transaction_data()
        return proxy, init_data, proxy.functions.proxy_linkLogicAdmin(logic.address, init_data)

    def linked(self, proxy_address, logic, label):
        proxy = self.contract("TransparentUpgradeableProxy", proxy_address)
        if not proxy.functions.proxy_getIsInit().call():
            return False
        current = self.contract("ProxyAdmin", PROXY_ADMIN).functions.getProxyImplementation(proxy_address).call()
        self.check(f"{label}: linked to the deployed implementation", current == logic.address, current)
        return True

    def link(self, proxy_address, logic, init_fn, label):
        """Rehearsal only: the throwaway root sends exactly the calldata the root guide gives Chad."""
        if self.linked(proxy_address, logic, label):
            print(f"skip link:{label}")
            return
        _, init_data, call = self.link_call(proxy_address, logic, init_fn)
        self.check(f"{label}: init data present", len(init_data) > 10)
        guide = self.journal.get("guide", {}).get(label)
        if guide:
            self.check(f"{label}: calldata equals the root guide's", guide["data"] == call._encode_transaction_data())
        self.send(self.root_signer, {"to": proxy_address, "data": call._encode_transaction_data()}, "link:" + label)
        self.linked(proxy_address, logic, label)

    def reverts(self, fn, sender):
        try:
            fn.call({"from": sender})
            return False
        except Exception:
            return True

    # ── the plan ───────────────────────────────────────────────────────────────────────────────────

    # ── the plan ───────────────────────────────────────────────────────────────────────────────────

    def deployed(self, name):
        address = self.journal["steps"].get("deploy:" + name, {}).get("address")
        if not address:
            raise SystemExit(f"{name} is not deployed yet: run --phase deploy --execute first")
        return self.contract(name, address)

    def deploy_all(self):
        """Implementations, beacon and dispatcher. Grants no authority; the dev deployer sends these."""
        self.deploy("GasManager")
        self.deploy("CodeManager")
        delegation = self.deploy("CryftDelegation")
        if self.args.dry_run:
            self.check("dry run: deployments estimated", True)
            return
        beacon = self.deploy("CryftDelegationBeacon", delegation.address)
        self.check("Beacon: owned by the registry entry 0x…de1E6A7E", beacon.functions.owner().call() == ENTRY)
        self.check("Beacon: points at the delegation logic", beacon.functions.implementation().call() == delegation.address)
        self.deploy("CryftBeaconDispatcher", beacon.address)
        self.deploy(self.plan["gasSponsor"]["logic"])
        self.deploy("CryftDelegationRegistry")

    def links(self):
        """The four root links in order: (label, proxy, logic, init call)."""
        p = self.plan
        gm, cm, gs, rg = p["gasManager"], p["codeManager"], p["gasSponsor"], p["registry"]
        gm_logic, cm_logic = self.deployed("GasManager"), self.deployed("CodeManager")
        gs_logic, rg_logic = self.deployed(gs["logic"]), self.deployed("CryftDelegationRegistry")
        beacon, dispatcher = self.deployed("CryftDelegationBeacon"), self.deployed("CryftBeaconDispatcher")
        return [
            ("GasManager@cafE", CAFE, gm_logic, gm_logic.functions.initializeWithVoters(
                [A(v) for v in gm["voters"]], gm["executionDelaySeconds"], int(gm["outflowCapWei"]), gm["outflowPeriodSeconds"])),
            ("CodeManager@c0DE", CODE, cm_logic, cm_logic.functions.initializeWithVoters([A(v) for v in cm["voters"]])),
            ("GasSponsor@FEeD", FEED, gs_logic, gs_logic.functions.initialize(
                A(gs["platformAdmin"]), A(gs["voucherSigner"]), dispatcher.address, gs["fixedOverheadGas"])),
            ("CryftDelegationRegistry@de1E6A7E", ENTRY, rg_logic, rg_logic.functions.initializeWithAdmin(
                dispatcher.address, beacon.address, FEED, A(rg["admin"]), rg["upgradeDelaySeconds"])),
        ]

    def write_guide(self):
        """Numbered steps for Chad's root wallet: exact addresses, field values and raw calldata."""
        self.journal["guide"] = {}
        lines = ["# Root link guide: link the Cryft genesis system contracts", "",
                 f"Sign every step from the root wallet **{self.root_address}** on chain **113211** (Cryft Network).",
                 "Value is 0 for every step. Do the steps in this order. After each one, tell the coordinator; the",
                 "tool then checks it (`link.py --phase verify`). After step 2 the dev deployer sends the CodeManager",
                 "fee-vault ballot for you (it is the genesis voter).", ""]
        for n, (label, proxy_address, logic, init_fn) in enumerate(self.links(), start=1):
            proxy, init_data, call = self.link_call(proxy_address, logic, init_fn)
            data = call._encode_transaction_data()
            inputs = next(f for f in proxy.abi if f.get("name") == "proxy_linkLogicAdmin")["inputs"]
            done = proxy.functions.proxy_getIsInit().call()
            gas = None if done else self.w3.eth.estimate_gas({"from": self.root_address, "to": proxy_address, "data": data})
            self.journal["guide"][label] = {"to": proxy_address, "data": data, "logic": logic.address, "gasEstimate": gas}
            lines += [f"## Step {n}: link {label.split('@')[0]} at {proxy_address}" + (" (already done)" if done else ""), "",
                      f"1. Open {self.args.explorer.rstrip('/')}/address/{proxy_address}?tab=write_contract and connect the root wallet.",
                      "2. Function **proxy_linkLogicAdmin**.",
                      f"3. `{inputs[0]['name']}` (address): `{logic.address}`",
                      f"4. `{inputs[1]['name']}` (bytes): `{init_data}`",
                      f"5. Value `0`. Gas limit about `{int(gas * 1.3) if gas else 'n/a'}`. Write, then confirm in the wallet.", "",
                      "If the explorer form is not available, send a plain transaction from the wallet instead:", "",
                      f"- To: `{proxy_address}`", "- Value: `0`", f"- Data: `{data}`", ""]
        lines += ["## After the last step", "",
                  "The tool checks every link: implementation initializers locked, a second initialization refused, voters,",
                  "admins and the paused GasSponsor read back as planned, and 0x…Face still unlinked.", ""]
        out = Path(self.args.guide)
        out.write_text("\n".join(lines))
        self.check(f"root guide written: {out}", True)

    def verify(self, send_ballot):
        """Checks whatever is linked so far; sends the voter's fee-vault ballot once CodeManager is linked."""
        pending = []
        for label, proxy_address, logic, init_fn in self.links():
            if not self.linked(proxy_address, logic, label):
                pending.append(label)
                continue
            slot0 = int.from_bytes(self.w3.eth.get_storage_at(logic.address, 0), "big")
            self.check(f"{label}: implementation initializer still locked", slot0 & 0xff == 0xff, hex(slot0))
            self.check(f"{label}: a second initialization is refused", self.reverts(init_fn, self.root_address))
        p = self.plan
        if "GasManager@cafE" not in pending:
            gm = self.contract("GasManager", CAFE)
            self.check("GasManager: voters as planned", gm.functions.getVoters().call() == [A(v) for v in p["gasManager"]["voters"]])
        if "CodeManager@c0DE" not in pending:
            cm = self.contract("CodeManager", CODE)
            self.check("CodeManager: voters as planned", cm.functions.getVoters().call() == [A(v) for v in p["codeManager"]["voters"]])
            if cm.functions.feeVault().call() != A(p["codeManager"]["feeVault"]):
                if not send_ballot:
                    pending.append("CodeManager fee-vault ballot (dev deployer)")
                else:
                    self.send(self.deployer, {"to": CODE, "data": cm.functions.voteToSetFeeVault(
                        A(p["codeManager"]["feeVault"]))._encode_transaction_data()}, "vote:CodeManager.feeVault")
            if cm.functions.feeVault().call() == A(p["codeManager"]["feeVault"]):
                self.check("CodeManager: fee vault is GasManager", True)
        if "GasSponsor@FEeD" not in pending:
            gs = self.contract(p["gasSponsor"]["logic"], FEED)
            self.check("GasSponsor: starts paused", gs.functions.paused().call())
            self.check("GasSponsor: platform admin is the root", gs.functions.platformAdmin().call() == A(p["gasSponsor"]["platformAdmin"]))
            self.check("GasSponsor: approved delegate is the dispatcher",
                       gs.functions.approvedDelegate().call() == self.deployed("CryftBeaconDispatcher").address)
            self.check("GasSponsor: version 1.5.2", gs.functions.implementationVersion().call() == "1.5.2")
        if "CryftDelegationRegistry@de1E6A7E" not in pending:
            rg = self.contract("CryftDelegationRegistry", ENTRY)
            self.check("Registry: admin is the root", rg.functions.registryAdmin().call() == A(p["registry"]["admin"]))
            self.check("Registry: upgrade delay as planned", rg.functions.upgradeDelay().call() == p["registry"]["upgradeDelaySeconds"])
        face = self.contract("TransparentUpgradeableProxy", FACE)
        self.check("0x…Face stays unlinked", not face.functions.proxy_getIsInit().call())
        self.journal["pending"] = pending
        if not pending:
            self.journal["completed"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        print("PENDING: " + ", ".join(pending) if pending else "ALL LINKED AND VERIFIED")

    def run(self):
        self.preflight()
        phase = self.args.phase
        if phase == "deploy":
            self.deploy_all()
        elif phase == "guide":
            self.write_guide()
        elif phase == "links":
            if not self.root_signer:
                raise SystemExit("--phase links signs as the root: rehearsal only. On the real chain Chad signs the guide.")
            for label, proxy_address, logic, init_fn in self.links():
                self.link(proxy_address, logic, init_fn, label)
                if label == "CodeManager@c0DE":
                    self.verify(send_ballot=True)
        elif phase == "verify":
            self.verify(send_ballot=bool(self.args.execute and self.deployer))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rpc")
    p.add_argument("--journal")
    p.add_argument("--rehearsal", help="run folder from localnet.py --kind rehearsal (throwaway signers)")
    p.add_argument("--phase", choices=["deploy", "guide", "links", "verify"])
    p.add_argument("--guide", default=str(REPO / "Contracts/Genesis/root-link-guide.md"))
    p.add_argument("--explorer", default="https://explore.cryft.cards", help="explorer base URL for the guide (Nebula-only for now)")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    mode.add_argument("--lock", action="store_true")
    a = p.parse_args()
    if a.lock:
        LOCK.write_text(json.dumps(lock_of(compile_all()), indent=1, sort_keys=True) + "\n")
        print("wrote", LOCK)
        return
    if not (a.rpc and a.journal and a.phase):
        raise SystemExit("--rpc, --journal and --phase are required")
    linker = Linker(a)
    try:
        linker.run()
    finally:
        linker.save()
    print("ALL CHECKS PASSED" if all(c["ok"] for c in linker.checks) else "SOME CHECKS FAILED")


if __name__ == "__main__":
    main()
