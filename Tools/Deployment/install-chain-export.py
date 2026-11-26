"""Install the nightly sealed chain export on Archive-01 (cryft-chain-export.timer, 03:30 UTC).

Run as root on Archive-01 from a staged release. Creates the system user cryft-chain-export, writes the backup
recipient certificate (public), installs cryft-chain-export.py, and enables a oneshot service + timer. Output:
/var/lib/cryft/chain-export/outgoing/*.cms on the data volume; the Mac pulls it (Tools/Deployment/pull-chain-export.py)
until offsite storage exists.

    python3 /opt/cryft/releases/<C>/Tools/Deployment/install-chain-export.py --commit <C> \\
        --recipient-cert /root/cryft-bootstrap/backup-recipient.crt [--run-now]
"""
import argparse, json, os, pwd, re, shutil, subprocess
from pathlib import Path

ROOT = Path('/var/lib/cryft/chain-export'); ETC = Path('/etc/cryft/chain-export')
LIB = Path('/usr/local/lib/cryft'); USER = 'cryft-chain-export'


def run(*args, **kw): return subprocess.run(list(map(str, args)), check=True, **kw)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--commit', required=True); p.add_argument('--recipient-cert', required=True); p.add_argument('--run-now', action='store_true')
    a = p.parse_args()
    assert os.geteuid() == 0 and re.fullmatch('[0-9a-f]{40}', a.commit)
    release = Path('/opt/cryft/releases') / a.commit
    assert subprocess.check_output(['git', '-C', str(release), 'rev-parse', 'HEAD'], text=True).strip() == a.commit
    assert '100.111.69.2' in subprocess.check_output(['ip', '-j', 'address'], text=True), 'Archive-01 only'
    assert subprocess.run(['findmnt', '-n', '/var/lib/cryft'], capture_output=True).returncode == 0, 'data volume not mounted'
    try: pwd.getpwnam(USER)
    except KeyError: run('useradd', '--system', '--user-group', '--no-create-home', '--home-dir', ROOT, '--shell', '/usr/sbin/nologin', USER)
    run('install', '-d', '-o', USER, '-g', USER, '-m', '0750', ROOT)
    run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', ETC, LIB)
    shutil.copyfile(a.recipient_cert, ETC / 'backup-recipient.crt'); os.chmod(ETC / 'backup-recipient.crt', 0o644)
    run('openssl', 'x509', '-in', ETC / 'backup-recipient.crt', '-noout', '-subject')
    shutil.copyfile(release / 'Tools/Deployment/cryft-chain-export.py', LIB / 'cryft-chain-export.py'); os.chmod(LIB / 'cryft-chain-export.py', 0o755)
    service = f'''[Unit]
Description=Cryft nightly sealed chain export (raw blocks, sealed to the backup recipient)
After=cryft-besu.service
[Service]
Type=oneshot
User={USER}
Group={USER}
ExecStart=/usr/bin/python3 {LIB}/cryft-chain-export.py
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths={ROOT}
TimeoutStartSec=3h
'''
    timer = '''[Unit]
Description=Nightly Cryft chain export
[Timer]
OnCalendar=*-*-* 03:30:00 UTC
RandomizedDelaySec=10min
Persistent=true
[Install]
WantedBy=timers.target
'''
    Path('/etc/systemd/system/cryft-chain-export.service').write_text(service)
    Path('/etc/systemd/system/cryft-chain-export.timer').write_text(timer)
    run('systemd-analyze', 'verify', '/etc/systemd/system/cryft-chain-export.service', '/etc/systemd/system/cryft-chain-export.timer')
    run('systemctl', 'daemon-reload'); run('systemctl', 'enable', '--now', 'cryft-chain-export.timer')
    if a.run_now:
        run('systemctl', 'start', 'cryft-chain-export.service')
    print(json.dumps({'source_commit': a.commit, 'timer': 'cryft-chain-export.timer 03:30 UTC', 'output': str(ROOT / 'outgoing'),
                      'user': USER, 'ran_now': a.run_now}))


if __name__ == '__main__':
    main()
