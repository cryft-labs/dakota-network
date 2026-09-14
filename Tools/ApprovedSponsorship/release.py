"""Journaled dev-network upgrade and CodeManager handoff from pushed artifacts.

The existing ProxyAdmin governance authorizes the atomic upgrade and seed list.
No genesis replacement, private-state change or registration-fee change occurs.
"""
import argparse, hashlib, json, sys
from pathlib import Path
from web3 import Web3

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'Tools/LiveGenesis'))
from common import Deployment, unlock, git, serial, hx, ADDR, ADMIN, DEPLOYER, GENESIS_HASH, IMPL_SLOT

RELEASE=REPO/'Releases/ApprovedSponsorship/1.2.0'
ACCOUNT=Web3.to_checksum_address('0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340')
CARD=Web3.to_checksum_address('0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410')
POLICY=Web3.to_checksum_address('0x1D205B1d531422f615101FE93622D65AB54943D2')
OLD=Web3.to_checksum_address('0x83AaF0a9d4FE1748e1fCFFd5a3adfd60a16E86dF')


class Release(Deployment):
    def __init__(self,workspace,execute=False):
        import requests
        from web3.middleware import ExtraDataToPOAMiddleware
        self.workspace=Path(workspace).resolve();self.execute=execute
        self.out=self.workspace/'outputs/approved-sponsorship-20260914';self.out.mkdir(exist_ok=True)
        self.path=self.out/'transactions.json'
        self.journal=json.loads(self.path.read_text()) if self.path.exists() else {'transactions':{},'deployments':{},'checks':{}}
        self.commit=git('rev-parse','HEAD');branch=git('branch','--show-current')
        if execute:
            assert branch.startswith('review/') and not git('status','--porcelain')
            assert git('ls-remote','origin','refs/heads/'+branch).split()[0]==self.commit
        path=next(RELEASE.rglob('ApprovedGasSponsor_artifact.json'))
        self.art=json.loads(path.read_text());self.artifacts={'ApprovedGasSponsor':self.art}
        assert self.art['runtime_size_bytes']<=32768 and self.art['evm_version']=='osaka'
        for name,unit in self.art['standard_json_input']['sources'].items():
            assert unit['content']==(REPO/'Contracts'/name.removeprefix('source/')).read_text(encoding='utf-8')
        session=requests.Session();session.trust_env=False
        self.w3=Web3(Web3.HTTPProvider('http://100.111.69.1:8547/',session=session,request_kwargs={'timeout':20},exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware,layer=0)
        assert self.w3.eth.chain_id==112311 and hx(self.w3.eth.get_block(0)['hash'])==GENESIS_HASH
        self.sponsor=self.w3.eth.contract(address=ADDR['GasSponsor'],abi=self.art['abi'])
        proxy_art=json.loads((self.workspace/'outputs/live-genesis-20260911/ProxyAdmin/artifact.json').read_text())
        self.proxy_admin=self.w3.eth.contract(address=ADDR['ProxyAdmin'],abi=proxy_art['abi'])
        cm_abi=json.loads((self.workspace/'work/source/kota-docs-main/router_v4/services/platform/contracts/CodeManagerStrict.json').read_text())
        self.cm=self.w3.eth.contract(address=ADDR['CodeManager'],abi=cm_abi)
        self.accounts={}
        if execute:
            entries=json.loads((self.workspace/'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            self.accounts[DEPLOYER]=unlock(next(e for e in entries if e['address']==DEPLOYER))

    def snapshot(self):
        return serial({'account':self.sponsor.functions.getSponsorAccount(ACCOUNT).call(),
            'funding':self.sponsor.functions.getSponsorFunding(ACCOUNT).call(),
            'policy':self.sponsor.functions.getSponsorPolicy(ACCOUNT).call(),
            'platform_admin':self.sponsor.functions.platformAdmin().call(),
            'signer':self.sponsor.functions.voucherSigner().call(),'delegate':self.sponsor.functions.approvedDelegate().call(),
            'paused':self.sponsor.functions.paused().call(),'fee':self.cm.functions.registrationFee().call(),
            'fee_vault':self.cm.functions.feeVault().call()})

    def permissions(self):
        maximum=2**256-1
        cases=[(ADDR['CodeManager'],'registerUniqueIds(address,string,uint256)',maximum,False),
               (ADDR['CodeManager'],'registrationFee()',0,False),
               (CARD,'buy(address,uint256,string)',maximum,True),(CARD,'setMaxSaleSupply(uint256)',maximum,True),
               (POLICY,'setDefaultLimit(bool,uint256,uint256)',0,False),
               (POLICY,'setWalletLimit(address,bool,bool,uint256,uint256)',0,False),
               (POLICY,'setTierLimit(uint32,bool,bool,uint256,uint256)',0,False)]
        result=[];detail=[]
        manifest=json.loads((self.workspace/'work/source/kota-docs-main/router_v4/services/platform/contracts/manifest.json').read_text())
        for name,target in [('CodeManagerStrict',ADDR['CodeManager']),('CryftGreetingCards',CARD)]:
            impl=Web3.to_checksum_address(self.w3.eth.get_storage_at(target,IMPL_SLOT)[-20:])
            assert hashlib.sha256(self.w3.eth.get_code(impl)).hexdigest()==manifest['contracts'][name]['runtime_sha256']
        deployed=json.loads((REPO/'Releases/TenantAllowances/1.0.0/deployment.json').read_text())['deployments']['TenantAllowancePolicy']
        assert deployed['address']==POLICY and hx(Web3.keccak(self.w3.eth.get_code(POLICY)))==deployed['runtime_keccak256']
        for target,signature,value,canonical in cases:
            implementation=Web3.to_checksum_address(self.w3.eth.get_storage_at(target,IMPL_SLOT)[-20:]) if target!=POLICY else '0x'+'0'*40
            admin_slot=int.from_bytes(Web3.keccak(text='eip1967.proxy.admin'),'big')-1
            reader=Web3.to_checksum_address(self.w3.eth.get_storage_at(target,admin_slot)[-20:]) if target!=POLICY else '0x'+'0'*40
            if target==ADDR['CodeManager']:reader=ADDR['ProxyAdmin']
            if int(implementation,16):
                probe=self.w3.eth.contract(address=reader,abi=self.proxy_admin.abi)
                assert probe.functions.getProxyImplementation(target).call()==implementation
            code_hash=Web3.keccak(self.w3.eth.get_code(target))
            implementation_hash=Web3.keccak(self.w3.eth.get_code(implementation)) if int(implementation,16) else b'\0'*32
            reader_hash=Web3.keccak(self.w3.eth.get_code(reader)) if int(reader,16) else b'\0'*32
            approval=(code_hash,implementation,implementation_hash,value,canonical,reader,reader_hash)
            result.append((target,Web3.keccak(text=signature)[:4],approval))
            detail.append(dict(target=target,function=signature,selector=hx(Web3.keccak(text=signature)[:4]),
                runtime_hash=hx(code_hash),implementation=implementation,implementation_hash=hx(implementation_hash),
                max_value_wei=str(value),canonical_manager_required=canonical,proxy_reader=reader,proxy_reader_hash=hx(reader_hash)))
        return result,detail

    def run(self):
        approvals,detail=self.permissions()
        snapshot=self.snapshot()
        self.journal['reviewed_calls']=detail;self.journal['release_commit']=self.commit
        self.journal['plan']={'current_implementation':self.proxy_admin.functions.getProxyImplementation(self.sponsor.address).call(),
            'fee_unchanged_wei':str(snapshot['fee']),'voter_handoff_to':ADMIN,'artifacts_sha256':hashlib.sha256(next(RELEASE.rglob('ApprovedGasSponsor_artifact.json')).read_bytes()).hexdigest()}
        self.save()
        if not self.execute:
            print(json.dumps(serial({'snapshot':snapshot,'plan':self.journal['plan'],'approved_calls':detail}),indent=2));return
        if 'before' not in self.journal:
            assert self.journal['plan']['current_implementation']==OLD
            old=json.loads(next((REPO/'Releases/TenantAllowances/1.0.0').rglob('GasSponsor_artifact.json')).read_text())
            assert self.w3.eth.get_code(OLD)==bytes.fromhex(old['runtime_bytecode'].removeprefix('0x'))
            assert snapshot['platform_admin']==ADMIN
            self.journal['before']=snapshot;self.save()
        receipt=self.tx('deploy:ApprovedGasSponsor',self.w3.eth.contract(abi=self.art['abi'],bytecode=self.art['creation_bytecode']).constructor())
        implementation=receipt.contractAddress
        actual=self.w3.eth.get_code(implementation)
        assert actual==bytes.fromhex(self.art['runtime_bytecode'].removeprefix('0x'))
        self.journal['deployments']['ApprovedGasSponsor']={'address':implementation,'constructor_args':[],
            'runtime_keccak256':hx(Web3.keccak(actual)),'artifact_sha256':self.journal['plan']['artifacts_sha256']};self.save()
        data=self.sponsor.functions.initializeCallApprovals(approvals)._encode_transaction_data()
        self.tx('upgrade-and-seed:GasSponsor',self.proxy_admin.functions.upgradeAndCall(self.sponsor.address,implementation,bytes.fromhex(data[2:])))
        self.check('balances_roles_policy_fee_preserved',self.snapshot()==self.journal['before'])
        self.check('mandatory_approval_version',self.sponsor.functions.implementationVersion().call()=='1.2.0')
        for target,selector,approval in approvals:
            self.check('approved:'+target+':'+hx(selector),tuple(self.sponsor.functions.getCallApproval(target,selector).call())==tuple(approval))
        self.check('unapproved_clone_rejected',not self.sponsor.functions.approvedCall(ACCOUNT,0,Web3.keccak(text='registerUniqueIds(address,string,uint256)')[:4]).call())
        # Existing authority is handed over atomically, never a two-step quorum deadlock.
        if self.cm.functions.getVoters().call()!=[ADMIN]:
            assert self.cm.functions.getVoters().call()==[DEPLOYER]
            from eth_abi import encode
            members_hash=Web3.keccak(encode(['address[]'],[[ADMIN]]))
            self.tx('handoff:CodeManager',self.cm.functions.voteToSetVoterConfiguration([ADMIN],[],members_hash))
        self.check('code_manager_voter_is_owner',self.cm.functions.getVoters().call()==[ADMIN])
        self.check('registration_fee_unchanged',self.cm.functions.registrationFee().call()==snapshot['fee'])
        self.cm.functions.voteToUpdateRegistrationFee(snapshot['fee']+1).call({'from':ADMIN})
        self.reject('deployment_wallet_no_fee_vote',self.cm.functions.voteToUpdateRegistrationFee(snapshot['fee']+1),sender=DEPLOYER)
        self.check('owner_fee_vote_simulated',True,{'new_fee_simulated_only':str(snapshot['fee']+1)})
        print(json.dumps(serial({'deployments':self.journal['deployments'],'checks':list(self.journal['checks'])}),indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--workspace',required=True);parser.add_argument('--execute',action='store_true')
    args=parser.parse_args();Release(args.workspace,args.execute).run()
