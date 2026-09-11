"""Pull a pinned review release and install its verified compressed genesis.

Does not start any node, install keys, change firewall policy or reset chain data.
"""
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile
from pathlib import Path

RELEASES=Path('/opt/cryft/releases')
TARGET=Path('/etc/cryft/besu/BesuGenesis.json')
REPOSITORY='https://github.com/cryft-labs/dakota-network.git'

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(8*1024*1024),b''):h.update(block)
    return h.hexdigest()

def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)

def main():
    p=argparse.ArgumentParser();p.add_argument('--commit',required=True);p.add_argument('--archive-sha256',required=True);p.add_argument('--genesis-sha256',required=True);a=p.parse_args()
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
    if TARGET.exists():
        assert sha(TARGET)==a.genesis_sha256,'Different existing genesis; inspect its chain/data before replacement'
        status='already_verified'
    else:
        assert shutil.disk_usage(TARGET.parent).free>manifest['genesis_bytes']+1024**3
        stage=Path(tempfile.mkdtemp(prefix='.genesis-',dir=TARGET.parent))
        run(extractor,'x','-bd','-y',str(archive),'-o'+str(stage),'BesuGenesis.json',stdout=subprocess.DEVNULL)
        candidate=stage/'BesuGenesis.json'
        assert candidate.stat().st_size==manifest['genesis_bytes']
        assert sha(candidate)==a.genesis_sha256
        os.chmod(candidate,0o644)
        # Flush the staged contents before atomically publishing the configuration.
        with candidate.open('rb') as f:os.fsync(f.fileno())
        os.replace(candidate,TARGET)
        stage.rmdir()  # Only the known empty staging directory; never recursive.
        status='installed_verified'
    assert sha(TARGET)==a.genesis_sha256
    receipt={'status':status,'source_commit':a.commit,'archive_sha256':a.archive_sha256,'genesis_sha256':a.genesis_sha256,'genesis_path':str(TARGET),'node_started':False,'chain_data_reset':False}
    (TARGET.parent/'genesis-installation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt))

if __name__=='__main__':main()
