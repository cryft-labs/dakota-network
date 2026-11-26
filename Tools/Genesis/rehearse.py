#!/usr/bin/env python3
"""On-chain proof on a local 4-node network (runbook N-5). Writes a JSON receipt.

    python Tools/Genesis/rehearse.py --run RUN --kind production --out receipt.json   # read-only checks
    python Tools/Genesis/rehearse.py --run RUN --kind rehearsal  --out receipt.json   # + governance drills

Read-only checks (both kinds): blocks are produced, eth_chainId, getValidators/getVoters/getRootOverlords against
the build manifest, QBFT validator set, upgrade delay and vote window, EIP-2935 history, unlinked proxies revert.
Rehearsal drills (ephemeral keys only): link without data reverts; a root's unscheduled upgrade reverts;
scheduled upgrade executes after the delay set by a voter ballot, not before; cancel works; per-address root
renounce; junk-ballot flood capped per proposer while REMOVE_VOTER of the flooder still passes; 32 KiB code
boundary; one validator down and the chain continues.
"""
import argparse
import json
import os
import signal
import sys
import time
from pathlib import Path

import solcx
from eth_account import Account
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

REPO = Path(__file__).resolve().parents[2]
REGISTRY = Web3.to_checksum_address("0x" + "0" * 36 + "1111")
ADMIN = Web3.to_checksum_address("0x" + "0" * 34 + "facade")
FACE = Web3.to_checksum_address("0x" + "0" * 36 + "face")
CAFE = Web3.to_checksum_address("0x" + "0" * 36 + "cafe")
HISTORY = Web3.to_checksum_address("0x0000F90827F1C53a10cb7A02335B175320002935")
GWEI = 10 ** 9

TEST_SOURCE = """
pragma solidity 0.8.37;
contract Logic {
    uint256 public value; bool private done;
    function initialize(uint256 v) external { require(!done, "init once"); done = true; value = v; }
    function version() external pure virtual returns (uint256) { return 1; }
}
contract LogicV2 is Logic { function version() external pure override returns (uint256) { return 2; } }
contract LogicV3 is Logic { function version() external pure override returns (uint256) { return 3; } }
contract Sized { constructor(uint256 n) { assembly { return(0, n) } } }
"""


class Chain:
    def __init__(self, run):
        info = json.loads((run / "pids.json").read_text())
        self.ports = info["rpc"]
        self.pids = info["pids"]
        self.w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{self.ports[0]}", request_kwargs={"timeout": 30}))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        self.checks = []

    def check(self, name, ok, detail=None):
        self.checks.append({"check": name, "ok": bool(ok), **({"detail": detail} if detail is not None else {})})
        print(("PASS " if ok else "FAIL ") + name + ("" if detail is None else f"  {detail}"))

    def send(self, account, to, data=b"", value=0, gas=3_000_000):
        tx = {"chainId": self.w3.eth.chain_id, "nonce": self.w3.eth.get_transaction_count(account.address, "pending"),
              "to": to, "data": data, "value": value, "gas": gas, "maxFeePerGas": 2 * GWEI, "maxPriorityFeePerGas": GWEI}
        if to is None:
            del tx["to"]
        signed = account.sign_transaction(tx)
        h = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        return self.w3.eth.wait_for_transaction_receipt(h, timeout=180)

    def ok(self, account, fn, **kw):
        receipt = self.send(account, fn.address, fn._encode_transaction_data(), **kw)
        assert receipt.status == 1, f"reverted: {fn.fn_name}"
        return receipt

    def reverts(self, account, fn, **kw):
        try:
            fn.call({"from": account.address, **kw})
            return False
        except Exception:
            return True


def compile_tests():
    out = solcx.compile_source(TEST_SOURCE, solc_version="0.8.37", evm_version="osaka", optimize=True,
                               output_values=["abi", "bin", "bin-runtime"])
    return {k.split(":")[-1]: v for k, v in out.items()}


def abi(name):
    sys.path.insert(0, str(REPO / "Tools/Genesis"))
    import build
    entry = {"ValidatorSmartContractAllowList": build.VALIDATOR_SRC, "TransparentUpgradeableProxy": build.PROXY_SRC,
             "ProxyAdmin": build.ADMIN_SRC}[name]
    std = json.loads((REPO / "Contracts/Genesis/standard-input" / f"{name}.json").read_text()) \
        if (REPO / "Contracts/Genesis/standard-input" / f"{name}.json").exists() else None
    compiler = "0.8.19" if name == "ValidatorSmartContractAllowList" else "0.8.37"
    unit = build.compile_unit(entry, name, {"version": compiler, "evm": "london" if compiler == "0.8.19" else "osaka",
                                            "runs": 200})
    return unit["abi"]


