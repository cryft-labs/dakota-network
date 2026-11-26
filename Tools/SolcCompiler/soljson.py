#!/usr/bin/env python3
"""Run an official soljson (emscripten) compiler build through Node.

Why: solc 0.8.19 (the validator contract's pinned compiler) ships only an x86_64 native binary for macOS.
On Apple Silicon without Rosetta it cannot run. The official soljson build of the same release produces the
same bytecode for the same standard-JSON input.

Two uses:
  * `compile_standard(input, version)`: standard JSON in, standard JSON out. Release builds use this.
  * a CLI shim for py-solc-x (tests only). Install it as ~/.solcx/solc-v0.8.19 with
        python Tools/SolcCompiler/soljson.py --install-shim 0.8.19
    It emulates the subset of the solc CLI that py-solc-x calls: --version, --combined-json, --evm-version,
    --optimize, --optimize-runs, --base-path, --allow-paths, files or "-" (stdin).

The soljson file is fetched once from binaries.soliditylang.org and pinned by sha256 below.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

PINS = {
    # version: (file name, sha256) from https://binaries.soliditylang.org/bin/list.json
    "0.8.19": ("soljson-v0.8.19+commit.7dd6d404.js", "e0b74e0a16e783a35169f74d1a615ecb48d07c30f97346b83cd587949268681e"),
}
CACHE = Path(os.environ.get("CRYFT_SOLJSON_DIR", Path.home() / ".solcx" / "soljson"))
RUNNER = r"""
const soljson = require(process.argv[2]);
const compile = soljson.cwrap('solidity_compile', 'string', ['string', 'number', 'number']);
const version = soljson.cwrap('solidity_version', 'string', []);
if (process.argv[3] === '--version') { process.stdout.write(version()); process.exit(0); }
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => input += d);
process.stdin.on('end', () => process.stdout.write(compile(input, 0, 0)));
"""


def _sha(path):
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def soljson_path(version):
    name, digest = PINS[version]
    path = CACHE / name
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        part = path.with_suffix(".part")
        with urllib.request.urlopen("https://binaries.soliditylang.org/bin/" + name, timeout=120) as r:
            part.write_bytes(r.read())
        part.replace(path)
    if _sha(path) != digest:
        raise SystemExit(f"soljson {name}: sha256 mismatch")
    return path


def _node(version, args, stdin=""):
    node = shutil.which("node")
    if not node:
        raise SystemExit("node is required to run soljson")
    runner = CACHE / "run-soljson.js"
    if not runner.exists() or runner.read_text() != RUNNER:
        CACHE.mkdir(parents=True, exist_ok=True)
        runner.write_text(RUNNER)
    out = subprocess.run([node, str(runner), str(soljson_path(version)), *args], input=stdin,
                         capture_output=True, text=True, check=True)
    return out.stdout


def full_version(version):
    return _node(version, ["--version"]).strip()


def compile_standard(standard_input, version):
    """Standard JSON in (dict or str), dict out. Every source must be inlined (no import callback)."""
    text = standard_input if isinstance(standard_input, str) else json.dumps(standard_input)
    return json.loads(_node(version, [], text))


# ── CLI shim (tests only) ─────────────────────────────────────────────

IMPORT = re.compile(r'^\s*import\s+(?:[^"\']*?\bfrom\s+)?["\']([^"\']+)["\']', re.M)


def _collect(sources, unit, path, base, allow):
    if unit in sources:
        return
    text = path.read_text(encoding="utf-8")
    sources[unit] = {"content": text}
    for target in IMPORT.findall(text):
        if target.startswith("."):
            child = (path.parent / target).resolve()
            child_unit = os.path.normpath(os.path.join(os.path.dirname(unit), target)).replace(os.sep, "/")
        else:
            child = None
            for root in [base, *allow]:
                if root and (Path(root) / target).exists():
                    child = (Path(root) / target).resolve()
                    break
            if child is None:
                raise SystemExit(f"Source \"{target}\" not found")
            child_unit = target
        _collect(sources, child_unit, child, base, allow)


def _unit_for(path, base):
    path = Path(path).resolve()
    if base:
        try:
            return str(path.relative_to(Path(base).resolve())).replace(os.sep, "/")
        except ValueError:
            pass
    return str(path).replace(os.sep, "/")


def shim(version, argv):
    if "--version" in argv:
        print(f"solc, the solidity compiler commandline interface\nVersion: {full_version(version)}")
        return 0
    fields, evm, optimize, runs, base, allow, files, stdin = [], None, False, 200, None, [], [], False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--combined-json":
            fields = argv[i + 1].split(","); i += 2; continue
        if a == "--evm-version":
            evm = argv[i + 1]; i += 2; continue
        if a == "--optimize":
            optimize = True; i += 1; continue
        if a == "--optimize-runs":
            runs = int(argv[i + 1]); i += 2; continue
        if a == "--base-path":
            base = argv[i + 1]; i += 2; continue
        if a == "--allow-paths":
            allow = [p for p in argv[i + 1].split(",") if p]; i += 2; continue
        if a == "-":
            stdin = True; i += 1; continue
        if a.startswith("--"):
            raise SystemExit(f"soljson shim: unsupported option {a}")
        files.append(a); i += 1
    sources = {}
    if stdin:
        sources["<stdin>"] = {"content": sys.stdin.read()}
    for f in files:
        _collect(sources, _unit_for(f, base), Path(f).resolve(), base, allow)
    selection = {"abi": "abi", "bin": "evm.bytecode.object", "bin-runtime": "evm.deployedBytecode.object",
                 "opcodes": "evm.bytecode.opcodes", "metadata": "metadata"}
    settings = {"optimizer": {"enabled": optimize, "runs": runs},
                "outputSelection": {"*": {"*": sorted({selection[f] for f in fields if f in selection})}}}
    if evm:
        settings["evmVersion"] = evm
    out = compile_standard({"language": "Solidity", "sources": sources, "settings": settings}, version)
    errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    if errors:
        sys.stderr.write("\n".join(e.get("formattedMessage", e.get("message", "")) for e in errors) + "\n")
        return 1
    contracts = {}
    for unit, named in out.get("contracts", {}).items():
        for name, data in named.items():
            entry = {}
            for f in fields:
                if f == "abi":
                    entry["abi"] = data.get("abi", [])
                elif f == "bin":
                    entry["bin"] = data["evm"]["bytecode"]["object"]
                elif f == "bin-runtime":
                    entry["bin-runtime"] = data["evm"]["deployedBytecode"]["object"]
                elif f == "opcodes":
                    entry["opcodes"] = data["evm"]["bytecode"].get("opcodes", "")
                elif f == "metadata":
                    entry["metadata"] = data.get("metadata", "")
            contracts[f"{unit}:{name}"] = entry
    json.dump({"contracts": contracts, "version": full_version(version)}, sys.stdout)
    return 0


def install_shim(version):
    target = Path.home() / ".solcx" / f"solc-v{version}"
    if target.exists() and not target.read_text(errors="ignore").startswith("#!/bin/sh\n# soljson shim"):
        backup = target.with_name(target.name + ".native")
        target.replace(backup)
    target.write_text(f'#!/bin/sh\n# soljson shim (tests only)\nexec "{sys.executable}" "{Path(__file__).resolve()}" --shim {version} "$@"\n')
    target.chmod(0o755)
    print(target)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--shim":
        raise SystemExit(shim(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) == 3 and sys.argv[1] == "--install-shim":
        install_shim(sys.argv[2])
        raise SystemExit(0)
    raise SystemExit(__doc__)
