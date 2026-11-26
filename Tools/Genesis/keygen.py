#!/usr/bin/env python3
"""Generate the four QBFT validator node keys for the Cryft Network genesis, on this Mac.

Custody (two places, never git, never printed):
  1. files  ~/Cryft/codex-outputs/cryft-wallets/private/validators-<date>/validator-0N.key  (0600, 64 hex + newline,
     the format install-besu.py stages as /root/cryft-bootstrap/validator-node.key)
  2. the macOS login Keychain: service "cryft-validator-0N-<date>", account "cryft-validator"
     (written through `security -i` on stdin, so the key never appears in a process list).

Only the PUBLIC parts are written to the repo: Tools/Genesis/validators.json (addresses, node public keys, enodes).
Refuses to overwrite an existing key set. `--verify` re-derives the public file from both custody places and
checks that they agree, again without printing any key.

    python Tools/Genesis/keygen.py --date 20261125            # generate (once)
    python Tools/Genesis/keygen.py --date 20261125 --verify    # check both copies against validators.json
"""
import argparse
import json
import os
import secrets
import subprocess
from pathlib import Path

from eth_keys import keys

REPO = Path(__file__).resolve().parents[2]
PUBLIC = REPO / "Tools/Genesis/validators.json"
ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141
COUNT = 4
NEBULA = "100.111.32.10{n}"  # validator-peers.json convention (Validator-0N)


def folder(date):
    return Path.home() / "Cryft/codex-outputs/cryft-wallets/private" / f"validators-{date}"


def service(date, n):
    return f"cryft-validator-0{n}-{date}"


def public_entry(n, private_hex):
    key = keys.PrivateKey(bytes.fromhex(private_hex))
    pub = key.public_key.to_bytes().hex()
    return {"name": f"Validator-0{n}", "address": key.public_key.to_checksum_address(),
            "public_key": "0x" + pub, "enode": f"enode://{pub}@{NEBULA.format(n=n)}:30303"}


def keychain_read(date, n):
    out = subprocess.run(["security", "find-generic-password", "-a", "cryft-validator", "-s", service(date, n), "-w"],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def keychain_write(date, n, private_hex):
    command = f'add-generic-password -a cryft-validator -s {service(date, n)} -w {private_hex}\n'
    subprocess.run(["security", "-i"], input=command, text=True, check=True, capture_output=True)


def generate(date):
    target = folder(date)
    assert not target.exists(), f"{target} exists: refusing to overwrite a key set"
    for n in range(1, COUNT + 1):
        assert keychain_read(date, n) is None, f"Keychain already holds {service(date, n)}"
    target.mkdir(parents=True, mode=0o700)
    entries = []
    for n in range(1, COUNT + 1):
        private_hex = f"{secrets.randbelow(ORDER - 1) + 1:064x}"
        path = target / f"validator-0{n}.key"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(private_hex + "\n")
        keychain_write(date, n, private_hex)
        entries.append(public_entry(n, private_hex))
        del private_hex
    PUBLIC.write_text(json.dumps({"generated": date, "custody": [str(target), "macOS login Keychain service "
                                  f"cryft-validator-0N-{date}"], "validators": entries}, indent=2) + "\n")
    return entries


def verify(date):
    recorded = json.loads(PUBLIC.read_text())["validators"]
    for n, expected in enumerate(recorded, start=1):
        from_file = (folder(date) / f"validator-0{n}.key").read_text().strip()
        from_keychain = keychain_read(date, n)
        assert from_keychain == from_file, f"Validator-0{n}: the two custody copies differ"
        assert public_entry(n, from_file) == expected, f"Validator-0{n}: validators.json does not match the key"
    return recorded


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    entries = verify(args.date) if args.verify else generate(args.date)
    for e in entries:
        print(e["name"], e["address"])
    print("verified: file and Keychain copies agree with validators.json" if args.verify else f"wrote {PUBLIC}")
