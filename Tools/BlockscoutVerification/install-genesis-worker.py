"""Install a bounded, rootless maintenance worker using the existing explorer image.

Run on Backend-01 after publication. No credentials are exported or new ports opened.
"""
import argparse,hashlib,json,os,pwd,shlex,subprocess,zipfile
from pathlib import Path

BASE=Path('/var/lib/cryft-explorer')
STAGE=Path('/root/cryft-bootstrap/blockscout-verification')
CONTAINER_DIR='/app/dets/verification-20260911'
UNIT='cryft-explorer-genesis-verification'

def main():
    p=argparse.ArgumentParser();p.add_argument('--bundle-sha256',required=True);a=p.parse_args()
    blob=STAGE/'bundle.zip';assert hashlib.sha256(blob.read_bytes()).hexdigest()==a.bundle_sha256
    user=pwd.getpwnam('cryft-explorer');assert user.pw_dir==str(BASE)
    prefix=['runuser','-u',user.pw_name,'--','env','HOME='+user.pw_dir,'XDG_RUNTIME_DIR=/run/user/'+str(user.pw_uid),'/usr/bin/podman','--cgroup-manager=cgroupfs']
    def pod(*args,**kwargs):return subprocess.run(prefix+list(args),cwd=BASE,check=True,**kwargs)
    # Take and validate a logical backup on the same server before address imports.
    backups=Path('/var/backups/cryft-explorer');backups.mkdir(mode=0o700,parents=True,exist_ok=True)
    backup=backups/'before-genesis-verification-20260911.dump'
    if not backup.exists():
        temp=backup.with_suffix('.tmp')
        with temp.open('wb') as f:pod('exec','cryft-explorer-db','pg_dump','-U','postgres','-d','blockscout','-Fc',stdout=f)
        os.chmod(temp,0o600);temp.rename(backup)
    with backup.open('rb') as f:pod('exec','-i','cryft-explorer-db','pg_restore','--list',stdin=f,stdout=subprocess.DEVNULL)
    target=BASE/'verification-staging';target.mkdir(mode=0o755,exist_ok=True)
    with zipfile.ZipFile(blob) as z:
        for item in z.infolist():
            path=(target/item.filename).resolve()
            assert path.is_relative_to(target.resolve()) and not item.is_dir()
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(z.read(item));os.chmod(path,0o644)
    pod('exec','cryft-explorer-api','mkdir','-p',CONTAINER_DIR)
    pod('cp',str(target)+'/.','cryft-explorer-api:'+CONTAINER_DIR)
    pod('exec','--user','0','cryft-explorer-api','chown','-R','10001:10001',CONTAINER_DIR)
    script=target/'genesis-worker.exs'
    assert script.exists()
    # An extra release process starts Explorer in API mode; no new web listener or
    # indexer is started, and the running API/indexer container is not restarted.
    cmd=['/usr/bin/podman','--cgroup-manager=cgroupfs','exec','--env','APPLICATION_MODE=api',
         '--env','DAKOTA_VERIFICATION_DIR='+CONTAINER_DIR,
         '--env','DAKOTA_VERIFICATION_LIMIT=${DAKOTA_VERIFICATION_LIMIT}',
         '--env','DAKOTA_VERIFICATION_OFFSET=${DAKOTA_VERIFICATION_OFFSET}',
         '--env','DAKOTA_VERIFICATION_DRY_RUN=${DAKOTA_VERIFICATION_DRY_RUN}',
         'cryft-explorer-api','bin/blockscout','eval','Code.eval_file("'+CONTAINER_DIR+'/genesis-worker.exs")']
    unit='\n'.join(['[Unit]','Description=Verify Dakota genesis contracts against live bytecode and genuine Rust results',
        'After=cryft-explorer-api.service cryft-explorer-db.service dnclient.service','Requires=cryft-explorer-api.service',
        '[Service]','Type=oneshot','User=cryft-explorer','Group=cryft-explorer','WorkingDirectory='+str(BASE),
        'Environment=HOME='+str(BASE),'Environment=XDG_RUNTIME_DIR=/run/user/'+str(user.pw_uid),
        'Environment=DAKOTA_VERIFICATION_LIMIT=32433','Environment=DAKOTA_VERIFICATION_OFFSET=0','Environment=DAKOTA_VERIFICATION_DRY_RUN=false',
        'EnvironmentFile=-/etc/cryft/explorer/genesis-verification.env','ExecStart='+' '.join(shlex.quote(x) for x in cmd),
        'TimeoutStartSec=infinity','MemoryMax=2G','CPUQuota=150%','UMask=0077','[Install]','WantedBy=multi-user.target',''])
    Path('/etc/systemd/system/'+UNIT+'.service').write_text(unit)
    subprocess.run(['systemctl','daemon-reload'],check=True)
    print(json.dumps({'backup':str(backup),'backup_bytes':backup.stat().st_size,'bundle_sha256':a.bundle_sha256,'unit':UNIT,'installed':True}))

if __name__=='__main__':main()
