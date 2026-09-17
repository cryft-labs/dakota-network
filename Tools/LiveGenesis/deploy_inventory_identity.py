"""Deploy reviewed v1.1.1 logic only; root retains exclusive proxy-upgrade authority."""
import argparse,hashlib,json
from pathlib import Path
import requests,solcx
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from common import ADMIN,DEPLOYER,GENESIS_HASH,REPO,IMPL_SLOT,Deployment,git,hx,unlock

PROXY=Web3.to_checksum_address('0xF1a8a53Ef5400F63B4E5cA9FCbeBed097f9b08C4')
PROXY_ADMIN=Web3.to_checksum_address('0xc551BC2A8c09c16daAE37a2288c672a42Ab3F8f5')
OLD=Web3.to_checksum_address('0xC1184a7f67B0de733eF445c03605398ac8766bd0')
NAME='MomentInventoryToken'


def layout(directory):
    standard=json.loads((directory/(NAME+'_standard_input.json')).read_text())
    standard['settings']['outputSelection']={'*':{'*':['storageLayout','evm.bytecode.object','evm.deployedBytecode.object']}}
    source=json.loads((directory/(NAME+'_artifact.json')).read_text())['fully_qualified_name'].rsplit(':',1)[0]
    output=solcx.compile_standard(standard,solc_version='0.8.37')['contracts'][source][NAME]
    types=output['storageLayout']['types']
    def shape(kind):
        value=types[kind]
        result={k:value[k] for k in ('encoding','label','numberOfBytes')}
        for k in ('key','value','base'):
            if k in value:result[k]=shape(value[k])
        if 'members' in value:result['members']=[entry(v) for v in value['members']]
        return result
    def entry(value):return dict(label=value['label'],slot=value['slot'],offset=value['offset'],type=shape(value['type']))
    return [entry(v) for v in output['storageLayout']['storage']],output['evm']


class IdentityDeployment(Deployment):
    def __init__(self,workspace,execute=False):
        self.workspace=Path(workspace).resolve();self.execute=execute
        self.out=self.workspace/'outputs/inventory-identity-20260917';self.out.mkdir(exist_ok=True)
        self.path=self.out/'deployment.json'
        self.journal=json.loads(self.path.read_text()) if self.path.exists() else dict(chain_id=112311,genesis_hash=GENESIS_HASH,transactions={},deployments={},checks={})
        self.commit=git('rev-parse','HEAD')
        if execute:
            branch=git('branch','--show-current')
            assert branch.startswith('review/') and not git('status','--porcelain'),'Commit the reviewed release first'
            assert git('ls-remote','origin','refs/heads/'+branch).split()[0]==self.commit,'Push the reviewed release first'
        base=REPO/'Contracts/Accounts/identity-artifacts/osaka/Accounts'/NAME
        old=REPO/'Contracts/Accounts/allocation-artifacts/osaka/Accounts'/NAME
        previous,_=layout(old);current,evm=layout(base)
        assert previous==current,'Storage layout changed'
        artifact_path=base/(NAME+'_artifact.json');artifact=json.loads(artifact_path.read_text())
        assert artifact['creation_bytecode'].removeprefix('0x')==evm['bytecode']['object']
        assert artifact['runtime_bytecode'].removeprefix('0x')==evm['deployedBytecode']['object']
        self.artifacts={NAME:artifact};self.lock={NAME:dict(immutable_references={},artifact_sha256=hashlib.sha256(artifact_path.read_bytes()).hexdigest())}
        http=requests.Session();http.trust_env=False
        self.w3=Web3(Web3.HTTPProvider('http://100.111.69.1:8547/',session=http,request_kwargs={'timeout':25},exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware,layer=0)
        assert self.w3.eth.chain_id==112311 and hx(self.w3.eth.get_block(0)['hash'])==GENESIS_HASH
        admin_artifact=json.loads((REPO/'Contracts/Accounts/projects-inventory-artifacts/osaka/Accounts/MomentProjectAdmin/MomentProjectAdmin_artifact.json').read_text())
        self.admin=self.w3.eth.contract(address=PROXY_ADMIN,abi=admin_artifact['abi'])
        assert self.admin.functions.owner().call()==ADMIN
        assert self.admin.functions.getProxyAdmin(PROXY).call()==PROXY_ADMIN
        assert self.admin.functions.getProxyImplementation(PROXY).call()==OLD,'Review active implementation before retrying'
        self.accounts={}
        if execute:
            entries=json.loads((self.workspace/'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            self.accounts[DEPLOYER]=unlock(next(e for e in entries if e['address']==DEPLOYER))
        (self.out/'storage-layout-review.json').write_text(json.dumps(dict(unchanged=True,layout=current),indent=2)+'\n')

    def run(self):
        if not self.execute:
            print(json.dumps(dict(storage_layout_unchanged=True,owner=ADMIN,proxy=PROXY,source_commit=self.commit,submitted=False)));return
        implementation=self.deploy(NAME,label='MomentInventoryTokenV111')
        self.reject('implementation_cannot_initialize',implementation.functions.initialize(DEPLOYER,DEPLOYER),sender=DEPLOYER)
        assert implementation.functions.implementationVersion().call()=='1.1.1'
        assert implementation.functions.name().call()=='Dakota Inventory'
        assert implementation.functions.symbol().call()=='DKINV'
        call=self.admin.functions.upgrade(PROXY,implementation.address)
        call.call({'from':ADMIN})
        self.reject('deployer_cannot_upgrade',call,sender=DEPLOYER)
        data=dict(chain_id=112311,proxy=PROXY,implementation=implementation.address,previous_implementation=OLD,
            runtime_sha256=hashlib.sha256(self.w3.eth.get_code(implementation.address)).hexdigest(),
            owner=ADMIN,admin=PROXY_ADMIN,source_commit=self.commit,storage_layout_unchanged=True,
            owner_transaction={'to':PROXY_ADMIN,'data':call._encode_transaction_data(),'value':'0x0','chain_id':112311},
            status='implementation_deployed_awaiting_owner_upgrade')
        (self.out/'configuration.json').write_text(json.dumps(data,indent=2)+'\n')
        print(json.dumps(data,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--workspace',required=True);parser.add_argument('--execute',action='store_true')
    args=parser.parse_args();IdentityDeployment(args.workspace,args.execute).run()
