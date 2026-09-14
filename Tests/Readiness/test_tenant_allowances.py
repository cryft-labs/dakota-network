"""Allowance policy integration in a real isolated EVM; no live keys or RPC."""
import importlib.util
import json
from pathlib import Path
import pytest
import solcx
from web3 import Web3
from web3.logs import DISCARD
from eth_account import Account
from test_native_sponsorship import builds, chain, setup, signed, tx, fails
from test_native_sponsorship import paid, deploy, at
from test_governance import ADMIN

REPO = Path(__file__).resolve().parents[2]

def test_upgrade_preserves_legacy_balances_nonces_and_authority(chain):
    c=chain;account,sponsor,_,entry=setup(c);a=c['accounts']
    legacy=json.loads((REPO/'Releases/TenantAllowances/1.0.0/baseline-gas-sponsor.json').read_text())
    created=tx(c,c['w3'].eth.contract(abi=legacy['abi'],bytecode=legacy['creation_bytecode']).constructor())
    admin=at(c,'ProxyAdmin',ADMIN)
    tx(c,admin.functions.upgrade(sponsor.address,created.contractAddress))
    assert sponsor.functions.implementationVersion().call()=='1.0.0'
    paid(c,sponsor.functions.depositGasCredit(a[4]),10**17)
    tx(c,sponsor.functions.setTenantLimits(a[4],10**16,10**17),a[5])
    used=signed(c,sponsor,account,entry.address,tag='before-upgrade')
    assert send(c,sponsor,used)[0]['success']
    old_account=sponsor.functions.getSponsorAccount(a[4]).call()
    old_funding=sponsor.functions.getSponsorFunding(a[4]).call()
    digest=sponsor.functions.voucherDigest(used[0]).call()
    namespace=sponsor.functions.sponsorStorageLocation().call()
    tx(c,admin.functions.upgrade(sponsor.address,deploy(c,'GasSponsor').address))
    assert sponsor.functions.implementationVersion().call()=='1.1.0'
    assert sponsor.functions.getSponsorAccount(a[4]).call()==old_account
    assert sponsor.functions.getSponsorFunding(a[4]).call()==old_funding
    assert sponsor.functions.voucherDigest(used[0]).call()==digest
    assert sponsor.functions.sponsorStorageLocation().call()==namespace
    assert sponsor.functions.platformAdmin().call()==a[0]
    assert sponsor.functions.voucherSigner().call()==a[1]
    assert sponsor.functions.isRelayer(a[2]).call()
    assert sponsor.functions.isOperationConsumed(used[0][0]).call()
    assert sponsor.functions.getSponsorPolicy(a[4]).call()==['0x'+'0'*40,False]
    assert send(c,sponsor,signed(c,sponsor,account,entry.address,tag='after-upgrade'))[0]['success']
    fails(c,sponsor.functions.withdrawSponsor(a[4],a[5],old_account[2]),a[5])

@pytest.fixture(scope='session')
def policy_build():
    spec=importlib.util.spec_from_file_location('allowance_compiler',REPO/'Tools/SolcCompiler/compile.py')
    compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(compiler)
    output=compiler.compile_contract(REPO/'Contracts/Templates/TenantAllowancePolicy.sol',solc_version='0.8.37',evm_version='osaka')
    return next(v for k,v in output.items() if k.rsplit(':',1)[-1]=='TenantAllowancePolicy')

def deploy_policy(c, artifact, sponsor, membership=None, tenant=None):
    a=c['accounts']
    factory=c['w3'].eth.contract(abi=artifact['abi'],bytecode=artifact['creation_bytecode'])
    receipt=tx(c,factory.constructor(sponsor.address,tenant or a[4],a[5],membership or '0x'+'0'*40,0,0,[]))
    return c['w3'].eth.contract(address=receipt.contractAddress,abi=artifact['abi'])

def attach(c, p, sponsor):
    tx(c,p.functions.setDefaultLimit(True,10**16,10**17),c['accounts'][5])
    tx(c,sponsor.functions.setSponsorPolicy(c['accounts'][4],p.address),c['accounts'][5])

def args(c,sponsor,account,dispatcher,**kwargs):
    voucher,data,_=signed(c,sponsor,account,dispatcher.address,**kwargs)
    value=list(voucher);value[-2]=(value[-4]+sponsor.functions.costOverheadGas(value[3]).call())*value[-3]
    sig=Account.unsafe_sign_hash(sponsor.functions.voucherDigest(tuple(value)).call(),c['tester'].backend.account_keys[1]).signature
    return tuple(value),data,sig

def send(c,sponsor,values):
    receipt=tx(c,sponsor.functions.executeSponsored(*values),c['accounts'][2])
    outcome=sponsor.events.SponsoredOperation().process_receipt(receipt,errors=DISCARD)[0]['args']
    cost=sponsor.events.RelayerReimbursed().process_receipt(receipt,errors=DISCARD)[0]['args']['reimbursement']
    return outcome,cost

