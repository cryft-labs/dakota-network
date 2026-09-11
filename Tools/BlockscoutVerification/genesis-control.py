"""Operator controls for the committed genesis verification maintenance job."""
import argparse,csv,hashlib,json,shlex,sys,zipfile
from pathlib import Path
REPO=Path(__file__).resolve().parents[2]

def main():
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);p.add_argument('action',choices=['prepare','start','status','download']);p.add_argument('--limit',type=int,default=32433);p.add_argument('--offset',type=int,default=0);p.add_argument('--dry-run',action='store_true');a=p.parse_args()
    workspace=Path(a.workspace).resolve();sys.path.insert(0,str(workspace/'work/production-hardening'))
    from hostctl import HOSTS,connect,run,upload_committed,git
    head=git('rev-parse','HEAD').decode().strip()
    assert git('ls-remote','origin','refs/heads/review/compiler-standard-json').decode().split()[0]==head
    assert not git('diff','HEAD','--','Tools/BlockscoutVerification','Contracts/Verification').strip()
    assert 0<a.limit<=32433 and 0<=a.offset<32433
    client=connect(next(h for h in HOSTS if h['name']=='Backend-01'),True)
    out=workspace/'outputs/blockscout-genesis-verification';out.mkdir(exist_ok=True)
    def checked(command,timeout=50):
        result=run(client,command,timeout);assert result['exit']==0,result;return result
    try:
        if a.action=='prepare':
            root=REPO/'Contracts/Verification/20260911';manifest=json.loads((root/'manifest.json').read_text());assert manifest['coverage_passed']
            assert hashlib.sha256((root/'genesis-addresses.csv').read_bytes()).hexdigest()==manifest['genesis']['inventory_sha256']
            with (root/'genesis-addresses.csv').open(newline='') as f:rows=list(csv.DictReader(f))
            assert len(rows)==32433 and len({r['address'].lower() for r in rows})==32433
            info={'source_commit':head,'genesis_block_hash':manifest['genesis_block_hash'],'addresses':rows,'builds':{}}
            bundle=out/'bundle.zip'
            with zipfile.ZipFile(bundle,'w',compression=zipfile.ZIP_DEFLATED) as z:
                for alias in sorted({r['artifact_alias'] for r in rows}):
                    build=manifest['builds'][alias]
                    info['builds'][alias]={k:build[k] for k in ['contract_name','source_path','compiler_version','spdx_license','license_type','immutable_references']}
                    info['builds'][alias]['reference_address']=next(r['address'] for r in rows if r['artifact_alias']==alias)
                    # The proxy at c0DE was independently verified through the v2 API.
                    if alias=='TransparentUpgradeableProxy':info['builds'][alias]['reference_address']='0x000000000000000000000000000000000000c0DE'
                    info['builds'][alias]['file_sha256']={}
                    for filename,record in build['files'].items():
                        body=(root/record['path']).read_bytes();assert hashlib.sha256(body).hexdigest()==record['sha256']
                        z.writestr(record['path'],body);info['builds'][alias]['file_sha256'][filename]=record['sha256']
                z.writestr('genesis-input.json',json.dumps(info))
                script=REPO/'Tools/BlockscoutVerification/genesis-worker.exs'
                assert git('show','HEAD:Tools/BlockscoutVerification/genesis-worker.exs')==script.read_bytes()
                z.writestr('genesis-worker.exs',script.read_bytes())
            checked('install -d -m 0700 /root/cryft-bootstrap/blockscout-verification')
            with client.open_sftp() as s:s.put(str(bundle),'/root/cryft-bootstrap/blockscout-verification/bundle.zip')
            installer=upload_committed(client,'Tools/BlockscoutVerification/install-genesis-worker.py')
            print(json.dumps(checked('python3 '+shlex.quote(installer)+' --bundle-sha256 '+hashlib.sha256(bundle.read_bytes()).hexdigest(),55)))
        elif a.action=='start':
            text=f'DAKOTA_VERIFICATION_LIMIT={a.limit}\nDAKOTA_VERIFICATION_OFFSET={a.offset}\nDAKOTA_VERIFICATION_DRY_RUN={str(a.dry_run).lower()}\n'
            with client.open_sftp() as s:
                with s.open('/etc/cryft/explorer/genesis-verification.env','wb') as f:f.write(text.encode())
                s.chmod('/etc/cryft/explorer/genesis-verification.env',0o644)
            if a.limit==32433 and a.offset==0 and not a.dry_run:
                checked('systemctl enable cryft-explorer-genesis-verification.service')
            print(json.dumps(checked('systemctl start --no-block cryft-explorer-genesis-verification.service')))
        elif a.action=='status':
            print(json.dumps(checked("systemctl show cryft-explorer-genesis-verification.service -p ActiveState -p SubState -p ExecMainStatus; journalctl -u cryft-explorer-genesis-verification.service -n 8 --no-pager; cat /var/lib/cryft-explorer/dets/verification-20260911/progress.json 2>/dev/null || true")))
        else:
            with client.open_sftp() as s:
                remote='/var/lib/cryft-explorer/dets/verification-20260911'
                for name in s.listdir(remote):
                    if name in ['progress.json','verified.jsonl','dry-run.jsonl'] or name.startswith('rust-result-'):
                        s.get(remote+'/'+name,str(out/name))
            print('Downloaded public verification evidence only.')
    finally:client.close()

if __name__=='__main__':main()
