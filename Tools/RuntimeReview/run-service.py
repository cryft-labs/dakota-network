#!/usr/bin/env python3
"""Launch digest-pinned rootless test containers. All network listeners are loopback."""
import argparse, json, os, subprocess
from pathlib import Path

ROOT=Path('/var/lib/kota-private-test')
HERE=Path(__file__).resolve().parent
pins=json.loads((HERE/'runtime-lock.json').read_text())
parser=argparse.ArgumentParser()
parser.add_argument('service',choices=['pull','besu-1','besu-2','besu-3','besu-4','paladin'])
args=parser.parse_args()
assert os.geteuid()!=0, 'Run as the unprivileged test user'

if args.service=='pull':
    for name in ('besu','paladin'):
        subprocess.run(['podman','pull',pins[name]['image']],check=True)
    raise SystemExit(0)

name=args.service
is_besu=name.startswith('besu-')
index=int(name[-1]) if is_besu else 0
cmd=['podman','run','--rm','--name','kota-test-'+name,'--pull=never','--network=host',
     '--userns=keep-id:uid=1001,gid=1001','--user=1001:1001','--cap-drop=ALL',
     '--security-opt=no-new-privileges','--read-only',
     '--tmpfs','/tmp:rw,size=256m,mode=1777',
     '--volume',str(ROOT/'config')+':/config:ro',
     '--volume',str(ROOT/name)+':/data:rw']
if is_besu:
    cmd+=['--entrypoint','/opt/besu/bin/besu','--env','JAVA_OPTS=-Xms256m -Xmx1536m',pins['besu']['image'],
          '--genesis-file=/config/genesis.json','--data-path=/data','--node-private-key-file=/config/test-node-key-'+str(index),
          '--sync-mode=FULL','--data-storage-format=BONSAI','--p2p-host=127.0.0.1','--p2p-interface=127.0.0.1',
          '--p2p-port='+str(19300+index),'--discovery-enabled=false','--nat-method=NONE',
          '--rpc-http-enabled=true','--rpc-http-host=127.0.0.1','--rpc-http-port='+str(18545+(index-1)*10),
          '--rpc-http-api=ETH,NET,WEB3,QBFT,DEBUG','--rpc-ws-enabled=true','--rpc-ws-host=127.0.0.1',
          '--rpc-ws-port='+str(18546+(index-1)*10),'--rpc-ws-api=ETH,NET,WEB3,QBFT','--host-allowlist=localhost,127.0.0.1',
          '--min-gas-price=1000000000','--revert-reason-enabled=true','--logging=INFO']
else:
    cmd+=['--tmpfs','/app/jna:rw,exec,size=256m,uid=1001,gid=1001,mode=0700',
          '--env','JAVA_TOOL_OPTIONS=-Xms128m -Xmx2g',pins[name]['image'],'/config/paladin.json']
os.execvp(cmd[0],cmd)
