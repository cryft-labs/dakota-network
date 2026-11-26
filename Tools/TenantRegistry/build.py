# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.
"""Tenant registry rename release (v1.7.0): build, storage-layout proof, sizes, and the live-source match.

    python Tools/TenantRegistry/build.py                 # build into Releases/TenantRegistryRename/1.7.0 (no chain)
    python Tools/TenantRegistry/build.py --check         # rebuild and refuse if any committed file differs
    python Tools/TenantRegistry/build.py --rpc http://127.0.0.1:18547/   # also: the baseline is the LIVE code

The sources are Contracts/TenantRegistry (KotaAccessFactory.sol: KotaTenantAccessSBT + KotaAccessFactory, OpenZeppelin 5.2.0
vendored as the live release's standard input carried it). The compiler and settings are the live release's exactly: solc
0.8.34+commit.80d5c536, Osaka, optimizer 200 runs, no viaIR, ipfs metadata. The baseline is the live v1.6.0 standard input
(Releases/TenantRegistryRename/baseline-v1.6.0/standard-input.json, sha256 e8b8e16b...), whose two contracts ARE the live
factory implementation 0x294Cd799... and registry beacon implementation 0xF9346D8a... (checked with --rpc).

Read only: nothing here signs or sends.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCES = REPO / "Contracts" / "TenantRegistry"
RELEASE = REPO / "Releases" / "TenantRegistryRename"
OUT = RELEASE / "1.7.0"
BASELINE = RELEASE / "baseline-v1.6.0" / "standard-input.json"
BASELINE_SHA256 = "e8b8e16b6a928a22282aabdd14269325b54ad89c00251eacf4cc5b4355e2bbc6"
UNIT = "KotaAccessFactory.sol"
NAMES = ("KotaAccessFactory", "KotaTenantAccessSBT")
SOLC_VERSION = "0.8.34"
SOLC_LONG = "0.8.34+commit.80d5c536"
SETTINGS = {"evmVersion": "osaka", "optimizer": {"enabled": True, "runs": 200}, "viaIR": False,
            "metadata": {"bytecodeHash": "ipfs"},
            "outputSelection": {"*": {"*": ["abi", "metadata", "storageLayout", "evm.bytecode", "evm.deployedBytecode"]}}}
CRYFT_CODE_LIMIT = 32_768          # Cryft's genesis contractSizeLimit
EIP170 = 24_576
LIVE = {"KotaAccessFactory": "0x294Cd799535bEBCd2141B07e94e6ac1A8b06e96d",
        "KotaTenantAccessSBT": "0xF9346D8a883F89b9e5DF9d22e8227bef3F9d0021"}
MAX_SOURCES = 64                    # bounds the source walk


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def solc_binary() -> str:
    given = os.environ.get("TENANT_REGISTRY_SOLC")
    if given:
        return given
    try:
        import solcx  # noqa: PLC0415
        return str(solcx.get_executable(SOLC_VERSION))
    except Exception:  # noqa: BLE001
        candidate = Path.home() / ".solcx" / f"solc-v{SOLC_VERSION}"
        if candidate.is_file():
            return str(candidate)
    raise SystemExit(f"solc {SOLC_VERSION} not found: set TENANT_REGISTRY_SOLC or install it with py-solc-x")


def compile_standard(standard: dict) -> dict:
    binary = solc_binary()
    version = subprocess.run([binary, "--version"], capture_output=True, text=True, check=True).stdout
    if SOLC_LONG not in version:
        raise SystemExit(f"refusing: {binary} is not solc {SOLC_LONG}")
    done = subprocess.run([binary, "--standard-json"], input=json.dumps(standard).encode(), capture_output=True, check=True)
    output = json.loads(done.stdout)
    errors = [e for e in output.get("errors", []) if e.get("severity") == "error"]
    if errors:
        raise SystemExit("compile errors:\n" + "\n".join(e.get("formattedMessage", e.get("message", "")) for e in errors))
    return output


def standard_input() -> dict:
    files = sorted(p for p in SOURCES.rglob("*.sol"))
    if not files or len(files) > MAX_SOURCES:
        raise SystemExit(f"refusing: {len(files)} sources under {SOURCES} (1..{MAX_SOURCES})")
    sources = {p.relative_to(SOURCES).as_posix(): {"content": p.read_text(encoding="utf-8")} for p in files}
    return {"language": "Solidity", "sources": sources, "settings": SETTINGS}


def baseline_input() -> dict:
    raw = BASELINE.read_bytes()
    if sha256(raw) != BASELINE_SHA256:
        raise SystemExit(f"refusing: {BASELINE} changed (sha256 {sha256(raw)})")
    return json.loads(raw)


def strip_metadata(code: bytes) -> bytes:
    if len(code) < 2:
        return code
    n = int.from_bytes(code[-2:], "big") + 2
    return code[:-n] if 0 < n < len(code) else code


def zero_immutables(code: bytes, refs: dict) -> bytes:
    body = bytearray(code)
    for ranges in refs.values():
        for r in ranges:
            body[r["start"]:r["start"] + r["length"]] = bytes(r["length"])
    return bytes(body)


def artifact(output: dict, name: str) -> dict:
    c = output["contracts"][UNIT][name]
    runtime = bytes.fromhex(c["evm"]["deployedBytecode"]["object"])
    refs = c["evm"]["deployedBytecode"].get("immutableReferences", {})
    return {"name": name, "source": UNIT, "compiler": SOLC_LONG, "evm_version": "osaka", "optimizer_runs": 200, "via_ir": False,
            "abi": c["abi"], "creation_bytecode": "0x" + c["evm"]["bytecode"]["object"],
            "runtime_bytecode": "0x" + runtime.hex(), "runtime_bytes": len(runtime),
            "runtime_keccak256_immutables_zeroed": None,   # filled below (needs keccak)
            "immutable_references": refs, "storage_layout": c["storageLayout"], "metadata": c["metadata"]}


def keccak(data: bytes) -> str:
    try:
        from eth_utils import keccak as k  # noqa: PLC0415
    except ImportError as error:
        raise SystemExit("eth_utils is needed for keccak256") from error
    return "0x" + k(data).hex()


def layout_rows(layout: dict) -> list[dict]:
    types = layout.get("types") or {}
    rows = []
    for entry in layout["storage"]:
        t = types.get(entry["type"], {})
        rows.append({"slot": int(entry["slot"]), "offset": entry["offset"], "label": entry["label"], "type": entry["type"],
                     "type_label": t.get("label"), "encoding": t.get("encoding"), "bytes": int(t.get("numberOfBytes", 0))})
    return rows


def layout_proof(old: dict, new: dict) -> dict:
    """Slot by slot: every live entry is in the new layout at the same slot and offset with the same type (a label may be
    renamed, and is reported), and every new entry lies past the live layout's end (append-only)."""
    before, after = layout_rows(old), layout_rows(new)
    by_position = {(r["slot"], r["offset"]): r for r in after}
    end = max((r["slot"] + max(1, (r["bytes"] + 31) // 32) - 1) for r in before) if before else -1
    rows, problems = [], []
    for r in before:
        n = by_position.get((r["slot"], r["offset"]))
        same = n is not None and (n["type"], n["encoding"], n["bytes"]) == (r["type"], r["encoding"], r["bytes"])
        rows.append({"slot": r["slot"], "offset": r["offset"], "live": f"{r['label']}: {r['type_label']}",
                     "new": f"{n['label']}: {n['type_label']}" if n else None, "same_type": same,
                     "renamed": bool(n) and n["label"] != r["label"]})
        if not same:
            problems.append(f"slot {r['slot']} offset {r['offset']} ({r['label']}) is not kept: {n}")
    kept = {(r["slot"], r["offset"]) for r in before}
    appended = [r for r in after if (r["slot"], r["offset"]) not in kept]
    for r in appended:
        if r["slot"] <= end:
            problems.append(f"new entry {r['label']} at slot {r['slot']} is inside the live layout (ends at slot {end})")
    return {"live_last_slot": end, "rows": rows,
            "appended": [{"slot": r["slot"], "offset": r["offset"], "entry": f"{r['label']}: {r['type_label']}"} for r in appended],
            "problems": problems, "append_only": not problems}


def signatures(abi: list) -> dict[str, str]:
    """{"name(types)": "outputs | mutability"} of every function in an ABI."""
    def kind(x):
        if x["type"] != "tuple":
            return x["type"]
        return "(" + ",".join(kind(c) for c in x["components"]) + ")" + x["type"][5:]
    out = {}
    for f in abi:
        if f.get("type") == "function":
            out[f"{f['name']}({','.join(kind(i) for i in f['inputs'])})"] = \
                ",".join(kind(o) for o in f.get("outputs", [])) + " | " + f.get("stateMutability", "")
    return out


def abi_proof(old_abi: list, new_abi: list) -> dict:
    """Every live function keeps its signature, outputs and mutability; the rest are additions."""
    old, new = signatures(old_abi), signatures(new_abi)
    changed = sorted(k for k in old if new.get(k) != old[k])
    return {"kept": len(old) - len(changed), "changed_or_missing": changed, "added": sorted(k for k in new if k not in old),
            "superset": not changed}


def rpc_code(url: str, address: str) -> bytes:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]}).encode()
    request = urllib.request.Request(url, body, {"content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return bytes.fromhex(json.load(response)["result"][2:])


def live_match(url: str, base_output: dict) -> dict:
    result = {}
    for name in NAMES:
        c = base_output["contracts"][UNIT][name]["evm"]["deployedBytecode"]
        built = bytes.fromhex(c["object"])
        live = rpc_code(url, LIVE[name])
        refs = c.get("immutableReferences", {})
        result[name] = {"address": LIVE[name], "live_bytes": len(live), "built_bytes": len(built),
                        "match_ignoring_metadata_and_immutables":
                            strip_metadata(zero_immutables(live, refs)) == strip_metadata(zero_immutables(built, refs)),
                        "immutables": sum(len(v) for v in refs.values())}
    return result


def build(rpc: str | None = None) -> tuple[dict, dict]:
    standard = standard_input()
    output = compile_standard(standard)
    base = baseline_input()
    base_output = compile_standard(base)
    files, summary = {}, {"compiler": SOLC_LONG, "settings": {k: v for k, v in SETTINGS.items() if k != "outputSelection"},
                          "cryft_code_limit": CRYFT_CODE_LIMIT, "contracts": {}}
    files["standard-input.json"] = json.dumps(standard, indent=1, sort_keys=True) + "\n"
    for name in NAMES:
        art = artifact(output, name)
        runtime = bytes.fromhex(art["runtime_bytecode"][2:])
        art["runtime_keccak256_immutables_zeroed"] = keccak(zero_immutables(runtime, art["immutable_references"]))
        old = base_output["contracts"][UNIT][name]
        proof = layout_proof(old["storageLayout"], art["storage_layout"])
        abi = abi_proof(old["abi"], art["abi"])
        live_size = len(bytes.fromhex(old["evm"]["deployedBytecode"]["object"]))
        summary["contracts"][name] = {
            "runtime_bytes": len(runtime), "live_runtime_bytes": live_size, "margin_to_cryft_limit": CRYFT_CODE_LIMIT - len(runtime),
            "within_cryft_limit": len(runtime) <= CRYFT_CODE_LIMIT, "within_eip170": len(runtime) <= EIP170,
            "runtime_keccak256_immutables_zeroed": art["runtime_keccak256_immutables_zeroed"],
            "immutables": art["immutable_references"], "append_only": proof["append_only"],
            "abi_superset": abi["superset"], "abi_added": abi["added"], "abi_changed_or_missing": abi["changed_or_missing"]}
        files[f"{name}.json"] = json.dumps(art, indent=1, sort_keys=True) + "\n"
        files[f"{name}.layout-proof.json"] = json.dumps(proof, indent=1) + "\n"
    if rpc:
        summary["live_baseline"] = live_match(rpc, base_output)
    summary["sources_sha256"] = {k: sha256(v["content"].encode()) for k, v in sorted(standard["sources"].items())}
    return files, summary


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="rebuild and refuse if a committed file differs")
    parser.add_argument("--rpc", help="an archive RPC: also check the baseline against the live implementations")
    args = parser.parse_args(argv)
    files, summary = build(args.rpc)
    problems = [f"{n}: not append-only" for n, s in summary["contracts"].items() if not s["append_only"]]
    problems += [f"{n}: a live function changed: {s['abi_changed_or_missing']}" for n, s in summary["contracts"].items()
                 if not s["abi_superset"]]
    problems += [f"{n}: {s['runtime_bytes']:,} bytes is past Cryft's {CRYFT_CODE_LIMIT:,}" for n, s in summary["contracts"].items()
                 if not s["within_cryft_limit"]]
    problems += [f"{n}: the baseline is not the live code" for n, s in (summary.get("live_baseline") or {}).items()
                 if not s["match_ignoring_metadata_and_immutables"]]
    files["build-summary.json"] = json.dumps({k: v for k, v in summary.items() if k != "live_baseline"}, indent=1) + "\n"
    if args.check:
        differs = [n for n, text in files.items() if not (OUT / n).is_file() or (OUT / n).read_text(encoding="utf-8") != text]
        if differs:
            problems.append("committed build differs: " + ", ".join(differs))
    else:
        OUT.mkdir(parents=True, exist_ok=True)
        for n, text in files.items():
            (OUT / n).write_text(text, encoding="utf-8", newline="\n")
        sums = "".join(f"{sha256((OUT / n).read_bytes())}  {n}\n" for n in sorted(files))
        (OUT / "SHA256SUMS").write_text(sums, encoding="utf-8", newline="\n")
    print(json.dumps(summary, indent=1))
    if problems:
        print("PROBLEMS:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
