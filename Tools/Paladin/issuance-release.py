"""Prepare and activate the reviewed development issuance implementation.

Uses the existing deployment wallet and remote Paladin identity. No new keys,
private receipts, redemption credentials or signing material are exported.
Root-owned gas permissions and policy activation remain explicit wallet actions.
"""
import argparse,hashlib,json,sys,time
from pathlib import Path
import requests
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'Tools/LiveGenesis'))
sys.path.insert(0,str(REPO/'Tools/SolcCompiler'))
from common import Deployment,unlock,git,serial,hx,ADMIN,DEPLOYER,ADDR,GENESIS_HASH,IMPL_SLOT
from ipfs_publish import KuboClient,metadata_cid

RELEASE=REPO/'Contracts/Verification/20260915'
CARD=Web3.to_checksum_address('0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410')
CARD_ADMIN=Web3.to_checksum_address('0x3571242a64Ac7166b36aAD18a1407853cCe52f71')
REGISTRY=Web3.to_checksum_address('0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340')
WORKER=Web3.to_checksum_address('0xe7850ecede5d6f7d0b2d2ccabfc2f29d2c345125')
GROUP='0x8b4e5a042c782d363c72538b2a518679c8a6e942c1b9850e768d975af54eba79'
COMBO='0x7a3eacca11e28712ed6e0dfc464795b2a0c2a342'
PRIVATE_ADMIN='0x4a35f4517ad2e26b332854b1eb94a67092968400'

