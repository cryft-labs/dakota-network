#!/usr/bin/env python3
# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.
# This software is part of a patented system. See LICENSE and PATENT NOTICE.

"""
dakota_keywizard.py

Generates:
- EOA accounts (ALWAYS generates privateKey + address; optional keystore V3 JSON)
- Besu node keys (key + key.pub) for P2P identity / validator signing
- Tessera keys (via tessera -keygen), without renaming outputs

Interactive wizard by default, flags available.
Optional SCP distribution is PER-KEY-PER-GROUP, with optional deletion of local originals.

No external Python packages required (PEP 668 friendly).
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Tuple


# ----------------------------
# Small helpers
# ----------------------------

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def die(msg: str, code: int = 1):
    eprint(f"ERROR: {msg}")
    sys.exit(code)

def which(cmd: str) -> Optional[str]:
    return shutil.which(cmd)

def mkdirp(p: Path, mode: int = 0o700):
    p.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(p, mode)
    except PermissionError:
        pass

def write_text_secure(p: Path, s: str, mode: int = 0o600):
    p.write_text(s, encoding="utf-8")
    try:
        os.chmod(p, mode)
    except PermissionError:
        pass

def run(cmd: List[str], check: bool = True, capture: bool = False, stdin_null: bool = False) -> subprocess.CompletedProcess:
    kwargs = {}
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
        kwargs["text"] = True
    if stdin_null:
        kwargs["stdin"] = subprocess.DEVNULL
    return subprocess.run(cmd, check=check, **kwargs)

def prompt_yes_no(msg: str, default_yes: bool = True) -> bool:
    d = "Y/n" if default_yes else "y/N"
    while True:
        ans = input(f"{msg} [{d}]: ").strip().lower()
        if ans == "":
            return default_yes
        if ans in ("y", "yes"):
            return True
        if ans in ("n", "no"):
            return False
        print("Please answer y or n.")

def prompt_int(msg: str, default: int, min_v: int = 0, max_v: int = 10_000) -> int:
    while True:
        raw = input(f"{msg} [{default}]: ").strip()
        if raw == "":
            v = default
        else:
            try:
                v = int(raw)
            except ValueError:
                print("Enter an integer.")
                continue
        if v < min_v or v > max_v:
            print(f"Enter a value in range [{min_v}, {max_v}].")
            continue
        return v

def prompt_path(msg: str, default: Path) -> Path:
    raw = input(f"{msg} [{default}]: ").strip()
    return Path(raw) if raw else default

def prompt_nonempty(msg: str, default: Optional[str] = None) -> str:
    while True:
        raw = input(f"{msg}{f' [{default}]' if default else ''}: ").strip()
        if not raw and default:
            return default
        if raw:
            return raw
        print("Value required.")

def safe_unlink(p: Path):
    try:
        p.unlink(missing_ok=True)
    except Exception as ex:
        eprint(f"  ! Could not delete {p}: {ex}")

def safe_rmdir_if_empty(p: Path):
    try:
        p.rmdir()
    except OSError:
        pass

def delete_tree(path: Path):
    """
    Best-effort delete of a directory tree (no shred).
    Files are chmod'd to user-writable before deletion where possible.
    """
    if not path.exists():
        return
    if path.is_file() or path.is_symlink():
        try:
            os.chmod(path, 0o600)
        except Exception:
            pass
        safe_unlink(path)
        return

    for child in sorted(path.rglob("*"), key=lambda x: len(str(x)), reverse=True):
        try:
            if child.is_dir():
                safe_rmdir_if_empty(child)
            else:
                try:
                    os.chmod(child, 0o600)
                except Exception:
                    pass
                safe_unlink(child)
        except Exception as ex:
            eprint(f"  ! Could not delete {child}: {ex}")
    safe_rmdir_if_empty(path)


# ----------------------------
# Keccak-256 (Ethereum) - pure python
# ----------------------------

_KECCAK_RNDC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
]
_KECCAK_ROTC = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]

def _rol64(x: int, n: int) -> int:
    n %= 64
    return ((x << n) & ((1 << 64) - 1)) | (x >> (64 - n))

def _keccak_f1600(state: List[int]) -> None:
    for rc in _KECCAK_RNDC:
        c = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol64(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x + 5*y] ^= d[x]

        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5*((2*x + 3*y) % 5)] = _rol64(state[x + 5*y], _KECCAK_ROTC[x][y])

        for x in range(5):
            for y in range(5):
                state[x + 5*y] = b[x + 5*y] ^ ((~b[((x + 1) % 5) + 5*y]) & b[((x + 2) % 5) + 5*y])

        state[0] ^= rc

def keccak_256(data: bytes) -> bytes:
    rate = 136
    state = [0] * 25

    off = 0
    while off + rate <= len(data):
        block = data[off:off+rate]
        for i in range(rate // 8):
            lane = int.from_bytes(block[i*8:(i+1)*8], "little")
            state[i] ^= lane
        _keccak_f1600(state)
        off += rate

    tail = bytearray(data[off:])
    tail.append(0x01)
    while len(tail) % rate != rate - 1:
        tail.append(0x00)
    tail.append(0x80)

    off2 = 0
    while off2 < len(tail):
        block = tail[off2:off2+rate]
        for i in range(rate // 8):
            lane = int.from_bytes(block[i*8:(i+1)*8], "little")
            state[i] ^= lane
        _keccak_f1600(state)
        off2 += rate

    out = bytearray()
    while len(out) < 32:
        for i in range(rate // 8):
            out.extend(state[i].to_bytes(8, "little"))
            if len(out) >= 32:
                break
        if len(out) < 32:
            _keccak_f1600(state)
    return bytes(out[:32])


# ----------------------------
# secp256k1 (pure python)
# ----------------------------

SECP_P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
SECP_N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
SECP_GX = 55066263022277343669578718895168534326250603453777594175500187360389116729240
SECP_GY = 32670510020758816978083085130507043184471273380659243275938904335757337482424

@dataclass(frozen=True)
class ECPoint:
    x: int
    y: int
    inf: bool = False

G = ECPoint(SECP_GX, SECP_GY, False)
INF = ECPoint(0, 0, True)

def _inv_mod(k: int, p: int) -> int:
    if k == 0:
        raise ZeroDivisionError("division by zero")
    return pow(k, p - 2, p)

def _ec_add(p1: ECPoint, p2: ECPoint) -> ECPoint:
    if p1.inf:
        return p2
    if p2.inf:
        return p1
    if p1.x == p2.x and (p1.y != p2.y or p1.y == 0):
        return INF

    if p1.x == p2.x and p1.y == p2.y:
        lam = (3 * p1.x * p1.x) * _inv_mod(2 * p1.y, SECP_P) % SECP_P
    else:
        lam = (p2.y - p1.y) * _inv_mod(p2.x - p1.x, SECP_P) % SECP_P

    x3 = (lam * lam - p1.x - p2.x) % SECP_P
    y3 = (lam * (p1.x - x3) - p1.y) % SECP_P
    return ECPoint(x3, y3, False)

def _ec_mul(k: int, p: ECPoint) -> ECPoint:
    if k % SECP_N == 0 or p.inf:
        return INF
    if k < 0:
        return _ec_mul(-k, ECPoint(p.x, (-p.y) % SECP_P, False))

    res = INF
    add = p
    while k:
        if k & 1:
            res = _ec_add(res, add)
        add = _ec_add(add, add)
        k >>= 1
    return res

def privkey_to_pubkey(priv: bytes) -> Tuple[bytes, bytes]:
    if len(priv) != 32:
        die("Private key must be 32 bytes")
    k = int.from_bytes(priv, "big")
    if k <= 0 or k >= SECP_N:
        die("Private key out of range for secp256k1")
    P = _ec_mul(k, G)
    x = P.x.to_bytes(32, "big")
    y = P.y.to_bytes(32, "big")
    uncompressed = b"\x04" + x + y
    xy = x + y
    return uncompressed, xy

def pubkey_to_address(xy64: bytes) -> str:
    if len(xy64) != 64:
        die("Public key must be 64 bytes (x||y)")
    h = keccak_256(xy64)
    return "0x" + h[-20:].hex()

def new_secp256k1_private_key() -> bytes:
    while True:
        b = secrets.token_bytes(32)
        k = int.from_bytes(b, "big")
        if 1 <= k < SECP_N:
            return b


# ----------------------------
# AES-128 (pure python) for keystore optional
# ----------------------------

_AES_SBOX = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
]
_AES_RCON = [0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1B,0x36]

def _xtime(a: int) -> int:
    return ((a << 1) ^ 0x1B) & 0xFF if (a & 0x80) else (a << 1) & 0xFF

def _sub_word(w: List[int]) -> List[int]:
    return [_AES_SBOX[b] for b in w]

def _rot_word(w: List[int]) -> List[int]:
    return w[1:] + w[:1]

def _aes_key_expand_128(key16: bytes) -> List[List[int]]:
    if len(key16) != 16:
        die("AES-128 key must be 16 bytes")
    key = list(key16)
    w = [key[i:i+4] for i in range(0, 16, 4)]
    for i in range(4, 44):
        temp = w[i-1].copy()
        if i % 4 == 0:
            temp = _sub_word(_rot_word(temp))
            temp[0] ^= _AES_RCON[i//4]
        w.append([(w[i-4][j] ^ temp[j]) & 0xFF for j in range(4)])
    round_keys = []
    for r in range(11):
        rk = []
        for i in range(4):
            rk += w[r*4 + i]
        round_keys.append(rk)
    return round_keys

def _aes_add_round_key(state: List[int], rk: List[int]) -> None:
    for i in range(16):
        state[i] ^= rk[i]

def _aes_sub_bytes(state: List[int]) -> None:
    for i in range(16):
        state[i] = _AES_SBOX[state[i]]

def _aes_shift_rows(state: List[int]) -> None:
    def idx(r,c): return r + 4*c
    rows = [[state[idx(r,c)] for c in range(4)] for r in range(4)]
    for r in range(4):
        rows[r] = rows[r][r:] + rows[r][:r]
    for r in range(4):
        for c in range(4):
            state[idx(r,c)] = rows[r][c]

def _aes_mix_columns(state: List[int]) -> None:
    def idx(r,c): return r + 4*c
    for c in range(4):
        a = [state[idx(r,c)] for r in range(4)]
        t = a[0] ^ a[1] ^ a[2] ^ a[3]
        u = a[0]
        state[idx(0,c)] ^= t ^ _xtime(a[0] ^ a[1])
        state[idx(1,c)] ^= t ^ _xtime(a[1] ^ a[2])
        state[idx(2,c)] ^= t ^ _xtime(a[2] ^ a[3])
        state[idx(3,c)] ^= t ^ _xtime(a[3] ^ u)

def aes128_encrypt_block(key16: bytes, block16: bytes) -> bytes:
    if len(block16) != 16:
        die("AES block must be 16 bytes")
    rks = _aes_key_expand_128(key16)
    state = list(block16)
    _aes_add_round_key(state, rks[0])
    for rnd in range(1, 10):
        _aes_sub_bytes(state)
        _aes_shift_rows(state)
        _aes_mix_columns(state)
        _aes_add_round_key(state, rks[rnd])
    _aes_sub_bytes(state)
    _aes_shift_rows(state)
    _aes_add_round_key(state, rks[10])
    return bytes(state)

def aes128_ctr_crypt(key16: bytes, iv16: bytes, data: bytes) -> bytes:
    if len(iv16) != 16:
        die("CTR IV must be 16 bytes")
    out = bytearray()
    counter = int.from_bytes(iv16, "big")
    for off in range(0, len(data), 16):
        block = data[off:off+16]
        ctr_block = counter.to_bytes(16, "big")
        ks = aes128_encrypt_block(key16, ctr_block)
        out.extend(bytes([block[i] ^ ks[i] for i in range(len(block))]))
        counter = (counter + 1) & ((1 << 128) - 1)
    return bytes(out)


# ----------------------------
# Key generation
# ----------------------------

@dataclass
class EOAResult:
    name: str
    dir: Path
    address: str
    priv_hex: str
    keystore_path: Optional[Path]

@dataclass
class BesuNodeKeyResult:
    name: str
    dir: Path
    key_path: Path
    pub_path: Path

@dataclass
class TesseraKeyResult:
    name: str
    dir: Path
    basepath: Path
    pub_path: Path
    key_path: Path

def generate_eoa(out_dir: Path, name: str, make_keystore: bool, keystore_password: Optional[str]) -> EOAResult:
    d = out_dir / name
    mkdirp(d, 0o700)

    priv = new_secp256k1_private_key()
    _, xy = privkey_to_pubkey(priv)
    addr = pubkey_to_address(xy)

    priv_hex = priv.hex()
    write_text_secure(d / "privateKey", priv_hex + "\n", 0o600)
    write_text_secure(d / "address", addr + "\n", 0o600)

    ks_path = None
    if make_keystore:
        if keystore_password is None:
            keystore_password = ""
        salt = secrets.token_bytes(16)
        iv = secrets.token_bytes(16)

        import hashlib
        dklen = 32
        c = 262144
        derived = hashlib.pbkdf2_hmac("sha256", keystore_password.encode("utf-8"), salt, c, dklen=dklen)

        enc_key = derived[:16]
        ciphertext = aes128_ctr_crypt(enc_key, iv, priv)
        mac = keccak_256(derived[16:32] + ciphertext).hex()

        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
        addr_noprefix = addr[2:].lower()
        filename = f"UTC--{now}--{addr_noprefix}"
        ks_path = d / filename

        keystore = {
            "version": 3,
            "id": str(uuid.uuid4()),
            "address": addr_noprefix,
            "crypto": {
                "cipher": "aes-128-ctr",
                "cipherparams": {"iv": iv.hex()},
                "ciphertext": ciphertext.hex(),
                "kdf": "pbkdf2",
                "kdfparams": {"dklen": dklen, "c": c, "prf": "hmac-sha256", "salt": salt.hex()},
                "mac": mac,
            },
        }
        write_text_secure(ks_path, json.dumps(keystore, indent=2) + "\n", 0o600)

    return EOAResult(name=name, dir=d, address=addr, priv_hex=priv_hex, keystore_path=ks_path)

def generate_besu_nodekey(out_dir: Path, name: str) -> BesuNodeKeyResult:
    d = out_dir / name
    mkdirp(d, 0o700)

    priv = new_secp256k1_private_key()
    _, xy = privkey_to_pubkey(priv)

    key_path = d / "key"
    pub_path = d / "key.pub"
    write_text_secure(key_path, priv.hex() + "\n", 0o600)
    write_text_secure(pub_path, xy.hex() + "\n", 0o644)

    return BesuNodeKeyResult(name=name, dir=d, key_path=key_path, pub_path=pub_path)

def generate_tessera_keys(tessera_bin: str, out_dir: Path, name: str, basename: str, unlocked: bool) -> TesseraKeyResult:
    if not which(tessera_bin):
        die(f"tessera binary not found in PATH: {tessera_bin}")

    d = out_dir / name
    mkdirp(d, 0o700)

    base = d / basename  # produces base.key and base.pub
    cmd = [tessera_bin, "-keygen", "-filename", str(base)]
    run(cmd, check=True, capture=False, stdin_null=unlocked)

    key_path = d / f"{basename}.key"
    pub_path = d / f"{basename}.pub"

    if not key_path.exists() or not pub_path.exists():
        cmd2 = [tessera_bin, "keygen", "--keyout", str(base)]
        run(cmd2, check=True, capture=False, stdin_null=unlocked)

    if not key_path.exists() or not pub_path.exists():
        die(f"Tessera did not produce expected files: {key_path} and {pub_path}")

    try:
        os.chmod(key_path, 0o600)
        os.chmod(pub_path, 0o644)
    except PermissionError:
        pass

    return TesseraKeyResult(name=name, dir=d, basepath=base, pub_path=pub_path, key_path=key_path)


# ----------------------------
# SCP distribution (per-key) + retry after 15s
# ----------------------------

def ensure_ssh_tools():
    if not which("ssh") or not which("scp"):
        die("ssh/scp not found. Install openssh-client (apt install -y openssh-client).")

def scp_send_dir(dest: str, local_dir: Path, remote_dir: str) -> bool:
    ensure_ssh_tools()
    try:
        run(["ssh", dest, "mkdir", "-p", remote_dir], check=True)
        run(["scp", "-r", str(local_dir), f"{dest}:{remote_dir.rstrip('/')}/"], check=True)
        return True
    except subprocess.CalledProcessError as ex:
        eprint(f"  ! SCP failed: {ex}")
        return False

def scp_send_files(dest: str, local_files: List[Path], remote_dir: str) -> bool:
    ensure_ssh_tools()
    try:
        run(["ssh", dest, "mkdir", "-p", remote_dir], check=True)
        run(["scp"] + [str(p) for p in local_files] + [f"{dest}:{remote_dir.rstrip('/')}/"], check=True)
        return True
    except subprocess.CalledProcessError as ex:
        eprint(f"  ! SCP failed: {ex}")
        return False

def scp_with_retry(transfer_fn, retry_delay_s: int = 15) -> bool:
    """
    Runs transfer_fn() once. If it fails, offers retry after a fixed delay.
    Returns True on success, False if user aborts retries or it never succeeds.
    """
    ok = transfer_fn()
    while not ok:
        if not prompt_yes_no(f"  Retry SCP after {retry_delay_s} seconds?", default_yes=True):
            return False
        print(f"  Waiting {retry_delay_s} seconds before retry...")
        time.sleep(retry_delay_s)
        ok = transfer_fn()
    return True

def per_key_transfer_flow(
    group_name: str,
    items: List[Tuple[str, Path, str, List[Path]]],
    default_remote_dir: str,
):
    """
    items: list of tuples:
      (display_name, local_root_dir, transfer_mode, files)
    transfer_mode:
      - "dir"   => scp -r local_root_dir to remote_dir
      - "files" => scp files[] to remote_dir
    """
    if not items:
        return

    print(f"\n=== SCP review: {group_name} ===")
    if not prompt_yes_no(f"Review and optionally SCP each {group_name} key set?", default_yes=False):
        return

    for (disp, local_root, mode, files) in items:
        print(f"\n[{group_name}] {disp}")
        print(f"  Local: {local_root}")

        if not prompt_yes_no("  Transfer this key set over SCP?", default_yes=False):
            continue

        user = prompt_nonempty("  Destination SSH username")
        host = prompt_nonempty("  Destination IP/hostname")
        dest = f"{user}@{host}"
        remote_dir = input(f"  Remote directory [{default_remote_dir}]: ").strip() or default_remote_dir

        print("  Starting SCP... (you may be prompted for SSH password by scp/ssh)")

        def do_transfer() -> bool:
            if mode == "dir":
                return scp_send_dir(dest, local_root, remote_dir)
            if mode == "files":
                return scp_send_files(dest, files, remote_dir)
            eprint("  ! Unknown transfer mode, skipping.")
            return False

        ok = scp_with_retry(do_transfer, retry_delay_s=15)
        if not ok:
            print("  Transfer not completed; keeping local copy.")
            continue

        print("  Transfer OK.")
        if prompt_yes_no("  Delete local original for this key set?", default_yes=False):
            print("  Deleting local copy...")
            delete_tree(local_root)
            print("  Local copy deleted (best-effort).")
        else:
            print("  Keeping local copy.")


# ----------------------------
# Main wizard
# ----------------------------

def main():
    ap = argparse.ArgumentParser(description="Dakota key wizard: EOA + Besu nodekeys + Tessera keys (+ per-key SCP).")
    ap.add_argument("--out", dest="out", default=str(Path.home() / "dakota-keys"), help="Base output directory (default: ~/dakota-keys)")
    ap.add_argument("--non-interactive", action="store_true", help="Run without prompts (uses flags/defaults). SCP per-key flow requires interactive mode.")
    ap.add_argument("--no-eoa", action="store_true", help="Disable EOA generation (EOA is ON by default)")
    ap.add_argument("--eoa-count", type=int, default=1, help="Number of EOA accounts to generate (default: 1)")
    ap.add_argument("--eoa-keystore", action="store_true", help="Also generate keystore JSON (optional)")
    ap.add_argument("--eoa-keystore-pass", default=None, help="Keystore password (if omitted and keystore enabled, you will be prompted unless non-interactive)")

    ap.add_argument("--besu-count", type=int, default=0, help="Number of Besu node keys to generate (default: 0)")
    ap.add_argument("--tessera-count", type=int, default=0, help="Number of Tessera keys to generate (default: 0)")
    ap.add_argument("--tessera-bin", default="tessera", help="Tessera binary name/path (default: tessera)")
    ap.add_argument("--tessera-basename", default="nodeKey", help="Tessera -filename base (produces <base>.key/.pub) (default: nodeKey)")
    ap.add_argument("--tessera-locked", action="store_true", help="Generate locked Tessera keys (will prompt for password); default is unlocked")

    ap.add_argument("--name-prefix-eoa", default="eoa-", help="Prefix for EOA key folders (default: eoa-)")
    ap.add_argument("--name-prefix-besu", default="besu-node-", help="Prefix for Besu key folders (default: besu-node-)")
    ap.add_argument("--name-prefix-tessera", default="tessera-", help="Prefix for Tessera key folders (default: tessera-)")

    ap.add_argument("--scp", action="store_true", help="Enable SCP step (interactive per-key prompts).")
    args = ap.parse_args()

    out_base = Path(args.out).expanduser().resolve()
    mkdirp(out_base, 0o700)

    interactive = not args.non_interactive

    gen_eoa = not args.no_eoa
    eoa_count = args.eoa_count
    besu_count = args.besu_count
    tessera_count = args.tessera_count
    make_keystore = args.eoa_keystore
    ks_pass = args.eoa_keystore_pass

    tessera_bin = args.tessera_bin
    tessera_basename = args.tessera_basename
    tessera_unlocked = not args.tessera_locked

    if interactive:
        print("\n=== Dakota Key Wizard ===\n")
        out_base = prompt_path("Base output directory", out_base)
        mkdirp(out_base, 0o700)

        gen_eoa = prompt_yes_no("Generate EOA account keys? (default ON)", default_yes=True)
        if gen_eoa:
            eoa_count = prompt_int("How many EOAs?", default=max(1, eoa_count), min_v=1, max_v=5000)
            make_keystore = prompt_yes_no("Also generate keystore JSON files? (optional)", default_yes=False)
            if make_keystore:
                pw1 = getpass.getpass("Keystore password (empty allowed, not recommended): ")
                pw2 = getpass.getpass("Confirm password: ")
                if pw1 != pw2:
                    die("Keystore passwords do not match.")
                ks_pass = pw1

        gen_besu = prompt_yes_no("Generate Besu node keys (key + key.pub)?", default_yes=(besu_count > 0))
        if gen_besu:
            besu_count = prompt_int("How many Besu node keypairs?", default=max(1, besu_count), min_v=1, max_v=5000)
        else:
            besu_count = 0

        gen_tessera = prompt_yes_no("Generate Tessera keys via tessera -keygen?", default_yes=(tessera_count > 0))
        if gen_tessera:
            tessera_count = prompt_int("How many Tessera keypairs?", default=max(1, tessera_count), min_v=1, max_v=5000)
            tessera_basename = input(f"Tessera basename (creates <base>.key/.pub) [{tessera_basename}]: ").strip() or tessera_basename
            tessera_unlocked = prompt_yes_no("Generate UNLOCKED Tessera keys (no password prompt)?", default_yes=True)
            tb = input(f"Tessera binary name/path [{tessera_bin}]: ").strip()
            if tb:
                tessera_bin = tb
        else:
            tessera_count = 0

        args.scp = prompt_yes_no("After generation, review each key set for optional SCP transfer?", default_yes=False)

    eoa_root = out_base / "eoa"
    besu_root = out_base / "besu"
    tessera_root = out_base / "tessera"
    if gen_eoa:
        mkdirp(eoa_root, 0o700)
    if besu_count > 0:
        mkdirp(besu_root, 0o700)
    if tessera_count > 0:
        mkdirp(tessera_root, 0o700)

    if make_keystore and ks_pass is None and interactive:
        pw1 = getpass.getpass("Keystore password (empty allowed, not recommended): ")
        pw2 = getpass.getpass("Confirm password: ")
        if pw1 != pw2:
            die("Keystore passwords do not match.")
        ks_pass = pw1
    if make_keystore and ks_pass is None and args.non_interactive:
        ks_pass = ""

    eoa_results: List[EOAResult] = []
    besu_results: List[BesuNodeKeyResult] = []
    tessera_results: List[TesseraKeyResult] = []

    if gen_eoa:
        print(f"\n[EOA] Generating {eoa_count} EOA account(s) into: {eoa_root}")
        for i in range(1, eoa_count + 1):
            name = f"{args.name_prefix_eoa}{i:02d}"
            r = generate_eoa(eoa_root, name, make_keystore=make_keystore, keystore_password=ks_pass)
            eoa_results.append(r)
            ks_note = f", keystore={r.keystore_path.name}" if r.keystore_path else ""
            print(f"  - {name}: address={r.address}{ks_note}")

    if besu_count > 0:
        print(f"\n[Besu] Generating {besu_count} node keypair(s) into: {besu_root}")
        for i in range(1, besu_count + 1):
            name = f"{args.name_prefix_besu}{i:02d}"
            r = generate_besu_nodekey(besu_root, name)
            besu_results.append(r)
            print(f"  - {name}: files={r.key_path.name},{r.pub_path.name}")

    if tessera_count > 0:
        print(f"\n[Tessera] Generating {tessera_count} keypair(s) into: {tessera_root}")
        print(f"         Using: {tessera_bin}, basename: {tessera_basename}, unlocked={tessera_unlocked}")
        for i in range(1, tessera_count + 1):
            name = f"{args.name_prefix_tessera}{i:02d}"
            r = generate_tessera_keys(tessera_bin, tessera_root, name, basename=tessera_basename, unlocked=tessera_unlocked)
            tessera_results.append(r)
            print(f"  - {name}: files={r.key_path.name},{r.pub_path.name}")

    if args.scp and interactive:
        eoa_items: List[Tuple[str, Path, str, List[Path]]] = []
        for r in eoa_results:
            eoa_items.append((r.name, r.dir, "dir", []))

        besu_items: List[Tuple[str, Path, str, List[Path]]] = []
        for r in besu_results:
            besu_items.append((r.name, r.dir, "files", [r.key_path, r.pub_path]))

        tess_items: List[Tuple[str, Path, str, List[Path]]] = []
        for r in tessera_results:
            tess_items.append((r.name, r.dir, "dir", []))

        per_key_transfer_flow(
            group_name="EOA",
            items=eoa_items,
            default_remote_dir="~/dakota-keys/eoa",
        )
        per_key_transfer_flow(
            group_name="Besu node key",
            items=besu_items,
            default_remote_dir="~/dakota-network/Node/Node/data",
        )
        per_key_transfer_flow(
            group_name="Tessera",
            items=tess_items,
            default_remote_dir="~/dakota-network/Node/Node/Tessera",
        )
    elif args.scp and not interactive:
        print("\n[SCP] NOTE: per-key SCP prompts require interactive mode. Re-run without --non-interactive to transfer keys.")

    print("\nDone.")
    print(f"Base output: {out_base}")
    if gen_eoa:
        print(f"  EOA keys:     {eoa_root}   (privateKey + address ALWAYS; keystore optional)")
    if besu_results:
        print(f"  Besu keys:    {besu_root}  (key + key.pub)")
    if tessera_results:
        print(f"  Tessera keys: {tessera_root} (tessera -keygen output)")


if __name__ == "__main__":
    main()