def test_optional_policy_settles_same_cost_and_replay_cannot_double_charge(chain,policy_build):
    c=chain;account,sponsor,_,entry=setup(c);p=deploy_policy(c,policy_build,sponsor);attach(c,p,sponsor)
    before=sponsor.functions.getSponsorAccount(c['accounts'][4]).call()[2]
    values=args(c,sponsor,account,entry)
    outcome,cost=send(c,sponsor,values)
    assert outcome['success'] and cost>0
    enabled,_,daily,available,spent,reserved,_=p.functions.allowance(account.address).call()
    assert enabled and spent==cost and reserved==0 and available==daily-cost
    assert p.functions.pendingReservations().call()==0
    assert sponsor.functions.getSponsorAccount(c['accounts'][4]).call()[2]==before-cost
    fails(c,sponsor.functions.executeSponsored(*values),c['accounts'][2])
    assert p.functions.allowance(account.address).call()[4]==cost

def test_explicit_wallet_approval_does_not_grant_management(chain,policy_build):
    c=chain;account,sponsor,_,entry=setup(c);a=c['accounts']
    tx(c,sponsor.functions.setWalletApprovalRequired(a[4],True),a[5])
    values=args(c,sponsor,account,entry)
    fails(c,sponsor.functions.executeSponsored(*values),a[2])
    tx(c,sponsor.functions.setSponsoredWallet(a[4],account.address,1),a[5])
    assert send(c,sponsor,values)[0]['success']
    fails(c,sponsor.functions.setTenantLimits(a[4],1,1),account.address)
    fails(c,sponsor.functions.setSponsoredWallet(a[4],a[9],1),account.address)
    tx(c,sponsor.functions.setSponsoredWallet(a[4],account.address,2),a[5])
    tx(c,sponsor.functions.setWalletApprovalRequired(a[4],False),a[5])
    fails(c,sponsor.functions.executeSponsored(*args(c,sponsor,account,entry,tag='denied')),a[2])

def test_policy_scope_authority_defaults_and_two_step_ownership(chain,policy_build):
    c=chain;account,sponsor,_,entry=setup(c);a=c['accounts'];p=deploy_policy(c,policy_build,sponsor)
    wrong=deploy_policy(c,policy_build,sponsor,tenant=a[9])
    fails(c,sponsor.functions.setSponsorPolicy(a[4],wrong.address),a[5])
    fails(c,sponsor.functions.setSponsorPolicy(a[4],p.address),a[3])
    tx(c,sponsor.functions.setSponsorPolicy(a[4],p.address),a[5])
    fails(c,sponsor.functions.executeSponsored(*args(c,sponsor,account,entry)),a[2])
    fails(c,p.functions.reserve(Web3.keccak(text='forged'),a[3],1),a[5])
    fails(c,p.functions.setDefaultLimit(True,1,2),a[0])
    fails(c,p.functions.proposeOwner('0x'+'0'*40),a[5])
    tx(c,p.functions.proposeOwner(a[6]),a[5])
    fails(c,p.functions.acceptOwnership(),a[7])
    assert p.functions.owner().call()==a[5]
    tx(c,p.functions.acceptOwnership(),a[6])
    fails(c,p.functions.setPaused(True),a[5])
    tx(c,p.functions.setPaused(True),a[6])

