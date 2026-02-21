# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.
# This software is part of a patented system. See LICENSE and PATENT NOTICE.

"""
Solidity Runtime Bytecode Compiler
===================================
Compiles Solidity contracts locally and extracts runtime bytecode
without deploying to a testnet. Uses Cancun EVM and Solidity 0.8.x+.

Directory layout (alongside this script):
    solc_compiler/
        compile.py              <-- this script
        contracts/              <-- drop .sol files/folders here
            MyContract.sol
            subfolder/
                Another.sol
        compiled_output/        <-- artifacts appear here, mirroring structure
            MyContract/
                MyContract_runtime.bin
                MyContract_abi.json
                ...
            subfolder/
                Another/
                    ...

Usage:
    python compile.py                          # compile all .sol in contracts/
    python compile.py --clean-cache            # clear downloaded import cache
    python compile.py --solc-version 0.8.0     # override compiler version
    python compile.py --evm berlin             # override EVM target
"""

import argparse
import json
import os
import sys
import re
import shutil
import ssl
import urllib.request
from pathlib import Path

# Fix SSL certificate verification issues on Windows
try:
    import certifi
    _ca_bundle = certifi.where()
    os.environ["SSL_CERT_FILE"] = _ca_bundle
    os.environ["REQUESTS_CA_BUNDLE"] = _ca_bundle
    os.environ["CURL_CA_BUNDLE"] = _ca_bundle
except ImportError:
    _ca_bundle = None

# Build a reusable SSL context (for urllib calls in this script)
try:
    _ssl_context = ssl.create_default_context(cafile=_ca_bundle)
except Exception:
    _ssl_context = ssl.create_default_context()
    _ssl_context.check_hostname = False
    _ssl_context.verify_mode = ssl.CERT_NONE

# Monkey-patch ssl.create_default_context so all libraries (requests, urllib3,
# solcx) pick up certifi certs automatically.
_original_create_default_context = ssl.create_default_context
def _patched_create_default_context(purpose=ssl.Purpose.SERVER_AUTH, *, cafile=None, capath=None, cadata=None):
    ctx = _original_create_default_context(purpose, cafile=cafile or _ca_bundle, capath=capath, cadata=cadata)
    return ctx
ssl.create_default_context = _patched_create_default_context

try:
    import solcx
except ImportError:
    print("Installing py-solc-x...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "py-solc-x"])
    import solcx

# Patch requests to use our SSL certs (fixes solcx download issues)
try:
    import requests
    _ca_bundle = None
    try:
        _ca_bundle = certifi.where()
    except Exception:
        pass

    _original_request = requests.Session.request
    def _patched_request(self, method, url, **kwargs):
        if "verify" not in kwargs:
            kwargs["verify"] = _ca_bundle if _ca_bundle else False
        return _original_request(self, method, url, **kwargs)
    requests.Session.request = _patched_request
except ImportError:
    pass


# ────────────────────────────────────────────
# Import resolution
# ────────────────────────────────────────────

OPENZEPPELIN_GITHUB_RAW = "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts-upgradeable"

APP_DIR = Path(__file__).parent.resolve()
CONTRACTS_DIR = APP_DIR.parent.parent / "Contracts"
OUTPUT_DIR = APP_DIR / "compiled_output"
IMPORT_CACHE_DIR = APP_DIR / ".import_cache"


def _download_file(raw_url: str, local_path: Path) -> bool:
    """Download a file from a URL to a local path. Returns True on success."""
    local_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"  Downloading: {raw_url}")
    try:
        req = urllib.request.urlopen(raw_url, context=_ssl_context)
        local_path.write_bytes(req.read())
        return True
    except Exception as e:
        print(f"  Warning: Failed to download {raw_url}: {e}")
        return False


def resolve_github_import(import_path: str, cache_dir: Path) -> Path:
    """Download and cache a GitHub import URL, returning the local path."""
    # Match: https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/...
    gh_match = re.match(
        r"https://github\.com/([^/]+/[^/]+)/blob/([^/]+)/(.+)", import_path
    )
    if gh_match:
        repo = gh_match.group(1)
        ref = gh_match.group(2)
        file_path = gh_match.group(3)
        raw_url = f"https://raw.githubusercontent.com/{repo}/{ref}/{file_path}"
        local_path = cache_dir / repo.replace("/", "_") / ref / file_path
    else:
        return None

    if local_path.exists():
        return local_path

    if not _download_file(raw_url, local_path):
        return None

    # Recursively resolve imports in the downloaded file
    resolve_imports_in_file(local_path, cache_dir)
    return local_path


