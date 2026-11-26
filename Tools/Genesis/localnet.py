#!/usr/bin/env python3
"""Local 4-node QBFT network on this Mac (runbook N-5 / D.3 "Verify").

Two kinds of run:
  production   Contracts/Genesis/CryftGenesis.json with the real validator keys (read from the keygen custody
               folder; never printed, never copied out of the run folder, which is deleted by `stop --wipe`).
               READ-ONLY proof: no transaction is ever sent, so nothing signed here could replay on the real chain.
  rehearsal    the same builder and inputs, but with ephemeral validators, roots and voters generated into the
               run folder (the real roots/voters never sign anything locally). Used for the on-chain governance
               drills in Tools/Genesis/rehearse.py.

    python Tools/Genesis/localnet.py start --kind production --run /path/to/run
    python Tools/Genesis/localnet.py start --kind rehearsal  --run /path/to/run
    python Tools/Genesis/localnet.py stop  --run /path/to/run [--wipe]

Besu 26.8.1 + Java 25 (BESU_HOME, JAVA_HOME). All listeners bind 127.0.0.1. Tx-pool flags come from
Tools/Deployment/txpool-policy.json, exactly as on the validators.
"""
import argparse
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from eth_keys import keys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "Tools/Genesis"))
import build  # noqa: E402

BESU = Path(os.environ.get("BESU_HOME", Path.home() / "Cryft/tools/besu/besu-26.8.1")) / "bin/besu"
JAVA_HOME = os.environ.get("JAVA_HOME", "/opt/homebrew/opt/openjdk@25")
ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141
RPC = 18545   # node i (1..4): RPC + 10*(i-1)
P2P = 30311   # node i: P2P + (i-1)


def rpc_port(i):
    return RPC + 10 * (i - 1)


def new_key():
    return f"{secrets.randbelow(ORDER - 1) + 1:064x}"


def address_of(private_hex):
    return keys.PrivateKey(bytes.fromhex(private_hex)).public_key.to_checksum_address()


def pub_of(private_hex):
    return keys.PrivateKey(bytes.fromhex(private_hex)).public_key.to_bytes().hex()


def write_secret(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def prepare_production(run):
    inputs = json.loads((REPO / "Tools/Genesis/inputs.json").read_text())
    custody = Path(json.loads((REPO / inputs["validatorsFile"]).read_text())["custody"][0])
    genesis = REPO / "Contracts/Genesis/CryftGenesis.json"
    shutil.copyfile(genesis, run / "genesis.json")
    node_keys = [(custody / f"validator-0{i}.key").read_text().strip() for i in range(1, 5)]
    return inputs, node_keys, {}


def prepare_rehearsal(run):
    inputs = json.loads((REPO / "Tools/Genesis/inputs.json").read_text())
    node_keys = [new_key() for _ in range(4)]
    accounts = {name: new_key() for name in ("root1", "root2", "voter1", "voter2", "voter3", "guardian", "outsider")}
    inputs["governance"]["roots"] = [address_of(accounts["root1"]), address_of(accounts["root2"])]
    inputs["governance"]["voters"] = [address_of(accounts["voter1"])]
    inputs["balances"] = {address_of(k): str(10 ** 24) for k in accounts.values()}
    genesis, manifest, _ = build.build(inputs, [address_of(k) for k in node_keys])
    (run / "genesis.json").write_text(build.canonical(genesis))
    (run / "manifest.json").write_text(build.canonical(manifest))
    write_secret(run / "accounts.json", json.dumps(accounts))
    return inputs, node_keys, accounts


def start(kind, run):
    run.mkdir(parents=True, exist_ok=True)
    os.chmod(run, 0o700)
    assert not (run / "pids.json").exists(), "already running here"
    inputs, node_keys, _ = (prepare_production if kind == "production" else prepare_rehearsal)(run)
    policy = json.loads((REPO / "Tools/Deployment/txpool-policy.json").read_text())
    priority = inputs["governance"]["roots"] + inputs["governance"]["voters"]
    enodes = [f"enode://{pub_of(k)}@127.0.0.1:{P2P + i}" for i, k in enumerate(node_keys)]
    env = dict(os.environ, JAVA_HOME=JAVA_HOME, JAVA_OPTS="-Xms256m -Xmx1536m")
    pids = []
    for i, key in enumerate(node_keys, start=1):
        node = run / f"node{i}"
        node.mkdir(exist_ok=True)
        write_secret(node / "key", key + "\n")
        (node / "static-nodes.json").write_text(json.dumps([e for j, e in enumerate(enodes) if j != i - 1]))
        args = [str(BESU), f"--data-path={node / 'data'}", f"--genesis-file={run / 'genesis.json'}",
                f"--node-private-key-file={node / 'key'}", f"--network-id={inputs['chainId']}",
                "--sync-mode=FULL", "--sync-min-peers=1", "--data-storage-format=BONSAI", "--discovery-enabled=false",
                f"--static-nodes-file={node / 'static-nodes.json'}", "--p2p-host=127.0.0.1",
                "--p2p-interface=127.0.0.1", f"--p2p-port={P2P + i - 1}", "--nat-method=NONE",
                "--rpc-http-enabled=true", "--rpc-http-host=127.0.0.1", f"--rpc-http-port={rpc_port(i)}",
                "--rpc-http-api=ETH,NET,WEB3,QBFT,ADMIN,TXPOOL,DEBUG", "--host-allowlist=localhost,127.0.0.1",
                "--min-gas-price=1000000000", "--revert-reason-enabled=true", "--logging=INFO",
                "--metrics-enabled=false"]
        for flag, value in policy["besu"].items():
            args.append(f"--{flag}={str(value).lower() if isinstance(value, bool) else value}")
        args.append("--tx-pool-priority-senders=" + ",".join(priority))
        log = open(node / "besu.log", "w")
        proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        pids.append(proc.pid)
    (run / "pids.json").write_text(json.dumps({"kind": kind, "pids": pids, "rpc": [rpc_port(i) for i in range(1, 5)]}))
    print(json.dumps({"kind": kind, "rpc": [f"http://127.0.0.1:{rpc_port(i)}" for i in range(1, 5)]}))


def call(port, method, params=()):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        reply = json.load(response)
    if "error" in reply:
        raise RuntimeError(reply["error"])
    return reply["result"]


def wait_ready(run, blocks=3, timeout=300):
    ports = json.loads((run / "pids.json").read_text())["rpc"]
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            heights = [int(call(p, "eth_blockNumber"), 16) for p in ports]
            if min(heights) >= blocks:
                return heights
        except Exception:
            pass
        time.sleep(2)
    raise SystemExit("network did not reach block %d" % blocks)


def stop(run, wipe):
    info = json.loads((run / "pids.json").read_text())
    for pid in info["pids"]:
        try:
            os.killpg(pid, signal.SIGINT)
        except ProcessLookupError:
            pass
    time.sleep(5)
    for pid in info["pids"]:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    (run / "pids.json").unlink()
    if wipe:
        shutil.rmtree(run)  # the run folder only: its own copies of keys, genesis and chain data


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["start", "stop", "wait"])
    parser.add_argument("--kind", choices=["production", "rehearsal"])
    parser.add_argument("--run", required=True)
    parser.add_argument("--wipe", action="store_true")
    args = parser.parse_args()
    run = Path(args.run).resolve()
    if args.action == "start":
        start(args.kind, run)
    elif args.action == "wait":
        print(wait_ready(run))
    else:
        stop(run, args.wipe)
