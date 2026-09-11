"""Real EIP-7702 authorizations in an isolated local EVM, using ephemeral keys."""
from pathlib import Path
import sys
import pytest
import solcx
from eth_account import Account
from web3 import Web3
from web3.logs import DISCARD

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Governance'))
from test_governance import builds, chain, tx, fails, deploy, at, linked, ADDRESSES


def paid(c, fn, value, sender=None):
    r = c['w3'].eth.wait_for_transaction_receipt(fn.transact({'from':sender or c['accounts'][0], 'value':value, 'gas':24000000}))
    assert r.status == 1
    return r


def authorize(c, target, data=b''):
    w3=c['w3']; a=c['accounts']; keys=c['tester'].backend.account_keys
    auth=Account.sign_authorization({'chainId':w3.eth.chain_id,'address':target,'nonce':w3.eth.get_transaction_count(a[3])},keys[3])
    signed=Account.sign_transaction({'chainId':w3.eth.chain_id,'nonce':w3.eth.get_transaction_count(a[0]),'to':a[3],
        'data':data,'gas':1000000,'maxFeePerGas':2*10**9,'maxPriorityFeePerGas':10**9,'authorizationList':[auth]},keys[0])
    r=w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))
    assert r.status==1


def setup(c):
    a=c['accounts']; logic=deploy(c,'DakotaDelegation'); beacon=deploy(c,'DakotaDelegationBeacon',logic.address)
    dispatcher=deploy(c,'DakotaDelegationBeaconDispatcher',beacon.address)
    authorize(c, dispatcher.address)
    account=at(c,'DakotaDelegation',a[3])
    sponsor=linked(c,'GasSponsor',args=(a[0],a[1],dispatcher.address,100000))
    tx(c,sponsor.functions.configureSponsor(a[4],Web3.keccak(text='tenant'),a[5],10**17,10**18,True))
    paid(c,sponsor.functions.depositFor(a[4]),10**18)
    tx(c,sponsor.functions.setRelayer(a[2],True)); tx(c,sponsor.functions.setPaused(False))
    return account, sponsor, beacon, dispatcher


def signed(c, sponsor, account, entry, *, inner=100000, outer=None, tag='operation', nonce=None, signature=None, calls=None):
    a=c['accounts']; w3=c['w3']; op=Web3.keccak(text=tag); deadline=w3.eth.get_block('latest').timestamp+3600
    calls=calls or [(a[9],123456789,b'')]
    nonce=account.functions.getNonce().call() if nonce is None else nonce
    request=(op,sponsor.address,calls,nonce,deadline,inner)
    if signature is None:
        digest=account.functions.getExecutionDigest(*request).call()
        signature=Account.unsafe_sign_hash(digest,c['tester'].backend.account_keys[3]).signature
    data=bytes.fromhex(account.functions.executeSponsored(request,signature)._encode_transaction_data()[2:])
    if outer is None: outer=sponsor.functions.minimumCallGas(inner,len(data)).call()
    voucher=(op,Web3.keccak(text='tenant'),Web3.keccak(text='campaign'),a[4],account.address,a[2],entry,Web3.keccak(data),outer,10**9,(outer+100000)*10**9,deadline)
    vsig=Account.unsafe_sign_hash(sponsor.functions.voucherDigest(voucher).call(),c['tester'].backend.account_keys[1]).signature
    return voucher,data,vsig


def submit(c, sponsor, args):
    r=tx(c,sponsor.functions.executeSponsored(*args),c['accounts'][2])
    return sponsor.events.SponsoredOperation().process_receipt(r,errors=DISCARD)[0]['args']


@pytest.mark.parametrize('inner',[100000,1000000,4500000])
def test_direct_delegation_minimum_envelope_executes_without_account_linking(chain,inner):
    c=chain; account,sponsor,_,dispatcher=setup(c)
    assert sponsor.functions.isDelegationReady(account.address).call()
    assert c['w3'].eth.get_code(account.address).hex()=='ef0100'+dispatcher.address[2:].lower()
    assert int.from_bytes(c['w3'].eth.get_storage_at(account.address, int('360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',16)),'big')==0
    before=c['w3'].eth.get_balance(c['accounts'][9])
    args=signed(c,sponsor,account,dispatcher.address,inner=inner)
    assert submit(c,sponsor,args)['success']
    assert account.functions.getNonce().call()==1
    assert c['w3'].eth.get_balance(c['accounts'][9])-before==123456789
    assert sponsor.functions.isOperationConsumed(args[0][0]).call()
    fails(c,sponsor.functions.executeSponsored(*args),c['accounts'][2])


@pytest.mark.parametrize('case',['impossible_gas','wrong_voucher','wrong_relayer','changed_payload','wrong_tenant','paused','disabled','tenant_cap','expired'])
def test_invalid_envelopes_do_not_consume_or_charge(chain,case):
    c=chain; account,sponsor,_,dispatcher=setup(c); a=c['accounts']
    kwargs={'inner':4900000,'outer':5000000} if case=='impossible_gas' else {}
    voucher,data,sig=signed(c,sponsor,account,dispatcher.address,**kwargs); caller=a[2]
    if case=='wrong_voucher': sig=b''
    elif case=='wrong_relayer': caller=a[7]
    elif case=='changed_payload': data+=b'\0'
    elif case=='wrong_tenant':
        values=list(voucher); values[1]=Web3.keccak(text='other'); voucher=tuple(values)
        sig=Account.unsafe_sign_hash(sponsor.functions.voucherDigest(voucher).call(),c['tester'].backend.account_keys[1]).signature
    elif case=='paused': tx(c,sponsor.functions.setPaused(True))
    elif case=='disabled': tx(c,sponsor.functions.setTenantEnabled(a[4],False),a[5])
    elif case=='tenant_cap': tx(c,sponsor.functions.setTenantLimits(a[4],1,1),a[5])
    elif case=='expired': c['tester'].time_travel(voucher[-1]+1); c['tester'].mine_blocks(1)
    before=sponsor.functions.getSponsorAccount(a[4]).call()[2]
    receipt=c['w3'].eth.wait_for_transaction_receipt(sponsor.functions.executeSponsored(voucher,data,sig).transact({'from':caller,'gas':12000000}))
    assert receipt.status==0
    assert sponsor.functions.getSponsorAccount(a[4]).call()[2]==before
    assert not sponsor.functions.isOperationConsumed(voucher[0]).call()
    assert account.functions.getNonce().call()==0