def _infer_github_url(cached_file: Path, relative_import: str, cache_dir: Path) -> str:
    """
    Given a cached file and a relative import path, reconstruct the GitHub raw URL.

    Cached files live at: cache_dir/<repo_slug>/<ref>/contracts/path/to/File.sol
    A relative import like '../../utils/Foo.sol' should resolve against the
    original GitHub path structure.
    """
    # Resolve the relative import against the cached file's directory
    resolved = (cached_file.parent / relative_import).resolve()
    # Try to find the repo slug and ref in the path
    try:
        rel_to_cache = resolved.relative_to(cache_dir.resolve())
    except ValueError:
        return None

    parts = rel_to_cache.parts
    if len(parts) < 3:
        return None

    # parts[0] = "OpenZeppelin_openzeppelin-contracts-upgradeable"
    # parts[1] = "v4.9.0"
    # parts[2:] = "contracts/utils/AddressUpgradeable.sol"
    repo_slug = parts[0]
    ref = parts[1]
    file_path = "/".join(parts[2:])

    # Convert slug back to owner/repo
    # Slug format: "Owner_repo-name" → "Owner/repo-name"
    underscore_idx = repo_slug.find("_")
    if underscore_idx == -1:
        return None
    owner = repo_slug[:underscore_idx]
    repo_name = repo_slug[underscore_idx + 1:]

    return f"https://raw.githubusercontent.com/{owner}/{repo_name}/{ref}/{file_path}"


def resolve_imports_in_file(sol_file: Path, cache_dir: Path, _visited: set = None):
    """Read a .sol file, download any GitHub imports, and rewrite them to local paths.
    Also resolves relative imports in cached GitHub files by reconstructing URLs."""
    if _visited is None:
        _visited = set()
    sol_file = sol_file.resolve()
    if sol_file in _visited:
        return
    _visited.add(sol_file)

    content = sol_file.read_text(encoding="utf-8", errors="replace")
    # Match: import "path"; and import {X} from "path";
    imports = re.findall(r'import\s+(?:\{[^}]*\}\s+from\s+)?"([^"]+)";', content)
    imports += re.findall(r"import\s+(?:\{[^}]*\}\s+from\s+)?'([^']+)';", content)

    for imp in imports:
        if imp.startswith("http://") or imp.startswith("https://"):
            # Direct GitHub URL import
            local = resolve_github_import(imp, cache_dir)
            if local:
                rel = os.path.relpath(str(local), str(sol_file.parent)).replace("\\", "/")
                content = content.replace(imp, rel)
        elif imp.startswith("@"):
            continue  # package imports handled elsewhere
        else:
            # Relative import — check if it already exists locally
            resolved = (sol_file.parent / imp).resolve()
            if resolved.exists():
                # Already exists; recurse into it
                resolve_imports_in_file(resolved, cache_dir, _visited)
            else:
                # Not on disk — try to reconstruct the GitHub URL and download
                raw_url = _infer_github_url(sol_file, imp, cache_dir)
                if raw_url:
                    if _download_file(raw_url, resolved):
                        resolve_imports_in_file(resolved, cache_dir, _visited)

    sol_file.write_text(content, encoding="utf-8")


