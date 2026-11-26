"""Install Paladin v1.0.0 and its Postgres on Paladin-01 (runbook Phase E.1), rootless Podman under cryft-paladin.

Run as root on Paladin-01 from a staged release (/opt/cryft/releases/<commit>, e.g. via
Tools/Deployment/stage-genesis.py). Never resets the database or the seed: secrets are created once.

- Data lives on the DO volume: /var/lib/cryft/paladin (the volume is mounted at /var/lib/cryft by install-besu.py).
- The seed is generated here. With --seal-cert, /etc/cryft/paladin/secrets.json (seed + database passwords) is
  sealed to the backup recipient certificate (openssl cms, AES-256-GCM, RSA-OAEP-SHA256; the same format as the
  kit's cryft-backup) into /etc/cryft/paladin/secrets.json.cms, for the Mac and offsite custody (Chad, I-1).
  The plaintext seed never leaves the host and is never printed.
- Paladin's JSON-RPC: 127.0.0.1:8548, published by nginx on 100.111.32.201:8550 for Backend-01 only.
- Paladin reaches the colocated Besu through nginx 127.0.0.1:8552.

    python3 /opt/cryft/releases/<C>/Tools/Paladin/install-runtime.py --commit <C> \\
        --factory <PenteFactory proxy> --from-block <deploy block> --seal-cert /root/cryft-bootstrap/backup-recipient.crt
"""
import argparse, hashlib, json, os, pwd, re, secrets, subprocess, time
from pathlib import Path

DATA_ROOT = Path('/var/lib/cryft'); HOME = DATA_ROOT / 'paladin'; CONFIG = Path('/etc/cryft/paladin')
PALADIN = 'ghcr.io/lfdt-paladin/paladin@sha256:b7d9b4ab98c5330a2515e8c2c97d0b5f4460278ded824bee0a10ad6008984357'
POSTGRES = 'docker.io/library/postgres@sha256:67f41722b7a8cbdb868a44a4995c846eddfdc2973bccb291ce937dce88ad5675'
NEBULA_IP = '100.111.32.201'


def run(*args, **kw): return subprocess.run(list(map(str, args)), check=True, **kw)
def write(path, text, gid=0, mode=0o644):
    assert not path.is_symlink(); path.write_text(text); os.chown(path, 0, gid); os.chmod(path, mode)
