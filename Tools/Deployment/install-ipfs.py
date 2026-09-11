"""Install the approved isolated Backend-01 Kubo service; no public gateway yet."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tarfile

VERSION='0.43.0'
SHA='2ccb2c16c4ed0c893858dc6ac8a062d789e36a03339a7164459a917b64354c3d'
ROOT=Path('/opt/cryft/ipfs')
REPO=Path('/var/lib/cryft-ipfs')

def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--commit',required=True);a=p.parse_args()
    assert os.geteuid()==0 and len(a.commit)==40 and all(c in '0123456789abcdef' for c in a.commit)
    release=Path('/opt/cryft/releases')/a.commit
    assert subprocess.check_output(['git','-C',str(release),'rev-parse','HEAD'],text=True).strip()==a.commit
    assert not subprocess.check_output(['git','-C',str(release),'status','--porcelain'],text=True).strip()
    assert Path(__file__).read_bytes()==(release/'Tools/Deployment/install-ipfs.py').read_bytes()
    addresses=json.loads(subprocess.check_output(['ip','-j','address']))
    assert any(x.get('local')=='100.111.67.1' for link in addresses for x in link.get('addr_info',[]))
    active=subprocess.run(['systemctl','is-active','--quiet','cryft-ipfs.service']).returncode==0
    assert not active,'Preserve a running IPFS service; use the documented upgrade procedure'
    try:
        user=pwd.getpwnam('cryft-ipfs')
        assert user.pw_shell=='/usr/sbin/nologin'
    except KeyError:
        run('useradd','--system','--user-group','--home-dir',str(REPO),'--no-create-home','--shell','/usr/sbin/nologin','cryft-ipfs')
    run('install','-d','-o','cryft-ipfs','-g','cryft-ipfs','-m','0700',str(REPO))
    run('install','-d','-m','0755',str(ROOT),'/var/cache/cryft','/etc/cryft/ipfs')
    archive=Path('/var/cache/cryft/kubo-v0.43.0-linux-amd64.tar.gz')
    if not archive.exists():
        temporary=archive.with_suffix('.download')
        run('curl','--proto','=https','--tlsv1.2','--fail','--location','--retry','3','--max-time','300',
            'https://dist.ipfs.tech/kubo/v0.43.0/kubo_v0.43.0_linux-amd64.tar.gz','--output',str(temporary))
        assert sha(temporary)==SHA
        os.replace(temporary,archive)
    assert sha(archive)==SHA
    version=ROOT/('v'+VERSION);version.mkdir(mode=0o755,exist_ok=True)
    binary=version/'ipfs'
    if not binary.exists():
        with tarfile.open(archive) as bundle:
            member=bundle.getmember('kubo/ipfs')
            assert member.isfile()
            with bundle.extractfile(member) as source,binary.open('xb') as target:
                shutil.copyfileobj(source,target)
        os.chmod(binary,0o755)
    assert subprocess.check_output(['runuser','-u','cryft-ipfs','--','env','IPFS_PATH='+str(REPO),str(binary),'version','--number'],text=True).strip()==VERSION
    current=ROOT/'current'
    if current.is_symlink():assert current.resolve()==version
    else:
        assert not current.exists()
        current.symlink_to(version,target_is_directory=True)
    config=REPO/'config'
    original_peer=json.loads(config.read_text())['Identity']['PeerID'] if config.exists() else None
    if not config.exists():
        run('runuser','-u','cryft-ipfs','--','env','IPFS_PATH='+str(REPO),str(binary),'init','--profile=server')
    peer_file=Path('/etc/cryft/ipfs/peers.json')
    existing_peers=json.loads(config.read_text()).get('Peering',{}).get('Peers',[]) or []
    peer_file.write_text(json.dumps(existing_peers,indent=2)+'\n')
    os.chmod(peer_file,0o644)
    files=release/'Tools/SolcCompiler/deploy/backend-ipfs'
    run('runuser','-u','cryft-ipfs','--','python3',str(files/'configure.py'),'--repo',str(REPO),'--peers-file',str(peer_file))
    settings=json.loads(config.read_text())
    assert original_peer is None or settings['Identity']['PeerID']==original_peer
    unit=Path('/etc/systemd/system/cryft-ipfs.service')
    if unit.exists():assert unit.read_bytes()==(files/unit.name).read_bytes()
    else:shutil.copyfile(files/unit.name,unit)
    os.chmod(unit,0o644)
    run('systemd-analyze','verify',str(unit))
    run('systemctl','daemon-reload')
    run('systemctl','enable','--now','cryft-ipfs.service')
    receipt={'source_commit':a.commit,'version':VERSION,'archive_sha256':SHA,'peer_id':settings['Identity']['PeerID'],
        'runtime_user':'cryft-ipfs','service':'cryft-ipfs.service','service_enabled':True,'start_requested':True,
        'api':settings['Addresses']['API'],'gateway':settings['Addresses']['Gateway'],
        'swarm':settings['Addresses']['Swarm'],'peer_policy':'nebula_only','public_gateway_configured':False,
        'compiler_publication_verified':False,'existing_identity_preserved':True}
    Path('/etc/cryft/ipfs/installation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt))

if __name__=='__main__':main()
