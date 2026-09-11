"""Install the shared unprivileged Nginx service; optionally add archive RPC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess

def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)

def copy_once(source,target,gid=0,mode=0o644):
    assert not target.is_symlink()
    if target.exists():assert target.read_bytes()==source.read_bytes(),f'Review existing configuration at {target}'
    else:shutil.copyfile(source,target)
    os.chown(target,0,gid);os.chmod(target,mode)

def main():
    p=argparse.ArgumentParser();p.add_argument('--commit',required=True);p.add_argument('--host',required=True);a=p.parse_args()
    assert os.geteuid()==0 and len(a.commit)==40 and all(c in '0123456789abcdef' for c in a.commit)
    release=Path('/opt/cryft/releases')/a.commit
    assert subprocess.check_output(['git','-C',str(release),'rev-parse','HEAD'],text=True).strip()==a.commit
    assert not subprocess.check_output(['git','-C',str(release),'status','--porcelain'],text=True).strip()
    assert Path(__file__).read_bytes()==(release/'Tools/Deployment/install-nginx.py').read_bytes()
    host=next(h for h in json.loads((release/'Tools/Deployment/hosts.json').read_text()) if h['name']==a.host)
    assert a.host in ['Frontend-01','Backend-01','Paladin-01']
    addresses=json.loads(subprocess.check_output(['ip','-j','address']))
    assert any(x.get('local')==host['nebula'] for link in addresses for x in link.get('addr_info',[]))
    assert subprocess.run(['systemctl','is-active','--quiet','nginx.service']).returncode!=0, 'Review and migrate an existing default Nginx instance first'
    # Prevent the package's default root-master service opening public port 80.
    run('systemctl','mask','--runtime','nginx.service')
    env=dict(os.environ,DEBIAN_FRONTEND='noninteractive')
    run('apt-get','update',env=env)
    run('apt-get','install','-y','nginx',env=env)
    run('systemctl','disable','nginx.service')
    try:
        user=pwd.getpwnam('cryft-proxy')
        assert user.pw_shell=='/usr/sbin/nologin'
    except KeyError:
        run('useradd','--system','--user-group','--home-dir','/var/cache/cryft-nginx','--no-create-home','--shell','/usr/sbin/nologin','cryft-proxy')
        user=pwd.getpwnam('cryft-proxy')
    base=Path('/etc/cryft/nginx')
    run('install','-d','-o','root','-g','cryft-proxy','-m','0750',str(base),str(base/'conf.d'))
    files=release/'Tools/SolcCompiler/deploy/backend-ipfs'
    copy_once(files/'nginx.conf',base/'nginx.conf',user.pw_gid,0o640)
    copy_once(files/'cryft-nginx.service',Path('/etc/systemd/system/cryft-nginx.service'))
    if a.host=='Frontend-01':
        copy_once(release/'Tools/Deployment/nginx-archive-rpc.conf',base/'conf.d/archive-rpc.conf',user.pw_gid,0o640)
    run('systemd-analyze','verify','/etc/systemd/system/cryft-nginx.service')
    run('systemctl','daemon-reload')
    run('systemctl','enable','--now','cryft-nginx.service')
    receipt={'source_commit':a.commit,'host':a.host,'version':subprocess.run(['nginx','-v'],capture_output=True,text=True,check=True).stderr.strip(),
        'runtime_user':'cryft-proxy','service':'cryft-nginx.service','service_enabled':True,
        'public_listener_configured':False,'archive_http':'http://100.111.69.1:8547' if a.host=='Frontend-01' else None,
        'archive_websocket':'ws://100.111.69.1:8547/ws' if a.host=='Frontend-01' else None,
        'config_sha256':hashlib.sha256((base/'nginx.conf').read_bytes()).hexdigest(),
        'default_root_nginx_disabled':True}
    (base/'installation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt))

if __name__=='__main__':main()