def test_failed_inner_execution_is_charged_and_limits_never_reset_usage(chain,policy_build):
    c=chain;account,sponsor,_,entry=setup(c);a=c['accounts'];p=deploy_policy(c,policy_build,sponsor);attach(c,p,sponsor)
    outcome,cost=send(c,sponsor,args(c,sponsor,account,entry,signature=b''))
    assert not outcome['success'] and p.functions.allowance(account.address).call()[4]==cost
    tx(c,p.functions.setWalletLimit(account.address,True,False,0,0),a[5])
    fails(c,sponsor.functions.executeSponsored(*args(c,sponsor,account,entry,tag='revoked')),a[2])
    tx(c,p.functions.setWalletLimit(account.address,False,False,0,0),a[5])
    assert p.functions.allowance(account.address).call()[4]==cost
    values=args(c,sponsor,account,entry,tag='over-budget')
    maximum=values[0][-2]
    tx(c,p.functions.setDefaultLimit(True,maximum,maximum),a[5])
    fails(c,sponsor.functions.executeSponsored(*values),a[2])
    assert p.functions.pendingReservations().call()==0
    c['tester'].time_travel((c['w3'].eth.get_block('latest').timestamp//86400+1)*86400);c['tester'].mine_blocks(1)
    assert p.functions.allowance(account.address).call()[4]==0
    assert send(c,sponsor,args(c,sponsor,account,entry,tag='next-day'))[0]['success']

def mock(c,source,name,*parameters):
    output=solcx.compile_source(source,solc_version='0.8.37',evm_version='osaka',output_values=['abi','bin'])
    art=next(v for k,v in output.items() if k.endswith(':'+name))
    receipt=tx(c,c['w3'].eth.contract(abi=art['abi'],bytecode=art['bin']).constructor(*parameters))
    return c['w3'].eth.contract(address=receipt.contractAddress,abi=art['abi'])

def test_settlement_failure_rolls_back_user_execution_and_manager_can_detach(chain,policy_build):
    c=chain;account,sponsor,_,entry=setup(c);a=c['accounts']
    broken=mock(c,'''pragma solidity ^0.8.34; contract Broken {
        address public gasSponsor; address public sponsor;
        constructor(address g,address s){gasSponsor=g;sponsor=s;}
        function reserve(bytes32,address,uint) external pure returns(bytes4){return this.reserve.selector;}
        function settle(bytes32,uint) external pure returns(bytes4){revert();}
    }''','Broken',sponsor.address,a[4])
    tx(c,sponsor.functions.setSponsorPolicy(a[4],broken.address),a[5])
    balance=c['w3'].eth.get_balance(a[9]);values=args(c,sponsor,account,entry)
    fails(c,sponsor.functions.executeSponsored(*values),a[2])
    assert c['w3'].eth.get_balance(a[9])==balance and account.functions.getNonce().call()==0
    assert not sponsor.functions.isOperationConsumed(values[0][0]).call()
    tx(c,sponsor.functions.setSponsorPolicy(a[4],'0x'+'0'*40),a[5])
    assert send(c,sponsor,args(c,sponsor,account,entry))[0]['success']

def test_membership_tiers_default_and_nonmember_admin_override(chain,policy_build):
    c=chain;account,sponsor,_,entry=setup(c);a=c['accounts']
    registry=mock(c,'''pragma solidity ^0.8.34; contract Members {
        mapping(address=>uint) public tokenOf; mapping(address=>uint32) public tierOf; bool public registryLocked;
        function set(address a,uint id,uint32 tier) external {tokenOf[a]=id;tierOf[a]=tier;}
        mapping(uint32=>bool) public disabled;
        function tierActive(uint32 tier) external view returns(bool) {return tier!=0 && !disabled[tier];}
        function disable(uint32 tier,bool x) external {disabled[tier]=x;}
        function lock(bool x) external {registryLocked=x;}
    }''','Members')
    p=deploy_policy(c,policy_build,sponsor,membership=registry.address);attach(c,p,sponsor)
    assert not p.functions.allowance(account.address).call()[0]
    # An admin need not hold an end-user access token to receive an explicit allowance.
    tx(c,p.functions.setWalletLimit(account.address,True,True,10**16,10**17),a[5])
    assert send(c,sponsor,args(c,sponsor,account,entry,tag='admin'))[0]['success']
    tx(c,registry.functions.set(account.address,1,2))
    tx(c,p.functions.setWalletLimit(account.address,False,False,0,0),a[5])
    tx(c,p.functions.setTierLimit(2,True,True,10**16,10**17),a[5])
    _,cost=send(c,sponsor,args(c,sponsor,account,entry,tag='member'))
    previous=p.functions.allowance(account.address).call()[4]
    tx(c,registry.functions.disable(2,True))
    fails(c,sponsor.functions.executeSponsored(*args(c,sponsor,account,entry,tag='inactive-tier')),a[2])
    tx(c,registry.functions.disable(2,False))
    # The credential carries its history across an approved wallet transfer.
    tx(c,registry.functions.set(account.address,0,0));tx(c,registry.functions.set(a[8],1,2))
    assert p.functions.allowance(a[8]).call()[3]==10**17-cost
    # Re-issuing a credential to the same wallet preserves its wallet-level usage.
    tx(c,registry.functions.set(account.address,2,2))
    assert p.functions.allowance(account.address).call()[4]==previous
    tx(c,registry.functions.lock(True))
    fails(c,sponsor.functions.executeSponsored(*args(c,sponsor,account,entry,tag='locked')),a[2])

def test_admin_can_change_policy_and_disconnect_using_sponsored_execution(chain,policy_build):
    c=chain;account,sponsor,_,entry=setup(c);a=c['accounts'];p=deploy_policy(c,policy_build,sponsor);attach(c,p,sponsor)
    tx(c,p.functions.proposeOwner(account.address),a[5]);tx(c,p.functions.acceptOwnership(),account.address)
    tx(c,sponsor.functions.setSponsorManager(a[4],account.address))
    changed=bytes.fromhex(p.encode_abi('setDefaultLimit',args=[True,10**16,2*10**17])[2:])
    outcome,first=send(c,sponsor,args(c,sponsor,account,entry,inner=500000,calls=[(p.address,0,changed)],tag='admin-edit'))
    assert outcome['success'] and p.functions.allowance(account.address).call()[4]==first
    disconnect=bytes.fromhex(sponsor.encode_abi('setSponsorPolicy',args=[a[4],'0x'+'0'*40])[2:])
    outcome,second=send(c,sponsor,args(c,sponsor,account,entry,inner=500000,calls=[(sponsor.address,0,disconnect)],tag='admin-disconnect'))
    assert outcome['success'] and sponsor.functions.getSponsorPolicy(a[4]).call()[0]=='0x'+'0'*40
    assert p.functions.allowance(account.address).call()[4]==first+second
    assert p.functions.pendingReservations().call()==0