def quote(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
def sha256(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def seal(plain, cert, sealed):
    """Seal once to the backup recipient; refuse to overwrite an existing sealed copy."""
    if sealed.exists():
        return
    temp = sealed.with_name('.' + sealed.name + '.part')
    run('openssl', 'cms', '-encrypt', '-binary', '-aes-256-gcm', '-in', plain, '-outform', 'DER', '-out', temp,
        '-recip', cert, '-keyopt', 'rsa_padding_mode:oaep', '-keyopt', 'rsa_oaep_md:sha256')
    os.chmod(temp, 0o600); os.replace(temp, sealed)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--commit', required=True); p.add_argument('--factory', required=True)
    p.add_argument('--from-block', required=True, type=int); p.add_argument('--seal-cert')
    a = p.parse_args()
    assert os.geteuid() == 0 and re.fullmatch('[0-9a-f]{40}', a.commit) and re.fullmatch('0x[0-9a-fA-F]{40}', a.factory)
    release = Path('/opt/cryft/releases') / a.commit
    assert subprocess.check_output(['git', '-C', str(release), 'rev-parse', 'HEAD'], text=True).strip() == a.commit
    assert not subprocess.check_output(['git', '-C', str(release), 'status', '--porcelain'], text=True).strip()
    assert Path(__file__).resolve() == (release / 'Tools/Paladin/install-runtime.py').resolve()
    assert NEBULA_IP in subprocess.check_output(['ip', '-j', 'address'], text=True)
    assert subprocess.run(['findmnt', '-n', str(DATA_ROOT)], capture_output=True).returncode == 0, \
        'Mount the data volume at /var/lib/cryft first (install-besu.py --data-device)'
    env = dict(os.environ, DEBIAN_FRONTEND='noninteractive')
    if not Path('/usr/bin/podman').exists():
        run('apt-get', 'update', env=env)
        run('apt-get', 'install', '-y', '--no-install-recommends', 'podman', 'uidmap', 'slirp4netns', 'fuse-overlayfs',
            'dbus-user-session', env=env)
    try: user = pwd.getpwnam('cryft-paladin')
    except KeyError:
        run('useradd', '--user-group', '--create-home', '--home-dir', HOME, '--shell', '/usr/sbin/nologin', 'cryft-paladin')
        user = pwd.getpwnam('cryft-paladin')
    assert user.pw_dir == str(HOME) and user.pw_shell == '/usr/sbin/nologin'
    run('loginctl', 'enable-linger', user.pw_name); run('systemctl', 'start', f'user@{user.pw_uid}.service')
    run('install', '-d', '-o', 'root', '-g', user.pw_name, '-m', '0750', CONFIG)
    prefix = ['runuser', '-u', user.pw_name, '--', 'env', f'HOME={HOME}', f'XDG_RUNTIME_DIR=/run/user/{user.pw_uid}',
              '/usr/bin/podman', '--cgroup-manager=cgroupfs']
    def pod(*args, **kw): return run(*prefix, *args, **kw)
    for image in (POSTGRES, PALADIN): pod('pull', image)

    secret_path = CONFIG / 'secrets.json'
    if secret_path.exists(): private = json.loads(secret_path.read_text())
    else:
        private = {key: secrets.token_hex(32) for key in ('postgres', 'database', 'seed')}
        write(secret_path, json.dumps(private) + '\n', 0, 0o600)
    for key in private: assert re.fullmatch('[0-9a-f]{64}', private[key])
    sealed = None
    if a.seal_cert:
        cert = CONFIG / 'backup-recipient.crt'
        write(cert, Path(a.seal_cert).read_text(), 0, 0o644)
        seal(secret_path, cert, CONFIG / 'secrets.json.cms')
        sealed = {'file': str(CONFIG / 'secrets.json.cms'), 'sha256': sha256(CONFIG / 'secrets.json.cms'),
                  'recipient_cert_sha256': sha256(cert), 'plaintext_sha256': sha256(secret_path)}
    write(CONFIG / 'postgres.env', 'POSTGRES_PASSWORD=' + private['postgres'] + '\nPGDATA=/var/lib/postgresql/data\n', user.pw_gid, 0o640)
    write(CONFIG / 'database-password', private['database'] + '\n', user.pw_gid, 0o640)
    write(CONFIG / 'seed.hex', private['seed'] + '\n', user.pw_gid, 0o640)
    pg = HOME / 'postgres'
    if not pg.exists():
        run('install', '-d', '-o', user.pw_name, '-g', user.pw_name, '-m', '0700', pg); pod('unshare', 'chown', '999:999', pg)

    def service(name, args, memory, cpu, after):
        command = ['/usr/bin/podman', '--cgroup-manager=cgroupfs', 'run', '--rm', '--replace', '--name', name, '--cgroups=disabled',
                   '--cap-drop=ALL', '--security-opt=no-new-privileges', '--log-driver=journald', '--pids-limit=2048'] + args
        content = f'''[Unit]
Description=Cryft {name}
Wants=network-online.target
After=network-online.target dnclient.service {after}
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Type=exec
User={user.pw_name}
Group={user.pw_name}
WorkingDirectory={HOME}
Environment=HOME={HOME}
Environment=XDG_RUNTIME_DIR=/run/user/{user.pw_uid}
ExecStart={' '.join(map(quote, command))}
ExecStop=/usr/bin/podman --cgroup-manager=cgroupfs stop --time=90 {name}
Restart=on-failure
RestartSec=15
TimeoutStartSec=300
TimeoutStopSec=120
MemoryMax={memory}
CPUQuota={cpu}%
TasksMax=2048
LimitNOFILE=65536
Delegate=yes
UMask=0077
[Install]
WantedBy=multi-user.target
'''
        path = Path('/etc/systemd/system') / (name + '.service'); write(path, content); run('systemd-analyze', 'verify', path)

    # Sized to share a 2 vCPU / 16 GB host with the companion Besu (heap 6 GiB, MemoryMax 12 GiB).
    service('cryft-paladin-db', ['--network=slirp4netns', '--user=999:999', '--publish=127.0.0.1:5433:5432', '--env-file', str(CONFIG / 'postgres.env'),
            '--volume', f'{pg}:/var/lib/postgresql/data', '--shm-size=256m', POSTGRES, 'postgres', '-c', 'shared_buffers=256MB',
            '-c', 'max_connections=60', '-c', 'work_mem=8MB'], '1536M', 50, '')
    run('systemctl', 'daemon-reload'); run('systemctl', 'enable', 'cryft-paladin-db'); run('systemctl', 'reset-failed', 'cryft-paladin-db')
    run('systemctl', 'restart', 'cryft-paladin-db')
    for _ in range(90):
        if subprocess.run(prefix + ['exec', 'cryft-paladin-db', 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True).returncode == 0: break
        time.sleep(1)
    else: raise RuntimeError('Database not ready')
    def sql(query): return pod('exec', '-i', 'cryft-paladin-db', 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', input=query, text=True, capture_output=True).stdout.strip()
    if sql("SELECT 1 FROM pg_roles WHERE rolname='paladin';") != '1':
        sql("CREATE ROLE paladin LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '" + private['database'] + "';")
    if sql("SELECT 1 FROM pg_database WHERE datname='paladin';") != '1': sql('CREATE DATABASE paladin OWNER paladin;')
    assert sql("SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname='paladin';") == 'f'

    cfg = {'nodeName': 'paladin01', 'log': {'level': 'warn'},
           'db': {'type': 'postgres', 'postgres': {'dsn': 'postgres://paladin:{{.Password}}@127.0.0.1:5433/paladin?sslmode=disable',
                  'dsnParams': {'Password': {'file': '/config/database-password'}}, 'autoMigrate': True,
                  'migrationsDir': '/app/db/migrations/postgres', 'maxOpenConns': 40, 'maxIdleConns': 10, 'debugQueries': False}},
           'rpcServer': {'http': {'address': '127.0.0.1', 'port': 8548}, 'ws': {'address': '127.0.0.1', 'port': 8549}},
           'blockIndexer': {'fromBlock': a.from_block},
           'blockchain': {'http': {'url': 'http://127.0.0.1:8552'}, 'ws': {'url': 'ws://127.0.0.1:8552/ws'}},
           'wallets': [{'name': 'node-wallet', 'keySelector': '.*', 'signer': {'keyDerivation': {'type': 'bip32'},
                        'keyStore': {'type': 'static', 'static': {'keys': {'seed': {'encoding': 'hex', 'filename': '/config/seed.hex', 'trim': True}}}}}}],
           'domains': {'pente': {'registryAddress': a.factory, 'allowSigning': True, 'defaultGasLimit': 12000000,
                                 'fixedSigningIdentity': 'settlement@paladin01',
                                 'plugin': {'type': 'jar', 'library': '/app/domains/pente.jar', 'class': 'io.kaleido.paladin.pente.domain.PenteDomainFactory'},
                                 'config': {}}},
           'publicTxManager': {'gasLimit': {'gasEstimateFactor': 2.0},
                               'gasPrice': {'fixedGasPrice': {'maxFeePerGas': '1000000000', 'maxPriorityFeePerGas': '1000000000'},
                                            'maxFeePerGasCap': '2000000000', 'maxPriorityFeePerGasCap': '2000000000'},
                               'orchestrator': {'maxInFlight': 20}},
           'metricsServer': {'enabled': True, 'address': '127.0.0.1', 'port': 6100}}
    target = CONFIG / 'paladin.json'
    if target.exists():
        before = json.loads(target.read_text())
        assert before['domains']['pente']['registryAddress'].lower() == a.factory.lower(), 'A different PenteFactory is configured'
        cfg['blockIndexer'] = before['blockIndexer']
    write(target, json.dumps(cfg, indent=2) + '\n', user.pw_gid, 0o640)

    run('python3', release / 'Tools/Deployment/install-nginx.py', '--commit', a.commit, '--host', 'Paladin-01')
    proxy = pwd.getpwnam('cryft-proxy')
    write(Path('/etc/cryft/nginx/conf.d/paladin.conf'), (release / 'Tools/Paladin/nginx.conf').read_text(), proxy.pw_gid, 0o640)
    run('runuser', '-u', 'cryft-proxy', '--', '/usr/sbin/nginx', '-t', '-c', '/etc/cryft/nginx/nginx.conf')
    run('systemctl', 'reload', 'cryft-nginx')

    service('cryft-paladin', ['--network=host', '--userns=keep-id:uid=1001,gid=1001', '--user=1001:1001', '--read-only',
            '--tmpfs', '/tmp:rw,size=256m,mode=1777', '--tmpfs', '/app/jna:rw,exec,size=256m,mode=1777',
            '--volume', f'{CONFIG}:/config:ro', '--env', 'JAVA_TOOL_OPTIONS=-Xms256m -Xmx1536m', PALADIN, '/config/paladin.json', 'engine'],
            '3G', 150, 'cryft-paladin-db.service cryft-besu.service cryft-nginx.service')
    run('systemctl', 'daemon-reload'); run('systemctl', 'enable', 'cryft-paladin'); run('systemctl', 'reset-failed', 'cryft-paladin')
    run('systemctl', 'restart', 'cryft-paladin')
    receipt = {'source_commit': a.commit, 'factory': a.factory, 'from_block': cfg['blockIndexer']['fromBlock'],
               'paladin_image': PALADIN, 'postgres_image': POSTGRES, 'runtime_user': user.pw_name, 'data': str(HOME),
               'rpc': f'http://{NEBULA_IP}:8550 (Backend-01 only)', 'rpc_raw': '127.0.0.1:8548', 'database': '127.0.0.1:5433',
               'public_listeners': False, 'sealed_secrets': sealed}
    write(CONFIG / 'installation.json', json.dumps(receipt, indent=2) + '\n', user.pw_gid, 0o640); print(json.dumps(receipt))


if __name__ == '__main__': main()
