"""Pull a pinned release and install its verified genesis (Contracts/Genesis/CryftGenesis.json).

Does not start any node, install keys, change firewall policy or reset chain data. Refuses to replace a
different existing genesis: a new genesis means a new chain, which is a deliberate, separate step.
"""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

RELEASES = Path('/opt/cryft/releases')
TARGET = Path('/etc/cryft/besu/BesuGenesis.json')
REPOSITORY = 'https://github.com/cryft-labs/dakota-network.git'  # repo rename is out of scope (Chad decides later)
CHAIN_ID = 113211


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def verify_release(release, genesis_sha256):
    """Checks the committed genesis against its manifest and the expected hash."""
    manifest = json.loads((release / 'Contracts/Genesis/genesis-release.json').read_text())
    genesis = release / manifest['genesis_file']
    assert manifest['chainId'] == CHAIN_ID
    assert manifest['genesis_sha256'] == genesis_sha256 == sha(genesis), 'Genesis hash mismatch'
    config = json.loads(genesis.read_text())['config']
    assert config['chainId'] == CHAIN_ID and config['contractSizeLimit'] == 32768
    return genesis


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--commit', required=True)
    p.add_argument('--genesis-sha256', required=True)
    a = p.parse_args()
    assert os.getuid() == 0
    assert re.fullmatch(r'[0-9a-f]{40}', a.commit)
    assert re.fullmatch(r'[0-9a-f]{64}', a.genesis_sha256)
    environment = dict(os.environ, DEBIAN_FRONTEND='noninteractive', GIT_TERMINAL_PROMPT='0')
    RELEASES.mkdir(parents=True, exist_ok=True, mode=0o755)
    release = RELEASES / a.commit
    if not release.exists():
        release.mkdir(mode=0o755)
        run('git', 'init', str(release))
        run('git', '-C', str(release), 'fetch', '--depth=1', REPOSITORY, a.commit, env=environment)
        run('git', '-C', str(release), 'checkout', '--detach', 'FETCH_HEAD')
    assert subprocess.check_output(['git', '-C', str(release), 'rev-parse', 'HEAD'], text=True).strip() == a.commit
    assert not subprocess.check_output(['git', '-C', str(release), 'status', '--porcelain'], text=True).strip()
    genesis = verify_release(release, a.genesis_sha256)
    TARGET.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    assert not TARGET.is_symlink()
    if TARGET.exists():
        assert sha(TARGET) == a.genesis_sha256, 'A different genesis is installed: inspect its chain data first'
        status = 'already_verified'
    else:
        staged = TARGET.with_name('.BesuGenesis.json.staged')
        staged.write_bytes(genesis.read_bytes())
        with staged.open('rb') as f:
            os.fsync(f.fileno())
        os.chmod(staged, 0o644)
        os.replace(staged, TARGET)
        status = 'installed_verified'
    assert sha(TARGET) == a.genesis_sha256
    receipt = {'status': status, 'source_commit': a.commit, 'genesis_sha256': a.genesis_sha256,
               'genesis_path': str(TARGET), 'node_start_requested': False, 'chain_data_reset': False}
    (TARGET.parent / 'genesis-installation.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
