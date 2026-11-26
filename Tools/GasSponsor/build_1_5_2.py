"""GasSponsor 1.5.2 (ProgramGasSponsor): the release build and its storage-layout proof (2026-11-25, the contract audit's P-1 for
the fresh chain 113211: pauser, openedBy, one-time setProgram behind a seeded deny list, program sponsors locked to their program,
ops/day for every sponsor, wallet approval by default, per-sponsor operation ids, worker release without charge and revenue
redirect, bounded best-effort policy settle, the gas reserve checked after the calldata copy, EIP-1967 proxies refused as immutable).

Nothing is deployed on the fresh chain, but the layout stays append-only against 1.5.1 so every later upgrade remains provable:
  * each namespaced struct (GasSponsorStorage, WorkerStorage, ProgramStorage, ApprovalStorage) keeps 1.5.1's members, in the same
    slot, offset and type, with any new ones after (solc lays them out: one probe contract holds each struct as a state variable);
  * the plain slots (Initializable, ReentrancyGuard and its gap) are identical;
  * every namespace constant is unchanged, and the four namespaces and the plain slots stay apart.

    python Tools/GasSponsor/build_1_5_2.py            # print the result; write nothing
    python Tools/GasSponsor/build_1_5_2.py --write    # also write Releases/GasSponsor/1.5.2/ (standard input, artifact, proof)

Needs py-solc-x with solc 0.8.37. Exit 1 past Cryft's 32,768-byte code limit or on any layout problem.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "Releases/GasSponsor/1.5.2"
VERSION = "1.5.2"
PREDECESSOR = REPO / "Releases/GasSponsor/1.5.1/standard-input.json"

_spec = importlib.util.spec_from_file_location("gas_sponsor_build_1_5_1", Path(__file__).with_name("build_1_5_1.py"))
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)


def build() -> tuple[dict, dict, dict]:
    sources = base.closure(base.ENTRY)
    standard = {"language": "Solidity", "sources": sources, "settings": base.SETTINGS}
    out = base.compile_input(standard)
    made = out["contracts"][base.ENTRY][base.NAME]
    runtime = bytes.fromhex(made["evm"]["deployedBytecode"]["object"])
    creation = bytes.fromhex(made["evm"]["bytecode"]["object"])
    text = json.dumps(standard, indent=1, sort_keys=True) + "\n"
    from eth_utils import keccak
    artifact = {"contract": f"{base.ENTRY}:{base.NAME}", "version": VERSION, "compiler": "v0.8.37+commit.f401782d",
                "evm_version": "osaka", "optimizer_runs": 200, "via_ir": False, "abi": made["abi"],
                "creation_bytecode": "0x" + creation.hex(), "runtime_bytecode": "0x" + runtime.hex(), "runtime_bytes": len(runtime),
                "code_limit": base.CODE_LIMIT, "runtime_keccak256": "0x" + keccak(runtime).hex(),
                "storage_layout": made["storageLayout"], "standard_input_sha256": base.sha256(text.encode()),
                "immutable_references": made["evm"]["deployedBytecode"]["immutableReferences"]}
    new = base.probe_layout(standard, "Contracts/Genesis/7702", list(base.STRUCTS))
    previous = json.loads(PREDECESSOR.read_text())
    old = base.probe_layout(previous, "Contracts/Genesis/7702", list(base.STRUCTS))
    selection = {"*": {"*": ["storageLayout"]}}
    old_plain = base.plain(base.compile_input(dict(previous, settings=dict(previous["settings"], outputSelection=selection)))
                           ["contracts"][base.ENTRY][base.NAME])
    new_plain = base.plain(made)
    problems = []
    for struct in old:
        problems += base.prefix_problems(f"1.5.1 -> {VERSION} {struct}", old[struct], new[struct])
    if old_plain != new_plain:
        problems.append(f"plain slots differ from 1.5.1: {old_plain} vs {new_plain}")
    bases = {name: (v if isinstance(v, int) else int.from_bytes(keccak(text=v), "big")) for name, v in base.NAMESPACES.items()}
    spans = sorted((b, b + 1 + max(m[1] for m in new[name]), name) for name, b in bases.items())
    if spans[0][0] <= 1 + max(slot for _, slot, _, _ in new_plain):
        problems.append("a namespace starts within the plain slots")
    for (_, e0, n0), (b1, _, n1) in zip(spans, spans[1:]):
        if b1 < e0:
            problems.append(f"the namespaces {n0} and {n1} overlap")
    for file, constant in base.CONSTANTS:
        if constant not in (REPO / "Contracts/Genesis/7702" / file).read_text():
            problems.append(f"{file}: the namespace constant {constant!r} changed")
        old_text = (previous["sources"].get(f"Contracts/Genesis/7702/{file}") or {}).get("content")
        if old_text is not None and constant not in old_text:
            problems.append(f"{file}: 1.5.1 has no {constant!r}")
    if len(runtime) > base.CODE_LIMIT:
        problems.append(f"runtime {len(runtime):,} bytes, past {base.CODE_LIMIT:,}")
    added = {struct: new[struct][len(old.get(struct, [])):] for struct in new}
    proof = {"kind": "cryft.storage-layout-proof.v1", "contract": base.NAME, "version": VERSION, "append_only": not problems,
             "problems": problems,
             "predecessors": {"1.5.1": {"sources": str(PREDECESSOR.relative_to(REPO)), "sources_sha256": base.sha256(PREDECESSOR.read_bytes()),
                                        "plain": old_plain, "structs": old}},
             "new": {"plain": new_plain, "structs": new}, "added": added,
             "namespaces": {name: hex(b) for name, b in bases.items()}, "constants": [c for _, c in base.CONSTANTS],
             "runtime_bytes": len(runtime), "code_limit": base.CODE_LIMIT, "margin_bytes": base.CODE_LIMIT - len(runtime)}
    return standard, artifact, proof


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args(argv)
    standard, artifact, proof = build()
    print(f"{base.NAME} {VERSION}: runtime {artifact['runtime_bytes']:,} bytes (limit {base.CODE_LIMIT:,}, margin "
          f"{proof['margin_bytes']:,}); keccak {artifact['runtime_keccak256']}; append-only: {proof['append_only']}")
    for struct, members in proof["added"].items():
        for member in members:
            print(f"  + {struct}.{member[0]} slot +{member[1]} {member[3]}")
    for line in proof["problems"]:
        print("PROBLEM", line)
    if args.write:
        OUT.mkdir(parents=True, exist_ok=True)
        files = {"standard-input.json": json.dumps(standard, indent=1, sort_keys=True) + "\n",
                 f"{base.NAME}.json": json.dumps(artifact, indent=1, sort_keys=True) + "\n",
                 "layout-proof.json": json.dumps(proof, indent=1, sort_keys=True) + "\n"}
        for name, text in files.items():
            (OUT / name).write_text(text, encoding="utf-8")
            print(f"  wrote {(OUT / name).relative_to(REPO)}")
    return 1 if proof["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
