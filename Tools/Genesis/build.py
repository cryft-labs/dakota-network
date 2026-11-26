#!/usr/bin/env python3
"""Reproducible Cryft Network genesis builder (audit X-7, runbook D.3).

Everything comes from committed inputs:
  * Tools/Genesis/inputs.json      chain config, governance (roots, voters, windows, upgrade delay), balances,
                                   system proxies, EIP-2935, pinned compilers
  * Tools/Genesis/validators.json  validator addresses (public part only; keys come from keygen.py)
  * the genesis-baked sources      ValidatorSmartContractAllowList (solc 0.8.19 / London, via the official soljson),
                                   TransparentUpgradeableProxy and ProxyAdmin (solc 0.8.37 / Osaka)

0x…1111 storage is derived from the compiler's storageLayout (never hand-typed slots).

    python Tools/Genesis/build.py            # writes Contracts/Genesis/{CryftGenesis.json, genesis-release.json, standard-input/}
    python Tools/Genesis/build.py --check    # rebuilds in memory and fails if the committed files differ

Running it twice gives byte-identical files (the manifest records sha256 of every input and output).
`build(inputs, validators)` is also used by Tools/Genesis/localnet.py to make a rehearsal genesis with
ephemeral governance keys.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

import solcx
from eth_utils import keccak, to_checksum_address

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "Tools/SolcCompiler"))
import soljson  # noqa: E402

OUT = REPO / "Contracts/Genesis"
GENESIS_FILE = OUT / "CryftGenesis.json"
MANIFEST_FILE = OUT / "genesis-release.json"
STANDARD_DIR = OUT / "standard-input"

VALIDATOR_SRC = "Contracts/Genesis/validatorContracts/ValidatorSmartContractAllowList.sol"
PROXY_SRC = "Contracts/Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol"
ADMIN_SRC = "Contracts/Genesis/Upgradeable/Proxy/Transparent/ProxyAdmin.sol"
REGISTRY = "0x0000000000000000000000000000000000001111"
PROXY_ADMIN = "0x0000000000000000000000000000000000FacAdE"
# QBFT extraData for contract-validator mode: RLP [32-byte vanity, [], [], round 0, []]
EXTRA_DATA = "0xe5a0" + "00" * 32 + "c0c080c0"
MIX_HASH = "0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365"


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def sources_for(entry):
    sources = {}
    soljson._collect(sources, entry, REPO / entry, str(REPO), [])
    return dict(sorted(sources.items()))


def standard_input(entry, evm, runs):
    return {
        "language": "Solidity",
        "sources": sources_for(entry),
        "settings": {
            "evmVersion": evm,
            "optimizer": {"enabled": True, "runs": runs},
            "metadata": {"bytecodeHash": "ipfs"},
            "outputSelection": {"*": {"*": ["abi", "evm.deployedBytecode.object", "evm.methodIdentifiers",
                                             "storageLayout", "metadata"]}},
        },
    }


def compile_unit(entry, name, compiler):
    std = standard_input(entry, compiler["evm"], compiler["runs"])
    if compiler["version"] == "0.8.19":
        out = soljson.compile_standard(std, "0.8.19")
    else:
        solcx.install_solc(compiler["version"]) if compiler["version"] not in map(str, solcx.get_installed_solc_versions()) else None
        out = solcx.compile_standard(std, solc_version=compiler["version"])
    errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    if errors:
        raise SystemExit("\n".join(e["formattedMessage"] for e in errors))
    contract = out["contracts"][entry][name]
    runtime = bytes.fromhex(contract["evm"]["deployedBytecode"]["object"])
    assert runtime, f"{name}: empty runtime"
    return {"std": std, "runtime": runtime, "abi": contract["abi"], "layout": contract["storageLayout"],
            "selectors": contract["evm"]["methodIdentifiers"]}


def word(value):
    return f"{value:064x}"


def address_word(address):
    return word(int(address, 16))


def layout_slots(layout):
    return {item["label"]: int(item["slot"]) for item in layout["storage"]}


def validator_storage(layout, validators, governance):
    """0x1111 storage from the compiler's layout. Arrays: length at p, items at keccak(p) + i."""
    slots = layout_slots(layout)
    storage = {}

    def put_array(label, members):
        p = slots[label]
        storage[word(p)] = word(len(members))
        base = int.from_bytes(keccak(p.to_bytes(32, "big")), "big")
        for i, member in enumerate(members):
            storage[word(base + i)] = address_word(member)

    def put(label, value):
        if value:
            storage[word(slots[label])] = word(value)

    assert 4 <= len(validators) <= governance["maxValidators"] <= 64
    assert 3600 <= governance["voteWindowSeconds"] <= 30 * 86400
    assert 0 <= governance["upgradeDelaySeconds"] <= 30 * 86400
    assert governance["roots"] and governance["voters"]
    for group in (validators, governance["roots"], governance["voters"]):
        assert len(set(a.lower() for a in group)) == len(group), "duplicate member"
        assert all(a.lower() not in (REGISTRY.lower(), PROXY_ADMIN.lower()) and int(a, 16) for a in group)
    put_array("validators", validators)
    put_array("votersArray", governance["voters"])
    put_array("rootOverlords", governance["roots"])
    put("maxValidators", governance["maxValidators"])
    put("voteTallyBlockThreshold", governance["voteWindowSeconds"])
    put("upgradeDelay", governance["upgradeDelaySeconds"])
    return dict(sorted(storage.items()))


