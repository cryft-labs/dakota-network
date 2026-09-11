"""License-explicit Blockscout Standard JSON upload, dry-run by default.

Uploads only inventoried PUBLIC contracts. No signing keys or chain mutations.
"""
import argparse,csv,hashlib,json,time
from pathlib import Path
import requests
from web3 import Web3

ROOT=Path(__file__).resolve().parents[2]/'Contracts/Verification/20260911'

def request_plan(address):
    manifest=json.loads((ROOT/'manifest.json').read_text());assert manifest['coverage_passed']
    address=Web3.to_checksum_address(address)
    public=next((r for r in manifest['public_creations']['contracts'] if r['address'].lower()==address.lower()),None)
    if public:
        alias=public['artifact_alias'];arguments=public['constructor_arguments'];expected_hash=public['runtime_keccak256']
    else:
        with (ROOT/'genesis-addresses.csv').open(newline='') as f:
            record=next((r for r in csv.DictReader(f) if r['address'].lower()==address.lower()),None)
        if not record:raise ValueError('Address is not an audited public Solidity contract; private state/precompiles/designators are excluded')
        alias=record['artifact_alias'];arguments='';expected_hash=None
    build=manifest['builds'][alias];paths={name:ROOT/record['path'] for name,record in build['files'].items()}
    for name,path in paths.items():assert hashlib.sha256(path.read_bytes()).hexdigest()==build['files'][name]['sha256']
    metadata=json.loads(paths['metadata.json'].read_text());standard=json.loads(paths['standard-input.json'].read_text())
    unit=build['source_path'];spdx=metadata['sources'][unit]['license'];allowed={'MIT':('mit',3),'Apache-2.0':('apache_2_0',12)}
    if spdx not in allowed:raise ValueError('Unsupported license expression requires review; never default to MIT')
    license_type,license_id=allowed[spdx]
    assert (license_type,license_id)==(build['license_type'],build['license_type_id'])
    assert Web3.keccak(text=standard['sources'][unit]['content']).hex().removeprefix('0x')==metadata['sources'][unit]['keccak256'].removeprefix('0x')
    plan={'address':address,'artifact_alias':alias,'compiler_version':build['compiler_version'],'contract_name':build['contract_name'],
          'source_path':unit,'license_type':license_type,'license_type_id':license_id,
          'autodetect_constructor_args':'false','constructor_args':arguments,
          'standard_input_file':str(paths['standard-input.json']),'genesis_runtime_only':public is None,
          'expected_runtime_keccak256':expected_hash or '0x'+Web3.keccak(hexstr=paths['runtime-bytecode.txt'].read_text().strip()).hex().removeprefix('0x')}
    return plan,build

def validate_verified_target(data,plan):
    assert data.get('license_type')==plan['license_type'],'Verified license mismatch: use a supported correction, never alter SPDX'
    assert data.get('name')==plan['contract_name'] and data.get('file_path')==plan['source_path'],'Wrong compilation target'
    assert (data.get('compiler_version') or '').lstrip('v')==plan['compiler_version'].lstrip('v'),'Wrong compiler'

def main():
    p=argparse.ArgumentParser();p.add_argument('--address',required=True);p.add_argument('--base-url',default='http://100.111.69.1:8080');p.add_argument('--rpc-url',default='http://100.111.69.1:8547/');p.add_argument('--execute',action='store_true');p.add_argument('--receipt-directory',default='blockscout-verification-receipts');a=p.parse_args()
    plan,build=request_plan(a.address);print(json.dumps(plan,indent=2),flush=True)
    if not a.execute:return
    session=requests.Session();session.trust_env=False
    config=session.get(a.base_url+'/api/v2/smart-contracts/verification/config',timeout=30);config.raise_for_status();config=config.json()
    assert config['license_types'][plan['license_type']]==plan['license_type_id']
    assert plan['compiler_version'] in config['solidity_compiler_versions'] and 'standard-input' in config['verification_options']
    w3=Web3(Web3.HTTPProvider(a.rpc_url,request_kwargs={'timeout':30}));assert w3.eth.chain_id==112311
    genesis=w3.provider.make_request('eth_getBlockByNumber',['0x0',False])
    assert genesis['result']['hash'].lower()=='0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8','Wrong genesis identity'
    actual='0x'+w3.keccak(w3.eth.get_code(plan['address'])).hex().removeprefix('0x');assert actual==plan['expected_runtime_keccak256'],'Live bytecode changed; reaudit'
    endpoint=a.base_url+'/api/v2/smart-contracts/'+plan['address']
    before=session.get(endpoint,timeout=30)
    if before.status_code==200 and before.json().get('is_verified'):
        data=before.json()
        validate_verified_target(data,plan)
        if not data.get('is_partially_verified'):
            print('Already fully verified with the expected target, compiler and license; no duplicate upload.');return
    receipt_dir=Path(a.receipt_directory);receipt_dir.mkdir(parents=True,exist_ok=True)
    receipt_file=receipt_dir/(plan['address'].lower()+'.json')
    if receipt_file.exists():
        old=json.loads(receipt_file.read_text());assert old.get('accepted') is not None,'Reconcile an uncertain prior submission before retrying'
        if old['accepted']:raise RuntimeError('A request is already accepted. Inspect its result; do not resubmit automatically')
    record={'plan':plan,'accepted':None,'state':'prepared'};receipt_file.write_text(json.dumps(record,indent=2)+'\n')
    data={k:plan[k] for k in ['compiler_version','contract_name','license_type','autodetect_constructor_args','constructor_args']}
    with Path(plan['standard_input_file']).open('rb') as f:
        response=session.post(endpoint+'/verification/via/standard-input',data=data,files={'files[0]':('standard-input.json',f,'application/json')},timeout=45)
    record.update({'accepted':response.ok,'http_status':response.status_code,'response':response.text[:2000],'state':'queued' if response.ok else 'rejected'})
    receipt_file.write_text(json.dumps(record,indent=2)+'\n');response.raise_for_status()
    for _ in range(40):
        result=session.get(endpoint,timeout=30)
        if result.status_code==200:
            verified=result.json()
            if verified.get('is_verified'):
                validate_verified_target(verified,plan)
                record.update({'state':'partial' if verified.get('is_partially_verified') else 'verified',
                               'verified_fields':{k:verified.get(k) for k in ['name','file_path','compiler_version','license_type','is_verified','is_partially_verified']}})
                receipt_file.write_text(json.dumps(record,indent=2)+'\n')
                assert not verified.get('is_partially_verified'),'Partial match requires investigation; not full acceptance'
                print('Verified target, compiler and license.',flush=True);return
        time.sleep(3)
    raise TimeoutError('Verification is queued or failed; retain the receipt and inspect worker logs before any retry')

if __name__=='__main__':main()
