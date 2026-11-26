"""Prepare rootless explorer builds from exact published source revisions."""
import argparse,json,os,pwd,re,subprocess
from pathlib import Path

def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def checkout(url,commit,path):
    assert len(commit)==40 and all(c in '0123456789abcdef' for c in commit)
    if not path.exists():
        run('git','init',str(path))
        run('git','-C',str(path),'fetch','--depth=1',url,commit)
        run('git','-C',str(path),'checkout','--detach','FETCH_HEAD')
    assert subprocess.check_output(['git','-C',str(path),'rev-parse','HEAD'],text=True).strip()==commit
    assert not subprocess.check_output(['git','-C',str(path),'status','--porcelain'],text=True).strip()

HOME=Path('/var/lib/cryft-explorer')
def mount_data_volume(device):
    """Mount the droplet's pre-formatted ext4 volume at the runtime home (by UUID, nofail), as install-besu.py does for
    /var/lib/cryft. Never formats anything; takes over DigitalOcean's /mnt/<name> auto-mount only while it is empty."""
    device=Path(device);assert device.is_block_device(),f'{device} is not a block device'
    probe=dict(line.split('=',1) for line in subprocess.check_output(['blkid','-o','export',str(device)],text=True).split())
    assert probe.get('TYPE')=='ext4',f'{device} is not ext4; formatting is a separate, approved step'
    uuid=probe['UUID'];assert re.fullmatch(r'[0-9a-f-]{36}',uuid)
    current=subprocess.run(['findmnt','-n','-o','SOURCE,UUID',str(HOME)],capture_output=True,text=True).stdout.split()
    if current:
        assert uuid in current,f'{HOME} is already a mount of something else: {current}'
        return uuid
    elsewhere=subprocess.run(['findmnt','-n','-o','TARGET','-S',f'UUID={uuid}'],capture_output=True,text=True).stdout.split()
    if elsewhere:
        assert len(elsewhere)==1 and elsewhere[0].startswith('/mnt/'),f'{device} is mounted at {elsewhere}'
        target=Path(elsewhere[0])
        assert {x.name for x in target.iterdir()}<={'lost+found'},f'{target} already holds data'
        unit=subprocess.check_output(['systemd-escape','--path','--suffix=mount',str(target)],text=True).strip()
        unit_file=Path('/etc/systemd/system')/unit
        assert unit_file.is_file() and 'DO Volume' in unit_file.read_text(),f'{target} is not a DO volume mount unit'
        run('systemctl','disable','--now',unit)
        assert not subprocess.run(['findmnt','-n','-S',f'UUID={uuid}'],capture_output=True,text=True).stdout.strip()
    HOME.mkdir(mode=0o700,exist_ok=True)
    assert not any(HOME.iterdir()),f'{HOME} already holds data; move it onto the volume by hand first'
    fstab=Path('/etc/fstab')
    if f'UUID={uuid} ' not in fstab.read_text():
        with fstab.open('a') as stream:stream.write(f'UUID={uuid} {HOME} ext4 defaults,nofail,noatime,discard 0 2\n')
    run('systemctl','daemon-reload');run('mount',str(HOME))
    assert uuid in subprocess.check_output(['findmnt','-n','-o','UUID',str(HOME)],text=True)
    return uuid

