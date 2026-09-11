"""Install persistent, rootless Blockscout services from a published release.

Secrets are generated once on Backend-01, never printed, and never committed.
Application images must already have been built by prepare-build.py.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import subprocess
import time

HOME = Path('/var/lib/cryft-explorer')
CONFIG = Path('/etc/cryft/explorer')
POSTGRES = 'docker.io/library/postgres@sha256:67f41722b7a8cbdb868a44a4995c846eddfdc2973bccb291ce937dce88ad5675'
REDIS = 'docker.io/library/redis@sha256:becdda6c7f4b3fb42e42fd7f120bbf5c54c4caaaf16f26da24e4563d2c1f0576'

def run(*args, **kw):
    return subprocess.run(args, check=True, **kw)

def write(path, content, gid=0, mode=0o644):
    assert not path.is_symlink()
    path.write_text(content)
    os.chown(path, 0, gid)
    os.chmod(path, mode)

def quote(value):
    # systemd ExecStart quoting (not shell quoting).
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--commit', required=True)
    p.add_argument('--host', choices=['Backend-01', 'Frontend-01'], required=True)
    a = p.parse_args()
    assert os.geteuid() == 0 and re.fullmatch('[0-9a-f]{40}', a.commit)
    release = Path('/opt/cryft/releases') / a.commit
    # The bootstrap helper is copied from the same reviewed release locally.
    spec = importlib.util.spec_from_file_location('prepare_build', Path(__file__).with_name('prepare-build.py'))
    prepare = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prepare)
    prepare.checkout('https://github.com/cryft-labs/dakota-network.git', a.commit, release)
    assert Path(__file__).read_bytes() == (release / 'Tools/Explorer/install-runtime.py').read_bytes()
    assert Path(__file__).with_name('prepare-build.py').read_bytes() == (release / 'Tools/Explorer/prepare-build.py').read_bytes()
    source = release / 'Tools/Explorer'
    user = pwd.getpwnam('cryft-explorer')
    assert user.pw_dir == str(HOME) and user.pw_shell == '/usr/sbin/nologin'
    run('loginctl', 'enable-linger', user.pw_name)
    run('systemctl', 'start', f'user@{user.pw_uid}.service')
    prefix = ['runuser', '-u', user.pw_name, '--', 'env', f'HOME={HOME}', f'XDG_RUNTIME_DIR=/run/user/{user.pw_uid}',
              '/usr/bin/podman', '--cgroup-manager=cgroupfs']
    def pod(*args, **kw):
        return run(*prefix, *map(str, args), **kw)
    run('install', '-d', '-o', 'root', '-g', user.pw_name, '-m', '0750', str(CONFIG))
    if subprocess.run(prefix + ['network', 'exists', 'cryft-explorer'], capture_output=True).returncode != 0:
        pod('network', 'create', 'cryft-explorer')
    build = json.loads((HOME / 'build-request.json').read_text())
    component = 'backend' if a.host == 'Backend-01' else 'frontend'
    assert build['component'] == component and build['host'] == a.host
    image = (HOME / (component + '-image.id')).read_text().strip()
    assert re.fullmatch('(sha256:)?[0-9a-f]{64}', image)
    pod('image', 'exists', image)
    write(CONFIG / (component + '.env'), (source / (component + '.env')).read_text(), user.pw_gid, 0o640)
    units = []
    def directory(name, uid, gid):
        path = HOME / name
        if not path.exists():
            run('install', '-d', '-o', user.pw_name, '-g', user.pw_name, '-m', '0700', str(path))
            pod('unshare', 'chown', f'{uid}:{gid}', path)
        assert not path.is_symlink()
        return path
    def service(name, args, memory, cpu, after='', oneshot=False):
        podman = ['/usr/bin/podman', '--cgroup-manager=cgroupfs']
        command = podman + ['run', '--rm', '--replace', '--name', name, '--cgroups=disabled',
                           '--network=cryft-explorer', '--cap-drop=ALL', '--security-opt=no-new-privileges',
                           '--log-driver=journald', '--pids-limit=2048'] + list(map(str, args))
        content = f'''[Unit]
Description=Dakota {name}
Wants=network-online.target
After=network-online.target dnclient.service {after}
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Type={'oneshot' if oneshot else 'exec'}
User={user.pw_name}
Group={user.pw_name}
WorkingDirectory={HOME}
Environment=HOME={HOME}
Environment=XDG_RUNTIME_DIR=/run/user/{user.pw_uid}
ExecStart={' '.join(map(quote, command))}
TimeoutStartSec={'900' if oneshot else '180'}
TimeoutStopSec=120
MemoryMax={memory}
CPUQuota={cpu}%
TasksMax=2048
LimitNOFILE=65536
Delegate=yes
UMask=0077
'''
        if not oneshot:
            content += 'ExecStop=' + ' '.join(map(quote, podman + ['stop', '--time=90', name])) + '\nRestart=on-failure\nRestartSec=15\n'
        content += '\n[Install]\nWantedBy=multi-user.target\n'
        path = Path('/etc/systemd/system') / (name + '.service')
        write(path, content)
        run('systemd-analyze', 'verify', str(path))
        units.append(name)
    if component == 'backend':
        secret_path = CONFIG / 'secrets.json'
        if secret_path.exists():
            private = json.loads(secret_path.read_text())
        else:
            private = {k: secrets.token_hex(48) for k in ['postgres_password', 'database_password', 'secret_key_base']}
            write(secret_path, json.dumps(private) + '\n', 0, 0o600)
        assert all(re.fullmatch('[0-9a-f]{96}', v) for v in private.values())
        write(CONFIG / 'postgres.env', 'POSTGRES_PASSWORD=' + private['postgres_password'] + '\nPGDATA=/var/lib/postgresql/data\n', user.pw_gid, 0o640)
        write(CONFIG / 'backend-private.env', 'DATABASE_URL=postgresql://blockscout:' + private['database_password'] + '@cryft-explorer-db:5432/blockscout\nSECRET_KEY_BASE=' + private['secret_key_base'] + '\n', user.pw_gid, 0o640)
        pod('pull', POSTGRES)
        pod('pull', REDIS)
        pg = directory('postgres', 999, 999)
        rd = directory('redis', 999, 999)
        dets = directory('dets', 10001, 10001)
        service('cryft-explorer-db', ['--user=999:999', '--env-file', CONFIG / 'postgres.env', '--volume', f'{pg}:/var/lib/postgresql/data', '--shm-size=512m', POSTGRES,
                                    'postgres', '-c', 'shared_buffers=1536MB', '-c', 'max_connections=100', '-c', 'effective_cache_size=4GB', '-c', 'work_mem=16MB'], '6G', 200)
        service('cryft-explorer-redis', ['--user=999:999', '--volume', f'{rd}:/data', REDIS, 'redis-server', '--appendonly', 'yes', '--maxmemory', '384mb', '--maxmemory-policy', 'noeviction'], '512M', 50)
        envargs = ['--env-file', CONFIG / 'backend.env', '--env-file', CONFIG / 'backend-private.env', '--volume', f'{dets}:/app/dets']
        service('cryft-explorer-migrate', envargs + [image, 'bin/blockscout', 'eval', 'Explorer.ReleaseTasks.migrate([])'], '4G', 200,
                'cryft-explorer-db.service', True)
        service('cryft-explorer-api', ['--publish=127.0.0.1:4000:4000'] + envargs + [image, 'bin/blockscout', 'start'], '8G', 300,
                'cryft-explorer-db.service cryft-explorer-redis.service')
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', '--now', 'cryft-explorer-db', 'cryft-explorer-redis')
        for attempt in range(60):
            probe = subprocess.run(prefix + ['exec', 'cryft-explorer-db', 'pg_isready', '-U', 'postgres'], capture_output=True)
            if probe.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('PostgreSQL did not become ready; inspect its journal')
        def sql(query):
            return pod('exec', '-i', 'cryft-explorer-db', 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', input=query, text=True, capture_output=True).stdout.strip()
        if sql("SELECT 1 FROM pg_roles WHERE rolname='blockscout';\n") != '1':
            sql("CREATE ROLE blockscout LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '" + private['database_password'] + "';\n")
        if sql("SELECT 1 FROM pg_database WHERE datname='blockscout';\n") != '1':
            sql('CREATE DATABASE blockscout OWNER blockscout;\n')
        assert sql("SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname='blockscout';\n") == 'f'
        run('systemctl', 'stop', 'cryft-explorer-api')
        run('systemctl', 'start', 'cryft-explorer-migrate')
        run('systemctl', 'enable', '--now', 'cryft-explorer-api')
    else:
        service('cryft-explorer-frontend', ['--publish=127.0.0.1:3001:3000', '--env-file', CONFIG / 'frontend.env', image], '4G', 200)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', 'cryft-explorer-frontend')
        run('systemctl', 'restart', 'cryft-explorer-frontend')
    proxy = pwd.getpwnam('cryft-proxy')
    target = Path('/etc/cryft/nginx/conf.d/explorer.conf')
    previous = target.read_bytes() if target.exists() else None
    write(target, (source / ('nginx-' + component + '.conf')).read_text(), proxy.pw_gid, 0o640)
    try:
        run('runuser', '-u', 'cryft-proxy', '--', '/usr/sbin/nginx', '-t', '-c', '/etc/cryft/nginx/nginx.conf')
        run('systemctl', 'reload', 'cryft-nginx')
    except Exception:
        if previous is None:
            target.unlink()
        else:
            target.write_bytes(previous)
        raise
    receipt = {'source_commit': a.commit, 'host': a.host, 'component': component, 'runtime_user': user.pw_name,
               'image_id': image, 'build': build, 'units': units, 'rootless': True, 'public_listener_configured': False,
               'ui_url': 'http://100.111.69.1:8080', 'backend_url': 'http://100.111.67.1:4002',
               'env_sha256': hashlib.sha256((CONFIG / (component + '.env')).read_bytes()).hexdigest()}
    write(CONFIG / 'installation.json', json.dumps(receipt, indent=2) + '\n', user.pw_gid, 0o640)
    print(json.dumps(receipt))

if __name__ == '__main__':
    main()
