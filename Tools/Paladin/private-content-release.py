"""Publish and deploy the additive Pente content registry; existing NFTs unchanged.

Uses Paladin-managed operator identity, the existing privacy group/ProxyAdmin,
source-pinned artifacts and durable idempotency. No raw secrets in the journal.
"""
import argparse,hashlib,json,subprocess,sys,time
from pathlib import Path
import requests
from web3 import Web3

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'Tools/SolcCompiler'))
from ipfs_publish import KuboClient,metadata_cid
GROUP='0x8b4e5a042c782d363c72538b2a518679c8a6e942c1b9850e768d975af54eba79'
COMBO='0x7a3eacca11e28712ed6e0dfc464795b2a0c2a342'
ADMIN='0x4a35f4517ad2e26b332854b1eb94a67092968400'
CARD='0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410'

def main():
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);p.add_argument('--execute',action='store_true');args=p.parse_args()
    workspace=Path(args.workspace).resolve();out=workspace/'outputs/private-content-20260917';out.mkdir(exist_ok=True)
    def git(*a):return subprocess.check_output(['git','-c','safe.directory='+REPO.as_posix(),'-C',str(REPO),*a],text=True).strip()
    branch=git('branch','--show-current');commit=git('rev-parse','HEAD')
    assert branch.startswith('review/') and not git('status','--porcelain','--','Contracts','Tools/Paladin','Tests/Readiness')
    assert git('ls-remote','origin','refs/heads/'+branch).split()[0]==commit,'Push the reviewed source before deployment'
    path=out/'deployment.json';journal=json.loads(path.read_text()) if path.exists() else {'source_commit':commit,'transactions':{}}
    assert journal['source_commit']==commit,'Continue with the original reviewed source'
    def save():path.write_text(json.dumps(journal,indent=2)+'\n')
    http=requests.Session();http.trust_env=False
    def rpc(method,*params):
        response=http.post('http://100.111.32.201:8550/',json={'jsonrpc':'2.0','id':1,'method':method,'params':list(params)},timeout=30)
        response.raise_for_status();data=response.json()
        if data.get('error'):raise RuntimeError(method+' failed; inspect service health without logging private payloads')
        return data['result']
    def request(abi,inputs,code=None,to=None):
        value=dict(domain='pente',group=GROUP,**{'from':'operator@paladin01'},gas=12000000,function=abi,input=inputs,
                   publicTxOptions={'gas':2000000,'maxFeePerGas':'1000000000','maxPriorityFeePerGas':'1000000000'})
        if code:value['bytecode']=code
        if to:value['to']=to
        return value
    def transact(label,value):
        fingerprint=hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()
        row=journal['transactions'].setdefault(label,{'key':'private-content-20260917:'+label,'fingerprint':fingerprint})
        assert row['fingerprint']==fingerprint;save()
        if not row.get('id'):
            existing=rpc('ptx_getTransactionByIdempotencyKey',row['key'])
            row['id']=existing['id'] if existing else rpc('pgroup_sendTransaction',dict(value,idempotencyKey=row['key']));save()
        for _ in range(40):
            result=rpc('ptx_getTransactionReceiptFull',row['id'])
            if result:break
            time.sleep(1)
        else:raise RuntimeError('Still pending; resume the same journal')
        assert result.get('success'),'Deployment reverted; review before proceeding'
        row.update(address=result.get('domainReceipt',{}).get('receipt',{}).get('contractAddress'),transaction_hash=result['transactionHash'],success=True);save()
        return row['address']
    artifacts={name:json.loads((REPO/'Contracts/Verification/20260917'/name/'artifact.json').read_text()) for name in ('PrivateCardContentRegistry','ManagedApplicationProxy')}
    if not journal.get('publication'):
        api=KuboClient('http://127.0.0.1:15101');report={}
        def pin(body,cid=None):
            cid=cid or api.add(body,only_hash=True);assert api.add(body)==cid;api.confirm(cid,body);return cid
        for name,a in artifacts.items():
            metadata=a['metadata'].encode();cid=pin(metadata,metadata_cid(a['runtime_bytecode']))
            for unit,source in json.loads(metadata)['sources'].items():
                content=a['standard_json_input']['sources'][unit]['content'].encode()
                assert '0x'+Web3.keccak(content).hex().removeprefix('0x')==source['keccak256']
                expected=next(s.removeprefix('dweb:/ipfs/') for s in source['urls'] if s.startswith('dweb:/ipfs/'));pin(content,expected)
            unit=next(iter(json.loads(metadata)['settings']['compilationTarget']))
            report[name]={'metadata_cid':cid,'license':json.loads(metadata)['sources'][unit]['license'],
                'files':{f:pin((REPO/'Contracts/Verification/20260917'/name/f).read_bytes()) for f in ('standard-input.json','standard-output.json','artifact.json')}}
            print('Published and verified '+name,flush=True)
        journal['publication']=report;save()
    if not args.execute:return
    a=artifacts['PrivateCardContentRegistry'];shell=artifacts['ManagedApplicationProxy']
    constructor=lambda a:next((item for item in a['abi'] if item['type']=='constructor'),{'type':'constructor','inputs':[]})
    logic=transact('implementation',request(constructor(a),[],code=a['creation_bytecode']))
    init=Web3().eth.contract(abi=a['abi']).functions.initialize(Web3.to_checksum_address(COMBO),112311,Web3.to_checksum_address(CARD))._encode_transaction_data()
    proxy=transact('proxy',request(constructor(shell),[logic,ADMIN,init],code=shell['creation_bytecode']))
    hashes={}
    for name,address,artifact in [('implementation',logic,a),('proxy',proxy,shell)]:
        result=rpc('pgroup_call',request({'type':'constructor','inputs':[],'outputs':[{'name':'hash','type':'bytes32'}]},[],code='0x73'+address[2:]+'3f5f5260205ff3'))
        expected=Web3.to_hex(Web3.keccak(hexstr=artifact['runtime_bytecode']))
        assert result['hash'].lower()==expected.lower()
        hashes[name]={'address':address,'runtime_keccak256':expected}
    release={'deployed':True,'source_commit':commit,'chain_id':112311,'card':CARD,'group':GROUP,'authority':COMBO,'proxy_admin':ADMIN,
             **hashes,'metadata_cid':journal['publication']['PrivateCardContentRegistry']['metadata_cid']}
    journal['release']=release;save();print(json.dumps(release),flush=True)

if __name__=='__main__':main()
