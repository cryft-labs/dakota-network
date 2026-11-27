"""Real isolated EVM approval enforcement; no live wallet keys or RPC.

GasSponsor 1.5.2 (fresh chain 113211, 2026-11-25): the engine under test is THIS source's ApprovedGasSponsor, linked fresh at
0x…FEeD (the released 1.2.0 artifact and the 1.1 -> 1.2 upgrade were the old chain's; replaying them is no longer a path). Adds
X-66: a non-genesis upgradeable proxy cannot be approved as if immutable.
"""
import importlib.util
import json
from pathlib import Path
import pytest
from web3 import Web3
from web3.logs import DISCARD
from test_native_sponsorship import builds, chain, setup, signed, tx, fails, linked, deploy, at, paid
from test_tenant_allowances import mock
from test_governance import ADMIN, upgrade

REPO=Path(__file__).resolve().parents[2]
ZERO='0x'+'0'*40


_APPROVED = {}


def approved_artifact():
    """This source's ApprovedGasSponsor (0.8.37, Osaka, 200 runs), compiled once per session."""
    if not _APPROVED:
        spec=importlib.util.spec_from_file_location('approved_compiler',REPO/'Tools/SolcCompiler/compile.py')
        compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(compiler)
        out=compiler.compile_contract(REPO/'Contracts/Genesis/7702/ApprovedGasSponsor.sol',solc_version='0.8.37',evm_version='osaka')
        _APPROVED.update(next(v for k,v in out.items() if k.rsplit(':',1)[-1]=='ApprovedGasSponsor'))
    return _APPROVED


def approved_setup(c):
    """native.setup with this source's ApprovedGasSponsor linked at 0x…FEeD."""
    return setup(c, approved_artifact())


def permission(c,target,signature,value=0,implementation=ZERO,canonical=False):
    return (target,Web3.keccak(text=signature)[:4],(Web3.keccak(c['w3'].eth.get_code(target)),implementation,
             Web3.keccak(c['w3'].eth.get_code(implementation)) if implementation!=ZERO else b'\0'*32,value,canonical,
             ADMIN if implementation!=ZERO else ZERO, Web3.keccak(c['w3'].eth.get_code(ADMIN)) if implementation!=ZERO else b'\0'*32))


def request(c,sponsor,account,entry,target,data,value=0,tag='approved'):
    return signed(c,sponsor,account,entry.address,inner=600000,calls=[(target,value,bytes.fromhex(data.removeprefix('0x')))],tag=tag)


def send(c,sponsor,args):
    receipt=tx(c,sponsor.functions.executeSponsored(*args),c['accounts'][2])
    return sponsor.events.SponsoredOperation().process_receipt(receipt,errors=DISCARD)[0]['args']['success']


def test_platform_signed_unapproved_calls_are_denied(chain):
    c=chain;account,sponsor,_,entry=approved_setup(c)
    assert sponsor.functions.implementationVersion().call()=='1.5.3'
    assert sponsor.functions.platformAdmin().call()==c['accounts'][0]
    before=sponsor.functions.getSponsorAccount(c['accounts'][4]).call()
    values=signed(c,sponsor,account,entry.address,tag='unauthorized')
    fails(c,sponsor.functions.executeSponsored(*values),c['accounts'][2])
    assert sponsor.functions.getSponsorAccount(c['accounts'][4]).call()==before
    assert not sponsor.functions.isOperationConsumed(c['accounts'][4],values[0][0]).call()
    assert account.functions.getNonce().call()==0


def test_tenant_manager_signer_and_user_cannot_grant_approval_or_initialize(chain):
    c=chain;account,sponsor,_,entry=approved_setup(c);target=deploy(c,'Value')
    p=permission(c,target.address,'value()')
    for who in (1,2,3,5):
        fails(c,sponsor.functions.setCallApprovals([p]),c['accounts'][who])
    assert not any(f.get('name')=='initializeCallApprovals' for f in sponsor.abi)      # gone since 1.5.1
    tx(c,sponsor.functions.setCallApprovals([p]))
    args=request(c,sponsor,account,entry,target.address,target.functions.value()._encode_transaction_data())
    assert send(c,sponsor,args)
    revoked=list(p);revoked[2]=(b'\0'*32,ZERO,b'\0'*32,0,False,ZERO,b'\0'*32)
    tx(c,sponsor.functions.setCallApprovals([tuple(revoked)]))
    fails(c,sponsor.functions.executeSponsored(*request(c,sponsor,account,entry,target.address,target.functions.value()._encode_transaction_data(),tag='revoked')),c['accounts'][2])