def build(inputs, validators):
    """Returns (genesis dict, manifest dict, {name: standard input})."""
    compilers = inputs["compilers"]
    validator = compile_unit(VALIDATOR_SRC, "ValidatorSmartContractAllowList", compilers["validator"])
    proxy = compile_unit(PROXY_SRC, "TransparentUpgradeableProxy", compilers["proxy"])
    admin = compile_unit(ADMIN_SRC, "ProxyAdmin", compilers["proxy"])
    for unit in (validator, proxy, admin):
        assert len(unit["runtime"]) <= inputs["contractSizeLimit"]

    # The proxy's own functions shadow any implementation selector with the same 4 bytes (audit X-I1).
    proxy_selectors = dict(sorted(proxy["selectors"].items()))

    config = {"chainId": inputs["chainId"]}
    config.update({fork: 0 for fork in inputs["forks"]})
    config["eip150Hash"] = "0x" + "00" * 32
    config.update({fork: 0 for fork in inputs["timeForks"]})
    config["qbft"] = dict(inputs["qbft"])
    config["contractSizeLimit"] = inputs["contractSizeLimit"]
    for key in ("depositContractAddress", "withdrawalRequestContractAddress", "consolidationRequestContractAddress"):
        config[key] = inputs["requestContractAddresses"][key]

    alloc = {}
    for address, wei in inputs["balances"].items():
        alloc[to_checksum_address(address)] = {"balance": hex(int(wei))}
    alloc[to_checksum_address(REGISTRY)] = {
        "comment": "Cryft validator, voter and root governance (ValidatorSmartContractAllowList)",
        "balance": "0x0", "code": "0x" + validator["runtime"].hex(),
        "storage": validator_storage(validator["layout"], validators, inputs["governance"])}
    alloc[to_checksum_address(PROXY_ADMIN)] = {
        "comment": "ProxyAdmin: executes scheduled upgrades of the genesis proxies",
        "balance": "0x0", "code": "0x" + admin["runtime"].hex()}
    for address, purpose in inputs["proxies"].items():
        alloc[to_checksum_address(address)] = {"comment": "Cryft genesis proxy: " + purpose,
                                               "balance": "0x0", "code": "0x" + proxy["runtime"].hex()}
    for name, system in inputs["systemContracts"].items():
        entry = {"comment": system["note"], "balance": "0x0", "nonce": system["nonce"], "code": system["code"]}
        if system.get("storage"):
            entry["storage"] = dict(sorted(system["storage"].items()))
        alloc[to_checksum_address(system["address"])] = entry
    assert len(alloc) == len(inputs["balances"]) + 2 + len(inputs["proxies"]) + len(inputs["systemContracts"])

    genesis = {
        "config": config,
        "nonce": "0x0",
        "timestamp": inputs["timestamp"],
        "extraData": EXTRA_DATA,
        "gasLimit": inputs["gasLimit"],
        "difficulty": "0x1",
        "mixHash": MIX_HASH,
        "coinbase": "0x" + "00" * 20,
        "parentHash": "0x" + "00" * 32,
        "number": "0x0",
        "gasUsed": "0x0",
        "alloc": dict(sorted(alloc.items(), key=lambda kv: int(kv[0], 16))),
    }
    standard = {"ValidatorSmartContractAllowList": validator["std"],
                "TransparentUpgradeableProxy": proxy["std"], "ProxyAdmin": admin["std"]}
    runtimes = {}
    for name, unit, compiler in (("ValidatorSmartContractAllowList", validator, compilers["validator"]),
                                 ("TransparentUpgradeableProxy", proxy, compilers["proxy"]),
                                 ("ProxyAdmin", admin, compilers["proxy"])):
        runtimes[name] = {"solc": compiler["version"], "evm": compiler["evm"], "optimizer_runs": compiler["runs"],
                          "runtime_bytes": len(unit["runtime"]), "runtime_keccak256": "0x" + keccak(unit["runtime"]).hex(),
                          "standard_input_sha256": sha256(canonical(standard[name]))}
    manifest = {
        "network": inputs["network"], "coin": inputs["coin"], "chainId": inputs["chainId"],
        "chainIdHex": hex(inputs["chainId"]),
        "validators": validators, "roots": inputs["governance"]["roots"], "voters": inputs["governance"]["voters"],
        "voteWindowSeconds": inputs["governance"]["voteWindowSeconds"],
        "upgradeDelaySeconds": inputs["governance"]["upgradeDelaySeconds"],
        "maxValidators": inputs["governance"]["maxValidators"],
        "balances": inputs["balances"], "proxies": inputs["proxies"],
        "proxyCountDecision": inputs["proxyCountDecision"],
        "systemContracts": {k: {"address": v["address"], "runtime_keccak256": "0x" + keccak(bytes.fromhex(v["code"][2:])).hex(),
                                "source": v.get("source")} for k, v in inputs["systemContracts"].items()},
        "requestContractAddresses": inputs["requestContractAddresses"],
        "validatorStorageSlots": {label: slot for label, slot in layout_slots(validator["layout"]).items()
                                  if label in ("validators", "votersArray", "rootOverlords", "maxValidators",
                                               "voteTallyBlockThreshold", "upgradeDelay")},
        "runtimes": runtimes,
        "proxySelectors": proxy_selectors,
        "counts": {"allocations": len(alloc), "proxies": len(inputs["proxies"])},
    }
    return genesis, manifest, standard


