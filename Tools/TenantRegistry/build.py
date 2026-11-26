# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.
"""Tenant registry 1.8.0 (fresh chain 113211): pinned Standard JSON inputs and artifacts for the kit's fresh-chain release.

    python Tools/TenantRegistry/build.py           # write Tools/TenantRegistry/standard-input/
    python Tools/TenantRegistry/build.py --check   # rebuild and refuse if any committed file differs

Writes, per deployment target, `<Name>.json` (self-contained Standard JSON input, the file the kit compiles and the explorer
verifies) and `<Name>.artifact.json` (abi, creation and runtime bytecode, runtime keccak256, immutable references, storage
layout), plus `build-summary.json` and SHA256SUMS:

  * KotaAccessFactory, KotaTenantAccessSBT: Contracts/TenantRegistry/KotaAccessFactory.sol with its vendored OpenZeppelin
    5.2.0 imports; solc 0.8.37, Osaka, optimizer 200, no viaIR, ipfs metadata.
  * UpgradeableBeacon, BeaconProxy: the same input. The factory creates both (deployTenantRegistryBeacon, every registry);
    their artifacts are here only to check the code the factory leaves on chain. The kit never deploys them itself.
  * ManagedProxyAdmin, ManagedApplicationProxy: the factory's proxy and its Ownable2Step admin (audit X-69), copied
    byte-for-byte from Contracts/Paladin/standard-input (OpenZeppelin 4.9.6, Shanghai), as the Paladin release pins them.

Runtime keccak256 is over the compiled runtime, in which solc leaves every immutable as zero bytes. On chain,
KotaTenantAccessSBT carries two immutables (_implementationSelf = its own address, RENAME_TARGET = address(0) on the fresh
chain) and BeaconProxy one (the beacon): zero them at the listed offsets before comparing.

Fresh-chain deploy order (nothing here signs or sends):
  1. KotaTenantAccessSBT(address(0))                       registry implementation; RENAME_TARGET = 0 disables renames
  2. KotaAccessFactory()                                   factory implementation (no constructor arguments)
  3. ManagedProxyAdmin(<factory upgrade owner>)            Ownable2Step; transferOwnership + acceptOwnership to hand over
  4. ManagedApplicationProxy(factoryImpl, proxyAdmin, initialize(<factory admin>, <platform KotaAccessSBT proxy>))
  5. factory.deployTenantRegistryBeacon(sbtImpl)           (factory admin) the factory creates and owns the beacon
  6. factory.deployTenantRegistry("cryft.cards", <tenant operator>, <name>, <symbol>, ["https://cryft.app"])
                                                           (factory admin or ROLE_SYSTEM); the operator must hold
                                                           ROLE_TENANT with an active tier on the platform registry
  7. registry.setMetadataUpdater(<dedicated updater key>)  (tenant operator) never the Paladin signer
"""
from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCES = REPO / "Contracts" / "TenantRegistry"
PALADIN_INPUTS = REPO / "Contracts" / "Paladin" / "standard-input"
OUT = Path(__file__).resolve().parent / "standard-input"
UNIT = "KotaAccessFactory.sol"
SOLC_VERSION = "0.8.37"
CRYFT_CODE_LIMIT = 32_768
MAX_SOURCES = 64
OUTPUTS = ["abi", "metadata", "storageLayout", "evm.bytecode", "evm.deployedBytecode"]
SETTINGS = {"evmVersion": "osaka", "optimizer": {"enabled": True, "runs": 200}, "viaIR": False,
            "metadata": {"bytecodeHash": "ipfs"}, "outputSelection": {"*": {"*": OUTPUTS}}}
OZ = "@openzeppelin/contracts/proxy/beacon/"
# name -> (standard input file, source unit)
REGISTRY_TARGETS = {"KotaAccessFactory": UNIT, "KotaTenantAccessSBT": UNIT,
                    "UpgradeableBeacon": OZ + "UpgradeableBeacon.sol", "BeaconProxy": OZ + "BeaconProxy.sol"}
PROXY_TARGETS = ("ManagedProxyAdmin", "ManagedApplicationProxy")
IMPORT = re.compile(r'import\s+(?:[^;]*?from\s+)?["\']([^"\']+)["\']\s*;')


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def keccak(data: bytes) -> str:
    from eth_utils import keccak as k  # noqa: PLC0415
    return "0x" + k(data).hex()