def prepare_source(sol_path: str, cache_dir: Path) -> Path:
    """Copy source file to working dir and resolve all imports."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    work_dir = cache_dir / "source"
    work_dir.mkdir(parents=True, exist_ok=True)

    src = Path(sol_path).resolve()
    dst = work_dir / src.name

    # Copy the original and any local imports
    copy_local_tree(src, work_dir, set())

    # Resolve GitHub/HTTP imports
    resolve_imports_in_file(dst, cache_dir)

    return dst


def copy_local_tree(src_file: Path, work_dir: Path, visited: set):
    """Recursively copy local import dependencies."""
    src_file = src_file.resolve()
    if src_file in visited:
        return
    visited.add(src_file)

    dst = work_dir / src_file.name
    if not dst.exists() or dst.read_text(encoding="utf-8", errors="replace") != src_file.read_text(encoding="utf-8", errors="replace"):
        shutil.copy2(src_file, dst)

    content = src_file.read_text(encoding="utf-8", errors="replace")
    imports = re.findall(r'import\s+"([^"]+)";', content)
    imports += re.findall(r"import\s+'([^']+)';", content)

    for imp in imports:
        if imp.startswith("http") or imp.startswith("@"):
            continue
        imp_path = (src_file.parent / imp).resolve()
        if imp_path.exists():
            # For relative imports that are in subdirectories, maintain structure
            rel = os.path.relpath(imp_path, src_file.parent)
            dest_path = work_dir / rel
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            if not dest_path.exists():
                shutil.copy2(imp_path, dest_path)
            copy_local_tree(imp_path, dest_path.parent, visited)


# ────────────────────────────────────────────
# Compilation
# ────────────────────────────────────────────

VALID_EVM_VERSIONS = [
    "homestead", "tangerineWhistle", "spuriousDragon",
    "byzantium", "constantinople", "petersburg",
    "istanbul", "berlin", "london", "paris", "shanghai", "cancun",
]

DEFAULT_SOLC_VERSION = "0.8.19"
DEFAULT_EVM_VERSION = "cancun"


def get_pragma_constraints(source: str) -> tuple:
    """
    Parse pragma solidity constraints and return (min_version, max_version).

    Handles: >=0.8.2 <0.8.20, ^0.8.0, ^0.8.2, >=0.8.0, etc.
    Returns (min, max) as tuples of ints, e.g. ((0,8,2), (0,8,20)) or None for no bound.
    """
    match = re.search(r"pragma\s+solidity\s+(.+?);", source)
    if not match:
        return None, None

    constraint = match.group(1).strip()
    min_ver = None
    max_ver = None

    # >=X.Y.Z
    m = re.search(r">=\s*(0\.8\.(\d+))", constraint)
    if m:
        min_ver = (0, 8, int(m.group(2)))

    # <X.Y.Z  (strict upper bound)
    m = re.search(r"<\s*(0\.8\.(\d+))", constraint)
    if m:
        max_ver = (0, 8, int(m.group(2)) - 1)  # exclusive → inclusive

    # <=X.Y.Z
    m = re.search(r"<=\s*(0\.8\.(\d+))", constraint)
    if m:
        max_ver = (0, 8, int(m.group(2)))

    # ^X.Y.Z  (>=X.Y.Z, <0.9.0 effectively — but for 0.8.x it means >=X.Y.Z <0.9.0)
    m = re.search(r"\^\s*(0\.8\.(\d+))", constraint)
    if m:
        min_ver = (0, 8, int(m.group(2)))
        if max_ver is None:
            max_ver = (0, 8, 99)  # effectively no 0.8.x upper bound

    return min_ver, max_ver


def _ver_tuple(version_str: str) -> tuple:
    """Convert '0.8.19' to (0, 8, 19)."""
    parts = version_str.split(".")
    return tuple(int(p) for p in parts)


def pick_solc_version(source: str) -> str:
    """
    Choose the best installed solc version that satisfies the pragma.
    Falls back to DEFAULT_SOLC_VERSION, then tries to install the minimum.
    """
    min_ver, max_ver = get_pragma_constraints(source)

    installed = sorted(
        [str(v) for v in solcx.get_installed_solc_versions()],
        key=lambda v: _ver_tuple(v),
        reverse=True,  # prefer newest
    )

    for v in installed:
        vt = _ver_tuple(v)
        if min_ver and vt < min_ver:
            continue
        if max_ver and vt > max_ver:
            continue
        return v

    # No installed version satisfies — return the minimum required
    if min_ver:
        return f"{min_ver[0]}.{min_ver[1]}.{min_ver[2]}"
    return DEFAULT_SOLC_VERSION


def install_solc(version: str):
    """Install the specified solc version if not already installed."""
    installed = [str(v) for v in solcx.get_installed_solc_versions()]
    if version not in installed:
        print(f"Installing solc {version}...")
        solcx.install_solc(version)
    solcx.set_solc_version(version)


def compile_contract(
    sol_path: str,
    solc_version: str = None,
    evm_version: str = DEFAULT_EVM_VERSION,
    contract_name: str = None,
    optimize: bool = True,
    optimize_runs: int = 200,
) -> dict:
    """
    Compile a Solidity file and return bytecode info for all contracts.

    Returns dict of:
        {contract_name: {
            "runtime_bytecode": "0x...",
            "creation_bytecode": "0x...",
            "abi": [...],
            "opcodes": "...",
        }}
    """
    sol_path = Path(sol_path).resolve()
    if not sol_path.exists():
        raise FileNotFoundError(f"File not found: {sol_path}")

    source = sol_path.read_text(encoding="utf-8", errors="replace")

    # Determine solc version
    if not solc_version:
        solc_version = pick_solc_version(source)
        print(f"Selected Solidity version: {solc_version}")

    if not solc_version.startswith("0.8"):
        print(f"Warning: Version {solc_version} is not 0.8.x — forcing {DEFAULT_SOLC_VERSION}")
        solc_version = DEFAULT_SOLC_VERSION

    install_solc(solc_version)

    # Validate EVM version
    if evm_version not in VALID_EVM_VERSIONS:
        print(f"Warning: Invalid EVM version '{evm_version}', using 'cancun'")
        evm_version = DEFAULT_EVM_VERSION

    print(f"\nCompiling with:")
    print(f"  Solidity: {solc_version}")
    print(f"  EVM:      {evm_version}")
    print(f"  Optimize: {optimize} (runs={optimize_runs})")
    print(f"  File:     {sol_path.name}")
    print()

    # Resolve imports
    print("Resolving imports...")
    work_file = prepare_source(str(sol_path), IMPORT_CACHE_DIR)

    # Build allow-paths for local imports
    allow_paths = [
        str(work_file.parent),
        str(IMPORT_CACHE_DIR),
        str(sol_path.parent),
    ]

    # Compile
    try:
        compiled = solcx.compile_files(
            [str(work_file)],
            output_values=[
                "abi",
                "bin",
                "bin-runtime",
                "opcodes",
                "metadata",
            ],
            solc_version=solc_version,
            evm_version=evm_version,
            optimize=optimize,
            optimize_runs=optimize_runs,
            allow_paths=allow_paths,
        )
    except solcx.exceptions.SolcError as e:
        print(f"\nCompilation failed:\n{e}")
        sys.exit(1)

    results = {}
    for key, contract_data in compiled.items():
        # key format: "path:ContractName"
        name = key.split(":")[-1]

        # Skip interfaces and abstract contracts (empty bytecode)
        runtime = contract_data.get("bin-runtime", "")
        creation = contract_data.get("bin", "")
        if not runtime and not creation:
            continue

        results[name] = {
            "runtime_bytecode": f"0x{runtime}" if runtime else "",
            "creation_bytecode": f"0x{creation}" if creation else "",
            "abi": contract_data.get("abi", []),
            "opcodes": contract_data.get("opcodes", ""),
            "runtime_size_bytes": len(bytes.fromhex(runtime)) if runtime else 0,
            "creation_size_bytes": len(bytes.fromhex(creation)) if creation else 0,
        }

    return results


# ────────────────────────────────────────────
# Output formatting
# ────────────────────────────────────────────

def print_results(results: dict, contract_name: str = None):
    """Print compilation results."""
    if not results:
        print("No contracts found in compilation output.")
        return

    contracts = results
    if contract_name:
        if contract_name in results:
            contracts = {contract_name: results[contract_name]}
        else:
            print(f"Contract '{contract_name}' not found. Available: {list(results.keys())}")
            return

    for name, data in contracts.items():
        print(f"{'='*70}")
        print(f"  Contract: {name}")
        print(f"  Runtime size:  {data['runtime_size_bytes']} bytes ({data['runtime_size_bytes'] / 1024:.1f} KB)")
        print(f"  Creation size: {data['creation_size_bytes']} bytes ({data['creation_size_bytes'] / 1024:.1f} KB)")
        if data['runtime_size_bytes'] > 24576:
            print(f"  ⚠ WARNING: Exceeds EIP-170 contract size limit (24,576 bytes)!")
        print(f"{'='*70}")
        print(f"\n  Runtime Bytecode:")
        print(f"  {data['runtime_bytecode'][:120]}...")
        print(f"\n  Creation Bytecode:")
        print(f"  {data['creation_bytecode'][:120]}...")
        print(f"\n  ABI entries: {len(data['abi'])}")
        print()


def save_results(results: dict, output_dir: str):
    """Save compilation artifacts to files."""
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    for name, data in results.items():
        # Runtime bytecode
        (out / f"{name}_runtime.bin").write_text(data["runtime_bytecode"])
        # Creation bytecode
        (out / f"{name}_creation.bin").write_text(data["creation_bytecode"])
        # ABI
        (out / f"{name}_abi.json").write_text(json.dumps(data["abi"], indent=2))
        # Full artifact
        (out / f"{name}_artifact.json").write_text(json.dumps(data, indent=2))

    print(f"Artifacts saved to: {out.resolve()}")


# ────────────────────────────────────────────
# Batch directory compilation
# ────────────────────────────────────────────

def discover_sol_files(contracts_dir: Path) -> list:
    """Find all .sol files in the contracts directory, recursively."""
    sol_files = sorted(contracts_dir.rglob("*.sol"))
    return [f for f in sol_files if f.is_file()]


def get_local_imports(sol_file: Path) -> set:
    """Extract local relative import paths from a .sol file (not HTTP/package imports)."""
    content = sol_file.read_text(encoding="utf-8", errors="replace")
    imports = re.findall(r'import\s+"([^"]+)";', content)
    imports += re.findall(r"import\s+'([^']+)';", content)
    # Also match import {X} from "path" style
    imports += re.findall(r'from\s+"([^"]+)"', content)
    imports += re.findall(r"from\s+'([^']+)'", content)

    local_paths = set()
    for imp in imports:
        if imp.startswith("http://") or imp.startswith("https://") or imp.startswith("@"):
            continue
        resolved = (sol_file.parent / imp).resolve()
        if resolved.exists():
            local_paths.add(resolved)
    return local_paths


def build_dependency_graph(contracts_dir: Path) -> tuple:
    """
    Scan all .sol files and determine which are root contracts vs imported dependencies.

    Returns:
        (root_files, imported_files)
        - root_files: list of .sol files that are NOT imported by any other file
        - imported_files: set of .sol files that ARE imported by at least one other file
    """
    all_files = [f.resolve() for f in contracts_dir.rglob("*.sol") if f.is_file()]
    imported_by_others = set()

    for sol_file in all_files:
        local_imports = get_local_imports(sol_file)
        for imp in local_imports:
            if imp in [f for f in all_files]:
                imported_by_others.add(imp)

    root_files = sorted([f for f in all_files if f not in imported_by_others])
    return root_files, imported_by_others


def compile_all(
    solc_version: str = None,
    evm_version: str = DEFAULT_EVM_VERSION,
    optimize: bool = True,
    optimize_runs: int = 200,
):
    """Compile all .sol files in the contracts/ directory and output artifacts."""
    # Ensure directories exist
    CONTRACTS_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    all_files = discover_sol_files(CONTRACTS_DIR)

    if not all_files:
        print(f"\nNo .sol files found in: {CONTRACTS_DIR}")
        print(f"Drop your Solidity files into that directory and run again.")
        return

    # Build dependency graph to skip imported files
    root_files, imported_files = build_dependency_graph(CONTRACTS_DIR)

    print("\n" + "=" * 60)
    print("  Solidity Runtime Bytecode Compiler")
    print("=" * 60)
    print(f"\n  Contracts dir:  {CONTRACTS_DIR}")
    print(f"  Output dir:     {OUTPUT_DIR}")
    print(f"  Solidity:       {solc_version or 'auto-detect'}")
    print(f"  EVM:            {evm_version}")
    print(f"  Optimize:       {optimize} (runs={optimize_runs})")
    print(f"\n  Found {len(all_files)} .sol file(s), {len(root_files)} root contract(s):\n")

    for f in all_files:
        rel = f.relative_to(CONTRACTS_DIR)
        if f.resolve() in imported_files:
            print(f"    {rel}  [IMPORT - skipped]")
        else:
            print(f"    {rel}  [ROOT - will compile]")
    print()

    total_compiled = 0
    total_failed = 0
    summary = []

    for sol_file in root_files:
        rel_path = sol_file.relative_to(CONTRACTS_DIR)
        # Output goes to: compiled_output/<relative_dir>/<filename_stem>/
        out_subdir = OUTPUT_DIR / rel_path.parent / sol_file.stem

        print(f"\n{'─'*60}")
        print(f"  Compiling: {rel_path}")
        print(f"{'─'*60}")

        try:
            results = compile_contract(
                str(sol_file),
                solc_version=solc_version,
                evm_version=evm_version,
                optimize=optimize,
                optimize_runs=optimize_runs,
            )

            if results:
                print_results(results)
                save_results(results, str(out_subdir))
                total_compiled += len(results)
                for name, data in results.items():
                    summary.append({
                        "source": str(rel_path),
                        "contract": name,
                        "runtime_bytes": data["runtime_size_bytes"],
                        "creation_bytes": data["creation_size_bytes"],
                        "output": str(out_subdir / name),
                        "over_limit": data["runtime_size_bytes"] > 24576,
                    })
            else:
                print(f"  No concrete contracts found in {rel_path}")

        except Exception as e:
            print(f"  FAILED: {e}")
            total_failed += 1
            summary.append({
                "source": str(rel_path),
                "contract": "ERROR",
                "runtime_bytes": 0,
                "creation_bytes": 0,
                "output": "",
                "over_limit": False,
                "error": str(e),
            })

    # Save manifest
    manifest_path = OUTPUT_DIR / "manifest.json"
    manifest_path.write_text(json.dumps(summary, indent=2))

    # Final summary
    print(f"\n{'='*60}")
    print(f"  COMPILATION SUMMARY")
    print(f"{'='*60}")
    print(f"  Total .sol files:   {len(all_files)}")
    print(f"  Root contracts:     {len(root_files)}")
    print(f"  Skipped (imports):  {len(imported_files)}")
    print(f"  Contracts compiled: {total_compiled}")
    print(f"  Failed:             {total_failed}")
    print()

    if summary:
        print(f"  {'Contract':<40} {'Runtime':>10} {'Status':>10}")
        print(f"  {'─'*40} {'─'*10} {'─'*10}")
        for item in summary:
            if item.get("error"):
                status = "FAILED"
            elif item["over_limit"]:
                status = "OVER 24KB"
            else:
                status = "OK"
            size_str = f"{item['runtime_bytes']:,} B" if item['runtime_bytes'] else "—"
            print(f"  {item['contract']:<40} {size_str:>10} {status:>10}")

    print(f"\n  Artifacts: {OUTPUT_DIR}")
    print(f"  Manifest:  {manifest_path}")
    print()


# ────────────────────────────────────────────
# Main
# ────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Compile all Solidity contracts in the contracts/ directory"
    )
    parser.add_argument("--solc-version", default=None, help=f"Solidity compiler version (default: auto-detect, fallback: {DEFAULT_SOLC_VERSION})")
    parser.add_argument("--evm", default=DEFAULT_EVM_VERSION, help=f"EVM version (default: {DEFAULT_EVM_VERSION})")
    parser.add_argument("--no-optimize", action="store_true", help="Disable optimizer")
    parser.add_argument("--runs", type=int, default=200, help="Optimizer runs (default: 200)")
    parser.add_argument("--clean-cache", action="store_true", help="Clear the downloaded import cache")
    parser.add_argument("--clean-output", action="store_true", help="Clear previous compiled output before compiling")

    args = parser.parse_args()

    if args.clean_cache:
        if IMPORT_CACHE_DIR.exists():
            shutil.rmtree(IMPORT_CACHE_DIR)
            print("Import cache cleared.")
        if not args.clean_output:
            return

    if args.clean_output:
        if OUTPUT_DIR.exists():
            shutil.rmtree(OUTPUT_DIR)
            print("Compiled output cleared.")
        if args.clean_cache:
            return

    compile_all(
        solc_version=args.solc_version,
        evm_version=args.evm,
        optimize=not args.no_optimize,
        optimize_runs=args.runs,
    )


if __name__ == "__main__":
    main()
