"""Journaled authorized deployment/acceptance; source and artifacts must be pushed."""
import argparse,hashlib,json,sys
from pathlib import Path
from eth_account import Account
from web3 import Web3
from web3.logs import DISCARD

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'Tools/LiveGenesis'))
from common import Deployment,unlock,git,serial,hx,ADDR,ADMIN,DEPLOYER,GENESIS_HASH,IMPL_SLOT

TENANT='moment.cards'
REGISTRY=Web3.to_checksum_address('0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340')
OLD=Web3.to_checksum_address('0x31A4ea654E4C0BFd6eFD5286decC72C2CA1cdb3E')
RELEASE=REPO/'Releases/TenantAllowances/1.0.0'

class Release(Deployment):
    def __init__(self,workspace,wallets_file,execute):
        import requests
        from web3.middleware import ExtraDataToPOAMiddleware
        self.workspace=Path(workspace).resolve();self.execute=execute
        self.out=self.workspace/'outputs/tenant-allowances-20260913';self.out.mkdir(parents=True,exist_ok=True)
        self.path=self.out/'transactions.json'
        self.journal=json.loads(self.path.read_text()) if self.path.exists() else {'transactions':{},'deployments':{},'checks':{}}
        self.commit=git('rev-parse','HEAD');branch=git('branch','--show-current')
        if execute:
            assert branch.startswith('review/')
            assert not git('status','--porcelain','--','Contracts','Releases/TenantAllowances','Tools/TenantAllowances','Tests/Readiness/test_tenant_allowances.py')
            assert git('ls-remote','origin','refs/heads/'+branch).split()[0]==self.commit
        self.artifacts={}
        for name in ('GasSponsor','TenantAllowancePolicy'):
            path=next(RELEASE.rglob(name+'_artifact.json'))
            self.artifacts[name]=json.loads(path.read_text())
        self.validation=json.loads((RELEASE/'validation.json').read_text())
        assert self.validation['storage_append_only']
        for name,record in self.validation['contracts'].items():
            assert hashlib.sha256(next(RELEASE.rglob(name+'_artifact.json')).read_bytes()).hexdigest()==record['artifact_sha256']
        self.session=requests.Session();self.session.trust_env=False
        self.w3=Web3(Web3.HTTPProvider('http://100.111.69.1:8547/',session=self.session,request_kwargs={'timeout':25},exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware,layer=0)
        assert self.w3.eth.chain_id==112311 and hx(self.w3.eth.get_block(0)['hash'])==GENESIS_HASH
        self.sponsor=self.w3.eth.contract(address=ADDR['GasSponsor'],abi=self.artifacts['GasSponsor']['abi'])
        self.accounts={}
        if execute:
            entries=json.loads((self.workspace/'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            entry=next(e for e in entries if e['address'].lower()==DEPLOYER.lower())
            self.accounts[DEPLOYER]=unlock(entry)
            # Existing development wallets, decrypted only in this process; never journal secrets.
            keys=json.loads(Path(wallets_file).read_text())
            for name in ('dev_admin','dev_user'):
                account=Account.from_key(keys[name]['private_key']);assert account.address.lower()==keys[name]['address'].lower()
                self.accounts[account.address]=account
            self.manager=Account.from_key(keys['dev_admin']['private_key']).address
            self.user=Account.from_key(keys['dev_user']['private_key']).address
        self.journal['release_commit']=self.commit;self.save()

    def create(self,name,*args):
        art=self.artifacts[name]
        receipt=self.tx('deploy:'+name,self.w3.eth.contract(abi=art['abi'],bytecode=art['creation_bytecode']).constructor(*args))
        address=receipt.contractAddress
        actual=self.w3.eth.get_code(address)
        normalized=bytearray(actual)
        expected=bytes.fromhex(art['runtime_bytecode'].removeprefix('0x'))
        allowed={int(address,16)}|{int(item,16) for item in args if isinstance(item,str) and item.startswith('0x')}
        for spans in self.validation['contracts'][name]['immutable_references'].values():
            values={int.from_bytes(actual[s['start']:s['start']+s['length']],'big') for s in spans}
            assert len(values)==1 and values.issubset(allowed),'Unexpected deployed immutable'
            for s in spans:normalized[s['start']:s['start']+s['length']]=expected[s['start']:s['start']+s['length']]
        assert bytes(normalized)==expected,'Deployed runtime differs from reviewed build'
        self.journal['deployments'][name]={'address':address,'constructor_args':args,'runtime_keccak256':hx(Web3.keccak(actual)),
                                          'artifact_sha256':hashlib.sha256(next(RELEASE.rglob(name+'_artifact.json')).read_bytes()).hexdigest()}
        self.save()
        return self.w3.eth.contract(address=address,abi=art['abi'])

    def snapshot(self):
        return serial({'account':self.sponsor.functions.getSponsorAccount(REGISTRY).call(),
                       'funding':self.sponsor.functions.getSponsorFunding(REGISTRY).call(),
                       'platform_admin':self.sponsor.functions.platformAdmin().call(),
                       'voucher_signer':self.sponsor.functions.voucherSigner().call(),
                       'delegate':self.sponsor.functions.approvedDelegate().call(),
                       'paused':self.sponsor.functions.paused().call()})

    def deploy_release(self):
        assert self.execute
        if 'before_upgrade' not in self.journal:
            assert Web3.to_checksum_address(self.w3.eth.get_storage_at(self.sponsor.address,IMPL_SLOT)[-20:])==OLD
            baseline=json.loads((RELEASE/'baseline-gas-sponsor.json').read_text())
            assert self.w3.eth.get_code(OLD)==bytes.fromhex(baseline['runtime_bytecode'].removeprefix('0x')),'Live implementation differs from reviewed baseline'
            self.journal['before_upgrade']=self.snapshot();self.save()
        logic=self.create('GasSponsor')
        # Public state is retained; never call initialize on the existing proxy.
        proxy_abi=[{'type':'function','name':'upgrade','stateMutability':'nonpayable','inputs':[{'name':'proxy','type':'address'},{'name':'implementation','type':'address'}],'outputs':[]}]
        admin=self.w3.eth.contract(address=ADDR['ProxyAdmin'],abi=proxy_abi)
        self.tx('upgrade:GasSponsor',admin.functions.upgrade(self.sponsor.address,logic.address))
        assert self.sponsor.functions.implementationVersion().call()=='1.1.0'
        if 'upgrade_state_preserved' not in self.journal['checks']:
            self.check('upgrade_state_preserved',self.snapshot()==self.journal['before_upgrade'])
        assert self.sponsor.functions.getSponsorAccount(REGISTRY).call()[1]==self.manager
        assert self.sponsor.functions.voucherSigner().call()==self.manager and self.sponsor.functions.isRelayer(self.manager).call()
        policy=self.create('TenantAllowancePolicy',self.sponsor.address,REGISTRY,ADMIN,REGISTRY,5*10**15,10**16,[self.manager])
        self.check('policy_owned_by_supplied_admin',policy.functions.owner().call()==ADMIN)
        self.tx('wallet:admin',self.sponsor.functions.setSponsoredWallet(REGISTRY,ADMIN,1),sender=self.manager)
        self.tx('wallet:manager',self.sponsor.functions.setSponsoredWallet(REGISTRY,self.manager,1),sender=self.manager)
        self.tx('wallet:member',self.sponsor.functions.setSponsoredWallet(REGISTRY,self.user,1),sender=self.manager)
        # Membership policy admits newly enrolled members; do not add manual acceptance.
        self.tx('wallet:require_approval',self.sponsor.functions.setWalletApprovalRequired(REGISTRY,False),sender=self.manager)
        self.tx('policy:connect',self.sponsor.functions.setSponsorPolicy(REGISTRY,policy.address),sender=self.manager)
        self.check('policy_bound',self.sponsor.functions.getSponsorPolicy(REGISTRY).call()==[policy.address,False])
        self.journal['policy_address']=policy.address;self.save()

    def delegated(self,wallet):
        entry=self.sponsor.functions.approvedDelegate().call()
        if self.sponsor.functions.isDelegationReady(wallet).call():return
        assert self.w3.eth.get_code(wallet)==b'', 'Do not replace an existing wallet delegation automatically'
        authorization=self.accounts[wallet].sign_authorization({'chainId':112311,'address':entry,'nonce':self.w3.eth.get_transaction_count(wallet)})
        self.tx('delegate:'+wallet,transaction={'to':wallet,'data':'0x','value':0,'gas':1000000,'maxFeePerGas':10**9,'maxPriorityFeePerGas':10**9,'authorizationList':[authorization]},sender=DEPLOYER)
        self.check('delegation:'+wallet,self.sponsor.functions.isDelegationReady(wallet).call())

    def execute_case(self,label,wallet,calls):
        self.delegated(wallet)
        # Current direct dispatcher uses the stable DakotaDelegation ABI.
        art=json.loads((self.workspace/'outputs/live-genesis-20260911/DakotaDelegation/artifact.json').read_text())
        delegated=self.w3.eth.contract(address=wallet,abi=art['abi'])
        op=Web3.keccak(text='dakota-allowances-20260913:'+label)
        if 'sponsored:'+label in self.journal['transactions']:
            return self.w3.eth.get_transaction_receipt(self.journal['transactions']['sponsored:'+label]['hash'])
        deadline=self.w3.eth.get_block('latest').timestamp+1800
        execution=(op,self.sponsor.address,calls,delegated.functions.getNonce().call(),deadline,750000)
        signature=self.accounts[wallet].unsafe_sign_hash(delegated.functions.getExecutionDigest(*execution).call()).signature
        data=bytes.fromhex(delegated.encode_abi('executeSponsored',args=[execution,signature])[2:])
        outer=self.sponsor.functions.minimumCallGas(execution[-1],len(data)).call()
        maximum=(outer+self.sponsor.functions.costOverheadGas(REGISTRY).call())*10**9
        voucher=(op,Web3.keccak(text=TENANT),bytes(32),REGISTRY,wallet,self.manager,self.sponsor.functions.approvedDelegate().call(),Web3.keccak(data),outer,10**9,maximum,deadline)
        vsig=self.accounts[self.manager].unsafe_sign_hash(self.sponsor.functions.voucherDigest(voucher).call()).signature
        policy=self.w3.eth.contract(address=self.journal['policy_address'],abi=self.artifacts['TenantAllowancePolicy']['abi'])
        before=self.sponsor.functions.getSponsorFunding(REGISTRY).call()[1]
        spent=policy.functions.allowance(wallet).call()[4]
        receipt=self.tx('sponsored:'+label,self.sponsor.functions.executeSponsored(voucher,data,vsig),sender=self.manager)
        event=self.sponsor.events.SponsoredOperation().process_receipt(receipt,errors=DISCARD)[0]['args']
        reimbursement=self.sponsor.events.RelayerReimbursed().process_receipt(receipt,errors=DISCARD)[0]['args']['reimbursement']
        self.check('sponsored:'+label,event['success'] and reimbursement>0)
        self.check('accounting:'+label,before-self.sponsor.functions.getSponsorFunding(REGISTRY).call()[1]==reimbursement
                   and policy.functions.allowance(wallet).call()[4]-spent==reimbursement
                   and policy.functions.pendingReservations().call()==0)
        self.reject('replay:'+label,self.sponsor.functions.executeSponsored(voucher,data,vsig),sender=self.manager)
        return receipt

    def acceptance(self):
        assert self.execute and self.journal.get('policy_address')
        # Harmless member call followed by a genuine admin management call.
        call=bytes.fromhex(self.sponsor.encode_abi('getSponsorAccount',args=[REGISTRY])[2:])
        self.execute_case('member-usage',self.user,[(self.sponsor.address,0,call)])
        call=bytes.fromhex(self.sponsor.encode_abi('setSponsoredWallet',args=[REGISTRY,self.user,1])[2:])
        self.execute_case('admin-management',self.manager,[(self.sponsor.address,0,call)])
        self.journal['after_acceptance']=self.snapshot();self.save()
        print(json.dumps({'deployments':self.journal['deployments'],'checks':self.journal['checks']},indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);p.add_argument('--wallets-file',required=True);p.add_argument('--execute',action='store_true');p.add_argument('stage',choices=['deploy','acceptance','inspect']);a=p.parse_args()
    release=Release(a.workspace,a.wallets_file,a.execute)
    if a.stage=='deploy':release.deploy_release()
    elif a.stage=='acceptance':release.acceptance()
    else:print(json.dumps(release.snapshot(),indent=2))
