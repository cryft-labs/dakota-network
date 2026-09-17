import json
from pathlib import Path
import pytest
import solcx
from web3 import Web3
from web3.providers.eth_tester import EthereumTesterProvider

ART=Path(__file__).resolve().parents[2]/'Contracts/Verification/20260917'

@pytest.fixture
def registry():
    w=Web3(EthereumTesterProvider());a=w.eth.accounts
    def deploy(artifact,args=()):
        c=w.eth.contract(abi=artifact['abi'],bytecode=artifact['creation_bytecode'])
        r=w.eth.wait_for_transaction_receipt(c.constructor(*args).transact({'from':a[0],'gas':12000000}))
        assert r.status==1
        return w.eth.contract(address=r.contractAddress,abi=artifact['abi'])
    stub=solcx.compile_source('''pragma solidity ^0.8.19; contract Authority {
      address public ADMIN; address public AUTHORIZED;
      constructor(address a,address s){ADMIN=a;AUTHORIZED=s;}
      function rotate(address a,address s) external {require(msg.sender==ADMIN);ADMIN=a;AUTHORIZED=s;}
    }''',output_values=['abi','bin'],solc_version='0.8.37',evm_version='shanghai')['<stdin>:Authority']
    authority=deploy(dict(abi=stub['abi'],creation_bytecode='0x'+stub['bin']),[a[0],a[1]])
    artifact=json.loads((ART/'PrivateCardContentRegistry/artifact.json').read_text())
    logic=deploy(artifact)
    # Only code at the admin address is needed by the managed proxy constructor;
    # production uses the established Pente ManagedProxyAdmin.
    init=logic.functions.initialize(authority.address,112311,a[8])._encode_transaction_data()
    proxy=deploy(json.loads((ART/'ManagedApplicationProxy/artifact.json').read_text()),[logic.address,authority.address,bytes.fromhex(init[2:])])
    return w,a,authority,logic,w.eth.contract(address=proxy.address,abi=artifact['abi'])

def send(w,call,sender,ok=True):
    r=w.eth.wait_for_transaction_receipt(call.transact({'from':sender,'gas':12000000}));assert bool(r.status)==ok
    return r

def entry(i=1):return [bytes([1])*32,bytes([i])*32,bytes([i+1])*32,bytes([i+2])*32,'ipfs://Qm'+'1'*44+'/'+str(i)+'.json']

def test_atomic_initializer_and_implementation_are_locked(registry):
    w,a,auth,logic,r=registry
    send(w,r.functions.initialize(auth.address,112311,a[8]),a[0],False)
    send(w,logic.functions.initialize(auth.address,112311,a[8]),a[0],False)
    assert r.functions.authority().call()==auth.address and r.functions.card().call()==a[8]

def test_key_binding_is_immutable_scoped_and_service_only(registry):
    w,a,auth,_,r=registry;e=entry()
    send(w,r.functions.storeBatch([e]),a[3],False)
    send(w,r.functions.storeBatch([e]),a[1])
    send(w,r.functions.storeBatch([e]),a[1]) # Reconciliation must be idempotent.
    with pytest.raises(Exception):r.functions.getContent(*e[:2]).call({'from':a[3]})
    assert list(r.functions.getContent(*e[:2]).call({'from':a[0]}))==e[2:]
    changed=e.copy();changed[2]=bytes([9])*32
    send(w,r.functions.storeBatch([changed]),a[1],False)
    with pytest.raises(Exception):r.functions.getContent(bytes([7])*32,e[1]).call({'from':a[0]})
    send(w,auth.functions.rotate(a[4],a[5]),a[0])
    with pytest.raises(Exception):r.functions.getContent(*e[:2]).call({'from':a[0]})
    assert list(r.functions.getContent(*e[:2]).call({'from':a[5]}))==e[2:]

def test_bounded_batch_gas_and_atomic_rollback(registry):
    w,a,_,_,r=registry
    receipt=send(w,r.functions.storeBatch([entry(i) for i in range(1,26)]),a[1])
    assert receipt.gasUsed<12000000
    send(w,r.functions.storeBatch([entry()]*26),a[1],False)
    invalid=entry(30);invalid[2]=bytes(32)
    send(w,r.functions.storeBatch([entry(29),invalid]),a[1],False)
    with pytest.raises(Exception):r.functions.getContent(*entry(29)[:2]).call({'from':a[1]})