def test_clone_selector_value_and_mixed_batch_cannot_bypass(chain):
    c=chain;account,sponsor,_,entry=approved_setup(c)
    target,clone=deploy(c,'Value'),deploy(c,'Value')
    tx(c,sponsor.functions.setCallApprovals([permission(c,target.address,'value()')]))
    for address,data,value in [(clone.address,target.functions.value()._encode_transaction_data(),0),
        (target.address,'0x12345678',0),(target.address,'0x',0),
        (target.address,target.functions.value()._encode_transaction_data(),1)]:
        fails(c,sponsor.functions.executeSponsored(*request(c,sponsor,account,entry,address,data,value)),c['accounts'][2])
    calls=[(target.address,0,bytes.fromhex(target.functions.value()._encode_transaction_data()[2:])),(clone.address,0,b'1234')]
    values=signed(c,sponsor,account,entry.address,calls=calls)
    fails(c,sponsor.functions.executeSponsored(*values),c['accounts'][2])
    assert account.functions.getNonce().call()==0


def test_real_canonical_registration_pays_fee_and_manager_swap_blocks(chain):
    c=chain;account,sponsor,_,entry=approved_setup(c)
    cm=linked(c,'CodeManager');vault=c['accounts'][8]
    tx(c,cm.functions.voteToSetFeeVault(vault))
    gift=mock(c,'''pragma solidity ^0.8.20;
    interface CM { function registerUniqueIds(address,string memory,uint256) external payable; }
    contract Gift { address public codeManagerAddress;
      constructor(address m){codeManagerAddress=m;}
      function setManager(address m) external {codeManagerAddress=m;}
      function register(uint n) external payable {CM(codeManagerAddress).registerUniqueIds{value:msg.value}(address(this),"113211",n);}
    }''','Gift',cm.address)
    fee=cm.functions.registrationFee().call()
    tx(c,sponsor.functions.setCallApprovals([permission(c,gift.address,'register(uint256)',fee,canonical=True)]))
    data=gift.functions.register(1)._encode_transaction_data()
    balance=c['w3'].eth.get_balance(vault)
    assert not send(c,sponsor,request(c,sponsor,account,entry,gift.address,data,tag='unpaid'))
    assert cm.functions.getIdentifierCounter(gift.address,'113211').call()[1]==0
    assert send(c,sponsor,request(c,sponsor,account,entry,gift.address,data,fee,tag='paid'))
    assert c['w3'].eth.get_balance(vault)==balance+fee
    assert cm.functions.getIdentifierCounter(gift.address,'113211').call()[1]==1
    tx(c,gift.functions.setManager(c['accounts'][9]))
    fails(c,sponsor.functions.executeSponsored(*request(c,sponsor,account,entry,gift.address,data,fee,tag='wrong-manager')),c['accounts'][2])


def test_proxy_implementation_must_be_pinned_and_upgrade_invalidates_approval(chain):
    c=chain;account,sponsor,_,entry=approved_setup(c)
    cm=linked(c,'CodeManager');admin=at(c,'ProxyAdmin',ADMIN)
    implementation=admin.functions.getProxyImplementation(cm.address).call()
    fails(c,sponsor.functions.setCallApprovals([permission(c,cm.address,'registrationFee()')]))
    tx(c,sponsor.functions.setCallApprovals([permission(c,cm.address,'registrationFee()',implementation=implementation)]))
    args=request(c,sponsor,account,entry,cm.address,cm.functions.registrationFee()._encode_transaction_data())
    assert send(c,sponsor,args)
    upgrade(c,cm.address,deploy(c,'CodeManager').address)  # scheduled on the proxy, then executed (X-1)
    fails(c,sponsor.functions.executeSponsored(*request(c,sponsor,account,entry,cm.address,cm.functions.registrationFee()._encode_transaction_data(),tag='upgraded')),c['accounts'][2])


