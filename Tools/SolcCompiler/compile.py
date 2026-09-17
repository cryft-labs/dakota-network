# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.
# This software is part of a patented system. See LICENSE and PATENT NOTICE.

"""
Solidity Runtime Bytecode Compiler
===================================
Compiles Solidity contracts locally and extracts runtime bytecode
without deploying to a testnet. Exports self-contained Solidity standard JSON
verification inputs. Public target: Osaka; validator: London/0.8.19; private
target: Shanghai until the separately reviewed Pente runtime supports a newer fork.

Directory layout:
    dakota-network/
        Contracts/              <-- source .sol files (recursive scan)
            Genesis/
                7702/
                CodeManagement/
                GasManager/
                ValidatorContracts/
                Upgradeable/    <-- vendored OZ 4.9.6 + proxy stack
            Tokens/
        Tools/
            solc_compiler/
                compile.py          <-- this script
                compiled_output/    <-- artifacts appear here, mirroring structure
                .import_cache/      <-- downloaded OZ imports (GitHub URLs)

Usage:
    python compile.py                          # compile all .sol in Contracts/
    python compile.py --clean-cache            # clear downloaded import cache
    python compile.py --clean-output           # clear previous compiled output
    python compile.py --solc-version 0.8.37    # public/private compiler override
    python compile.py --evm berlin             # override EVM target
    python compile.py --private --file Contracts/Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol
"""

import argparse
import json
import hashlib
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
    raise SystemExit("Install the pinned compiler dependencies: python -m pip install py-solc-x==2.0.5")

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
            kwargs["verify"] = _ca_bundle if _ca_bundle else True
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
        local_path.write_bytes(req.read().replace(b"\r\n", b"\n"))
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


def _extract_version_from_cache_path(file_path: Path, cache_dir: Path) -> str:
    """Extract the OZ version tag (e.g. 'v5.0.0') from a cached file's path."""
    try:
        rel = file_path.resolve().relative_to(cache_dir.resolve())
        parts = rel.parts
        # Expected layout: parts[0] = repo slug, parts[1] = version tag
        if len(parts) >= 2 and parts[1].startswith("v"):
            return parts[1]
    except ValueError:
        pass
    return None


def _resolve_openzeppelin_import(import_path: str, importing_file: Path, cache_dir: Path) -> Path:
    """
    Resolve @openzeppelin/... imports by downloading from the correct GitHub repo.

    Maps:
      @openzeppelin/contracts/X        → OpenZeppelin/openzeppelin-contracts,          contracts/X
      @openzeppelin/contracts-upgradeable/X → OpenZeppelin/openzeppelin-contracts-upgradeable, contracts/X
    """
    version = _extract_version_from_cache_path(importing_file, cache_dir)
    if not version:
        version = "v5.0.0"  # sensible default for OZ v5

    if import_path.startswith("@openzeppelin/contracts-upgradeable/"):
        suffix = import_path[len("@openzeppelin/contracts-upgradeable/"):]
        repo = "OpenZeppelin/openzeppelin-contracts-upgradeable"
    elif import_path.startswith("@openzeppelin/contracts/"):
        suffix = import_path[len("@openzeppelin/contracts/"):]
        repo = "OpenZeppelin/openzeppelin-contracts"
    else:
        return None

    github_url = f"https://github.com/{repo}/blob/{version}/contracts/{suffix}"
    return resolve_github_import(github_url, cache_dir)


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
        elif imp.startswith("@openzeppelin/"):
            # Resolve @openzeppelin package imports by downloading from GitHub
            local = _resolve_openzeppelin_import(imp, sol_file, cache_dir)
            if local:
                rel = os.path.relpath(str(local), str(sol_file.parent)).replace("\\", "/")
                content = content.replace(imp, rel)
        elif imp.startswith("@"):
            continue  # other package imports not handled
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

    sol_file.write_text(content, encoding="utf-8", newline="\n")


