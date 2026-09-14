"""Restore the exact released 1.1 runtime; use only ephemeral local EVM keys."""
import json
from pathlib import Path
import pytest
from web3 import Web3
import test_native_sponsorship as native
from test_native_sponsorship import builds, chain, tx, fails, at, paid, linked
from test_approved_sponsorship import upgrade
from test_tenant_allowances import policy_build, deploy_policy, attach, args, send, mock
from test_governance import ADMIN

REPO = Path(__file__).resolve().parents[2]
ARTIFACT = json.loads(next((REPO/'Releases/TenantAllowances/1.0.0').rglob('GasSponsor_artifact.json')).read_text())


def restore(c, sponsor):
    made = tx(c, c['w3'].eth.contract(abi=ARTIFACT['abi'], bytecode=ARTIFACT['creation_bytecode']).constructor())
    assert c['w3'].eth.get_code(made.contractAddress) == bytes.fromhex(ARTIFACT['runtime_bytecode'].removeprefix('0x'))
    tx(c, at(c, 'ProxyAdmin', ADMIN).functions.upgrade(sponsor.address, made.contractAddress))
    return c['w3'].eth.contract(address=sponsor.address, abi=ARTIFACT['abi'])


@pytest.fixture
def restored_setup(monkeypatch):
    original = native.setup
    def setup(c):
        account, sponsor, beacon, entry = original(c)
        sponsor = restore(c, upgrade(c, sponsor))
        assert sponsor.functions.implementationVersion().call() == '1.1.0'
        return account, sponsor, beacon, entry
    monkeypatch.setattr(native, 'setup', setup)
    return setup


@pytest.mark.parametrize('case', ['impossible_gas','wrong_voucher','wrong_relayer','changed_payload','wrong_tenant','paused','disabled','tenant_cap','expired'])
def test_restoration_keeps_envelope_security(chain, restored_setup, case):
    native.test_invalid_envelopes_do_not_consume_or_charge(chain, case)


def test_restoration_keeps_owner_signature_nonce_and_credit_custody(chain, restored_setup):
    native.test_owner_signature_and_account_nonce_remain_required(chain)


def test_restoration_keeps_nonwithdrawable_allocation(chain, restored_setup):
    native.test_treasury_credit_is_gas_only_and_refundable_deposits_stay_withdrawable(chain)


def test_existing_spending_policy_roles_and_consumed_operation_survive(chain, policy_build):
    c=chain; account,sponsor,_,entry=native.setup(c); a=c['accounts']
    policy=deploy_policy(c,policy_build,sponsor); attach(c,policy,sponsor)
    tx(c,sponsor.functions.setWalletApprovalRequired(a[4],True),a[5])
    tx(c,sponsor.functions.setSponsoredWallet(a[4],account.address,1),a[5])
    paid(c,sponsor.functions.depositGasCredit(a[4]),10**16)
    used=args(c,sponsor,account,entry,tag='used-before-restoration')
    assert send(c,sponsor,used)[0]['success']
    sponsor=upgrade(c,sponsor)
    candidate=args(c,sponsor,account,entry,tag='unlisted-application')
    fails(c,sponsor.functions.executeSponsored(*candidate),a[2])
    def snapshot():
        return [sponsor.functions.getSponsorAccount(a[4]).call(),sponsor.functions.getSponsorFunding(a[4]).call(),
            sponsor.functions.getSponsorPolicy(a[4]).call(),sponsor.functions.sponsoredWalletPermission(a[4],account.address).call(),
            sponsor.functions.platformAdmin().call(),sponsor.functions.voucherSigner().call(),sponsor.functions.isRelayer(a[2]).call(),
            sponsor.functions.isOperationConsumed(used[0][0]).call(),account.functions.getNonce().call(),policy.functions.allowance(account.address).call()]
    before=snapshot(); sponsor=restore(c,sponsor)
    assert snapshot()==before
    fails(c,sponsor.functions.executeSponsored(*used),a[2])
    assert send(c,sponsor,candidate)[0]['success']
    tx(c,policy.functions.setWalletLimit(account.address,True,False,0,0),a[5])
    fails(c,sponsor.functions.executeSponsored(*args(c,sponsor,account,entry,tag='policy-denied')),a[2])
    fails(c,sponsor.functions.setTenantLimits(a[4],1,1),a[3])


def test_independent_registry_allowed_but_official_registration_still_pays(chain, restored_setup):
    c=chain;account,sponsor,_,entry=restored_setup(c)
    independent=mock(c,'pragma solidity ^0.8.20; contract Independent { uint public count; function register() external {count++;} }','Independent')
    def operation(target,data,value=0,tag='custom'):
        return native.signed(c,sponsor,account,entry.address,inner=600000,calls=[(target,value,bytes.fromhex(data[2:]))],tag=tag)
    assert send(c,sponsor,operation(independent.address,independent.functions.register()._encode_transaction_data()))[0]['success']
    assert independent.functions.count().call()==1
    cm=linked(c,'CodeManager'); vault=c['accounts'][8]
    tx(c,cm.functions.voteToUpdateFeeVault(vault))
    gift=mock(c,'''pragma solidity ^0.8.20;
      interface CM {function registerUniqueIds(address,string memory,uint256) external payable;}
      contract Gift {address public codeManagerAddress; constructor(address m){codeManagerAddress=m;}
        function register() external payable {CM(codeManagerAddress).registerUniqueIds{value:msg.value}(address(this),"112311",1);}}
    ''','Gift',cm.address)
    data=gift.functions.register()._encode_transaction_data(); fee=cm.functions.registrationFee().call()
    assert not send(c,sponsor,operation(gift.address,data,tag='unpaid'))[0]['success']
    assert cm.functions.getIdentifierCounter(gift.address,'112311').call()[1]==0
    balance=c['w3'].eth.get_balance(vault)
    assert send(c,sponsor,operation(gift.address,data,fee,tag='paid'))[0]['success']
    assert cm.functions.getIdentifierCounter(gift.address,'112311').call()[1]==1
    assert c['w3'].eth.get_balance(vault)==balance+fee