def test_policy_callback_cannot_change_manager_after_validation(chain):
    from eth_account import Account
    c=chain;account,sponsor,_,entry=approved_setup(c)
    cm=linked(c,'CodeManager')
    gift=mock(c,'''pragma solidity ^0.8.20; contract Gift {
        address public codeManagerAddress; uint public executions;
        constructor(address cm){codeManagerAddress=cm;}
        function setManager(address cm) external {codeManagerAddress=cm;}
        function run() external {executions++;}
    }''','Gift',cm.address)
    policy=mock(c,'''pragma solidity ^0.8.20;
      interface G {function setManager(address) external;}
      contract Change {address public gasSponsor;address public sponsor;address public gift;
        constructor(address g,address s,address t){gasSponsor=g;sponsor=s;gift=t;}
        function reserve(bytes32,address,uint) external returns(bytes4){G(gift).setManager(address(123));return this.reserve.selector;}
        function settle(bytes32,uint) external pure returns(bytes4){return this.settle.selector;}
      }''','Change',sponsor.address,c['accounts'][4],gift.address)
    tx(c,sponsor.functions.setCallApprovals([permission(c,gift.address,'run()',canonical=True)]))
    tx(c,sponsor.functions.setSponsorPolicy(c['accounts'][4],policy.address),c['accounts'][5])
    voucher,data,_=request(c,sponsor,account,entry,gift.address,gift.functions.run()._encode_transaction_data())
    v=list(voucher);v[-2]=(v[-4]+sponsor.functions.costOverheadGas(v[3]).call())*v[-3]
    sig=Account.unsafe_sign_hash(sponsor.functions.voucherDigest(tuple(v)).call(),c['tester'].backend.account_keys[1]).signature
    fails(c,sponsor.functions.executeSponsored(tuple(v),data,sig),c['accounts'][2])
    assert gift.functions.codeManagerAddress().call()==cm.address and gift.functions.executions().call()==0


def test_admin_seeds_permissions_without_changing_roles(chain):
    # 1.5.1 removed initializeCallApprovals: the platform admin seeds them after the link (setCallApprovals).
    c=chain;account,sponsor,_,entry=approved_setup(c);target=deploy(c,'Value')
    p=permission(c,target.address,'value()')
    fails(c,sponsor.functions.executeSponsored(*request(c,sponsor,account,entry,target.address,target.functions.value()._encode_transaction_data(),tag='unseeded')),c['accounts'][2])
    tx(c,sponsor.functions.setCallApprovals([p]))
    assert tuple(sponsor.functions.getCallApproval(target.address,p[1]).call())==p[2]
    assert sponsor.functions.platformAdmin().call()==c['accounts'][0]
    assert send(c,sponsor,request(c,sponsor,account,entry,target.address,target.functions.value()._encode_transaction_data()))


PROXIES='''pragma solidity ^0.8.20;
contract Impl { function value() external pure returns (uint256) { return 42; } }
contract SlotProxy {            // an EIP-1967 proxy (as OZ ERC1967Proxy / TransparentUpgradeableProxy keep their implementation)
    bytes32 private constant S = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    constructor(address i) { assembly { sstore(S, i) } }
    function upgradeTo(address i) external { assembly { sstore(S, i) } }
    fallback() external payable { assembly { let i := sload(S) calldatacopy(0, 0, calldatasize())
        let r := delegatecall(gas(), i, 0, calldatasize(), 0, 0) returndatacopy(0, 0, returndatasize())
        switch r case 0 { revert(0, returndatasize()) } default { return(0, returndatasize()) } } }
}
contract BeaconProxy {          // an EIP-1967 beacon proxy (the beacon slot)
    bytes32 private constant B = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    constructor(address b) { assembly { sstore(B, b) } }
    function beacon() external view returns (address b) { assembly { b := sload(B) } }
}
'''


def test_a_non_genesis_upgradeable_proxy_cannot_be_approved_as_immutable(chain):
    # X-66 (1.5.2). Before: implementation == 0 was checked against the proxy's constant codehash only, so an OZ-style proxy's
    # approval survived any upgrade behind it. Now its code is scanned for the EIP-1967 implementation and beacon slots.
    c=chain;account,sponsor,_,entry=approved_setup(c)
    impl=mock(c,PROXIES,'Impl'); proxy=mock(c,PROXIES,'SlotProxy',impl.address); beacon=mock(c,PROXIES,'BeaconProxy',impl.address)
    for target in (proxy, beacon):
        fails(c,sponsor.functions.setCallApprovals([permission(c,target.address,'value()')]))
    plain=permission(c,impl.address,'value()')                     # the plain contract behind it is immutable: approvable
    tx(c,sponsor.functions.setCallApprovals([plain]))
    assert tuple(sponsor.functions.getCallApproval(impl.address,plain[1]).call())==plain[2]
