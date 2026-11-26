"""The open engine (base GasSponsor, no platform call approvals) on a fresh link; only ephemeral local EVM keys.

GasSponsor 1.5.2 (fresh chain 113211, 2026-11-25): this file used to restore the released 1.1 runtime over the 1.2 upgrade (the old
chain's rollback drill). Neither release exists on the fresh chain and ProxyAdmin upgrades are now scheduled (X-1), so these are
fresh-link tests of the same properties on this source's base GasSponsor.
"""
import pytest
from web3 import Web3
import test_native_sponsorship as native
from test_native_sponsorship import builds, chain, tx, fails, at, paid, linked  # noqa: F401
from test_tenant_allowances import policy_build, deploy_policy, attach, args, send, mock  # noqa: F401


def test_spending_policy_roles_and_consumed_operation(chain, policy_build):
    c=chain; account,sponsor,_,entry=native.setup(c); a=c['accounts']
    policy=deploy_policy(c,policy_build,sponsor); attach(c,policy,sponsor)
    tx(c,sponsor.functions.setWalletApprovalRequired(a[4],True),a[5])
    unlisted=args(c,sponsor,account,entry,tag='unlisted-wallet')
    fails(c,sponsor.functions.executeSponsored(*unlisted),a[2])                       # approval required, wallet not approved
    tx(c,sponsor.functions.setSponsoredWallet(a[4],account.address,1),a[5])
    paid(c,sponsor.functions.depositGasCredit(a[4]),10**16)
    used=args(c,sponsor,account,entry,tag='used')
    assert send(c,sponsor,used)[0]['success']
    assert sponsor.functions.isOperationConsumed(a[4],used[0][0]).call()
    fails(c,sponsor.functions.executeSponsored(*used),a[2])                           # replay refused
    assert send(c,sponsor,args(c,sponsor,account,entry,tag='open-target'))[0]['success']  # the open engine: any target
    tx(c,policy.functions.setWalletLimit(account.address,True,False,0,0),a[5])
    fails(c,sponsor.functions.executeSponsored(*args(c,sponsor,account,entry,tag='policy-denied')),a[2])
    fails(c,sponsor.functions.setTenantLimits(a[4],1,1),a[3])


def test_independent_registry_allowed_but_official_registration_still_pays(chain):
    c=chain;account,sponsor,_,entry=native.setup(c)
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