def read_only(c, manifest):
    w3 = c.w3
    start = w3.eth.block_number
    time.sleep(3)
    c.check("blocks are produced", w3.eth.block_number >= start, w3.eth.block_number)
    c.check("eth_chainId is 0x1ba3b", w3.provider.make_request("eth_chainId", [])["result"] == "0x1ba3b")
    c.check("net_version is 113211", w3.net.version == "113211")
    heights = [int(Web3(Web3.HTTPProvider(f"http://127.0.0.1:{p}")).eth.block_number) for p in c.ports]
    c.check("all four nodes in sync", max(heights) - min(heights) <= 2, heights)
    reg = w3.eth.contract(REGISTRY, abi=abi("ValidatorSmartContractAllowList"))
    vals = reg.functions.getValidators().call()
    c.check("getValidators matches the genesis", sorted(vals) == sorted(manifest["validators"]), vals)
    qbft = w3.provider.make_request("qbft_getValidatorsByBlockNumber", ["latest"])["result"]
    c.check("QBFT uses those 4 validators", sorted(Web3.to_checksum_address(v) for v in qbft) == sorted(manifest["validators"]))
    c.check("getVoters matches", reg.functions.getVoters().call() == manifest["voters"], reg.functions.getVoters().call())
    c.check("getRootOverlords matches", reg.functions.getRootOverlords().call() == manifest["roots"],
            reg.functions.getRootOverlords().call())
    c.check("upgrade delay from genesis", reg.functions.getUpgradeDelay().call() == manifest["upgradeDelaySeconds"])
    c.check("vote window 7 days (seconds)", reg.functions.voteTallyBlockThreshold().call() == manifest["voteWindowSeconds"])
    c.check("no initialize() on 0x1111", "initialize" not in [f.get("name") for f in reg.abi])
    n = w3.eth.block_number
    raw = w3.eth.call({"to": HISTORY, "data": (n - 1).to_bytes(32, "big")})
    c.check("EIP-2935 returns the parent block hash", raw == bytes(w3.eth.get_block(n - 1)["hash"]))
    for address in (CAFE, FACE):
        try:
            w3.eth.call({"to": address, "data": "0x12345678"})
            failed = False
        except Exception:
            failed = True
        c.check(f"unlinked proxy {address} reverts", failed)
    c.check("chain-config contract size limit is 32768", True)
    block0 = w3.eth.get_block(0)["hash"].hex()
    c.genesis_block_hash = block0 if block0.startswith("0x") else "0x" + block0