def prepare_source(sol_path: str, cache_dir: Path) -> Path:
    """Copy source file to working dir and resolve all imports.

    The local import tree is mirrored inside ``cache_dir/source/`` using
    relative paths anchored at ``CONTRACTS_DIR`` so that ``../`` imports
    never escape the ``source/`` directory.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    work_dir = cache_dir / "source"
    work_dir.mkdir(parents=True, exist_ok=True)

    src = Path(sol_path).resolve()
    contracts_root = CONTRACTS_DIR.resolve()

    # Copy the original and any local imports, mirroring the directory
    # structure relative to CONTRACTS_DIR.
    copy_local_tree(src, work_dir, contracts_root, set())

    # Destination mirrors the original contract path inside source/
    dst = work_dir / src.relative_to(contracts_root)

    # Resolve GitHub/HTTP imports
    resolve_imports_in_file(dst, cache_dir)

    return dst


def _copy_normalized(src: Path, dst: Path):
    """Copy a source file, normalizing CRLF to LF for deterministic builds.

    solc includes a keccak256 of each source file in the IPFS metadata hash
    appended to the bytecode.  Windows CRLF vs Unix LF produces different
    hashes, so we strip \\r\\n -> \\n before writing to the build directory."""
    normalized = src.read_bytes().replace(b"\r\n", b"\n")
    if dst.exists() and dst.read_bytes() == normalized:
        return
    dst.write_bytes(normalized)


def copy_local_tree(src_file: Path, work_dir: Path,
                    src_root: Path, visited: set):
    """Recursively copy local import dependencies.

    All files are placed at ``work_dir / relpath(file, src_root)`` so that
    the directory hierarchy inside ``work_dir`` mirrors the original source
    tree and ``../`` imports resolve correctly without escaping the boundary.
    """
    src_file = src_file.resolve()
    if src_file in visited:
        return
    visited.add(src_file)

    rel = src_file.relative_to(src_root)
    dst = work_dir / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    _copy_normalized(src_file, dst)

    content = src_file.read_text(encoding="utf-8", errors="replace")
    imports = re.findall(r'import\s+(?:\{[^}]*\}\s+from\s+)?"([^"]+)";', content)
    imports += re.findall(r"import\s+(?:\{[^}]*\}\s+from\s+)?'([^']+)';", content)

    for imp in imports:
        if imp.startswith("http") or imp.startswith("@"):
            continue
        imp_path = (src_file.parent / imp).resolve()
        if imp_path.exists():
            copy_local_tree(imp_path, work_dir, src_root, visited)


# ────────────────────────────────────────────
# Compilation
# ────────────────────────────────────────────

VALID_EVM_VERSIONS = [
    "homestead", "tangerineWhistle", "spuriousDragon",
    "byzantium", "constantinople", "petersburg",
    "istanbul", "berlin", "london", "paris", "shanghai", "cancun",
    "prague", "osaka",
]

DEFAULT_SOLC_VERSION = "0.8.37"
DEFAULT_EVM_VERSION = "osaka"

# Pente v1.0.0 bundles Besu EVM 24.5.4, but its transaction selector only
# accepts London, Paris and Shanghai. A Cancun helper exists but is not wired.
# The private target must be raised together with a reviewed Pente upgrade.
DEFAULT_PRIVATE_EVM_VERSION = "shanghai"
PRIVATE_ENTRYPOINTS = {
    "codemanagement/privatecardcontentregistry.sol",
    "codemanagement/privatecombostorage.sol",
    "codemanagement/privatemetatxrelay.sol",
    "codemanagement/interfaces/iprivatemetatxrelay.sol",
}
VALIDATOR_SOLC_VERSION = "0.8.19"
VALIDATOR_EVM_VERSION = "london"


def contract_compile_settings(sol_path, solc_version, evm_version, private_evm_version, private=False):
    relative = Path(sol_path).resolve().relative_to(CONTRACTS_DIR.resolve()).as_posix().lower()
    if relative.startswith("genesis/validatorcontracts/"):
        return VALIDATOR_SOLC_VERSION, VALIDATOR_EVM_VERSION
    if private or relative in PRIVATE_ENTRYPOINTS:
        if private_evm_version not in {"london", "paris", "shanghai"}:
            raise ValueError("Pente v1.0.0 selects at most Shanghai; review a Pente runtime upgrade before raising this target")
        evm_version = private_evm_version
    if evm_version not in VALID_EVM_VERSIONS:
        raise ValueError(f"Invalid EVM target: {evm_version}")
    return solc_version or DEFAULT_SOLC_VERSION, evm_version

# Maximum EVM version supported by each solc range
_SOLC_EVM_CAPS = [
    # (max_solc_exclusive, max_evm)
    ((0, 8, 20), "london"),    # solc <0.8.20 → max london
    ((0, 8, 24), "shanghai"),  # solc 0.8.20–0.8.23 → max shanghai
    ((0, 8, 28), "cancun"),    # solc 0.8.24–0.8.27 → max cancun
    ((0, 9, 0),  "osaka"),     # solc 0.8.28+ → osaka
]

def clamp_evm_version(solc_version: str, evm_version: str) -> str:
    """
    Clamp the EVM target to the maximum supported by the selected solc.
    E.g. solc 0.8.19 only supports up to london, so cancun → london.
    """
    sv = _ver_tuple(solc_version)
    evm_idx = VALID_EVM_VERSIONS.index(evm_version) if evm_version in VALID_EVM_VERSIONS else 0
    for max_solc, max_evm in _SOLC_EVM_CAPS:
        if sv < max_solc:
            cap_idx = VALID_EVM_VERSIONS.index(max_evm)
            if evm_idx > cap_idx:
                return max_evm
            return evm_version
    return evm_version


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
    private_evm_version: str = DEFAULT_PRIVATE_EVM_VERSION,
    private: bool = False,
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

    solc_version, evm_version = contract_compile_settings(
        sol_path, solc_version, evm_version, private_evm_version, private)
    install_solc(solc_version)
    # Fail on incompatible compiler/target combinations instead of silently
    # emitting a different release target. Validator settings are explicitly pinned.

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
            base_path=str(IMPORT_CACHE_DIR),
        )
    except solcx.exceptions.SolcError as e:
        print(f"\nCompilation failed:\n{e}")
        raise

    results = {}
    source_base = (IMPORT_CACHE_DIR / "source").resolve()
    cache_base = IMPORT_CACHE_DIR.resolve()
    for key, contract_data in compiled.items():
        # key format: "path:ContractName"
        name = key.split(":")[-1]

        # Determine source path relative to the local Contracts tree first.
        # External cached dependencies are grouped under External/<owner>/<repo>/
        # <version>/..., so artifact layout stays deterministic and clearly
        # separated from in-repo contracts.
        source_name = key.rsplit(":", 1)[0]
        source_file = Path(source_name)
        if not source_file.is_absolute():
            source_file = IMPORT_CACHE_DIR / source_file
        source_file = source_file.resolve()
        try:
            source_rel = str(source_file.relative_to(source_base))
        except ValueError:
            try:
                source_rel = str(normalize_external_source_rel_path(source_file.relative_to(cache_base)))
            except ValueError:
                source_rel = str(Path("External") / source_file.name)

        # Export verification input for interfaces and abstract contracts too.
        runtime = contract_data.get("bin-runtime", "")
        creation = contract_data.get("bin", "")

        if contract_name and name != contract_name:
            continue
        if name in results:
            raise ValueError(f"Duplicate contract name in compilation: {name}; compile distinct source units separately")
        standard_input = standard_json_input(contract_data.get("metadata", ""))
        results[name] = {
            "runtime_bytecode": f"0x{runtime}" if runtime else "",
            "creation_bytecode": f"0x{creation}" if creation else "",
            "abi": contract_data.get("abi", []),
            "opcodes": contract_data.get("opcodes", ""),
            "metadata": contract_data.get("metadata", ""),
            "runtime_size_bytes": len(bytes.fromhex(runtime)) if runtime else 0,
            "creation_size_bytes": len(bytes.fromhex(creation)) if creation else 0,
            "source_rel_path": source_rel.replace("\\", "/"),
            "fully_qualified_name": f"{source_name}:{name}",
            "compiler_version": solc_version,
            "evm_version": evm_version,
            "deployable": bool(creation),
            "standard_json_input": standard_input,
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


def standard_json_input(metadata_text: str) -> dict:
    """Embed the exact compiled sources with solc's metadata-derived settings.

    Source unit names are relative to the import cache, so verification never
    needs the operator's filesystem or an HTTP import callback.
    """
    metadata = json.loads(metadata_text)
    settings = dict(metadata["settings"])
    targets = settings.pop("compilationTarget")
    settings["outputSelection"] = {
        source: {name: ["abi", "metadata", "storageLayout", "evm.bytecode", "evm.deployedBytecode"]}
        for source, name in targets.items()
    }
    sources = {}
    cache = IMPORT_CACHE_DIR.resolve()
    for name in sorted(metadata["sources"]):
        source = (cache / name).resolve()
        if not source.is_relative_to(cache):
            raise ValueError(f"Compiled source is outside the import cache: {name}")
        if Path(name).is_absolute() or "\\" in name:
            raise ValueError(f"Nonportable source unit name: {name}")
        # Preserve the compiled bytes, including CRLF, for metadata/source CIDs.
        sources[name] = {"content": source.read_bytes().decode("utf-8")}
    return {"language": "Solidity", "sources": sources, "settings": settings}


def save_results(results: dict, output_dir: str, quiet: bool = False):
    """Save compilation artifacts to files."""
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, data in results.items():
        # Runtime bytecode
        (out / f"{name}_runtime.bin").write_text(data["runtime_bytecode"], newline="\n")
        # Creation bytecode
        (out / f"{name}_creation.bin").write_text(data["creation_bytecode"], newline="\n")
        # ABI
        (out / f"{name}_abi.json").write_text(json.dumps(data["abi"], indent=2), newline="\n")
        # The exact source graph and metadata-derived settings are self-contained.
        standard_input = data.get("standard_json_input")
        if standard_input:
            encoded = json.dumps(standard_input, indent=2, sort_keys=True) + "\n"
            (out / f"{name}_standard_input.json").write_text(encoded, encoding="utf-8", newline="\n")
            data["standard_input_sha256"] = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
        # Full artifact
        (out / f"{name}_artifact.json").write_text(json.dumps(data, indent=2), newline="\n")
        # Solc metadata (the JSON whose IPFS hash is embedded in bytecode)
        if data.get("metadata"):
            # IPFS identifies these exact bytes: no BOM, added newline or reformatting.
            (out / f"{name}_metadata.json").write_bytes(data["metadata"].encode("utf-8"))

    if not quiet:
        print(f"Artifacts saved to: {out.resolve()}")


def normalize_external_source_rel_path(cache_relative_path: Path) -> Path:
    """Map a cached dependency path into a readable External/ artifact path.

    Cache layout uses:
        <repo_slug>/<version>/<repo-relative source path>

    Artifacts use:
        External/<owner>/<repo>/<version>/<repo-relative source path>
    or, for non-GitHub/non-owner_repo cache slugs:
        External/Vendor/<slug>/<version>/<repo-relative source path>

    Example:
        OpenZeppelin_openzeppelin-contracts/v5.2.0/contracts/utils/Address.sol
        -> External/OpenZeppelin/openzeppelin-contracts/v5.2.0/contracts/utils/Address.sol
    """
    parts = cache_relative_path.parts
    if len(parts) < 3:
        return Path("External") / cache_relative_path

    repo_slug = parts[0]
    version = parts[1]
    remainder = Path(*parts[2:])

    underscore_idx = repo_slug.find("_")
    if underscore_idx == -1:
        return Path("External") / "Vendor" / repo_slug / version / remainder

    owner = repo_slug[:underscore_idx]
    repo_name = repo_slug[underscore_idx + 1:]
    return Path("External") / owner / repo_name / version / remainder


def get_contract_output_dir(output_root: Path, source_rel_path: str, contract_name: str, evm_version: str = DEFAULT_EVM_VERSION) -> Path:
    """Build an artifact directory that mirrors the Contracts tree dynamically.

    Artifacts are stored under:
        compiled_output/<evm version>/<source parent directories>/<contract_name>/

    This preserves the source directory hierarchy without hardcoded folder rules
    and ensures each concrete contract gets its own directory even when multiple
    contracts are compiled from the same Solidity file.
    """
    source_rel = Path(source_rel_path)
    directory = output_root / evm_version / source_rel.parent / contract_name
    # Preserve the readable source hierarchy even beyond Windows MAX_PATH.
    # The extended absolute form also survives manifest-driven IPFS publication.
    if os.name == "nt":
        absolute = str(directory.resolve())
        if not absolute.startswith("\\\\?\\"):
            absolute = "\\\\?\\UNC\\" + absolute[2:] if absolute.startswith("\\\\") else "\\\\?\\" + absolute
        return Path(absolute)
    return directory


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
    imports = re.findall(r'import\s+(?:\{[^}]*\}\s+from\s+)?"([^"]+)";', content)
    imports += re.findall(r"import\s+(?:\{[^}]*\}\s+from\s+)?'([^']+)';", content)
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
    private_evm_version: str = DEFAULT_PRIVATE_EVM_VERSION,
    private: bool = False,
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
                private_evm_version=private_evm_version,
                private=private,
            )

            if results:
                print_results(results)
                # Save each contract to a directory mirroring its source tree
                # and named after the concrete contract.
                for cname, cdata in results.items():
                    contract_out = get_contract_output_dir(
                        OUTPUT_DIR,
                        cdata.get("source_rel_path", f"{cname}.sol"),
                        cname,
                        cdata["evm_version"],
                    )
                    save_results({cname: cdata}, str(contract_out), quiet=True)
                print(f"Artifacts saved to: {OUTPUT_DIR.resolve()}")
                total_compiled += len(results)
                for name, data in results.items():
                    contract_out = get_contract_output_dir(
                        OUTPUT_DIR,
                        data.get("source_rel_path", f"{name}.sol"),
                        name,
                        data["evm_version"],
                    )
                    summary.append({
                        "source": data.get("source_rel_path", str(rel_path)),
                        "contract": name,
                        "runtime_bytes": data["runtime_size_bytes"],
                        "creation_bytes": data["creation_size_bytes"],
                        "output": str(contract_out),
                        "over_limit": data["runtime_size_bytes"] > 24576,
                        "evm_version": data["evm_version"],
                        "compiler_version": data["compiler_version"],
                        "standard_input_sha256": data.get("standard_input_sha256", ""),
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
    manifest_path.write_text(json.dumps(summary, indent=2), newline="\n")

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
    if total_failed:
        raise RuntimeError(f"{total_failed} Solidity source files failed to compile; see {manifest_path}")
    return summary


def compile_selected(
    file_paths: list[str],
    solc_version: str = None,
    evm_version: str = DEFAULT_EVM_VERSION,
    optimize: bool = True,
    optimize_runs: int = 200,
    private_evm_version: str = DEFAULT_PRIVATE_EVM_VERSION,
    private: bool = False,
):
    """Compile only the specified Solidity files and output artifacts."""
    CONTRACTS_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    selected_files = []
    for file_path in file_paths:
        resolved = Path(file_path).expanduser()
        if not resolved.is_absolute():
            resolved = (APP_DIR.parent.parent / resolved).resolve()
        else:
            resolved = resolved.resolve()

        if not resolved.exists() or not resolved.is_file():
            raise FileNotFoundError(f"File not found: {resolved}")
        if resolved.suffix.lower() != ".sol":
            raise ValueError(f"Not a Solidity file: {resolved}")
        selected_files.append(resolved)

    print("\n" + "=" * 60)
    print("  Solidity Runtime Bytecode Compiler")
    print("=" * 60)
    print(f"\n  Output dir:     {OUTPUT_DIR}")
    print(f"  Solidity:       {solc_version or 'auto-detect'}")
    print(f"  EVM:            {evm_version}")
    print(f"  Optimize:       {optimize} (runs={optimize_runs})")
    print(f"\n  Selected {len(selected_files)} file(s):\n")
    for sol_file in selected_files:
        try:
            rel = sol_file.relative_to(APP_DIR.parent.parent)
        except ValueError:
            rel = sol_file
        print(f"    {rel}")
    print()

    total_compiled = 0
    total_failed = 0
    summary = []

    for sol_file in selected_files:
        try:
            rel_path = sol_file.relative_to(APP_DIR.parent.parent)
        except ValueError:
            rel_path = sol_file

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
                private_evm_version=private_evm_version,
                private=private,
            )

            if results:
                print_results(results)
                for cname, cdata in results.items():
                    contract_out = get_contract_output_dir(
                        OUTPUT_DIR,
                        cdata.get("source_rel_path", f"{cname}.sol"),
                        cname,
                        cdata["evm_version"],
                    )
                    save_results({cname: cdata}, str(contract_out), quiet=True)
                print(f"Artifacts saved to: {OUTPUT_DIR.resolve()}")
                total_compiled += len(results)
                for name, data in results.items():
                    contract_out = get_contract_output_dir(
                        OUTPUT_DIR,
                        data.get("source_rel_path", f"{name}.sol"),
                        name,
                        data["evm_version"],
                    )
                    summary.append({
                        "source": data.get("source_rel_path", str(rel_path)),
                        "contract": name,
                        "runtime_bytes": data["runtime_size_bytes"],
                        "creation_bytes": data["creation_size_bytes"],
                        "output": str(contract_out),
                        "over_limit": data["runtime_size_bytes"] > 24576,
                        "evm_version": data["evm_version"],
                        "compiler_version": data["compiler_version"],
                        "standard_input_sha256": data.get("standard_input_sha256", ""),
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

    manifest_path = OUTPUT_DIR / "manifest.json"
    manifest_path.write_text(json.dumps(summary, indent=2), newline="\n")

    print(f"\n{'='*60}")
    print(f"  COMPILATION SUMMARY")
    print(f"{'='*60}")
    print(f"  Selected files:     {len(selected_files)}")
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
    if total_failed:
        raise RuntimeError(f"{total_failed} Solidity source files failed to compile; see {manifest_path}")
    return summary


# ────────────────────────────────────────────
# Main
# ────────────────────────────────────────────

def main():
    global OUTPUT_DIR
    # Redirected Windows output otherwise uses a legacy code page and can abort
    # a successful build on the progress table's Unicode characters.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="backslashreplace")
    parser = argparse.ArgumentParser(
        description="Compile Solidity contracts from the contracts directory or a selected file list"
    )
    parser.add_argument(
        "--file",
        action="append",
        default=[],
        help="Relative or absolute path to a Solidity file to compile. Repeat for multiple files.",
    )
    parser.add_argument("--solc-version", default=None, help=f"Solidity compiler version (default: auto-detect, fallback: {DEFAULT_SOLC_VERSION})")
    parser.add_argument("--evm", default=DEFAULT_EVM_VERSION, help=f"EVM version (default: {DEFAULT_EVM_VERSION})")
    parser.add_argument("--output-dir", type=Path, help="Write review artifacts outside the checked-in historical output directory")
    parser.add_argument("--private-evm", default=DEFAULT_PRIVATE_EVM_VERSION, choices=["london", "paris", "shanghai"], help="Pente private target; default Shanghai for Paladin v1.0.0")
    parser.add_argument("--private", action="store_true", help="Compile selected dependencies/proxies for a Pente group too")
    parser.add_argument("--no-optimize", action="store_true", help="Disable optimizer")
    parser.add_argument("--runs", type=int, default=200, help="Optimizer runs (default: 200)")
    parser.add_argument("--clean-cache", action="store_true", help="Clear the downloaded import cache")
    parser.add_argument("--clean-output", action="store_true", help="Clear previous compiled output before compiling")
    parser.add_argument("--ipfs-api", help="Kubo API base URL; defaults to IPFS_API_URL")
    parser.add_argument("--no-ipfs", action="store_true", help="Explicit local-only build; skip automatic IPFS publication")
    parser.add_argument("--publish-only", action="store_true", help="Retry publishing the current output manifest without recompiling")

    args = parser.parse_args()
    if args.publish_only and (args.clean_cache or args.clean_output):
        parser.error("--publish-only cannot clear the cache or output")
    if args.output_dir:
        OUTPUT_DIR = args.output_dir.resolve()

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

    # Import only for CLI publication; library compilation/export stays offline.
    from ipfs_publish import configured_client, publish_manifest, write_receipt
    write_receipt(OUTPUT_DIR, {"version": 1, "status": "not_started"})
    try:
        client = configured_client(args.ipfs_api, args.no_ipfs)
        if args.publish_only:
            if args.file or args.no_ipfs or client is None:
                raise ValueError("--publish-only requires an IPFS endpoint and cannot use --file or --no-ipfs")
            summary = json.loads((OUTPUT_DIR / "manifest.json").read_text(encoding="utf-8"))
        else:
            options = dict(solc_version=args.solc_version, evm_version=args.evm,
                           optimize=not args.no_optimize, optimize_runs=args.runs,
                           private_evm_version=args.private_evm, private=args.private)
            summary = compile_selected(file_paths=args.file, **options) if args.file else compile_all(**options)
    except Exception:
        write_receipt(OUTPUT_DIR, {"version": 1, "status": "failed_before_publication"})
        raise
    if client is None:
        reason = "explicitly_disabled" if args.no_ipfs or os.getenv("IPFS_AUTO_PUBLISH", "").lower() == "false" else "not_configured"
        write_receipt(OUTPUT_DIR, {"version": 1, "status": "skipped", "reason": reason})
        print(f"IPFS publication skipped ({reason}); files are local only.")
    else:
        receipt = publish_manifest(OUTPUT_DIR, summary, client)
        print(f"IPFS: verified {len(receipt['objects'])} pinned objects; release bundle {receipt['release_bundle_cid']}")
        print("Backend pin/read-back verified; external gateway reachability requires a separate deployment check.")


if __name__ == "__main__":
    main()
