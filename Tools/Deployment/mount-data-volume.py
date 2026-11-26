"""Put a host's service data on its DigitalOcean volume, before the services are installed.

Mounts the droplet's pre-formatted ext4 volume at /var/lib/cryft by UUID (nofail), taking over DigitalOcean's own
auto-mount only while the volume is empty, then bind-mounts /var/lib/cryft/<name> onto each /var/lib/<name> given
with --bind. Every service keeps its usual path; its data lives on the volume (snapshots, re-attach on rebuild).
Never formats anything. Refuses a bind target that already holds data: run it before the service is installed.
Idempotent: a second run changes nothing.

    python3 /opt/cryft/releases/<C>/Tools/Deployment/mount-data-volume.py --device /dev/sda \\
        --bind postgresql cryft-router cryft-ipfs cryft-ipfs-public cryft-kota cryft-backup
"""
import argparse, json, os, re, subprocess
from pathlib import Path

DATA_ROOT = Path('/var/lib/cryft')
FSTAB = Path('/etc/fstab')


def run(*args): return subprocess.run(list(map(str, args)), check=True)
def out(*args): return subprocess.run(list(map(str, args)), capture_output=True, text=True).stdout.strip()


def mount_volume(device):
    device = Path(device)
    assert device.is_block_device(), f'{device} is not a block device'
    probe = dict(line.split('=', 1) for line in out('blkid', '-o', 'export', device).split())
    assert probe.get('TYPE') == 'ext4', f'{device} is not ext4; formatting is a separate, approved step'
    uuid = probe['UUID']
    assert re.fullmatch(r'[0-9a-f-]{36}', uuid)
    if uuid in out('findmnt', '-n', '-o', 'UUID', DATA_ROOT):
        return uuid
    assert not out('findmnt', '-n', DATA_ROOT), f'{DATA_ROOT} is already a mount of something else'
    elsewhere = out('findmnt', '-n', '-o', 'TARGET', '-S', f'UUID={uuid}').split()
    if elsewhere:
        # DigitalOcean's "Mount DO Volume" unit at /mnt/<name>: take it over only while the volume is empty.
        assert len(elsewhere) == 1 and elsewhere[0].startswith('/mnt/'), f'{device} is mounted at {elsewhere}'
        target = Path(elsewhere[0])
        assert {p.name for p in target.iterdir()} <= {'lost+found'}, f'{target} already holds data'
        unit = out('systemd-escape', '--path', '--suffix=mount', target)
        unit_file = Path('/etc/systemd/system') / unit
        assert unit_file.is_file() and 'DO Volume' in unit_file.read_text(), f'{target} is not a DO volume mount unit'
        run('systemctl', 'disable', '--now', unit)
        assert not out('findmnt', '-n', '-S', f'UUID={uuid}')
    DATA_ROOT.mkdir(mode=0o755, exist_ok=True)
    assert not any(DATA_ROOT.iterdir()), f'{DATA_ROOT} already holds data'
    if f'UUID={uuid} ' not in FSTAB.read_text():
        with FSTAB.open('a') as stream:
            stream.write(f'UUID={uuid} {DATA_ROOT} ext4 defaults,nofail,noatime,discard 0 2\n')
    run('systemctl', 'daemon-reload')
    run('mount', DATA_ROOT)
    assert uuid in out('findmnt', '-n', '-o', 'UUID', DATA_ROOT)
    return uuid


def bind(name):
    assert re.fullmatch(r'[a-z0-9][a-z0-9_-]{1,40}', name), name
    source, target = DATA_ROOT / name, Path('/var/lib') / name
    if out('findmnt', '-n', '-o', 'TARGET', '--mountpoint', target) == str(target):
        return 'already bound'
    source.mkdir(mode=0o755, exist_ok=True)
    target.mkdir(mode=0o755, exist_ok=True)
    assert not any(target.iterdir()), f'{target} already holds data: move it onto the volume by hand first'
    line = f'{source} {target} none bind,nofail,x-systemd.requires-mounts-for={DATA_ROOT} 0 0\n'
    if f'{source} {target} ' not in FSTAB.read_text():
        with FSTAB.open('a') as stream:
            stream.write(line)
    run('systemctl', 'daemon-reload')
    run('mount', target)
    return 'bound'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--device', required=True)
    p.add_argument('--bind', nargs='*', default=[])
    a = p.parse_args()
    assert os.geteuid() == 0
    uuid = mount_volume(a.device)
    binds = {name: bind(name) for name in a.bind}
    print(json.dumps({'volume_uuid': uuid, 'mount': str(DATA_ROOT), 'binds': binds,
                      'free': out('df', '-h', '--output=avail', DATA_ROOT).split()[-1]}))


if __name__ == '__main__':
    main()
