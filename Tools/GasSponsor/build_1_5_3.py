"""GasSponsor 1.5.3 (ProgramGasSponsor; 1.5.2 plus the zero-pending accept fix): the release build and its storage-layout record (2026-11-25, the contract audit's P-1 for
the fresh chain 113211: pauser, openedBy, one-time setProgram behind a seeded deny list, program sponsors locked to their program,
ops/day for every sponsor, wallet approval by default, per-sponsor operation ids, worker release without charge and revenue
redirect, bounded best-effort policy settle, the gas reserve checked after the calldata copy, EIP-1967 proxies refused as immutable).

This is the first release on the fresh chain (genesis links it at 0x…FEeD), so there is no predecessor to prove against. The
build records the layout every later upgrade must stay append-only against, and checks:
  * each namespaced struct (GasSponsorStorage, WorkerStorage, ProgramStorage, ApprovalStorage), laid out by solc (one probe
    contract holds each struct as a state variable), and the plain slots (Initializable, ReentrancyGuard and its gap);
  * every namespace constant is the one recorded here, and the four namespaces and the plain slots stay apart;
  * the runtime fits Cryft's 32,768-byte code limit.

    python Tools/GasSponsor/build_1_5_3.py            # print the result; write nothing
    python Tools/GasSponsor/build_1_5_3.py --write    # also write Releases/GasSponsor/1.5.3/ (standard input, artifact, layout)

Needs py-solc-x with solc 0.8.37. Exit 1 past the code limit or on any layout problem.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import solcx

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "Releases/GasSponsor/1.5.3"
VERSION = "1.5.3"
ENTRY = "Contracts/Genesis/7702/ProgramGasSponsor.sol"
NAME = "ProgramGasSponsor"
SOLC = "0.8.37"
SETTINGS = {"optimizer": {"enabled": True, "runs": 200}, "evmVersion": "osaka", "remappings": ["@cryft/=Contracts/"],
            "outputSelection": {"*": {"*": ["abi", "storageLayout", "evm.bytecode.object", "evm.deployedBytecode.object",
                                            "evm.deployedBytecode.immutableReferences"]}}}
CODE_LIMIT = 32_768
IMPORTS_MOST = 64                       # files in the import closure (11 today)
IMPORT = re.compile(r'^\s*import\s+(?:[^"\']*from\s+)?["\']([^"\']+)["\']\s*;', re.M)
# the namespaced structs, by the contract that declares them, and the constants that place them
STRUCTS = {"GasSponsor": "GasSponsorStorage", "WorkerGasSponsor": "WorkerStorage", "ProgramGasSponsor": "ProgramStorage",
           "ApprovedGasSponsor": "ApprovalStorage"}
CONSTANTS = (("GasSponsor.sol", "_GAS_SPONSOR_STORAGE_LOCATION =\n        0x1517881409dbca238e515328317c78f643c8aa79fdd0217b0d2dee62cd1df100;"),
             ("WorkerGasSponsor.sol", 'WORKER_SLOT = keccak256("cryft.storage.WorkerGasSponsor.v1");'),
             ("ProgramGasSponsor.sol", 'PROGRAM_SLOT = keccak256("cryft.storage.ProgramGasSponsor.v1");'),
             ("ApprovedGasSponsor.sol", '_APPROVAL_SLOT = keccak256("cryft.storage.ApprovedGasSponsor.v1");'))
NAMESPACES = {"GasSponsorStorage": 0x1517881409dbca238e515328317c78f643c8aa79fdd0217b0d2dee62cd1df100,
              "WorkerStorage": "cryft.storage.WorkerGasSponsor.v1", "ProgramStorage": "cryft.storage.ProgramGasSponsor.v1",
              "ApprovalStorage": "cryft.storage.ApprovedGasSponsor.v1"}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized(path: str) -> str:
    parts = []
    for part in path.split("/"):
        if part == "..":
            parts.pop()
        elif part not in (".", ""):
            parts.append(part)
    return "/".join(parts)


def closure(entry: str) -> dict[str, dict]:
    """The entry and every file it imports, by repository path, read from this checkout (bounded by IMPORTS_MOST)."""
    seen, todo = {}, [entry]
    while todo:
        if len(seen) > IMPORTS_MOST:
            raise SystemExit(f"refusing: more than {IMPORTS_MOST} files in the import closure")
        path = todo.pop()
        if path in seen:
            continue
        text = (REPO / path).read_text(encoding="utf-8")
        seen[path] = {"content": text}
        for name in IMPORT.findall(text):
            target = ("Contracts/" + name[len("@cryft/"):]) if name.startswith("@cryft/") else str(Path(path).parent / name)
            todo.append(normalized(target))
    return {k: seen[k] for k in sorted(seen)}


def compile_input(standard: dict) -> dict:
    out = solcx.compile_standard(standard, solc_version=SOLC)
    errors = [e["formattedMessage"] for e in out.get("errors", []) if e["severity"] == "error"]
    if errors:
        raise SystemExit("refusing: " + "\n".join(errors))
    return out


def probe_layout(standard: dict, folder: str, contracts: list[str]) -> dict:
    """{struct: [(label, slot, offset, type label, bytes)]} for `contracts`' namespaced structs, laid out by solc as the probe's
    state variables, compiled against `standard`'s own sources (folder: where those sources keep 7702/)."""
    probe = "// SPDX-License-Identifier: Apache-2.0\npragma solidity >=0.8.20 <0.9.0;\n"
    probe += "".join(f'import "{folder}/{c}.sol";\n' for c in contracts)
    probe += "contract LayoutProbe {\n" + "".join(f"    {c}.{STRUCTS[c]} internal s{i};\n" for i, c in enumerate(contracts)) + "}\n"
    request = json.loads(json.dumps(standard))
    request["sources"]["LayoutProbe.sol"] = {"content": probe}
    request["settings"] = dict(request["settings"], outputSelection={"*": {"*": ["storageLayout"]}})
    layout = compile_input(request)["contracts"]["LayoutProbe.sol"]["LayoutProbe"]["storageLayout"]
    types = layout["types"]
    found = {}
    for i, c in enumerate(contracts):
        entry = next(e for e in layout["storage"] if e["label"] == f"s{i}")
        found[STRUCTS[c]] = [(m["label"], int(m["slot"]), m["offset"], types[m["type"]]["label"], int(types[m["type"]]["numberOfBytes"]))
                             for m in types[entry["type"]]["members"]]
    return found


