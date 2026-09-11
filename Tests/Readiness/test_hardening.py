"""Fixed-behavior regressions on isolated EVMs; no real keys or remote RPC."""
from pathlib import Path
import importlib.util
import sys
import pytest
import solcx
from eth_tester.exceptions import TransactionFailed
from web3 import Web3

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'Tests/Governance'))
from test_governance import builds as base_builds, chain, tx, fails, deploy, at, linked, ADDRESSES, members_hash


@pytest.fixture(scope='session')
def builds(tmp_path_factory):
    result = base_builds.__wrapped__(tmp_path_factory)
    spec=importlib.util.spec_from_file_location('readiness_compiler', REPO/'Tools/SolcCompiler/compile.py')
    compiler=importlib.util.module_from_spec(spec); spec.loader.exec_module(compiler)
    for name,path,evm in [('PrivateComboStorage','CodeManagement/PrivateComboStorage.sol','shanghai'),
                          ('CryftGreetingCards','Tokens/GreetingCards.sol','osaka')]:
        artifacts=compiler.compile_contract(REPO/'Contracts'/path,solc_version=compiler.DEFAULT_SOLC_VERSION,evm_version=evm)
        result[name]=next(a for k,a in artifacts.items() if k.rsplit(':',1)[-1]==name)
    source='''pragma solidity ^0.8.19;
interface CM { function registerUniqueIds(address,string calldata,uint256) external payable; function setRegistrationOperator(address,bool) external; }
contract Gift {
    bool public broken; uint public delivered; address public recipient;
    function setBroken(bool b) external { broken=b; }
    function register(address cm,uint count) external payable { CM(cm).registerUniqueIds{value:msg.value}(address(this),"112311",count); }
    function permit(address cm,address registrar,bool allowed) external { CM(cm).setRegistrationOperator(registrar,allowed); }
    function recordRedemption(string calldata,address r) external { require(!broken,"broken"); delivered++; recipient=r; }
}
contract Echo {
    fallback() external {
        assembly { calldatacopy(0,0,calldatasize())
            if eq(byte(0,calldataload(0)),255) { revert(0,calldatasize()) }
            return(0,calldatasize()) }
    }
}
'''
    for key,a in solcx.compile_source(source,solc_version='0.8.19',output_values=['abi','bin','bin-runtime']).items():
        result[key.split(':')[-1]]={'abi':a['abi'],'creation_bytecode':'0x'+a['bin'],'runtime_bytecode':'0x'+a['bin-runtime']}
    return result


def paid(c, fn, value, sender=None):
    r=c['w3'].eth.wait_for_transaction_receipt(fn.transact({'from':sender or c['accounts'][0],'value':value,'gas':24000000}))
    assert r.status==1
    return r


def manager(c):
    cm=linked(c,'CodeManager')
    tx(c,cm.functions.voteToUpdateFeeVault(c['accounts'][9]))
    return cm


def registered(c,cm,gift,count=1):
    paid(c,gift.functions.register(cm.address,count),cm.functions.registrationFee().call()*count)
    identifier,counter=cm.functions.getIdentifierCounter(gift.address,'112311').call()
    return identifier+'-'+str(counter)


def proxy_contract(c,name,args,initializer='initialize'):
    logic=deploy(c,name)
    proxy=at(c,'TransparentUpgradeableProxy',ADDRESSES['proxy'])
    data=bytes.fromhex(getattr(logic.functions,initializer)(*args)._encode_transaction_data()[2:])
    tx(c,proxy.functions.proxy_linkLogicAdmin(logic.address,data))
    return at(c,name,proxy.address)


def test_gas_migration_rejects_uninitialized_and_non_voter(chain):
    c=chain; logic=deploy(c,'GasManager'); p=at(c,'TransparentUpgradeableProxy',ADDRESSES['GasManager'])
    tx(c,p.functions.proxy_linkLogicAdmin(logic.address,b''))
    gm=at(c,'GasManager',p.address)
    fails(c,gm.functions.initializeV2())
    tx(c,gm.functions.initializeWithVoter(c['accounts'][0]))
    fails(c,gm.functions.initializeV2(),c['accounts'][1])
    tx(c,gm.functions.initializeV2())
    assert gm.functions.fundApprovalBlockThreshold().call()==1000
    fails(c,gm.functions.initializeV2())


def test_proxy_combined_controller_capacity_and_removal(chain):
    c=chain; p=at(c,'TransparentUpgradeableProxy',ADDRESSES['proxy']); a=c['accounts']
    tx(c,p.functions.proxy_addOverlord(a[1])); tx(c,p.functions.proxy_addOverlord(a[2]))
    roots=[a[0]]+[Web3.to_checksum_address('0x'+format(0x100000+i,'040x')) for i in range(63)]
    tx(c,c['registry'].functions.voteToSetRootConfiguration(roots,[],members_hash(c,roots)))
    assert len(p.functions.proxy_getGovernanceMembers().call())==66
    tx(c,p.functions.proxy_removeOverlord(a[1]))
    assert len(p.functions.proxy_getGovernanceMembers().call())==65
    tx(c,p.functions.proxy_removeOverlord(a[2]))
    assert len(p.functions.proxy_getGovernanceMembers().call())==64


