"""Verify the journaled public release using exact Standard JSON and SPDX license."""
import argparse,hashlib,json,time
from pathlib import Path
import requests
from web3 import Web3
from eth_abi import encode

REPO=Path(__file__).resolve().parents[2]
RELEASE=REPO/'Releases/TenantAllowances/1.0.0'
GENESIS='0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8'

def main():
    p=argparse.ArgumentParser();p.add_argument('--journal',required=True);p.add_argument('--execute',action='store_true');args=p.parse_args()
    journal_path=Path(args.journal);journal=json.loads(journal_path.read_text())
    session=requests.Session();session.trust_env=False
    w3=Web3(Web3.HTTPProvider('http://100.111.69.1:8547/',session=session,request_kwargs={'timeout':20},exception_retry_configuration=None))
    assert w3.eth.chain_id==112311
    assert w3.provider.make_request('eth_getBlockByNumber',['0x0',False])['result']['hash']==GENESIS
    base='http://100.111.69.1:8080'
    config=session.get(base+'/api/v2/smart-contracts/verification/config',timeout=20);config.raise_for_status();config=config.json()
    for name in ('GasSponsor','TenantAllowancePolicy'):
        deployed=journal['deployments'][name];path=next(RELEASE.rglob(name+'_artifact.json'));raw=path.read_bytes();art=json.loads(raw)
        assert hashlib.sha256(raw).hexdigest()==deployed['artifact_sha256']
        assert Web3.to_hex(Web3.keccak(w3.eth.get_code(deployed['address'])))==deployed['runtime_keccak256']
        metadata=json.loads(art['metadata']);source=art['fully_qualified_name'].rsplit(':',1)[0]
        assert metadata['sources'][source]['license']=='Apache-2.0'
        compiler='v'+metadata['compiler']['version'];assert compiler in config['solidity_compiler_versions']
        assert config['license_types']['apache_2_0']==12
        inputs=next(a['inputs'] for a in art['abi'] if a['type']=='constructor')
        constructor=encode([a['type'] for a in inputs],deployed['constructor_args']).hex()
        form={'compiler_version':compiler,'contract_name':name,'license_type':'apache_2_0','autodetect_constructor_args':'false','constructor_args':constructor}
        endpoint=base+'/api/v2/smart-contracts/'+deployed['address']
        receipt_file=journal_path.parent/('verification-'+name+'.json')
        def check():
            response=session.get(endpoint,timeout=20)
            if response.status_code!=200:return None
            value=response.json()
            if not value.get('is_verified'):return None
            assert not value.get('is_partially_verified'),'Partial match requires investigation'
            assert value['name']==name and value['file_path']==source
            assert value['compiler_version'].lstrip('v')==compiler.lstrip('v')
            assert value['license_type']=='apache_2_0'
            expected=art['standard_json_input']['sources'][source]['content']
            assert value['source_code']==expected,'Verified source differs'
            return {'address':deployed['address'],'verified':True,'name':name,'source_path':source,'compiler':compiler,'license':'Apache-2.0','runtime_keccak256':deployed['runtime_keccak256']}
        verified=check()
        if verified:
            receipt_file.write_text(json.dumps(verified,indent=2)+'\n',encoding='utf-8');print(json.dumps(verified),flush=True);continue
        if not args.execute:print(json.dumps({'address':deployed['address'],'planned':form}));continue
        if receipt_file.exists():
            prior=json.loads(receipt_file.read_text());assert prior.get('accepted') is True,'Reconcile the previous uncertain/rejected upload before retrying'
        else:
            receipt_file.write_text(json.dumps({'address':deployed['address'],'accepted':None,'state':'prepared'}),encoding='utf-8')
            standard=path.with_name(name+'_standard_input.json')
            assert hashlib.sha256(standard.read_bytes()).hexdigest()==art['standard_input_sha256']
            with standard.open('rb') as handle:
                response=session.post(endpoint+'/verification/via/standard-input',data=form,files={'files[0]':('standard-input.json',handle,'application/json')},timeout=40)
            receipt_file.write_text(json.dumps({'address':deployed['address'],'accepted':response.ok,'status':response.status_code,'response':response.text[:1000]}),encoding='utf-8')
            response.raise_for_status()
        for _ in range(30):
            verified=check()
            if verified:break
            time.sleep(3)
        assert verified,'Verification remains queued; inspect before another upload'
        receipt_file.write_text(json.dumps(verified,indent=2)+'\n',encoding='utf-8');print(json.dumps(verified),flush=True)

if __name__=='__main__':main()
