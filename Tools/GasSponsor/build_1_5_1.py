"""GasSponsor 1.5.1 (ProgramGasSponsor): the release build and its storage-layout proof (2026-11-23, the review's P2-D: a program
sponsor's credit is recovered by the program alone).

Writes Releases/GasSponsor/1.5.1/:
  standard-input.json   the Standard JSON input (sources by content, the live settings: solc 0.8.37, Osaka, 200 runs), the input the
                        explorer verifies with and the kit's release tool builds from;
  ProgramGasSponsor.json  abi, creation and runtime bytecode, storage layout, sizes, sha256 of the input;
  layout-proof.json     append-only against BOTH live predecessors, by compiling one probe contract that holds every namespaced
                        struct as a state variable (so solc lays them out), against each version's own sources:
                          * 1.3.0 WorkerGasSponsor, live at 0x…FEeD (Contracts/Verification/20260915/WorkerGasSponsor);
                          * 1.4.0 ProgramGasSponsor (Releases/GasSponsor/1.5.0/live-1.4.0-standard-input.json), dev before PB-2;
                          * 1.5.0 ProgramGasSponsor, live behind the dev test sponsor 0xDEa7…66C2 since PB-2 (implementation
                            0x1238…2458, verified from Releases/GasSponsor/1.5.0/standard-input.json).
                        Each struct's members must be the predecessor's, in the same slot, offset and type, with any new ones
                        after; the plain slots (Initializable, ReentrancyGuard and its gap) must be identical; and every namespace
                        constant must be unchanged.

    python Tools/GasSponsor/build_1_5_1.py [--check]      # --check: rebuild and compare with the committed files, write nothing

Needs py-solc-x with solc 0.8.37 installed. Refuses (exit 1) past Cryft's 32,768-byte code limit or on any layout problem.
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
OUT = REPO / "Releases/GasSponsor/1.5.1"
VERSION = "1.5.1"
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
LIVE_STRUCTS = ["GasSponsor", "WorkerGasSponsor", "ProgramGasSponsor"]          # what 1.4.0 and 1.5.0 hold
APPROVED_COMMIT = "7f70541"          # ApprovedGasSponsor (GasSponsor 1.2), live on 0x…FEeD blocks 5171-5330 (0x788e…9fb0): its namespace
NAMESPACES = {"GasSponsorStorage": 0x1517881409dbca238e515328317c78f643c8aa79fdd0217b0d2dee62cd1df100,
              "WorkerStorage": "cryft.storage.WorkerGasSponsor.v1", "ProgramStorage": "cryft.storage.ProgramGasSponsor.v1",
              "ApprovalStorage": "cryft.storage.ApprovedGasSponsor.v1"}
LIVE_130 = REPO / "Contracts/Verification/20260915/WorkerGasSponsor/standard-input.json"
LIVE_140 = REPO / "Releases/GasSponsor/1.5.0/live-1.4.0-standard-input.json"
LIVE_150 = REPO / "Releases/GasSponsor/1.5.0/standard-input.json"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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


def normalized(path: str) -> str:
    parts = []
    for part in path.split("/"):
        if part == "..":
            parts.pop()
        elif part not in (".", ""):
            parts.append(part)
    return "/".join(parts)


def compile_input(standard: dict) -> dict:
    out = solcx.compile_standard(standard, solc_version=SOLC)
    errors = [e["formattedMessage"] for e in out.get("errors", []) if e["severity"] == "error"]
    if errors:
        raise SystemExit("refusing: " + "\n".join(errors))
    return out


def probe_layout(standard: dict, folder: str, contracts: list[str]) -> dict:
    """{struct: [(label, slot, offset, type label, bytes)], '_plain': [...]} for `contracts`' namespaced structs, laid out by solc
    as the probe's state variables, compiled against `standard`'s own sources (folder: where those sources keep 7702/)."""
    probe = "// SPDX-License-Identifier: Apache-2.0\npragma solidity >=0.8.20 <0.9.0;\n"
    probe += "".join(f'import "{folder}/{c}.sol";\n' for c in contracts)
    probe += "contract LayoutProbe {\n" + "".join(f"    {c}.{STRUCTS[c]} internal s{i};\n" for i, c in enumerate(contracts)) + "}\n"
    request = json.loads(json.dumps(standard))
    request["sources"]["LayoutProbe.sol"] = {"content": probe}
    request["settings"] = dict(request["settings"], outputSelection={"*": {"*": ["storageLayout"]}})
    out = compile_input(request)
    layout = out["contracts"]["LayoutProbe.sol"]["LayoutProbe"]["storageLayout"]
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


def prefix_problems(name: str, old: list, new: list) -> list[str]:
    problems = []
    if len(new) < len(old):
        problems.append(f"{name}: {len(old) - len(new)} member(s) removed")
    for i, member in enumerate(old):
        if i >= len(new) or new[i] != member:
            problems.append(f"{name}: member {i} was {member}, now {new[i] if i < len(new) else 'gone'}")
    return problems


def build() -> tuple[dict, dict, dict]:
    sources = closure(ENTRY)
    standard = {"language": "Solidity", "sources": sources, "settings": SETTINGS}
    out = compile_input(standard)
    made = out["contracts"][ENTRY][NAME]
    runtime = bytes.fromhex(made["evm"]["deployedBytecode"]["object"])
    creation = bytes.fromhex(made["evm"]["bytecode"]["object"])
    text = json.dumps(standard, indent=1, sort_keys=True) + "\n"
    artifact = {"contract": f"{ENTRY}:{NAME}", "version": VERSION, "compiler": "v0.8.37+commit.f401782d", "evm_version": "osaka",
                "optimizer_runs": 200, "via_ir": False, "abi": made["abi"], "creation_bytecode": "0x" + creation.hex(),
                "runtime_bytecode": "0x" + runtime.hex(), "runtime_bytes": len(runtime), "code_limit": CODE_LIMIT,
                "runtime_keccak256": "0x" + __import__("eth_utils").keccak(runtime).hex(),
                "storage_layout": made["storageLayout"], "standard_input_sha256": sha256(text.encode()),
                "immutable_references": made["evm"]["deployedBytecode"]["immutableReferences"]}
    # the proof: 1.5.1 against 1.3.0 (production 0x…FEeD), 1.4.0 (dev before PB-2) and 1.5.0 (dev now, 0xDEa7…66C2)
    new = probe_layout(standard, "Contracts/Genesis/7702", list(STRUCTS))
    live130 = json.loads(LIVE_130.read_text())
    live140 = json.loads(LIVE_140.read_text())
    live150 = json.loads(LIVE_150.read_text())
    old130 = probe_layout(live130, "source/Genesis/7702", ["GasSponsor", "WorkerGasSponsor"])
    old140 = probe_layout(live140, "Contracts/Genesis/7702", LIVE_STRUCTS)
    old150 = probe_layout(live150, "Contracts/Genesis/7702", LIVE_STRUCTS)
    # ApprovedGasSponsor's struct as 1.2 wrote it (0x…FEeD's namespace still holds its entries), from its commit
    import subprocess
    approved_old = subprocess.run(["git", "-C", str(REPO), "show", f"{APPROVED_COMMIT}:Contracts/Genesis/7702/ApprovedGasSponsor.sol"],
                                  capture_output=True, text=True, timeout=60, check=True).stdout
    live12 = json.loads(json.dumps(standard))
    live12["sources"]["Contracts/Genesis/7702/ApprovedGasSponsor.sol"] = {"content": approved_old}
    live12["sources"].pop(ENTRY)                                         # the probe needs the 1.2 contract alone
    old12 = probe_layout(live12, "Contracts/Genesis/7702", ["ApprovedGasSponsor"])
    selection = {"*": {"*": ["storageLayout"]}}
    plain140 = plain(compile_input(dict(live140, settings=dict(live140["settings"], outputSelection=selection)))["contracts"][ENTRY][NAME])
    plain150 = plain(compile_input(dict(live150, settings=dict(live150["settings"], outputSelection=selection)))["contracts"][ENTRY][NAME])
    out130 = compile_input(dict(live130, settings=dict(live130["settings"], outputSelection=selection)))
    plain130 = plain(out130["contracts"]["source/Genesis/7702/WorkerGasSponsor.sol"]["WorkerGasSponsor"])
    plain151 = plain(made)
    problems = []
    for label, old in (("1.3.0", old130), ("1.4.0", old140), ("1.5.0", old150), ("1.2 approvals", old12)):
        for struct in old:
            problems += prefix_problems(f"{label} -> {VERSION} {struct}", old[struct], new[struct])
    for label, old_plain in (("1.3.0", plain130), ("1.4.0", plain140), ("1.5.0", plain150)):
        if old_plain != plain151:
            problems.append(f"plain slots differ from {label}: {old_plain} vs {plain151}")
    # every namespace apart: four distinct keccak-placed bases, each struct a few slots, none near another or the plain slots
    from eth_utils import keccak as _k
    bases = {name: (v if isinstance(v, int) else int.from_bytes(_k(text=v), "big")) for name, v in NAMESPACES.items()}
    spans = sorted((b, b + 1 + max(m[1] for m in new[name]), name) for name, b in bases.items())
    plain_top = 1 + max(slot for _, slot, _, _ in plain151)
    if spans[0][0] <= plain_top:
        problems.append(f"a namespace starts within the plain slots (0..{plain_top})")
    for (b0, e0, n0), (b1, e1, n1) in zip(spans, spans[1:]):
        if b1 < e0:
            problems.append(f"the namespaces {n0} and {n1} overlap")
    for file, constant in CONSTANTS:
        here = (REPO / "Contracts/Genesis/7702" / file).read_text()
        if constant not in here:
            problems.append(f"{file}: the namespace constant {constant!r} changed")
        for label, standard_old, folder in (("1.5.0", live150, "Contracts/Genesis/7702"), ("1.4.0", live140, "Contracts/Genesis/7702"),
                                            ("1.3.0", live130, "source/Genesis/7702")):
            old_text = (standard_old["sources"].get(f"{folder}/{file}") or {}).get("content")
            if old_text is not None and constant not in old_text:
                problems.append(f"{file}: {label} has no {constant!r}")
    if len(runtime) > CODE_LIMIT:
        problems.append(f"runtime {len(runtime):,} bytes, past {CODE_LIMIT:,}")
    proof = {"kind": "cryft.storage-layout-proof.v1", "contract": NAME, "version": VERSION, "append_only": not problems,
             "problems": problems,
             "predecessors": {"1.3.0": {"where": "0x000000000000000000000000000000000000FEeD (production, genesis proxy)",
                                        "sources": str(LIVE_130.relative_to(REPO)), "sources_sha256": sha256(LIVE_130.read_bytes()),
                                        "plain": plain130, "structs": old130},
                              "1.4.0": {"where": "dev test sponsor 0xDEa7fB5e0c52Cf996Bf2BD2CBe8D177C015e66C2 before PB-2 (0xbEB8…05c)",
                                        "sources": str(LIVE_140.relative_to(REPO)), "sources_sha256": sha256(LIVE_140.read_bytes()),
                                        "plain": plain140, "structs": old140},
                              "1.5.0": {"where": "0xDEa7fB5e0c52Cf996Bf2BD2CBe8D177C015e66C2 (dev test sponsor; implementation "
                                                 "0x123849C1E99067cEF6aD37548a85A9b905472458 since PB-2)",
                                        "sources": str(LIVE_150.relative_to(REPO)), "sources_sha256": sha256(LIVE_150.read_bytes()),
                                        "plain": plain150, "structs": old150}},
             "new": {"plain": plain151, "structs": new},
             "approvals_1_2": {"where": f"ApprovedGasSponsor at {APPROVED_COMMIT} (0x…FEeD's implementation 0x788e77a7f7e6d1e65a9c4b19d1c36ac93e749fb0, "
                                        "blocks 5171-5330; its namespace still initialized with 7 entries)", "structs": old12},
             "namespaces": {name: hex(b) for name, b in bases.items()},
             "constants": [c for _, c in CONSTANTS], "runtime_bytes": len(runtime), "code_limit": CODE_LIMIT,
             "margin_bytes": CODE_LIMIT - len(runtime)}
    return standard, artifact, proof


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    standard, artifact, proof = build()
    files = {"standard-input.json": json.dumps(standard, indent=1, sort_keys=True) + "\n",
             f"{NAME}.json": json.dumps(artifact, indent=1, sort_keys=True) + "\n",
             "layout-proof.json": json.dumps(proof, indent=1, sort_keys=True) + "\n"}
    if args.check:
        stale = [n for n, t in files.items() if not (OUT / n).is_file() or (OUT / n).read_text() != t]
        print("committed files match the rebuild" if not stale else "STALE: " + ", ".join(stale))
        return 1 if stale or proof["problems"] else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (OUT / name).write_text(text, encoding="utf-8")
    print(f"{NAME} {VERSION}: runtime {artifact['runtime_bytes']:,} bytes (limit {CODE_LIMIT:,}); append-only: {proof['append_only']}")
    for line in proof["problems"]:
        print("PROBLEM", line)
    for name in files:
        print(f"  {OUT.relative_to(REPO)}/{name}  sha256 {sha256((OUT / name).read_bytes())}")
    return 1 if proof["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