def test_owner_signature_and_account_nonce_remain_required(chain):
    c=chain; account,sponsor,_,dispatcher=setup(c)
    args=signed(c,sponsor,account,dispatcher.address,signature=b'')
    assert not submit(c,sponsor,args)['success']
    assert account.functions.getNonce().call()==0
    assert sponsor.functions.isOperationConsumed(args[0][0]).call()  # submitted execution failure is charged, by policy
    args=signed(c,sponsor,account,dispatcher.address,tag='valid')
    assert submit(c,sponsor,args)['success']
    args=signed(c,sponsor,account,dispatcher.address,tag='stale-owner-nonce',nonce=0)
    assert not submit(c,sponsor,args)['success']
    assert account.functions.getNonce().call()==1


def test_wrong_eoa_designation_and_legacy_proxy_are_not_approved(chain):
    c=chain; account,sponsor,_,dispatcher=setup(c)
    # An EOA may set its own code designation; this does not change sponsor approval.
    other=deploy(c,'Value'); authorize(c,other.address,bytes.fromhex(other.functions.value()._encode_transaction_data()[2:]))
    assert not sponsor.functions.isDelegationReady(account.address).call()
    fails(c,sponsor.functions.setApprovedDelegate(ADDRESSES['DakotaDelegationRegistry']))
    authorize(c,dispatcher.address)
    assert sponsor.functions.isDelegationReady(account.address).call()


def test_registry_agrees_with_sponsor_and_beacon_upgrade_preserves_nonce(chain):
    c=chain; account,sponsor,beacon,dispatcher=setup(c); a=c['accounts']
    registry=linked(c,'DakotaDelegationRegistry',args=(dispatcher.address,beacon.address,sponsor.address,a[0]),initializer='initializeWithAdmin')
    assert registry.functions.delegationEntry().call()==dispatcher.address
    assert registry.functions.isAccountReady(account.address).call()
    assert registry.functions.expectedAccountCodeHash().call()==Web3.keccak(c['w3'].eth.get_code(account.address))
    assert submit(c,sponsor,signed(c,sponsor,account,dispatcher.address))['success']
    logic=deploy(c,'DakotaDelegation'); tx(c,beacon.functions.upgradeTo(logic.address))
    assert account.functions.getNonce().call()==1
    assert sponsor.functions.isDelegationReady(account.address).call()
    assert submit(c,sponsor,signed(c,sponsor,account,dispatcher.address,tag='after-upgrade'))['success']
    assert account.functions.getNonce().call()==2


def test_treasury_credit_is_gas_only_and_refundable_deposits_stay_withdrawable(chain):
    c=chain; account,sponsor,_,dispatcher=setup(c); a=c['accounts']
    gm=linked(c,'GasManager'); amount=10**16
    c['w3'].eth.wait_for_transaction_receipt(c['w3'].eth.send_transaction({'from':a[0],'to':gm.address,'value':amount,'gas':100000}))
    key,_=gm.functions.proposeSponsorFunding('gas-only',a[4],amount,'restricted gas').call({'from':a[0]})
    tx(c,gm.functions.proposeSponsorFunding('gas-only',a[4],amount,'restricted gas'))
    tx(c,gm.functions.executeSponsorFunding(key),a[4])
    assert sponsor.functions.getSponsorFunding(a[4]).call()==[10**18,amount]
    tx(c,sponsor.functions.withdrawSponsor(a[4],a[9],10**18),a[5])
    fails(c,sponsor.functions.withdrawSponsor(a[4],a[9],1),a[5])
    assert submit(c,sponsor,signed(c,sponsor,account,dispatcher.address))['success']
    refundable,credit=sponsor.functions.getSponsorFunding(a[4]).call()
    assert refundable==0 and 0<credit<amount
    fails(c,sponsor.functions.recoverGasCredit(a[4],a[9],1),a[5])
    tx(c,sponsor.functions.recoverGasCredit(a[4],a[9],credit))
    assert sponsor.functions.getSponsorFunding(a[4]).call()==[0,0]


@pytest.mark.parametrize('size,success',[(4096,True),(4097,False)])
def test_target_returndata_is_bounded_and_reverts_target_effects(chain,size,success):
    c=chain; account,sponsor,_,dispatcher=setup(c)
    code='''pragma solidity ^0.8.19; contract ReturnData { uint public calls;
    function run(uint size) external { calls++; assembly { return(0,size) } } }'''
    art=next(iter(solcx.compile_source(code,solc_version='0.8.19',output_values=['abi','bin']).values()))
    r=tx(c,c['w3'].eth.contract(abi=art['abi'],bytecode=art['bin']).constructor())
    target=c['w3'].eth.contract(address=r.contractAddress,abi=art['abi'])
    calls=[(target.address,0,bytes.fromhex(target.functions.run(size)._encode_transaction_data()[2:]))]
    args=signed(c,sponsor,account,dispatcher.address,inner=250000,calls=calls)
    assert submit(c,sponsor,args)['success']==success
    assert target.functions.calls().call()==int(success)
    assert account.functions.getNonce().call()==int(success)