def main():
    p=argparse.ArgumentParser();p.add_argument('--commit',required=True);p.add_argument('--host',choices=['Frontend-01','Indexer-01'],required=True);p.add_argument('--frontend-commit',required=True)
    p.add_argument('--data-device');a=p.parse_args()   # the backend's DO volume (Indexer-01): Postgres, Redis and the image store live on it
    assert os.geteuid()==0
    release=Path('/opt/cryft/releases')/a.commit
    checkout('https://github.com/cryft-labs/dakota-network.git',a.commit,release)
    assert Path(__file__).read_bytes()==(release/'Tools/Explorer/prepare-build.py').read_bytes()
    volume=mount_data_volume(a.data_device) if a.data_device else None
    env=dict(os.environ,DEBIAN_FRONTEND='noninteractive')
    run('apt-get','update',env=env)
    run('apt-get','install','-y','podman','uidmap','slirp4netns','fuse-overlayfs','passt','git','ca-certificates',env=env)
    name='cryft-explorer';home=HOME
    try:user=pwd.getpwnam(name)
    except KeyError:
        # On a mounted volume the home already exists: no skeleton is copied into it, and it is handed to the user below.
        run('useradd','--user-group',('--no-create-home' if home.is_dir() else '--create-home'),'--home-dir',str(home),'--shell','/usr/sbin/nologin',name)
        user=pwd.getpwnam(name)
        run('chown',f'{name}:{name}',str(home))
    assert user.pw_dir==str(home) and user.pw_shell=='/usr/sbin/nologin'
    for kind in ['uid','gid']:
        entries=Path('/etc/sub'+kind).read_text().splitlines()
        if not any(line.startswith(name+':') for line in entries):
            start=max([100000]+[int(x.split(':')[1])+int(x.split(':')[2]) for x in entries if x])
            run('usermod','--add-sub'+kind+'s',f'{start}-{start+65535}',name)
    run('chmod','0700',str(home))
    run('loginctl','enable-linger',name)
    run('systemctl','start',f'user@{user.pw_uid}.service')
    run('install','-d','-o','root','-g','root','-m','0755','/opt/cryft/builds')
    frontend=a.host=='Frontend-01'
    component='frontend' if frontend else 'backend'
    revision=a.frontend_commit if frontend else '43af7ea84797e2f3a55ac1191d9cbe67436eb3e8'
    source=Path('/opt/cryft/builds')/(component+'-'+revision)
    checkout('https://github.com/cryft-labs/dakota-explorer.git' if frontend else 'https://github.com/blockscout/blockscout.git',revision,source)
    dockerfile=source/'Dockerfile' if frontend else release/'Tools/Explorer/backend.Dockerfile'
    args=['/usr/bin/podman','--cgroup-manager=cgroupfs','build','--network=host','--layers','--jobs=2','--pull=missing',
       '--file',str(dockerfile),'--tag',f'localhost/cryft-explorer-{component}:{revision}',
       '--iidfile',str(home/(component+'-image.id'))]
    if frontend:args+=['--build-arg','GIT_COMMIT_SHA='+revision,'--build-arg','GIT_TAG=cryft-production','--build-arg','NEXT_OPEN_TELEMETRY_ENABLED=false']
    else:args+=['--build-arg','RELEASE_VERSION=11.3.0','--build-arg','BLOCKSCOUT_VERSION=v11.3.0','--build-arg','CHAIN_TYPE=default']
    args+=[str(source)]
    unit=f'''[Unit]
Description=Build pinned Cryft explorer {component}
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User={name}
Group={name}
WorkingDirectory={home}
Environment=HOME={home}
Environment=XDG_RUNTIME_DIR=/run/user/{user.pw_uid}
ExecStart={' '.join(args)}
TimeoutStartSec=3600
MemoryHigh=10G
MemoryMax=12G
CPUQuota=400%
TasksMax=2048
LimitNOFILE=65536
Delegate=yes
UMask=0077
'''
    path=Path('/etc/systemd/system/cryft-explorer-build.service')
    assert subprocess.run(['systemctl','is-active','--quiet','cryft-explorer-build']).returncode!=0,'Build already running'
    path.write_text(unit);os.chmod(path,0o644)
    run('systemd-analyze','verify',str(path));run('systemctl','daemon-reload')
    receipt={'data_volume_uuid':volume,'host':a.host,'source_commit':revision,'deployment_commit':a.commit,'runtime_user':name,'runtime_uid':user.pw_uid,'component':component,'image_tag':f'localhost/cryft-explorer-{component}:{revision}','image_id_file':str(home/(component+'-image.id'))}
    (home/'build-request.json').write_text(json.dumps(receipt,indent=2)+'\n')
    os.chmod(home/'build-request.json',0o644)
    run('systemctl','start','--no-block','cryft-explorer-build')
    print(json.dumps(receipt))
if __name__=='__main__':main()
