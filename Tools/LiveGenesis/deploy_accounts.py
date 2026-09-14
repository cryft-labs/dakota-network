"""Deploy the reviewed Dakota-local ERC-6551 registry and account implementation.

No genesis changes, canonical factory funding, proxy upgrades or owner powers.
The registry is permissionless; account authority always follows the parent NFT.
"""
import argparse
import json
from pathlib import Path
import requests
import hashlib
import solcx
from common import Deployment, REPO, DEPLOYER, GENESIS_HASH, unlock, git, hx
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware


class AccountsDeployment(Deployment):
    def __init__(self, workspace, execute=False):
        self.workspace=Path(workspace).resolve(); self.execute=execute
        self.out=self.workspace/'outputs/token-bound-inventories-20260914'
        self.out.mkdir(exist_ok=True)
        self.path=self.out/'deployment.json'
        self.journal=json.loads(self.path.read_text()) if self.path.exists() else {
            'chain_id':112311,'genesis_hash':GENESIS_HASH,'canonical_registry':False,
            'transactions':{},'deployments':{},'checks':{}}
        self.commit=git('rev-parse','HEAD'); branch=git('branch','--show-current')
        if execute:
            assert branch.startswith('review/') and not git('status','--porcelain')
            assert git('ls-remote','origin','refs/heads/'+branch).split()[0]==self.commit
        base=REPO/'Contracts/Accounts/artifacts/osaka/Accounts'
        self.artifacts={name:json.loads((base/name/(name+'_artifact.json')).read_text())
                        for name in ('ERC6551Registry','MomentCardAccount')}
        self.lock={}
        for name,artifact in self.artifacts.items():
            standard=json.loads((base/name/(name+'_standard_input.json')).read_text())
            standard['settings']['outputSelection']={'*':{'*':['evm.bytecode.object','evm.deployedBytecode.object','evm.deployedBytecode.immutableReferences']}}
            result=solcx.compile_standard(standard,solc_version=artifact['compiler_version'])
            source,contract=artifact['fully_qualified_name'].rsplit(':',1)
            built=result['contracts'][source][contract]['evm']
            assert artifact['creation_bytecode'].removeprefix('0x')==built['bytecode']['object']
            assert artifact['runtime_bytecode'].removeprefix('0x')==built['deployedBytecode']['object']
            self.lock[name]={'immutable_references':built['deployedBytecode'].get('immutableReferences',{}),
                'artifact_sha256':hashlib.sha256((base/name/(name+'_artifact.json')).read_bytes()).hexdigest()}
        session=requests.Session(); session.trust_env=False
        self.w3=Web3(Web3.HTTPProvider('http://100.111.69.1:8547/',session=session,
            request_kwargs={'timeout':20},exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware,layer=0)
        assert self.w3.eth.chain_id==112311 and hx(self.w3.eth.get_block(0)['hash'])==GENESIS_HASH
        self.accounts={}
        if execute:
            entries=json.loads((self.workspace/'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            self.accounts[DEPLOYER]=unlock(next(e for e in entries if e['address']==DEPLOYER))

    def run(self):
        if not self.execute:
            print(json.dumps({'chain_id':112311,'canonical':False,'contracts':list(self.artifacts),
                'source_commit':self.commit,'deployer':DEPLOYER,'submitted':False})); return
        registry=self.deploy('ERC6551Registry')
        implementation=self.deploy('MomentCardAccount')
        # Deployment.deploy returns a contract instance.
        registry_address=getattr(registry,'address',registry)
        implementation_address=getattr(implementation,'address',implementation)
        config={'chain_id':112311,'registry':registry_address,'implementation':implementation_address,
                'salt':hx(Web3.keccak(text='moment.cards:tba:v1')),
                'registry_runtime_hash':hx(Web3.keccak(self.w3.eth.get_code(registry_address))),
                'implementation_runtime_hash':hx(Web3.keccak(self.w3.eth.get_code(implementation_address))),
                'canonical_registry':False,'source_commit':self.commit}
        self.journal['configuration']=config; self.save()
        (self.out/'configuration.json').write_text(json.dumps(config,indent=2)+'\n')
        print(json.dumps(config,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--workspace',required=True)
    parser.add_argument('--execute',action='store_true')
    args=parser.parse_args(); AccountsDeployment(args.workspace,args.execute).run()