def registry_input() -> dict:
    """KotaAccessFactory.sol and exactly the files it imports, transitively (bounded by MAX_SOURCES)."""
    sources: dict[str, dict] = {}
    queue = [UNIT]
    for _ in range(MAX_SOURCES):
        if not queue:
            break
        name = queue.pop()
        if name in sources:
            continue
        path = (SOURCES / name).resolve()
        if not path.is_relative_to(SOURCES.resolve()) or not path.is_file():
            raise SystemExit(f"refusing: import {name} is not under {SOURCES}")
        text = path.read_text(encoding="utf-8")
        sources[name] = {"content": text}
        for dep in IMPORT.findall(text):
            queue.append(posixpath.normpath(posixpath.join(posixpath.dirname(name), dep)) if dep.startswith(".") else dep)
    if queue:
        raise SystemExit(f"refusing: more than {MAX_SOURCES} sources")
    return {"language": "Solidity", "sources": dict(sorted(sources.items())), "settings": SETTINGS}


def compile_standard(standard: dict) -> dict:
    import solcx  # noqa: PLC0415
    return solcx.compile_standard(standard, solc_version=SOLC_VERSION)


def artifact(output: dict, unit: str, name: str, standard: dict) -> dict:
    c = output["contracts"][unit][name]
    runtime = bytes.fromhex(c["evm"]["deployedBytecode"]["object"])
    return {"name": name, "source": unit, "compiler": SOLC_VERSION, "evm_version": standard["settings"]["evmVersion"],
            "abi": c["abi"], "creation_bytecode": "0x" + c["evm"]["bytecode"]["object"],
            "runtime_bytecode": "0x" + runtime.hex(), "runtime_bytes": len(runtime),
            "runtime_keccak256": keccak(runtime),
            "immutable_references": c["evm"]["deployedBytecode"].get("immutableReferences", {}),
            "storage_layout": c.get("storageLayout"), "metadata": c["metadata"]}


def build() -> tuple[dict[str, bytes], dict]:
    files: dict[str, bytes] = {}
    summary = {"compiler": SOLC_VERSION, "cryft_code_limit": CRYFT_CODE_LIMIT, "contracts": {}}
    standard = registry_input()
    output = compile_standard(standard)
    text = (json.dumps(standard, indent=1) + "\n").encode()
    arts = {}
    for name, unit in REGISTRY_TARGETS.items():
        files[f"{name}.json"] = text
        arts[name] = (artifact(output, unit, name, standard), f"{name}.json")
    for name in PROXY_TARGETS:
        raw = (PALADIN_INPUTS / f"{name}.json").read_bytes()
        files[f"{name}.json"] = raw
        pinned = json.loads(raw)
        out = compile_standard(pinned)
        units = [u for u, cs in out["contracts"].items() if name in cs]
        if len(units) != 1:
            raise SystemExit(f"refusing: {name} found in {units}")
        arts[name] = (artifact(out, units[0], name, pinned), f"{name}.json")
    for name, (art, input_file) in arts.items():
        if art["runtime_bytes"] > CRYFT_CODE_LIMIT:
            raise SystemExit(f"refusing: {name} is {art['runtime_bytes']:,} bytes, past {CRYFT_CODE_LIMIT:,}")
        files[f"{name}.artifact.json"] = (json.dumps(art, indent=1, sort_keys=True) + "\n").encode()
        summary["contracts"][name] = {
            "standard_input": input_file, "standard_input_sha256": sha256(files[input_file]), "source": art["source"],
            "evm_version": art["evm_version"], "runtime_bytes": art["runtime_bytes"],
            "runtime_keccak256": art["runtime_keccak256"],
            "immutables": {k: v for k, v in art["immutable_references"].items()}}
    summary["sources_sha256"] = {k: sha256(v["content"].encode()) for k, v in standard["sources"].items()}
    files["build-summary.json"] = (json.dumps(summary, indent=1) + "\n").encode()
    files["SHA256SUMS"] = "".join(f"{sha256(files[n])}  {n}\n" for n in sorted(files)).encode()
    return files, summary


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="rebuild and refuse if a committed file differs")
    args = parser.parse_args(argv)
    files, summary = build()
    if args.check:
        differs = [n for n, data in files.items() if not (OUT / n).is_file() or (OUT / n).read_bytes() != data]
        if differs:
            print("committed build differs: " + ", ".join(differs), file=sys.stderr)
            return 1
    else:
        OUT.mkdir(parents=True, exist_ok=True)
        for n, data in files.items():
            (OUT / n).write_bytes(data)
    print(json.dumps({n: {k: c[k] for k in ("runtime_bytes", "runtime_keccak256")} for n, c in summary["contracts"].items()},
                     indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
