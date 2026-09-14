"""Restore the verified GasSponsor 1.1 implementation without reinitialization.

Only the proxy implementation changes. All journaled identities, balances, spent
allowances, wallet permissions, replay markers and CodeManager governance remain.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path
import requests
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'Tools/LiveGenesis'))
from common import Deployment, unlock, git, serial, hx, ADDR, ADMIN, DEPLOYER, GENESIS_HASH

OLD = Web3.to_checksum_address('0x788e77a7f7e6d1E65a9C4b19D1C36ac93E749FB0')
TARGET = Web3.to_checksum_address('0x83AaF0a9d4FE1748e1fCFFd5a3adfd60a16E86dF')
RELEASE = REPO/'Releases/TenantAllowances/1.0.0'


class RestoreOpen(Deployment):
    def __init__(self, workspace, execute=False):
        self.workspace=Path(workspace).resolve(); self.execute=execute
        self.out=self.workspace/'outputs/open-sponsorship-20260914'; self.out.mkdir(exist_ok=True)
        self.path=self.out/'transactions.json'
        self.journal=json.loads(self.path.read_text()) if self.path.exists() else {'transactions':{},'deployments':{},'checks':{}}
        self.commit=git('rev-parse','HEAD'); branch=git('branch','--show-current')
        if execute:
            assert branch.startswith('review/') and not git('status','--porcelain')
            assert git('ls-remote','origin','refs/heads/'+branch).split()[0]==self.commit
        artifact_path=next(RELEASE.rglob('GasSponsor_artifact.json'))
        self.art=json.loads(artifact_path.read_text())
        record=json.loads((RELEASE/'deployment.json').read_text())['deployments']['GasSponsor']
        assert record['address']==TARGET
        assert hashlib.sha256(artifact_path.read_bytes()).hexdigest()==record['artifact_sha256']
        self.http=requests.Session(); self.http.trust_env=False
        self.w3=Web3(Web3.HTTPProvider('http://100.111.69.1:8547/',session=self.http,request_kwargs={'timeout':20},exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware,layer=0)
        assert self.w3.eth.chain_id==112311 and hx(self.w3.eth.get_block(0)['hash'])==GENESIS_HASH
        assert self.w3.eth.get_code(TARGET)==bytes.fromhex(self.art['runtime_bytecode'].removeprefix('0x'))
        strict=json.loads(next((REPO/'Releases/ApprovedSponsorship/1.2.0').rglob('ApprovedGasSponsor_artifact.json')).read_text())
        assert self.w3.eth.get_code(OLD)==bytes.fromhex(strict['runtime_bytecode'].removeprefix('0x'))
        self.sponsor=self.w3.eth.contract(address=ADDR['GasSponsor'],abi=self.art['abi'])
        proxy=json.loads((self.workspace/'outputs/live-genesis-20260911/ProxyAdmin/artifact.json').read_text())
        self.proxy_admin=self.w3.eth.contract(address=ADDR['ProxyAdmin'],abi=proxy['abi'])
        cm=json.loads((self.workspace/'work/source/kota-docs-main/router_v4/services/platform/contracts/CodeManagerStrict.json').read_text())
        self.cm=self.w3.eth.contract(address=ADDR['CodeManager'],abi=cm)
        self.accounts={}
        if execute:
            entries=json.loads((self.workspace/'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            self.accounts[DEPLOYER]=unlock(next(e for e in entries if e['address']==DEPLOYER))

    def snapshot(self):
        block=self.w3.eth.block_number
        def call(name,*args): return getattr(self.sponsor.functions,name)(*args).call(block_identifier=block)
        def events(name):
            event=getattr(self.sponsor.events,name)()
            return [entry for start in range(0,block+1,500)
                for entry in event.get_logs(from_block=start,to_block=min(start+499,block))]
        sponsors=sorted({e['args']['sponsor'] for e in events('SponsorConfigured')})
        relayers=sorted({e['args']['relayer'] for e in events('RelayerUpdated')})
        operations={hx(e['args']['operationId']):e['args']['account'] for e in events('SponsoredOperation')}
        wallet_pairs=sorted({(e['args']['sponsor'],e['args']['wallet']) for e in events('SponsoredWalletUpdated')})
        return serial(dict(
            accounts={s:dict(account=call('getSponsorAccount',s),funding=call('getSponsorFunding',s),policy=call('getSponsorPolicy',s)) for s in sponsors},
            relayers={r:call('isRelayer',r) for r in relayers},
            operations={op:call('isOperationConsumed',bytes.fromhex(op[2:])) for op in operations},
            wallets={s+'/'+w:call('sponsoredWalletPermission',s,w) for s,w in wallet_pairs},
            platform={name:call(name) for name in ['platformAdmin','pendingPlatformAdmin','voucherSigner','approvedDelegate','fixedOverheadGas','paused','sponsorStorageLocation']},
            fee=self.cm.functions.registrationFee().call(block_identifier=block),
            fee_vault=self.cm.functions.feeVault().call(block_identifier=block),
            voters=self.cm.functions.getVoters().call(block_identifier=block)))

    def run(self):
        current=self.proxy_admin.functions.getProxyImplementation(self.sponsor.address).call()
        assert current in (OLD,TARGET)
        assert self.sponsor.functions.platformAdmin().call()==ADMIN
        before=self.snapshot()
        self.journal['plan']=dict(source_commit=self.commit,chain_id=112311,proxy=self.sponsor.address,
            current_implementation=current,target_implementation=TARGET,version='1.1.0',
            runtime_keccak256=hx(Web3.keccak(self.w3.eth.get_code(TARGET))),
            artifact='Releases/TenantAllowances/1.0.0',reinitialize=False)
        if not self.execute:
            self.save(); print(json.dumps(dict(plan=self.journal['plan'],snapshot=before),indent=2)); return
        if 'before' not in self.journal:
            assert current==OLD, 'Unexpected preexisting restoration; investigate first'
            self.journal['before']=before; self.save()
        receipt=self.tx('restore-open:GasSponsor',self.proxy_admin.functions.upgrade(self.sponsor.address,TARGET))
        self.check('implementation_restored',self.proxy_admin.functions.getProxyImplementation(self.sponsor.address).call()==TARGET)
        self.check('version_open_1_1',self.sponsor.functions.implementationVersion().call()=='1.1.0')
        self.check('all_observed_accounts_roles_permissions_replay_and_fee_preserved',self.snapshot()==self.journal['before'])
        self.check('exact_released_runtime',self.w3.eth.get_code(TARGET)==bytes.fromhex(self.art['runtime_bytecode'].removeprefix('0x')))
        self.check('root_code_manager_governance_retained',self.cm.functions.getVoters().call()==[ADMIN])
        self.journal['status']='open_sponsorship_active'; self.save()
        print(json.dumps(dict(transaction=hx(receipt.transactionHash),block=receipt.blockNumber,target=TARGET,checks=self.journal['checks']),indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--workspace',required=True); parser.add_argument('--execute',action='store_true')
    options=parser.parse_args(); RestoreOpen(options.workspace,options.execute).run()