class IssuanceRelease(Deployment):
    def __init__(self,workspace,execute=False):
        self.workspace=Path(workspace).resolve();self.execute=execute
        self.out=self.workspace/'outputs/issuance-release-20260915';self.out.mkdir(exist_ok=True)
        self.path=self.out/'transactions.json'
        self.journal=json.loads(self.path.read_text()) if self.path.exists() else {'transactions':{},'deployments':{},'checks':{},'private':{}}
        self.commit=git('rev-parse','HEAD');branch=git('branch','--show-current')
        self.artifacts={name:json.loads((RELEASE/name/'artifact.json').read_text()) for name in ('PrivateComboStorage','CryftGreetingCards','WorkerGasSponsor','TenantAllowancePolicy')}
        self.http=requests.Session();self.http.trust_env=False
        self.w3=Web3(Web3.HTTPProvider('http://100.111.69.1:8547/',session=self.http,request_kwargs={'timeout':25},exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware,layer=0)
        assert self.w3.eth.chain_id==112311 and hx(self.w3.eth.get_block(0)['hash'])==GENESIS_HASH
        self.accounts={}
        if execute:
            assert branch.startswith('review/') and git('ls-remote','origin','refs/heads/'+branch).split()[0]==self.commit
            assert not git('status','--porcelain','--','Contracts','Tools/Paladin','Tests/Readiness')
            entries=json.loads((self.workspace/'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            self.accounts[DEPLOYER]=unlock(next(e for e in entries if e['address']==DEPLOYER))
        self.journal['source_commit']=self.commit

    def rpc(self,method,*params):
        response=self.http.post('http://100.111.32.201:8550/',json={'jsonrpc':'2.0','id':1,'method':method,'params':list(params)},timeout=30)
        response.raise_for_status();value=response.json()
        if value.get('error'):raise RuntimeError(method+' failed; reconcile the journal before retrying')
        return value.get('result')

    def private(self,label,request):
        assert self.execute
        digest=hashlib.sha256(json.dumps(request,sort_keys=True).encode()).hexdigest()
        row=self.journal['private'].setdefault(label,{'key':'dakota-issuance-20260915:'+label,'digest':digest})
        assert row['digest']==digest;self.save()
        if not row.get('id'):
            prior=self.rpc('ptx_getTransactionByIdempotencyKey',row['key'])
            row['id']=prior['id'] if prior else self.rpc('pgroup_sendTransaction',dict(request,idempotencyKey=row['key']));self.save()
        for _ in range(35):
            receipt=self.rpc('ptx_getTransactionReceiptFull',row['id'])
            if receipt:break
            time.sleep(1)
        else:raise TimeoutError('Private step is still pending; resume the same journal')
        assert receipt['success'],'Private step reverted; do not resubmit with another key'
        row.update(success=True,transaction_hash=receipt.get('transactionHash'),address=receipt.get('domainReceipt',{}).get('receipt',{}).get('contractAddress'));self.save()
        return row

    def private_request(self,abi,to=None,inputs=None,bytecode=None):
        request={'domain':'pente','group':GROUP,'from':'operator@paladin01','gas':12000000,'function':abi,'input':inputs or [],
            'publicTxOptions':{'gas':2000000,'maxFeePerGas':'1000000000','maxPriorityFeePerGas':'1000000000'}}
        if to:request['to']=to
        if bytecode:request['bytecode']=bytecode
        return request

    def publish(self,endpoint):
        api=KuboClient(endpoint);report={'source_commit':self.commit,'contracts':{},'objects':{},'private_state_published':False}
        def pin(body,cid=None):
            cid=cid or api.add(body,only_hash=True)
            if cid not in report['objects']:
                assert api.add(body)==cid;api.confirm(cid,body)
                response=self.http.get('http://100.111.67.1:8082/ipfs/'+cid,timeout=20);response.raise_for_status();assert response.content==body
                report['objects'][cid]={'sha256':hashlib.sha256(body).hexdigest(),'pinned':True,'gateway_readback':True}
            return cid
        for name,a in self.artifacts.items():
            metadata=a['metadata'].encode();cid=pin(metadata,metadata_cid(a['runtime_bytecode']))
            for unit,source in json.loads(metadata)['sources'].items():
                body=a['standard_json_input']['sources'][unit]['content'].encode();assert hx(Web3.keccak(body))==source['keccak256']
                expected=next(url.removeprefix('dweb:/ipfs/') for url in source['urls'] if url.startswith('dweb:/ipfs/'));pin(body,expected)
            report['contracts'][name]={'metadata_cid':cid,'license':json.loads(metadata)['sources'][a['source']]['license'],
                'files':{filename:pin((RELEASE/name/filename).read_bytes()) for filename in ('abi.json','standard-input.json','standard-output.json','artifact.json')}}
            print('Published and verified '+name,flush=True)
        report['passed']=True;(self.out/'ipfs.json').write_text(json.dumps(report,indent=2)+'\n')

    def create(self,name,args=()):
        a=self.artifacts[name]
        receipt=self.tx('deploy:'+name,self.w3.eth.contract(abi=a['abi'],bytecode=a['creation_bytecode']).constructor(*args))
        actual=self.w3.eth.get_code(receipt.contractAddress);normalized=bytearray(actual);expected=bytes.fromhex(a['runtime_bytecode'][2:])
        compiled=json.loads((RELEASE/name/'standard-output.json').read_text())['contracts'][a['source']][name]
        allowed={int(receipt.contractAddress,16)}|{int(x,16) for x in args if isinstance(x,str) and x.startswith('0x')}
        for spans in compiled['evm']['deployedBytecode']['immutableReferences'].values():
            assert {int.from_bytes(actual[p['start']:p['start']+p['length']],'big') for p in spans}.issubset(allowed)
            for p in spans:normalized[p['start']:p['start']+p['length']]=expected[p['start']:p['start']+p['length']]
        assert bytes(normalized)==expected
        self.journal['deployments'][name]={'address':receipt.contractAddress,'args':args,'runtime_sha256':hashlib.sha256(actual).hexdigest()};self.save()

    def stage(self):
        publication=json.loads((self.out/'ipfs.json').read_text());assert publication['passed'] and publication['source_commit']==self.commit
        for name in ('WorkerGasSponsor','CryftGreetingCards'):self.create(name)
        # The supplied owner controls the policy from construction. Other wallet
        # overrides and current-day usage are copied before any activation.
        self.create('TenantAllowancePolicy',[ADDR['GasSponsor'],REGISTRY,ADMIN,REGISTRY,10**16,2*10**16,[]])
        a=self.artifacts['PrivateComboStorage'];constructor=next((v for v in a['abi'] if v['type']=='constructor'),{'type':'constructor','inputs':[]})
        deployed=self.private('deploy:PrivateComboStorage',self.private_request(constructor,bytecode=a['creation_bytecode']))
        address=deployed['address'];assert address
        result=self.rpc('pgroup_call',self.private_request({'type':'constructor','inputs':[],'outputs':[{'name':'codeHash','type':'bytes32'}]},
            bytecode='0x73'+address[2:]+'3f5f5260205ff3'))
        assert result['codeHash'].lower()==hx(Web3.keccak(hexstr=a['runtime_bytecode'])).lower()
        self.journal['deployments']['PrivateComboStorage']={'address':address,'runtime_keccak256':result['codeHash']};self.save()

    def activate_development(self):
        assert self.execute
        abi=[{'type':'function','name':'upgrade','stateMutability':'nonpayable','inputs':[{'name':'proxy','type':'address'},{'name':'implementation','type':'address'}],'outputs':[]}]
        for name,proxy,admin in [('WorkerGasSponsor',ADDR['GasSponsor'],ADDR['ProxyAdmin']),('CryftGreetingCards',CARD,CARD_ADMIN)]:
            target=self.journal['deployments'][name]['address']
            self.tx('upgrade:'+name,self.w3.eth.contract(address=admin,abi=abi).functions.upgrade(proxy,target))
            assert Web3.to_checksum_address(self.w3.eth.get_storage_at(proxy,IMPL_SLOT)[-20:])==target
        self.private('upgrade:PrivateComboStorage',self.private_request(abi[0],PRIVATE_ADMIN,[COMBO,self.journal['deployments']['PrivateComboStorage']['address']]))
        card=self.w3.eth.contract(address=CARD,abi=self.artifacts['CryftGreetingCards']['abi'])
        assert card.functions.owner().call()==DEPLOYER
        self.tx('cards:issuer',card.functions.setIssuanceAccess(True,WORKER,True))
        # Add bounded development capacity once; retain all existing token IDs.
        if 'cards:capacity' not in self.journal['transactions']:
            current=card.functions.maxSaleSupply().call();assert current==12,'Review unexpected capacity before paying any registration fee'
            abi_fee=[{'type':'function','name':'registrationFee','stateMutability':'view','inputs':[],'outputs':[{'name':'fee','type':'uint256'}]}]
            fee=self.w3.eth.contract(address=ADDR['CodeManager'],abi=abi_fee).functions.registrationFee().call()
            assert fee==10**15,'Review changed registration fees'
            self.tx('cards:capacity',card.functions.setMaxSaleSupply(64),value=52*fee)
        assert card.functions.maxSaleSupply().call()==64
        print('Development upgrades verified. Root-owned worker permissions and policy connection remain disabled.',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);p.add_argument('--ipfs-api',default='http://127.0.0.1:15101');p.add_argument('action',choices=['publish','stage','activate-development']);a=p.parse_args()
    d=IssuanceRelease(a.workspace,execute=a.action!='publish')
    if a.action=='publish':d.publish(a.ipfs_api)
    elif a.action=='stage':d.stage()
    else:d.activate_development()
