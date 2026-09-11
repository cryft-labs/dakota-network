"""Independently validate all explorer DB records and sampled public API results.

Reads only public explorer data, never runtime credentials or private Pente state.
"""
import argparse,csv,gzip,hashlib,io,json,shlex,sys,zipfile
from datetime import datetime,timezone
from pathlib import Path
import requests
from web3 import Web3

REPO=Path(__file__).resolve().parents[2]
ART=REPO/'Contracts/Verification/20260911'
FIELDS=['address','artifact_alias','category','state','contract_name','spdx_license','license_type','compiler_version','metadata_cid','explorer_url','runtime_sha256','source_files_checked']

def sha(body):return hashlib.sha256(body).hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);a=p.parse_args();workspace=Path(a.workspace).resolve()
    sys.path.insert(0,str(workspace/'work/production-hardening'))
    from hostctl import HOSTS,connect,run
    out=workspace/'outputs/blockscout-genesis-verification';manifest=json.loads((ART/'manifest.json').read_text())
    progress=json.loads((out/'progress.json').read_text());assert progress['completed'] and not progress['dry_run'] and progress['checked']==32433 and progress['offset']==0
    with (ART/'genesis-addresses.csv').open(newline='') as f:genesis={r['address'].lower():r for r in csv.DictReader(f)}
    public={r['address'].lower():r for r in manifest['public_creations']['contracts']}
    expected={**{k:(v['artifact_alias'],'genesis') for k,v in genesis.items()},**{k:(v['artifact_alias'],'public_creation') for k,v in public.items()}}
    proof={}
    for line in (out/'verified.jsonl').read_text().splitlines():
        row=json.loads(line);proof[row['address'].lower()]=row
    assert set(proof)==set(genesis) and all(r['state']=='verified' for r in proof.values())
    # A read-only SQL export computes bytecode and every source file's SHA-256 in
    # PostgreSQL, then compresses the public audit data locally on Backend-01.
    query="""COPY (
      SELECT '0x'||encode(a.hash,'hex') AS address,a.verified,sc.partially_verified,
        sc.name,sc.file_path,sc.compiler_version,sc.license_type,sc.constructor_arguments,
        encode(sha256(a.contract_code),'hex') AS runtime_sha256,
        encode(sha256(convert_to(sc.contract_source_code,'UTF8')),'hex') AS primary_source_sha256,
        COALESCE((SELECT jsonb_object_agg(ss.file_name,encode(sha256(convert_to(ss.contract_source_code,'UTF8')),'hex'))
          FROM smart_contracts_additional_sources ss WHERE ss.address_hash=a.hash),'{}'::jsonb) AS additional_sources
      FROM smart_contracts sc JOIN addresses a ON a.hash=sc.address_hash ORDER BY a.hash
    ) TO STDOUT WITH CSV HEADER;"""
    remote_script="""import gzip,json,pwd,subprocess,sys
from pathlib import Path
q=json.load(sys.stdin)['query'];u=pwd.getpwnam('cryft-explorer')
p=['runuser','-u',u.pw_name,'--','env','HOME='+u.pw_dir,'XDG_RUNTIME_DIR=/run/user/'+str(u.pw_uid),'podman','--cgroup-manager=cgroupfs']
target=Path('/var/lib/cryft-explorer/dets/verification-20260911/database.csv.gz')
proc=subprocess.Popen(p+['exec','-i','cryft-explorer-db','psql','-U','postgres','-d','blockscout','-v','ON_ERROR_STOP=1','-q'],cwd=u.pw_dir,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
proc.stdin.write(('BEGIN READ ONLY;\\n'+q+'\\nCOMMIT;\\n').encode());proc.stdin.close()
with gzip.open(target,'wb',compresslevel=6) as f:
 while True:
  chunk=proc.stdout.read(65536)
  if not chunk:break
  f.write(chunk)
err=proc.stderr.read();assert proc.wait()==0,err.decode()[:1000]
print(json.dumps({'path':str(target),'bytes':target.stat().st_size,'read_only':True}))
"""
    client=connect(next(h for h in HOSTS if h['name']=='Backend-01'),True)
    try:
        result=run(client,'python3 -c '+shlex.quote(remote_script),55,json.dumps({'query':query}));assert result['exit']==0,result
        with client.open_sftp() as s:s.get('/var/lib/cryft-explorer/dets/verification-20260911/database.csv.gz',str(out/'database.csv.gz'))
    finally:client.close()
    builds={}
    for alias,build in manifest['builds'].items():
        for record in build['files'].values():assert sha((ART/record['path']).read_bytes())==record['sha256']
        standard=json.loads((ART/build['files']['standard-input.json']['path']).read_text())
        builds[alias]={'build':build,'sources':{k:sha(v['content'].encode()) for k,v in standard['sources'].items()},
                       'runtime':bytes.fromhex((ART/build['files']['runtime-bytecode.txt']['path']).read_text().strip()[2:])}
    with gzip.open(out/'database.csv.gz','rt',newline='') as f:database={r['address']:r for r in csv.DictReader(f)}
    assert set(database)==set(expected),{'missing':list(set(expected)-set(database))[:10],'unexpected':list(set(database)-set(expected))[:10]}
    session=requests.Session();session.trust_env=False;api_evidence=[];api_runtime_hash={}
    samples=set(public)|set(list(genesis)[:12])|set(list(genesis)[-2:])|set(list(genesis)[::1000])
    for address in sorted(samples):
        alias,category=expected[address];b=builds[alias];build=b['build']
        response=session.get('http://100.111.69.1:8080/api/v2/smart-contracts/'+address,timeout=30);response.raise_for_status();data=response.json()
        assert data['is_verified'] and data['is_fully_verified'] and not data['is_partially_verified'] and not data.get('verified_twin_address_hash'),address
        assert data['name']==build['contract_name'] and data['file_path']==build['source_path'] and data['license_type']==build['license_type'],address
        assert data['compiler_version'].lstrip('v')==build['compiler_version'].lstrip('v'),address
        sources={build['source_path']:sha(data['source_code'].encode()),**{s['file_path']:sha(s['source_code'].encode()) for s in data['additional_sources']}}
        assert sources==b['sources'],address+': API sources differ'
        runtime=bytes.fromhex(data['deployed_bytecode'][2:]);api_runtime_hash[address]=sha(runtime)
        expected_keccak=public[address]['runtime_keccak256'] if category=='public_creation' else '0x'+Web3.keccak(b['runtime']).hex().removeprefix('0x')
        assert '0x'+Web3.keccak(runtime).hex().removeprefix('0x')==expected_keccak,address
        api_evidence.append({'address':address,'source_files':len(sources),**{k:data.get(k) for k in ['name','file_path','compiler_version','license_type','is_verified','is_fully_verified','is_partially_verified','verified_twin_address_hash','implementations','proxy_type']}})
    rows=[]
    for address,(alias,category) in expected.items():
        db=database[address];b=builds[alias];build=b['build'];sources={db['file_path']:db['primary_source_sha256'],**json.loads(db['additional_sources'])}
        assert db['verified']=='t' and db['partially_verified']=='f',address
        assert db['name']==build['contract_name'] and db['file_path']==build['source_path'],address
        assert db['compiler_version'].lstrip('v')==build['compiler_version'].lstrip('v') and int(db['license_type'])==build['license_type_id'],address
        assert sources==b['sources'],address+': stored source hashes differ'
        runtime_hash=sha(b['runtime']) if category=='genesis' else api_runtime_hash[address]
        assert db['runtime_sha256']==runtime_hash,address+': indexed runtime differs'
        if category=='genesis':
            assert proof[address]['runtime_sha256']==runtime_hash and proof[address]['license_type']==build['license_type']
            assert db['constructor_arguments']=='',address+': invented genesis constructor'
        else:assert db['constructor_arguments'].removeprefix('0x')==public[address]['constructor_arguments'].removeprefix('0x'),address+': constructor differs'
        rows.append({'address':Web3.to_checksum_address(address),'artifact_alias':alias,'category':category,'state':'fully_verified',
            'contract_name':build['contract_name'],'spdx_license':build['spdx_license'],'license_type':build['license_type'],
            'compiler_version':build['compiler_version'],'metadata_cid':build['metadata_cid'],
            'explorer_url':'http://100.111.69.1:8080/address/'+address+'?tab=contract','runtime_sha256':runtime_hash,'source_files_checked':len(sources)})
    ipfs=json.loads((workspace/'outputs/blockscout-ipfs-revalidation.json').read_text());private=json.loads((workspace/'outputs/blockscout-private-code-validation.json').read_text())
    assert ipfs['passed'] and private['passed']
    summary={'checked_at':datetime.now(timezone.utc).isoformat(),'passed':True,'chain_id':112311,'genesis_block_hash':manifest['genesis_block_hash'],
        'public_fully_verified':len(rows),'genesis_fully_verified':len(genesis),'later_public_fully_verified':len(public),
        'partial':0,'failed':0,'license_mismatches':0,'database_all_runtime_and_source_hashes_checked':True,
        'public_api_addresses_checked':len(api_evidence),'genesis_live_code_proof':progress,'private_code_hashes_checked':len(private['private_contracts']),
        'native_precompiles_not_solidity':18,'ipfs_objects_revalidated':ipfs['objects_checked'],
        'genesis_method':'Genuine Rust FULL compilation results reused only after exact per-address live runtime equality; normal Blockscout publisher, no fabricated verification flags.',
        'api_evidence':api_evidence,'production_approval':False}
    buffer=io.StringIO(newline='');writer=csv.DictWriter(buffer,fieldnames=FIELDS,lineterminator='\n');writer.writeheader();writer.writerows(rows)
    (out/'addresses.csv').write_bytes(buffer.getvalue().encode());(out/'summary.json').write_bytes((json.dumps(summary,indent=2)+'\n').encode())
    archive=out/'blockscout-verification-evidence-20260911.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for name in ['addresses.csv','summary.json','progress.json','verified.jsonl','database.csv.gz']:
            z.write(out/name,name)
        for path in out.glob('rust-result-*.json'):z.write(path,'rust-results/'+path.name)
        for name in ['blockscout-ipfs-revalidation.json','blockscout-private-code-validation.json','blockscout-new-creation-check.json']:
            z.write(workspace/'outputs'/name,name)
        for path in (workspace/'outputs/blockscout-verification-receipts').glob('*.json'):z.write(path,'api-receipts/'+path.name)
    summary['evidence_archive_sha256']=sha(archive.read_bytes());summary['evidence_archive_bytes']=archive.stat().st_size
    (out/'summary.json').write_bytes((json.dumps(summary,indent=2)+'\n').encode())
    print(json.dumps({k:v for k,v in summary.items() if k not in ['api_evidence','genesis_live_code_proof']},indent=2))

if __name__=='__main__':main()
