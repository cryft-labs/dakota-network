"""Install a pinned Besu runtime and enabled, unstarted, unprivileged service.

Run only after the release is committed/pushed and Nebula SSH is verified.
Existing keys and chain data are never replaced. Startup is a separate action.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import subprocess
import tarfile
import tempfile

VERSION = '26.8.1'
ARCHIVE_SHA = '0e0ed9cc0d8fa9091081b6c5d4646f15bbf7e33a6eb1e9f7bfb2ef831fe9aaf4'
GENESIS_SHA = '95b4b05f4dea051a6f6cbf3babc164456044d55369d28548aa8026787a75e0ee'
URL = 'https://github.com/besu-eth/besu/releases/download/26.8.1/besu-26.8.1.tar.gz'
ETC = Path('/etc/cryft/besu')
DATA = Path('/var/lib/cryft/besu')
RUNTIME = Path('/opt/cryft/runtimes/besu-26.8.1')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def atomic(path, text, mode, gid=0, preserve=False):
    assert not path.is_symlink()
    encoded = text.encode()
    if path.exists():
        if preserve:
            assert path.read_bytes() == encoded, f'Refusing to replace {path}'
            return
        if path.read_bytes() == encoded:
            return
    fd, staged = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(encoded)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(staged, mode)
    os.chown(staged, 0, gid)
    os.replace(staged, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--commit', required=True)
    parser.add_argument('--host', required=True)
    args = parser.parse_args()
    assert os.geteuid() == 0
    assert re.fullmatch(r'[0-9a-f]{40}', args.commit)
    release = Path('/opt/cryft/releases') / args.commit
    assert release.is_dir(), 'Pull the pinned release using stage-genesis.py first'
    assert subprocess.check_output(['git','-C',str(release),'rev-parse','HEAD'],text=True).strip() == args.commit
    assert not subprocess.check_output(['git','-C',str(release),'status','--porcelain'],text=True).strip()
    assert Path(__file__).read_bytes() == (release/'Tools/Deployment/install-besu.py').read_bytes()
    host = next(h for h in json.loads((release/'Tools/Deployment/hosts.json').read_text()) if h['name'] == args.host)
    assert host['name'] != 'Backend-01', 'Backend hosts application services, not a Besu node'
    ip = host['nebula']
    assert ipaddress.ip_address(ip) in ipaddress.ip_network('100.111.0.0/16')
    addresses = json.loads(subprocess.check_output(['ip','-j','address']))
    assert any(a.get('local') == ip for link in addresses for a in link.get('addr_info',[])), 'Expected Nebula interface is absent'
    assert sha(ETC/'BesuGenesis.json') == GENESIS_SHA
    validator = host['name'].startswith('Validator-')
    archive = host['name'] == 'Frontend-01'
    peers = json.loads((release/'Tools/Deployment/validator-peers.json').read_text())

    env = dict(os.environ, DEBIAN_FRONTEND='noninteractive')
    run('apt-get','update',env=env)
    run('apt-get','install','-y','openjdk-25-jre-headless','ca-certificates','curl',env=env)
    try:
        user = pwd.getpwnam('cryft-besu')
        assert user.pw_shell == '/usr/sbin/nologin'
    except KeyError:
        run('useradd','--system','--user-group','--home-dir',str(DATA),'--no-create-home','--shell','/usr/sbin/nologin','cryft-besu')
        user = pwd.getpwnam('cryft-besu')
    run('install','-d','-o','root','-g','root','-m','0755','/opt/cryft/runtimes','/var/cache/cryft','/var/lib/cryft')
    run('install','-d','-o','cryft-besu','-g','cryft-besu','-m','0700',str(DATA))
    run('install','-d','-o','root','-g','cryft-besu','-m','0750',str(ETC))
    tarball = Path('/var/cache/cryft') / f'besu-{VERSION}.tar.gz'
    if not tarball.exists():
        pending = tarball.with_suffix('.download')
        run('curl','--proto','=https','--tlsv1.2','--fail','--location','--retry','3','--max-time','300',URL,'--output',str(pending))
        assert sha(pending) == ARCHIVE_SHA
        os.replace(pending,tarball)
    assert sha(tarball) == ARCHIVE_SHA
    if not RUNTIME.exists():
        with tarfile.open(tarball) as source:
            # Python's data filter rejects escaping paths, links and special files.
            source.extractall(RUNTIME.parent,filter='data')
    assert (RUNTIME/'bin/besu').is_file()
    java_env = dict(os.environ,JAVA_HOME='/usr/lib/jvm/java-25-openjdk-amd64',JAVA_OPTS='-Xms64m -Xmx256m')
    version = subprocess.check_output([str(RUNTIME/'bin/besu'),'--version'],env=java_env,text=True).strip()
    assert '26.8.1' in version

    key_path = ETC/'node.key'
    if validator:
        expected = next(p for p in peers if p['name'] == host['name'])
        incoming = Path('/root/cryft-bootstrap/validator-node.key')
        if incoming.exists():
            assert not incoming.is_symlink() and incoming.stat().st_uid == 0 and incoming.stat().st_mode & 0o077 == 0
            key = incoming.read_text().strip()
            assert re.fullmatch('[0-9a-f]{64}',key)
            atomic(key_path,key+'\n',0o640,user.pw_gid,preserve=True)
            incoming.unlink()  # Exact known staging file; no chain data removed.
        assert key_path.is_file(), 'Existing validator identity must be installed'
    elif not key_path.exists():
        order = int('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',16)
        key = f'{secrets.randbelow(order-1)+1:064x}'
        atomic(key_path,key+'\n',0o640,user.pw_gid,preserve=True)
    os.chmod(key_path,0o640)
    os.chown(key_path,0,user.pw_gid)
    address_file = ETC/'node-address.txt'
    if not address_file.exists():
        run(str(RUNTIME/'bin/besu'),'--node-private-key-file='+str(key_path),'public-key','export-address','--to='+str(address_file),env=java_env)
    node_address = address_file.read_text().strip()
    assert re.fullmatch(r'0x[0-9a-fA-F]{40}',node_address)
    if validator:
        assert node_address.lower() == expected['address'].lower(), 'Validator key must match the genesis identity'

    static = [p['enode'] for p in peers if p['name'] != host['name']]
    atomic(ETC/'static-nodes.json',json.dumps(static,indent=2)+'\n',0o640,user.pw_gid,preserve=True)
    storage = 'FOREST' if archive else 'BONSAI'
    apis = ['ETH','NET','WEB3','QBFT','ADMIN'] + (['TRACE','DEBUG'] if archive else [])
    config = {
        'identity':'dakota-'+host['name'].lower(), 'data-path':str(DATA),
        'genesis-file':str(ETC/'BesuGenesis.json'), 'node-private-key-file':str(key_path),
        'network-id':112311, 'sync-mode':'FULL', 'data-storage-format':storage,
        'p2p-interface':ip, 'p2p-host':ip, 'p2p-port':30303,
        'p2p-ipv6-outbound-enabled':False, 'nat-method':'NONE', 'discovery-enabled':False,
        'bootnodes':[], 'static-nodes-file':str(ETC/'static-nodes.json'),
        'max-peers':20, 'sync-min-peers':1,
        'rpc-http-enabled':True, 'rpc-http-host':'127.0.0.1', 'rpc-http-port':8545,
        'rpc-http-api':apis, 'rpc-http-max-active-connections':200,
        'rpc-ws-enabled':True, 'rpc-ws-host':'127.0.0.1', 'rpc-ws-port':8546,
        'rpc-ws-api':['ETH','NET','WEB3'], 'rpc-ws-max-active-connections':100,
        'host-allowlist':['localhost','127.0.0.1'], 'rpc-http-cors-origins':[],
        'metrics-enabled':True, 'metrics-host':'127.0.0.1', 'metrics-port':9545,
        'min-gas-price':1000000000, 'revert-reason-enabled':True, 'logging':'INFO',
    }
    # JSON scalar/array syntax is also valid TOML for these primitive values.
    toml = ''.join(k+'='+json.dumps(v)+'\n' for k,v in config.items())
    atomic(ETC/'config.toml',toml,0o640,user.pw_gid,preserve=True)
    heap,high,maximum = (8,14,16) if archive else (6,10,12)
    unit = f'''[Unit]
Description=Dakota Besu {VERSION} ({host['name']})
Requires=dnclient.service
After=network-online.target dnclient.service
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=12

[Service]
Type=simple
User=cryft-besu
Group=cryft-besu
WorkingDirectory={DATA}
Environment="JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64"
Environment="JAVA_OPTS=-Xms2g -Xmx{heap}g -XX:MaxDirectMemorySize=2g -XX:ActiveProcessorCount=6 -XX:+ExitOnOutOfMemoryError"
ExecStart={RUNTIME}/bin/besu --config-file={ETC}/config.toml
Restart=on-failure
RestartSec=15
TimeoutStopSec=180
KillSignal=SIGINT
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths={DATA}
LimitNOFILE=65536
TasksMax=2048
MemoryHigh={high}G
MemoryMax={maximum}G
CPUQuota=600%

[Install]
WantedBy=multi-user.target
'''
    unit_path = Path('/etc/systemd/system/cryft-besu.service')
    atomic(unit_path,unit,0o644,preserve=True)
    run('systemd-analyze','verify',str(unit_path))
    run('systemctl','daemon-reload')
    run('systemctl','enable','cryft-besu.service')
    receipt = {'source_commit':args.commit,'host':host['name'],'version':version,
        'archive_sha256':ARCHIVE_SHA,'genesis_sha256':GENESIS_SHA,'node_address':node_address,
        'nebula_ip':ip,'storage_format':storage,'sync_mode':'FULL','runtime_user':'cryft-besu',
        'service':'cryft-besu.service','service_enabled':True,'start_requested':False,
        'http_origin':'127.0.0.1:8545','ws_origin':'127.0.0.1:8546','p2p':ip+':30303',
        'key_path':str(key_path),'key_replaced':False,'chain_data_reset':False}
    atomic(ETC/'runtime-installation.json',json.dumps(receipt,indent=2)+'\n',0o644)
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