@pytest.mark.parametrize('size',[1,63,64,65,4096,65536])
def test_proxy_forwards_exact_arbitrary_data(chain,size):
    c=chain; echo=deploy(c,'Echo'); p=at(c,'TransparentUpgradeableProxy',ADDRESSES['proxy'])
    tx(c,p.functions.proxy_linkLogicAdmin(echo.address,b''))
    data=b'\x7a'*size
    assert bytes(c['w3'].eth.call({'to':p.address,'data':data,'gas':24000000}))==data
    with pytest.raises(Exception): c['w3'].eth.call({'to':p.address,'data':b'\xff'+data,'gas':24000000})


def test_registration_authority_prevents_third_party_counter_drift(chain):
    c=chain; cm=manager(c); gift=deploy(c,'Gift'); a=c['accounts']
    registered(c,cm,gift)
    with pytest.raises(Exception): cm.functions.registerUniqueIds(gift.address,'112311',1).call({'from':a[5],'value':cm.functions.registrationFee().call()})
    tx(c,gift.functions.permit(cm.address,a[5],True))
    paid(c,cm.functions.registerUniqueIds(gift.address,'112311',1),cm.functions.registrationFee().call(),a[5])
    assert cm.functions.getIdentifierCounter(gift.address,'112311').call()[1]==2


def test_uid_alias_overflow_and_mixed_batch_are_safe(chain):
    c=chain; cm=manager(c); gift=deploy(c,'Gift'); a=c['accounts']; uid=registered(c,cm,gift)
    tx(c,cm.functions.voteToSetPrivacyGroupGift(a[6],gift.address,True))
    prefix=uid.rsplit('-',1)[0]
    invalid=[prefix+'-01',prefix+'-0',prefix+'-'+'9'*80,prefix+'-/',prefix+'-1-1']
    for bad in invalid:
        assert not cm.functions.validateUniqueId(bad).call()
        tx(c,cm.functions.recordRedemption(bad,a[4]),a[6])
    tx(c,cm.functions.setUniqueIdActiveBatch([invalid[2],uid],[True,False]),a[6])
    assert not cm.functions.isUniqueIdActive(uid).call()
    assert gift.functions.delivered().call()==0


def test_scoped_groups_cannot_mutate_other_gifts(chain):
    c=chain; cm=manager(c); a=c['accounts']; g1=deploy(c,'Gift'); g2=deploy(c,'Gift')
    u1=registered(c,cm,g1); u2=registered(c,cm,g2)
    tx(c,cm.functions.voteToSetPrivacyGroupGift(a[6],g1.address,True))
    tx(c,cm.functions.voteToSetPrivacyGroupGift(a[7],g2.address,True))
    tx(c,cm.functions.recordRedemption(u2,a[4]),a[6])
    tx(c,cm.functions.setUniqueIdActiveBatch([u2],[False]),a[6])
    assert cm.functions.isUniqueIdActive(u2).call()
    assert not cm.functions.isUniqueIdRedeemed(u2).call()
    fails(c,cm.functions.validateUniqueIdsOrRevert([u2]),a[6])
    tx(c,cm.functions.recordRedemption(u1,a[4]),a[6])
    assert g1.functions.delivered().call()==1


def test_delivery_retry_preserves_recipient_and_is_idempotent(chain):
    c=chain; cm=manager(c); a=c['accounts']; gift=deploy(c,'Gift'); uid=registered(c,cm,gift)
    tx(c,cm.functions.voteToSetPrivacyGroupGift(a[6],gift.address,True))
    tx(c,gift.functions.setBroken(True))
    tx(c,cm.functions.recordRedemption(uid,a[4]),a[6])
    assert cm.functions.getRedemptionDelivery(uid).call()==[a[4],False,1]
    tx(c,cm.functions.recordRedemption(uid,a[5]),a[6])
    assert cm.functions.getRedemptionRecipient(uid).call()==a[4]
    tx(c,gift.functions.setBroken(False))
    tx(c,cm.functions.retryRedemptionDelivery(uid),a[8])
    tx(c,cm.functions.retryRedemptionDelivery(uid),a[9])
    assert gift.functions.delivered().call()==1
    assert cm.functions.getRedemptionDelivery(uid).call()==[a[4],True,2]


