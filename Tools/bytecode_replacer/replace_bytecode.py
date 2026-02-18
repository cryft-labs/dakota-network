# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.
# This software is part of a patented system. See LICENSE and PATENT NOTICE.

"""
Runtime Bytecode Replacer
=========================
Interactive tool to replace all occurrences of one runtime bytecode
string with another inside a target file (e.g., genesis.json).

Designed for large files with hundreds of thousands of identical
bytecode entries — common in QBFT genesis files where many accounts
share the same pre-deployed contract code.

Usage:
    python replace_bytecode.py <target_file>
    python replace_bytecode.py <target_file> --dry-run
    python replace_bytecode.py <target_file> --no-backup
    python replace_bytecode.py <target_file> --old-file old.txt --new-file new.txt
"""

import argparse
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path


def normalize_hex(hex_str: str) -> str:
    """Strip 0x prefix and whitespace."""
    return hex_str.strip().removeprefix("0x").removeprefix("0X")


def replace_bytecode(target_path, old_bc, new_bc, dry_run=False, backup=True):
    target = Path(target_path)
    if not target.exists():
        print(f"  Error: File not found: {target}")
        sys.exit(1)

    file_size = target.stat().st_size
    print(f"\n  Target:       {target}")
    print(f"  File size:    {file_size:,} bytes ({file_size / 1024 / 1024:.1f} MB)")
    print(f"  Old bytecode: {old_bc[:40]}...{old_bc[-20:]}  ({len(old_bc)} chars)")
    print(f"  New bytecode: {new_bc[:40]}...{new_bc[-20:]}  ({len(new_bc)} chars)")

    if old_bc == new_bc:
        print("\n  Old and new bytecode are identical. Nothing to do.")
        return 0

    print(f"\n  Reading file...")
    t0 = time.time()
    content = target.read_text(encoding="utf-8")
    print(f"  Read in {time.time() - t0:.2f}s")

    # Count — try without prefix first, then with 0x
    count = content.count(old_bc)
    if count == 0:
        count = content.count("0x" + old_bc)
        if count > 0:
            old_bc = "0x" + old_bc
            new_bc = "0x" + new_bc
            print(f"  (Matched with '0x' prefix)")

    # Count pre-existing instances of the new bytecode (already replaced previously)
    pre_existing = content.count(new_bc)
    print(f"  Found {count:,} occurrence(s)")
    if pre_existing > 0:
        print(f"  Pre-existing new bytecode: {pre_existing:,} (already replaced previously)")

    if count == 0:
        print("  No matches found.")
        return 0

    if dry_run:
        print(f"\n  DRY RUN — {count:,} replacement(s) would be made. File not modified.")
        return count

    if backup:
        bak = str(target) + ".bak"
        print(f"  Backup: {bak}")
        shutil.copy2(str(target), bak)

    print(f"  Replacing...")
    t0 = time.time()
    new_content = content.replace(old_bc, new_bc)
    print(f"  Replaced in {time.time() - t0:.2f}s")

    # Write to a temp file first, verify size, then swap in
    tmp_dir = target.parent
    print(f"  Writing to temp file...")
    t0 = time.time()
    fd, tmp_path = tempfile.mkstemp(dir=tmp_dir, suffix=".tmp", prefix="genesis_")
    try:
        with os.fdopen(fd, "wb") as f:
            data = new_content.encode("utf-8")
            expected_size = len(data)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())

        tmp_size = os.path.getsize(tmp_path)
        if tmp_size != expected_size:
            print(f"  ERROR: Temp file size mismatch! Expected {expected_size:,}, got {tmp_size:,}")
            os.unlink(tmp_path)
            print("  Aborted. Original file untouched.")
            return 0

        # Atomic-ish replace: remove original, rename temp
        os.replace(tmp_path, str(target))
        new_size = target.stat().st_size
        print(f"  Written in {time.time() - t0:.2f}s  ({new_size:,} bytes, {new_size - file_size:+,})")

    except Exception as e:
        print(f"  ERROR during write: {e}")
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        print("  Aborted. Original file untouched.")
        return 0

    # Free memory before verify
    del new_content
    del data

    # Verify
    print(f"  Verifying...")
    verify = target.read_text(encoding="utf-8")
    remaining = verify.count(old_bc)
    found_new = verify.count(new_bc)
    print(f"  Verify: old remaining={remaining:,}  new found={found_new:,}")

    if remaining > 0 or found_new != count + pre_existing:
        print(f"  WARNING: Verification mismatch! Restoring backup...")
        if backup:
            shutil.copy2(bak, str(target))
            print(f"  Restored from backup.")
        return 0

    return count


def main():
    parser = argparse.ArgumentParser(description="Replace runtime bytecode in a file")
    parser.add_argument("target", help="Path to the file to modify (e.g., genesis.json)")
    parser.add_argument("--dry-run", action="store_true", help="Count matches without modifying")
    parser.add_argument("--no-backup", action="store_true", help="Skip .bak backup")
    parser.add_argument("--old-file", help="Read OLD bytecode from this text file instead of prompting")
    parser.add_argument("--new-file", help="Read NEW bytecode from this text file instead of prompting")
    args = parser.parse_args()

    print("\n" + "=" * 60)
    print("  Runtime Bytecode Replacer")
    print("=" * 60)

    if args.old_file:
        old_input = Path(args.old_file).read_text(encoding="utf-8").strip()
        print(f"\n  Old bytecode loaded from: {args.old_file}  ({len(old_input)} chars)")
    else:
        print("\n  Paste the OLD bytecode to find (then press Enter):")
        old_input = input("  > ").strip()
    if not old_input:
        print("  Error: No bytecode provided.")
        sys.exit(1)

    if args.new_file:
        new_input = Path(args.new_file).read_text(encoding="utf-8").strip()
        print(f"  New bytecode loaded from: {args.new_file}  ({len(new_input)} chars)")
    else:
        print("\n  Paste the NEW bytecode to replace with (then press Enter):")
        new_input = input("  > ").strip()
    if not new_input:
        print("  Error: No bytecode provided.")
        sys.exit(1)

    old_bc = normalize_hex(old_input)
    new_bc = normalize_hex(new_input)

    count = replace_bytecode(
        args.target,
        old_bc,
        new_bc,
        dry_run=args.dry_run,
        backup=not args.no_backup,
    )

    print(f"\n  Done. {count:,} replacement(s).\n")


if __name__ == "__main__":
    main()
