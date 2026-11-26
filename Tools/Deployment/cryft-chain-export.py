#!/usr/bin/env python3
"""Nightly chain-data export on Archive-01: raw blocks since the last run, sealed to the backup recipient.

Why blocks and not the database: the genesis is reproducible (Tools/Genesis/build.py), so replaying every block
(`besu blocks import --format=RLP`) rebuilds the full state on any host. Blocks come from the running node's
loopback RPC (debug_getRawBlock), so the node is never stopped and the archive RPC stays up.

Each run writes one segment: blocks-<from>-<to>.rlp plus manifest.json (block range, last block hash, sha256),
packed and sealed (openssl cms, AES-256-GCM, RSA-OAEP-SHA256; the kit's cryft-backup format) as
outgoing/chain-113211-<from>-<to>.cms. Plaintext is deleted after sealing. State lives in state.json.
A run exports at most MAX_BLOCKS blocks (bounded); the next run continues.

Installed by install-chain-export.py; runs as cryft-chain-export from cryft-chain-export.timer.
"""
import hashlib, io, json, os, subprocess, tarfile, time, urllib.request
from pathlib import Path

ROOT = Path('/var/lib/cryft/chain-export')
STATE = ROOT / 'state.json'
OUTGOING = ROOT / 'outgoing'
RECIPIENT = Path('/etc/cryft/chain-export/backup-recipient.crt')
RPC = 'http://127.0.0.1:8545'
CHAIN_ID = '0x1ba3b'
MAX_BLOCKS = 200_000


def rpc(method, params):
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
    request = urllib.request.Request(RPC, body, {'Content-Type': 'application/json'})
    reply = json.load(urllib.request.urlopen(request, timeout=60))
    if 'error' in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply['result']


def main():
    assert rpc('eth_chainId', []) == CHAIN_ID
    state = json.loads(STATE.read_text()) if STATE.exists() else {'next': 0, 'segments': 0}
    head = int(rpc('eth_blockNumber', []), 16)
    first, last = state['next'], min(head, state['next'] + MAX_BLOCKS - 1)
    if first > last:
        print(json.dumps({'status': 'nothing new', 'next': first, 'head': head}))
        return
    digest, blob = hashlib.sha256(), io.BytesIO()
    for number in range(first, last + 1):
        raw = bytes.fromhex(rpc('debug_getRawBlock', [hex(number)])[2:])
        blob.write(raw)
        digest.update(raw)
    last_hash = rpc('eth_getBlockByNumber', [hex(last), False])['hash']
    name = f'chain-113211-{first:010d}-{last:010d}'
    manifest = {'chainId': 113211, 'from': first, 'to': last, 'lastBlockHash': last_hash,
                'blocksSha256': digest.hexdigest(), 'format': 'concatenated RLP blocks (besu blocks import --format=RLP)',
                'genesisBlockHash': rpc('eth_getBlockByNumber', ['0x0', False])['hash'],
                'createdAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    OUTGOING.mkdir(parents=True, exist_ok=True)
    plain = ROOT / f'.{name}.tar'
    with tarfile.open(plain, 'w') as tar:
        for member, data in ((f'{name}/blocks.rlp', blob.getvalue()), (f'{name}/manifest.json', json.dumps(manifest, indent=1).encode())):
            info = tarfile.TarInfo(member)
            info.size, info.mtime, info.mode = len(data), int(time.time()), 0o600
            tar.addfile(info, io.BytesIO(data))
    sealed = OUTGOING / f'{name}.cms'
    part = OUTGOING / f'.{name}.cms.part'
    subprocess.run(['openssl', 'cms', '-encrypt', '-binary', '-aes-256-gcm', '-in', str(plain), '-outform', 'DER',
                    '-out', str(part), '-recip', str(RECIPIENT), '-keyopt', 'rsa_padding_mode:oaep',
                    '-keyopt', 'rsa_oaep_md:sha256'], check=True)
    with open(part, 'r+b') as handle:
        os.fsync(handle.fileno())
    os.replace(part, sealed)
    plain.unlink()
    state = {'next': last + 1, 'segments': state['segments'] + 1, 'lastBlockHash': last_hash, 'lastSegment': sealed.name}
    STATE.write_text(json.dumps(state, indent=1) + '\n')
    print(json.dumps({'status': 'sealed', 'segment': sealed.name, 'blocks': last - first + 1, 'bytes': sealed.stat().st_size}))


if __name__ == '__main__':
    main()
