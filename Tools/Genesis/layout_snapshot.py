#!/usr/bin/env python3
"""Storage-layout snapshot of every genesis-baked or genesis-linked contract (proof for formatting passes).

For each contract: the compiler's storageLayout (label, slot, offset, type) and the base contracts in
linearization order; for each source file: every keccak256("...") string literal (the namespaced storage
slots that storageLayout does not show). Two snapshots that compare equal prove no storage moved.

    python Tools/Genesis/layout_snapshot.py --out before.json
    python Tools/Genesis/layout_snapshot.py --out after.json --compare before.json
"""
import argparse, importlib.util, json, re, sys
from pathlib import Path

import solcx

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("compiler", REPO / "Tools/SolcCompiler/compile.py")
compiler = importlib.util.module_from_spec(spec); spec.loader.exec_module(compiler)

SCOPE = sorted([*map(str, (REPO / "Contracts/Genesis").rglob("*.sol")),
                str(REPO / "Contracts/CodeManagement/CodeManager.sol"),
                str(REPO / "Contracts/CodeManagement/CanonicalUid.sol"),
                *map(str, (REPO / "Contracts/CodeManagement/Interfaces").glob("*.sol")),
                str(REPO / "Contracts/Paladin/ManagedProxyAdmin.sol")])
SLOT_STRING = re.compile(r'keccak256\(\s*"([^"]+)"\s*\)')
STRUCT = re.compile(r"\bstruct\s+(\w+)\s*\{([^}]*)\}", re.S)
ENUM = re.compile(r"\benum\s+(\w+)\s*\{([^}]*)\}", re.S)
HEX_CONSTANT = re.compile(r"\bconstant\s+\w+\s*=\s*(0x[0-9a-fA-F]{64})\b")


def struct_bodies(source):
    """Namespaced storage lives in structs reached by slot, which storageLayout does not show: pin their fields."""
    clean = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    out = {}
    for name, body in STRUCT.findall(clean):
        out[name] = [" ".join(f.split()) for f in body.split(";") if f.strip()]
    return dict(sorted(out.items()))


def enum_sizes(source):
    """Enum values are stored as their index: the member count and order matter, the member names do not."""
    clean = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    return {name: len([m for m in body.split(",") if m.strip()]) for name, body in ENUM.findall(clean)}


def version_for(source):
    return "0.8.19" if re.search(r"pragma solidity[^;]*<\s*0\.8\.20", source) or "pragma solidity 0.8.19" in source else "0.8.37"


def snapshot(only=()):
    contracts, strings, structs, enums, hexes = {}, {}, {}, {}, {}
    for path in SCOPE:
        if only and not any(str(Path(path).relative_to(REPO)).startswith(o) for o in only):
            continue
        rel = str(Path(path).relative_to(REPO))
        source = Path(path).read_text()
        strings[rel] = sorted(set(SLOT_STRING.findall(source)))
        structs[rel] = struct_bodies(source)
        enums[rel] = enum_sizes(source)
        hexes[rel] = sorted(set(h.lower() for h in HEX_CONSTANT.findall(source)))
        version = version_for(source)
        work = compiler.prepare_source(path, compiler.IMPORT_CACHE_DIR)
        out = solcx.compile_files([str(work)], output_values=["storage-layout", "abi"], solc_version=version,
                                  evm_version="london" if version == "0.8.19" else "osaka",
                                  allow_paths=[str(work.parent), str(compiler.IMPORT_CACHE_DIR), str(Path(path).parent)],
                                  base_path=str(compiler.IMPORT_CACHE_DIR))
        for key, data in out.items():
            unit, name = key.rsplit(":", 1)
            if Path(unit).name != Path(path).name:
                continue
            layout = data.get("storage-layout") or {}
            types = layout.get("types") or {}
            contracts[f"{rel}:{name}"] = [
                {"label": s["label"], "slot": s["slot"], "offset": s["offset"],
                 "type": (types.get(s["type"]) or {}).get("label", s["type"]), "contract": s["contract"].rsplit(":", 1)[-1]}
                for s in layout.get("storage", [])]
    return {"contracts": dict(sorted(contracts.items())), "slotStrings": strings, "structs": structs,
            "enumSizes": enums, "hexSlotConstants": hexes}


if __name__ == "__main__":
    p = argparse.ArgumentParser(); p.add_argument("--out", required=True); p.add_argument("--compare"); p.add_argument("--only", nargs="*", default=[])
    a = p.parse_args()
    snap = snapshot(a.only)
    Path(a.out).write_text(json.dumps(snap, indent=1) + "\n")
    print("contracts:", len(snap["contracts"]), "with storage:", sum(1 for v in snap["contracts"].values() if v))
    if a.compare:
        old = json.loads(Path(a.compare).read_text())
        problems = []
        keep = lambda k: not a.only or any(k.startswith(o) for o in a.only)
        old["contracts"] = {k: v for k, v in old["contracts"].items() if keep(k)}
        for k, v in old["contracts"].items():
            if k not in snap["contracts"]:
                problems.append(f"missing contract {k}")
            elif v != snap["contracts"][k]:
                problems.append(f"layout changed: {k}")
        for k in snap["contracts"]:
            if k not in old["contracts"] and snap["contracts"][k]:
                problems.append(f"new contract with storage {k}")
        for section in ("slotStrings", "structs", "enumSizes", "hexSlotConstants"):
            for k, v in old.get(section, {}).items():
                if keep(k) and snap[section].get(k) != v:
                    problems.append(f"{section} changed: {k}")
        print("\n".join(problems) if problems else "IDENTICAL storage layouts and namespaced slots")
        sys.exit(1 if problems else 0)