def plain(art: dict) -> list:
    types = art["storageLayout"]["types"]
    return [(e["label"], int(e["slot"]), e["offset"], types[e["type"]]["label"]) for e in art["storageLayout"]["storage"]]


def build() -> tuple[dict, dict, dict]:
    sources = closure(ENTRY)
    standard = {"language": "Solidity", "sources": sources, "settings": SETTINGS}
    out = compile_input(standard)
    made = out["contracts"][ENTRY][NAME]
    runtime = bytes.fromhex(made["evm"]["deployedBytecode"]["object"])
    creation = bytes.fromhex(made["evm"]["bytecode"]["object"])
    text = json.dumps(standard, indent=1, sort_keys=True) + "\n"
    from eth_utils import keccak
    artifact = {"contract": f"{ENTRY}:{NAME}", "version": VERSION, "compiler": "v0.8.37+commit.f401782d",
                "evm_version": "osaka", "optimizer_runs": 200, "via_ir": False, "abi": made["abi"],
                "creation_bytecode": "0x" + creation.hex(), "runtime_bytecode": "0x" + runtime.hex(), "runtime_bytes": len(runtime),
                "code_limit": CODE_LIMIT, "runtime_keccak256": "0x" + keccak(runtime).hex(),
                "storage_layout": made["storageLayout"], "standard_input_sha256": sha256(text.encode()),
                "immutable_references": made["evm"]["deployedBytecode"]["immutableReferences"]}
    structs = probe_layout(standard, "Contracts/Genesis/7702", list(STRUCTS))
    slots = plain(made)
    problems = []
    bases = {name: (v if isinstance(v, int) else int.from_bytes(keccak(text=v), "big")) for name, v in NAMESPACES.items()}
    spans = sorted((b, b + 1 + max(m[1] for m in structs[name]), name) for name, b in bases.items())
    if spans[0][0] <= 1 + max(slot for _, slot, _, _ in slots):
        problems.append("a namespace starts within the plain slots")
    for (_, e0, n0), (b1, _, n1) in zip(spans, spans[1:]):
        if b1 < e0:
            problems.append(f"the namespaces {n0} and {n1} overlap")
    for file, constant in CONSTANTS:
        if constant not in (REPO / "Contracts/Genesis/7702" / file).read_text():
            problems.append(f"{file}: the namespace constant {constant!r} changed")
    if len(runtime) > CODE_LIMIT:
        problems.append(f"runtime {len(runtime):,} bytes, past {CODE_LIMIT:,}")
    layout = {"kind": "cryft.storage-layout.v1", "contract": NAME, "version": VERSION, "ok": not problems, "problems": problems,
              "plain": slots, "structs": structs, "namespaces": {name: hex(b) for name, b in bases.items()},
              "constants": [c for _, c in CONSTANTS], "runtime_bytes": len(runtime), "code_limit": CODE_LIMIT,
              "margin_bytes": CODE_LIMIT - len(runtime)}
    return standard, artifact, layout


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args(argv)
    standard, artifact, layout = build()
    print(f"{NAME} {VERSION}: runtime {artifact['runtime_bytes']:,} bytes (limit {CODE_LIMIT:,}, margin "
          f"{layout['margin_bytes']:,}); keccak {artifact['runtime_keccak256']}; layout ok: {layout['ok']}")
    for line in layout["problems"]:
        print("PROBLEM", line)
    if args.write:
        OUT.mkdir(parents=True, exist_ok=True)
        files = {"standard-input.json": json.dumps(standard, indent=1, sort_keys=True) + "\n",
                 f"{NAME}.json": json.dumps(artifact, indent=1, sort_keys=True) + "\n",
                 "storage-layout.json": json.dumps(layout, indent=1, sort_keys=True) + "\n"}
        for name, text in files.items():
            (OUT / name).write_text(text, encoding="utf-8")
            print(f"  wrote {(OUT / name).relative_to(REPO)}")
    return 1 if layout["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