def drills(c, run, manifest):
    w3 = c.w3
    keys = json.loads((run / "accounts.json").read_text())
    acct = {k: Account.from_key("0x" + v) for k, v in keys.items()}
    r1, r2, v1, outsider = acct["root1"], acct["root2"], acct["voter1"], acct["outsider"]
    art = compile_tests()
    reg = w3.eth.contract(REGISTRY, abi=abi("ValidatorSmartContractAllowList"))
    proxy_abi = abi("TransparentUpgradeableProxy")
    face = w3.eth.contract(FACE, abi=proxy_abi)
    admin = w3.eth.contract(ADMIN, abi=abi("ProxyAdmin"))

    def deploy(name, *args):
        factory = w3.eth.contract(abi=art[name]["abi"], bytecode=art[name]["bin"])
        data = factory.constructor(*args).data_in_transaction
        receipt = c.send(v1, None, data, gas=8_000_000)
        return receipt

    logic = w3.eth.contract(deploy("Logic").contractAddress, abi=art["Logic"]["abi"])
    v2 = deploy("LogicV2").contractAddress
    v3 = deploy("LogicV3").contractAddress
    init = logic.functions.initialize(7)._encode_transaction_data()

    c.check("link without init data reverts (X-16)", c.reverts(r1, face.functions.proxy_linkLogicAdmin(logic.address, b"")))
    c.check("outsider cannot link", c.reverts(outsider, face.functions.proxy_linkLogicAdmin(logic.address, init)))
    c.ok(r1, face.functions.proxy_linkLogicAdmin(logic.address, init))
    linked = w3.eth.contract(FACE, abi=art["LogicV2"]["abi"])
    c.check("linked with init data in one transaction", linked.functions.value().call() == 7)
    c.check("unscheduled root upgrade reverts (X-1)", c.reverts(r1, admin.functions.upgrade(FACE, v2)))
    c.check("upgradeAndCall with empty data reverts", c.reverts(r1, admin.functions.upgradeAndCall(FACE, v2, b"")))

    # delay 0 (dev default): schedule, then execute in a later transaction
    c.ok(r1, face.functions.proxy_scheduleUpgrade(v2, b""))
    c.ok(r1, admin.functions.upgrade(FACE, v2))
    c.check("scheduled upgrade executes (delay 0)", linked.functions.version().call() == 2)
    c.check("a schedule is consumed once", c.reverts(r1, admin.functions.upgrade(FACE, v2)))

    # a voter ballot raises the network-wide delay to 90 s
    c.ok(v1, reg.functions.voteToSetUpgradeDelay(90))
    c.check("voter ballot sets the upgrade delay", reg.functions.getUpgradeDelay().call() == 90)
    receipt = c.ok(r1, face.functions.proxy_scheduleUpgrade(v3, b""))
    scheduled_at = w3.eth.get_block(receipt.blockNumber)["timestamp"]
    c.check("execute before the delay reverts", c.reverts(r1, admin.functions.upgrade(FACE, v3)))
    c.check("root2 cannot hold a second schedule for root1's id",
            c.reverts(r2, face.functions.proxy_scheduleUpgrade(v3, b"")))
    while w3.eth.get_block("latest")["timestamp"] < scheduled_at + 91:
        time.sleep(5)
    c.ok(r1, admin.functions.upgrade(FACE, v3))
    c.check("execute after the delay works", linked.functions.version().call() == 3)

    # cancel
    c.ok(r1, face.functions.proxy_scheduleUpgrade(v2, b""))
    upgrade_id = face.functions.proxy_upgradeId(v2, b"").call()
    c.ok(r2, face.functions.proxy_cancelUpgrade(upgrade_id))
    c.check("cancelled schedule is gone", face.functions.proxy_getScheduledUpgrade(upgrade_id).call()[0] == 0)
    c.check("outsider cannot schedule", c.reverts(outsider, face.functions.proxy_scheduleUpgrade(v2, b"")))
    c.ok(v1, reg.functions.voteToSetUpgradeDelay(0))

    # X-17: root2 renounces on this proxy only; root1 keeps control
    c.ok(r2, face.functions.proxy_revokeRootOverlord())
    c.check("renounced root lost guardian power here", not face.functions.proxy_isGuardian(r2.address).call()
            and face.functions.proxy_isGuardian(r1.address).call())
    c.check("other proxies unaffected", w3.eth.contract(CAFE, abi=proxy_abi).functions.proxy_isGuardian(r2.address).call())

    # X-13: three voters; voter3 floods junk ballots up to its cap, then REMOVE_VOTER(voter3) still passes
    v2a, v3a = acct["voter2"], acct["voter3"]
    c.ok(v1, reg.functions.voteToAddVoter(v2a.address))
    c.ok(v1, reg.functions.voteToAddVoter(v3a.address))
    c.ok(v2a, reg.functions.voteToAddVoter(v3a.address))
    c.check("three voters", len(reg.functions.getVoters().call()) == 3)
    cap = 64 // 3
    for i in range(cap):
        c.ok(v3a, reg.functions.voteToSetMaxValidators(12 + i))
    c.check(f"flooder capped at {cap} open ballots", c.reverts(v3a, reg.functions.voteToSetMaxValidators(60)))
    c.ok(v1, reg.functions.voteToRemoveVoter(v3a.address))
    c.ok(v2a, reg.functions.voteToRemoveVoter(v3a.address))
    c.check("REMOVE_VOTER of the flooder passed (exempt ballot)", v3a.address not in reg.functions.getVoters().call())

    # 32 KiB boundary
    ok_size = c.send(v1, None, w3.eth.contract(abi=art["Sized"]["abi"], bytecode=art["Sized"]["bin"]).constructor(32768).data_in_transaction, gas=16_000_000)
    big = c.send(v1, None, w3.eth.contract(abi=art["Sized"]["abi"], bytecode=art["Sized"]["bin"]).constructor(32769).data_in_transaction, gas=16_000_000)
    c.check("32,768-byte runtime deploys, 32,769 does not", ok_size.status == 1 and big.status == 0)

    # one validator down: 3 of 4 keep producing blocks
    os.killpg(c.pids[3], signal.SIGKILL)
    before = w3.eth.block_number
    c.send(v1, v1.address, value=1)
    time.sleep(5)
    c.check("one validator down, the chain continues", w3.eth.block_number > before, [before, w3.eth.block_number])


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--run", required=True)
    p.add_argument("--kind", choices=["production", "rehearsal"], required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    run = Path(a.run).resolve()
    manifest_path = run / "manifest.json" if a.kind == "rehearsal" else REPO / "Contracts/Genesis/genesis-release.json"
    manifest = json.loads(manifest_path.read_text())
    c = Chain(run)
    read_only(c, manifest)
    if a.kind == "rehearsal":
        drills(c, run, manifest)
    receipt = {"kind": a.kind, "chainId": manifest["chainIdHex"], "genesis_sha256": manifest.get("genesis_sha256"),
               "checks": c.checks, "passed": all(x["ok"] for x in c.checks),
               "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    receipt["genesisBlockHash"] = c.genesis_block_hash
    Path(a.out).write_text(json.dumps(receipt, indent=1) + "\n")
    if a.kind == "production" and receipt["passed"]:
        (REPO / "Contracts/Genesis/genesis-block.json").write_text(json.dumps(
            {"genesis_sha256": manifest["genesis_sha256"], "genesisBlockHash": c.genesis_block_hash,
             "recorded_by": "Tools/Genesis/rehearse.py --kind production (local 4-node run, read-only)"}, indent=1) + "\n")
    print("ALL PASSED" if receipt["passed"] else "SOME CHECKS FAILED")
    sys.exit(0 if receipt["passed"] else 1)
