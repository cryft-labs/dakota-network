#!/usr/bin/env python3
"""Mac side of the nightly chain export: pull sealed segments from Archive-01, optionally prove a restore.

    python Tools/Deployment/pull-chain-export.py            # copy new *.cms into ~/Cryft/backups/chain-113211/
    python Tools/Deployment/pull-chain-export.py --drill    # + rebuild the chain locally from every segment

The drill decrypts each segment with the backup recipient's private key into a temporary folder, checks each
manifest (sha256, contiguous ranges, genesis), imports all blocks into a fresh Besu data directory on the
reproducible genesis (Contracts/Genesis/CryftGenesis.json) with `besu blocks import --format=RLP`, and checks
that the imported head hash equals the last manifest's. Offline: nothing is signed or sent; the temporary folder
(plaintext blocks) is deleted afterwards. Until offsite storage exists, the Mac copy is the off-host copy.
"""
import argparse, hashlib, json, os, shutil, subprocess, tarfile, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SSH = ["ssh", "-F", str(Path.home() / "Cryft/codex-outputs/cryft-ssh/mac-ssh-config"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=25"]
LOCAL = Path.home() / "Cryft/backups/chain-113211"
REMOTE = "/var/lib/cryft/chain-export/outgoing"
KEY = Path.home() / "Cryft/codex-outputs/cryft-backup/cryft-backup-recipient.key"
CERT = Path.home() / "Cryft/repos/design-kit/deploy/droplets/backup/cryft-backup-recipient.crt"
BESU = Path(os.environ.get("BESU_HOME", Path.home() / "Cryft/tools/besu/besu-26.8.1")) / "bin/besu"
JAVA_HOME = os.environ.get("JAVA_HOME", "/opt/homebrew/opt/openjdk@25")
GENESIS_BLOCK = json.loads((REPO / "Contracts/Genesis/genesis-block.json").read_text())["genesisBlockHash"]


def pull():
    LOCAL.mkdir(parents=True, exist_ok=True)
    os.chmod(LOCAL, 0o700)
    names = subprocess.run(SSH + ["Archive-01", f"ls {REMOTE}"], capture_output=True, text=True, check=True).stdout.split()
    copied = []
    for name in sorted(n for n in names if n.endswith(".cms") and not n.startswith(".")):
        target = LOCAL / name
        if target.exists():
            continue
        remote_sha = subprocess.run(SSH + ["Archive-01", f"sha256sum {REMOTE}/{name}"], capture_output=True, text=True,
                                    check=True).stdout.split()[0]
        with open(target.with_suffix(".part"), "wb") as out:
            subprocess.run(SSH + ["Archive-01", f"cat {REMOTE}/{name}"], stdout=out, check=True)
        assert hashlib.sha256(target.with_suffix(".part").read_bytes()).hexdigest() == remote_sha, name
        target.with_suffix(".part").replace(target)
        os.chmod(target, 0o600)
        copied.append(name)
    return copied


def drill():
    segments = sorted(LOCAL.glob("chain-113211-*.cms"))
    assert segments, "no segments pulled yet"
    work = Path(tempfile.mkdtemp(prefix="cryft-chain-drill-"))
    try:
        blocks, expected_next, last = work / "all.rlp", 0, None
        with open(blocks, "wb") as all_blocks:
            for segment in segments:
                plain = work / "segment.tar"
                subprocess.run(["openssl", "cms", "-decrypt", "-binary", "-inform", "DER", "-in", str(segment), "-out", str(plain),
                                "-inkey", str(KEY), "-recip", str(CERT)], check=True)
                with tarfile.open(plain) as tar:
                    members = {Path(m.name).name: tar.extractfile(m).read() for m in tar.getmembers()}
                plain.unlink()
                manifest = json.loads(members["manifest.json"])
                assert manifest["from"] == expected_next, f"gap before {segment.name}"
                assert manifest["genesisBlockHash"] == GENESIS_BLOCK
                assert hashlib.sha256(members["blocks.rlp"]).hexdigest() == manifest["blocksSha256"], segment.name
                all_blocks.write(members["blocks.rlp"])
                expected_next, last = manifest["to"] + 1, manifest
        data = work / "data"
        env = dict(os.environ, JAVA_HOME=JAVA_HOME)
        subprocess.run([str(BESU), f"--data-path={data}", f"--genesis-file={REPO / 'Contracts/Genesis/CryftGenesis.json'}",
                        "--data-storage-format=FOREST", "blocks", "import", "--format=RLP", f"--from={blocks}"],
                       env=env, check=True, capture_output=True, timeout=7200)
        # Read the imported head back: start the node offline (no peers, loopback RPC) just long enough to ask.
        node = subprocess.Popen([str(BESU), f"--data-path={data}", f"--genesis-file={REPO / 'Contracts/Genesis/CryftGenesis.json'}",
                                 "--data-storage-format=FOREST", "--discovery-enabled=false", "--max-peers=0", "--p2p-enabled=false",
                                 "--rpc-http-enabled", "--rpc-http-host=127.0.0.1", "--rpc-http-port=18999"],
                                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            import urllib.request
            head = None
            for _ in range(90):
                try:
                    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": [hex(last["to"]), False]}).encode()
                    reply = json.load(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18999", body,
                                                                                    {"Content-Type": "application/json"}), timeout=5))
                    head = reply["result"]["hash"]
                    break
                except Exception:
                    time.sleep(2)
        finally:
            node.terminate()
            node.wait(timeout=60)
        result = {"segments": len(segments), "blocks": last["to"] + 1, "lastBlockHash": last["lastBlockHash"],
                  "importedHash": head, "restored": head == last["lastBlockHash"]}
        print(json.dumps(result))
        return result
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--drill", action="store_true")
    a = p.parse_args()
    print(json.dumps({"copied": pull(), "local": str(LOCAL)}))
    if a.drill:
        raise SystemExit(0 if drill()["restored"] else 1)
