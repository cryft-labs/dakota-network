#!/usr/bin/env python3
"""Read-only Paladin-01 check from the Mac (runbook Phase E verify). Prints identities, never secrets.

Checks: services active; Paladin/Postgres listeners on loopback only and the RPC on Nebula :8550 allowed for
Backend-01 and refused for others; the configured PenteFactory and fromBlock; the sealed secrets file;
operator@paladin01 / settlement@paladin01 addresses; settlement balance on chain.

    python Tools/Paladin/verify.py [--out receipt.json] [--min-settlement-wei 10000000000000000]
"""
import argparse, json, subprocess, sys, time, urllib.request
from pathlib import Path

SSH = ["ssh", "-F", str(Path.home() / "Cryft/codex-outputs/cryft-ssh/mac-ssh-config"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=25"]
ARCHIVE_RPC = "http://100.111.69.2:8547"
results = []


def check(name, ok, detail=None):
    results.append({"check": name, "ok": bool(ok), **({"detail": detail} if detail is not None else {})})
    print(("PASS " if ok else "FAIL ") + name + ("" if detail is None else f"  {detail}"), flush=True)


def on(host, command):
    return subprocess.run(SSH + [host, command], capture_output=True, text=True).stdout.strip()


def paladin_rpc(host, method, params, url="http://100.111.32.201:8550"):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    out = on(host, f"curl -s -m 20 -o - -w '\\n%{{http_code}}' -X POST -H 'Content-Type: application/json' --data '{body}' {url}")
    text, _, code = out.rpartition("\n")
    return code, text


def chain(method, params):
    req = urllib.request.Request(ARCHIVE_RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=20))["result"]


def main():
    p = argparse.ArgumentParser(); p.add_argument("--out"); p.add_argument("--min-settlement-wei", type=int, default=10 ** 16)
    a = p.parse_args()
    for unit in ("cryft-besu", "cryft-paladin-db", "cryft-paladin", "cryft-nginx"):
        check(f"{unit} active", on("Paladin-01", f"systemctl is-active {unit}") == "active")
    listeners = on("Paladin-01", "ss -ltnH | awk '{print $4}'").split()
    for port in ("8548", "8549", "5433", "6100"):
        bound = [l for l in listeners if l.endswith(":" + port)]
        check(f"port {port} on loopback only", bound and all(l.startswith("127.0.0.1:") for l in bound), bound)
    check("RPC :8550 on Nebula and loopback", sorted(l for l in listeners if l.endswith(":8550")) == ["100.111.32.201:8550", "127.0.0.1:8550"])
    install = json.loads(on("Paladin-01", "cat /etc/cryft/paladin/installation.json"))
    config = json.loads(on("Paladin-01", "cat /etc/cryft/paladin/paladin.json"))
    check("PenteFactory configured", config["domains"]["pente"]["registryAddress"] == install["factory"], install["factory"])
    check("factory has code on chain", len(chain("eth_getCode", [install["factory"], "latest"])) > 4)
    sealed = install.get("sealed_secrets") or {}
    plain_now = on("Paladin-01", "sha256sum /etc/cryft/paladin/secrets.json | cut -d' ' -f1")
    check("secrets sealed to the backup certificate", sealed.get("sha256") and
          on("Paladin-01", "sha256sum /etc/cryft/paladin/secrets.json.cms | cut -d' ' -f1") == sealed["sha256"])
    check("sealed copy is of the current secrets", sealed.get("plaintext_sha256") == plain_now)
    code, _ = paladin_rpc("Archive-01", "ptx_resolveVerifier", ["settlement@paladin01", "ecdsa:secp256k1", "eth_address"])
    check("RPC refuses a non-Backend Nebula host (Archive-01)", code == "403", code)
    identities = {}
    for name in ("operator@paladin01", "settlement@paladin01"):
        for _ in range(30):
            code, text = paladin_rpc("Backend-01", "ptx_resolveVerifier", [name, "ecdsa:secp256k1", "eth_address"])
            if code == "200" and '"result"' in text:
                break
            time.sleep(5)
        address = json.loads(text).get("result") if code == "200" else None
        identities[name] = address
        check(f"{name} resolves from Backend-01", bool(address), address)
    if identities.get("settlement@paladin01"):
        balance = int(chain("eth_getBalance", [identities["settlement@paladin01"], "latest"]), 16)
        check(f"settlement funded (>= {a.min_settlement_wei} wei)", balance >= a.min_settlement_wei, balance)
    receipt = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "installation": install, "identities": identities,
               "checks": results, "passed": all(r["ok"] for r in results)}
    if a.out:
        Path(a.out).write_text(json.dumps(receipt, indent=1) + "\n")
    print("ALL PASSED" if receipt["passed"] else "SOME FAILED")
    sys.exit(0 if receipt["passed"] else 1)


if __name__ == "__main__":
    main()
