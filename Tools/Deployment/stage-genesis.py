"""Pull a pinned review release and install its verified compressed genesis.

Does not start any node, install keys, change firewall policy or reset chain data.
"""
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile
from pathlib import Path

RELEASES=Path('/opt/cryft/releases')
TARGET=Path('/etc/cryft/besu/BesuGenesis.json')
REPOSITORY='https://github.com/cryft-labs/dakota-network.git'
BPO2_GENESIS_SHA='95b4b05f4dea051a6f6cbf3babc164456044d55369d28548aa8026787a75e0ee'
BPO_INSERT=b'        "bpo3Time": 0,\n        "bpo4Time": 0,\n        "bpo5Time": 0,\n'

def verify_bpo_only_change(candidate):
    """Prove the entire candidate equals the deployed BPO2 file after three insertions."""
    h=hashlib.sha256()
    with candidate.open('rb') as f:
        prefix=f.read(4096)
        assert prefix.count(BPO_INSERT)==1 and prefix.index(BPO_INSERT)<prefix.index(b'"alloc"')
        h.update(prefix.replace(BPO_INSERT,b'',1))
        for block in iter(lambda:f.read(8*1024*1024),b''):h.update(block)
    assert h.hexdigest()==BPO2_GENESIS_SHA,'Candidate changes more than the approved BPO fields'

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(8*1024*1024),b''):h.update(block)
    return h.hexdigest()

def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)

def main():
    p=argparse.ArgumentParser();p.add_argument('--commit',required=True);p.add_argument('--archive-sha256',required=True);p.add_argument('--genesis-sha256',required=True)
    p.add_argument('--allow-compatible-bpo-update',action='store_true');a=p.parse_args()
    assert os.getuid()==0
    assert re.fullmatch(r'[0-9a-f]{40}',a.commit)
    assert all(re.fullmatch(r'[0-9a-f]{64}',d) for d in [a.archive_sha256,a.genesis_sha256])
    environment=dict(os.environ,DEBIAN_FRONTEND='noninteractive',GIT_TERMINAL_PROMPT='0')
    extractor=shutil.which('7zz') or shutil.which('7z')
    if not shutil.which('git') or not extractor:
        run('apt-get','update',env=environment)
        run('apt-get','install','-y','git','7zip',env=environment)
    extractor=shutil.which('7zz') or shutil.which('7z')
    assert extractor,'Installed 7zip package has no supported extractor executable'
    RELEASES.mkdir(parents=True,exist_ok=True,mode=0o755)
    release=RELEASES/a.commit
    if not release.exists():
        release.mkdir(mode=0o755)
        run('git','init',str(release))
        run('git','-C',str(release),'fetch','--depth=1',REPOSITORY,a.commit,env=environment)
        run('git','-C',str(release),'checkout','--detach','FETCH_HEAD')
    head=subprocess.check_output(['git','-C',str(release),'rev-parse','HEAD'],text=True).strip()
    assert head==a.commit
    assert not subprocess.check_output(['git','-C',str(release),'status','--porcelain'],text=True).strip()
    archive=release/'Contracts/Genesis/besuGenesis.7z'
    manifest=json.loads((release/'Contracts/Genesis/development-release.json').read_text())
    assert manifest['archive_sha256']==a.archive_sha256 and manifest['genesis_sha256']==a.genesis_sha256
    assert sha(archive)==a.archive_sha256
    TARGET.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
    assert not TARGET.is_symlink()
    replacing=False
    if TARGET.exists() and sha(TARGET)!=a.genesis_sha256:
        assert a.allow_compatible_bpo_update,'Different existing genesis; inspect its chain/data before replacement'
        assert sha(TARGET)==BPO2_GENESIS_SHA,'Unrecognized prior genesis'
        assert manifest['previous_genesis_sha256']==BPO2_GENESIS_SHA
        assert manifest['milestone_update']['qbft_binary_probe_passed']
        assert manifest['milestone_update']['genesis_block_hash']=='0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8'
        active=subprocess.run(['systemctl','is-active','cryft-besu.service'],capture_output=True,text=True).stdout.strip()
        assert active in ('inactive','failed','unknown'),'Stop the Besu service before the compatible genesis update'
        replacing=True
    if TARGET.exists() and not replacing:
        status='already_verified'
    else:
        assert shutil.disk_usage(TARGET.parent).free>manifest['genesis_bytes']+1024**3
        stage=Path(tempfile.mkdtemp(prefix='.genesis-',dir=TARGET.parent))
        run(extractor,'x','-bd','-y',str(archive),'-o'+str(stage),'BesuGenesis.json',stdout=subprocess.DEVNULL)
        candidate=stage/'BesuGenesis.json'
        assert candidate.stat().st_size==manifest['genesis_bytes']
        assert sha(candidate)==a.genesis_sha256
        if replacing:
            verify_bpo_only_change(candidate)
            backup=TARGET.with_name('BesuGenesis.'+BPO2_GENESIS_SHA+'.json')
            if backup.exists():
                assert not backup.is_symlink() and sha(backup)==BPO2_GENESIS_SHA
            else:
                os.link(TARGET,backup)
        os.chmod(candidate,0o644)
        # Flush the staged contents before atomically publishing the configuration.
        with candidate.open('rb') as f:os.fsync(f.fileno())
        os.replace(candidate,TARGET)
        stage.rmdir()  # Only the known empty staging directory; never recursive.
        status='compatible_bpo_update_verified' if replacing else 'installed_verified'
    assert sha(TARGET)==a.genesis_sha256
    receipt={'status':status,'source_commit':a.commit,'archive_sha256':a.archive_sha256,'genesis_sha256':a.genesis_sha256,'genesis_path':str(TARGET),'node_start_requested':False,'chain_data_reset':False}
    (TARGET.parent/'genesis-installation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt))

if __name__=='__main__':main()