def test_strict_redemption_rejects_preconditions_but_preserves_delivery_repair(chain):
    c=chain; cm=manager(c); a=c['accounts']; gift=deploy(c,'Gift'); uid=registered(c,cm,gift)
    tx(c,cm.functions.voteToSetPrivacyGroupGift(a[6],gift.address,True))
    tx(c,cm.functions.setUniqueIdActiveBatch([uid],[False]),a[6])
    fails(c,cm.functions.recordRedemptionStrict(uid,a[4]),a[6])
    assert not cm.functions.isUniqueIdRedeemed(uid).call()
    assert cm.functions.getRedemptionDelivery(uid).call()==['0x'+'0'*40,False,0]
    # Existing callers retain the original best-effort ABI.
    tx(c,cm.functions.recordRedemption(uid,a[4]),a[6])
    assert not cm.functions.isUniqueIdRedeemed(uid).call()
    tx(c,cm.functions.setUniqueIdActiveBatch([uid],[True]),a[6])
    fails(c,cm.functions.recordRedemptionStrict(uid,'0x'+'0'*40),a[6])
    fails(c,cm.functions.recordRedemptionStrict(uid,a[4]),a[7])
    tx(c,gift.functions.setBroken(True))
    tx(c,cm.functions.recordRedemptionStrict(uid,a[4]),a[6])
    assert cm.functions.getRedemptionDelivery(uid).call()==[a[4],False,1]
    fails(c,cm.functions.recordRedemptionStrict(uid,a[4]),a[6])
    tx(c,gift.functions.setBroken(False))
    tx(c,cm.functions.retryRedemptionDelivery(uid),a[8])
    assert cm.functions.getRedemptionDelivery(uid).call()==[a[4],True,2]


def private(c):
    p=proxy_contract(c,'PrivateComboStorage',(c['accounts'][0],c['accounts'][1],'0x'+'0'*40))
    tx(c,p.functions.setContractIdentifierWhitelist(['review'],[True]))
    tx(c,p.functions.syncRegisteredCodeCountBatch(['review'],[100]))
    return p


def test_private_roles_rotate_and_native_mode_needs_no_forwarder(chain):
    c=chain;p=private(c);a=c['accounts']
    assert p.functions.TRUSTED_FORWARDER().call()=='0x'+'0'*40
    assert not p.functions.isTrustedForwarder('0x'+'0'*40).call()
    fails(c,p.functions.initialize(a[5],a[5],a[5]))
    fails(c,p.functions.transferAdmin(p.address))
    tx(c,p.functions.transferAdmin(a[4]))
    assert p.functions.ADMIN().call()==a[0]
    fails(c,p.functions.acceptAdmin(),a[5])
    tx(c,p.functions.acceptAdmin(),a[4])
    fails(c,p.functions.setAuthorized(a[0]),a[0])
    tx(c,p.functions.setAuthorized(a[4]),a[4])
    assert p.functions.ADMIN().call()==a[4]


def test_private_batch_does_not_overwrite_same_pin_hash(chain):
    c=chain;p=private(c)
    h=Web3.keccak(text='same-code');e=Web3.keccak(text='same-entropy');z='0x'+'0'*40
    request=('review',[1,2],[h,h],1,False,[e,e],[z,z],[False,False])
    pins=p.functions.storeDataBatch(request).call({'from':c['accounts'][0]})
    tx(c,p.functions.storeDataBatch(request))
    assert pins[0]!=pins[1]
    assert p.functions.pinToHash(pins[0],h).call()[1]==1
    assert p.functions.pinToHash(pins[1],h).call()[1]==2


def test_private_batch_respects_pin_capacity(chain):
    c=chain;p=private(c);e=Web3.keccak(text='same-entropy');z='0x'+'0'*40
    request=('review',list(range(1,34)),[Web3.keccak(text=str(i)) for i in range(33)],1,False,[e]*33,[z]*33,[False]*33)
    pins=p.functions.storeDataBatch(request).call({'from':c['accounts'][0]})
    tx(c,p.functions.storeDataBatch(request))
    assert sum(p.functions.pinSlotCount(pin).call() for pin in set(pins))==33
    assert max(p.functions.pinSlotCount(pin).call() for pin in set(pins))<=32


def test_cards_safe_parser_owner_acceptance_and_supply_registration(chain):
    c=chain;cm=manager(c);a=c['accounts']
    card=proxy_contract(c,'CryftGreetingCards',('Cards','CARD','ipfs://test/',cm.address,'112311',a[4]),'initializeWithOwner')
    assert card.functions.owner().call()==a[4]
    for uid in ['review-/','review-'+'9'*80,'review-01']:
        with pytest.raises(TransactionFailed, match='Unknown uniqueId'):
            card.functions.getTokenForUniqueId(uid).call()
    fails(c,card.functions.renounceOwnership(),a[4])
    fails(c,card.functions.transferOwnership(card.address),a[4])
    tx(c,card.functions.transferOwnership(a[5]),a[4])
    assert card.functions.owner().call()==a[4]
    tx(c,card.functions.acceptOwnership(),a[5])
    fails(c,card.functions.setPaused(True),a[4])
    fee=cm.functions.registrationFee().call()
    paid(c,card.functions.setMaxSaleSupply(2),fee*2,a[5])
    with pytest.raises(Exception): cm.functions.registerUniqueIds(card.address,'112311',1).call({'from':a[3],'value':fee})
    paid(c,card.functions.setMaxSaleSupply(3),fee,a[5])
    assert card.functions.maxSaleSupply().call()==3