def canonical(obj):
    return json.dumps(obj, indent=2, sort_keys=False) + "\n"


def render(inputs_path):
    inputs = json.loads(inputs_path.read_text())
    validators_doc = json.loads((REPO / inputs["validatorsFile"]).read_text())
    validators = [v["address"] for v in validators_doc["validators"]]
    genesis, manifest, standard = build(inputs, validators)
    files = {GENESIS_FILE: canonical(genesis)}
    for name, std in standard.items():
        files[STANDARD_DIR / f"{name}.json"] = canonical(std)
    manifest["inputs_sha256"] = {"inputs.json": sha256(inputs_path.read_bytes()),
                                 "validators.json": sha256((REPO / inputs["validatorsFile"]).read_bytes())}
    manifest["genesis_file"] = str(GENESIS_FILE.relative_to(REPO))
    manifest["genesis_sha256"] = sha256(files[GENESIS_FILE])
    manifest["genesis_bytes"] = len(files[GENESIS_FILE].encode())
    files[MANIFEST_FILE] = canonical(manifest)
    return files, manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inputs", default=str(REPO / "Tools/Genesis/inputs.json"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    files, manifest = render(Path(args.inputs))
    if args.check:
        stale = [str(p.relative_to(REPO)) for p, text in files.items() if not p.exists() or p.read_text() != text]
        if stale:
            raise SystemExit("Committed genesis files differ from a fresh build: " + ", ".join(stale))
        print("genesis reproducible:", manifest["genesis_sha256"])
        return
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    print(json.dumps({"genesis_sha256": manifest["genesis_sha256"], "chainId": manifest["chainIdHex"],
                      "runtimes": {k: (v["runtime_bytes"], v["runtime_keccak256"]) for k, v in manifest["runtimes"].items()}},
                     indent=1))


if __name__ == "__main__":
    main()
