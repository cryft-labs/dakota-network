"""Private upgrade compatibility, numeric-only assignment, collisions and authorization."""
import json
from pathlib import Path
from web3 import Web3,EthereumTesterProvider
import pytest

def test_numeric_prefix_upgrade_preserves_legacy_state():
    repo=Path(__file__).resolve().parents[2];workspace=repo.parents[2]
    old=workspace/'outputs/paladin-live-20260911/artifacts'
    artifacts={name:json.loads((old/name/'artifact.json').read_text()) for name in ['PrivateComboStorageStrict','ManagedProxyAdmin','ManagedApplicationProxy']}
    artifacts['Numeric']=json.loads((repo/'Contracts/Verification/20260915/PrivateComboStorage/artifact.json').read_text())
    w=Web3(EthereumTesterProvider());admin,service,stranger=w.eth.accounts[:3];zero='0x'+'0'*40;identifier='0x'+'12'*32
    def send(fn,sender=admin):
        receipt=w.eth.wait_for_transaction_receipt(fn.transact({'from':sender,'gas':14000000}));assert receipt.status==1;return receipt
    def deploy(name,*args):
        art=artifacts[name];r=send(w.eth.contract(abi=art['abi'],bytecode=art['creation_bytecode']).constructor(*args));return w.eth.contract(address=r.contractAddress,abi=art['abi'])
    logic=deploy('PrivateComboStorageStrict');manager=deploy('ManagedProxyAdmin',admin)
    init=bytes.fromhex(logic.functions.initialize(admin,service,zero)._encode_transaction_data()[2:])
    proxy=deploy('ManagedApplicationProxy',logic.address,manager.address,init)
    contract=w.eth.contract(address=proxy.address,abi=artifacts['PrivateComboStorageStrict']['abi'])
    send(contract.functions.setContractIdentifierWhitelist([identifier],[True]));send(contract.functions.syncRegisteredCodeCountBatch([identifier],[1000]))
    def request(counters,length=3,special=False,entropy=1):
        return [identifier,counters,[w.keccak(text='numeric-test-'+str(i)) for i in counters],length,special,[entropy.to_bytes(32,'big')]*len(counters),[zero]*len(counters),[False]*len(counters)]
    legacy=request([1],8);pin=contract.functions.storeDataBatch(legacy).call({'from':service})[0]
    send(contract.functions.storeDataBatch(legacy),service)
    replacement=deploy('Numeric');send(manager.functions.upgrade(proxy.address,replacement.address))
    upgraded=w.eth.contract(address=proxy.address,abi=artifacts['Numeric']['abi'])
    assert upgraded.functions.ADMIN().call()==admin and upgraded.functions.AUTHORIZED().call()==service
    assert upgraded.functions.pinToHash(pin,legacy[2][0]).call()[2]
    short=request(list(range(2,35)));pins=upgraded.functions.storeDataBatchNumeric(short).call({'from':service})
    assert all(len(p)==3 and p.isascii() and p.isdigit() for p in pins)
    assert pins.count('001')==32 and pins[-1]!='001'
    send(upgraded.functions.storeDataBatchNumeric(short),service)
    assert upgraded.functions.pinSlotCount('001').call()==32
    for counter,assigned in zip(short[1],pins):assert upgraded.functions.pinToHash(assigned,w.keccak(text='numeric-test-'+str(counter))).call()[2]
    with pytest.raises(Exception):upgraded.functions.storeDataBatchNumeric(request([35])).call({'from':stranger})
    with pytest.raises(Exception):upgraded.functions.storeDataBatchNumeric(request([35],4)).call({'from':service})
    with pytest.raises(Exception):upgraded.functions.storeDataBatchNumeric(request([35],3,True)).call({'from':service})
    with pytest.raises(Exception,match='Incomplete numeric batch'):upgraded.functions.storeDataBatchNumeric(request([1001])).call({'from':service})
    with pytest.raises(Exception,match='Incomplete numeric batch'):upgraded.functions.storeDataBatchNumeric(request([2,35])).call({'from':service})
    assert upgraded.functions.storedCodeCount(w.keccak(text=identifier)).call()==34
    send(upgraded.functions.syncRegisteredCodeCountAtLeast([identifier],[2000]),service)
    send(upgraded.functions.syncRegisteredCodeCountAtLeast([identifier],[1500]),service)
    assert upgraded.functions.registeredCodeCount(w.keccak(text=identifier)).call()==2000
    assert len(upgraded.functions.storeDataBatch(request([35],8)).call({'from':service})[0])==8
