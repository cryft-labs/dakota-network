"""Local chain tests for shared fixed-supply tokens and upgradeable public projects."""
import importlib.util
import json
import solcx
from pathlib import Path
import pytest
from eth_tester import EthereumTester,PyEVMBackend
from eth_tester.exceptions import TransactionFailed
from web3 import Web3,EthereumTesterProvider

REPO=Path(__file__).resolve().parents[2]

@pytest.fixture(scope='module')
def builds():
    spec=importlib.util.spec_from_file_location('moment_compiler',REPO/'Tools/SolcCompiler/compile.py')
    compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(compiler)
    result={}
    for name in ('MomentInventoryToken','MomentProjectRegistry','MomentProjectProxy','ERC6551Registry','MomentCardAccount'):
        output=compiler.compile_contract(REPO/'Contracts/Accounts'/(name+'.sol'),solc_version='0.8.37',evm_version='osaka')
        result.update({key.rsplit(':',1)[-1]:value for key,value in output.items()})
    output=solcx.compile_source((REPO/'Tests/Accounts/AllocationTestReceivers.sol').read_text(),solc_version='0.8.37',evm_version='osaka',output_values=['abi','bin'])
    result.update({key.rsplit(':',1)[-1]:dict(abi=value['abi'],creation_bytecode=value['bin']) for key,value in output.items()})
    result['LegacyInventory']=json.loads((REPO/'Contracts/Accounts/projects-inventory-artifacts/osaka/Accounts/MomentInventoryToken/MomentInventoryToken_artifact.json').read_text())
    return result

@pytest.fixture
def chain(builds):
    w3=Web3(EthereumTesterProvider(EthereumTester(PyEVMBackend())))
    accounts=w3.eth.accounts
    def deploy(name,*args):
        artifact=builds[name]
        contract=w3.eth.contract(abi=artifact['abi'],bytecode=artifact['creation_bytecode'])
        receipt=w3.eth.wait_for_transaction_receipt(contract.constructor(*args).transact({'from':accounts[0],'gas':12000000}))
        assert receipt.status==1
        return w3.eth.contract(address=receipt.contractAddress,abi=artifact['abi'])
    return w3,accounts,deploy

def test_types_are_independently_fungible_fixed_supply_and_cannot_be_seized(chain):
    w3,a,deploy=chain;implementation=deploy('MomentInventoryToken');admin=deploy('MomentProjectAdmin',a[0])
    initialization=bytes.fromhex(implementation.functions.initialize(a[0],a[1])._encode_transaction_data()[2:])
    proxy=deploy('MomentProjectProxy',implementation.address,admin.address,initialization)
    token=w3.eth.contract(address=proxy.address,abi=implementation.abi)
    tenant=w3.keccak(text='moment.cards');request=w3.keccak(text='request')
    with pytest.raises(TransactionFailed):implementation.functions.initialize(a[0],a[1]).transact({'from':a[0]})
    with pytest.raises(TransactionFailed):token.functions.initialize(a[0],a[1]).transact({'from':a[0]})
    args=(a[2],tenant,request,'Coffee on me','ipfs://test/token.json',5,a[3])
    token.functions.createType(*args).transact({'from':a[1]})
    assert token.functions.balanceOf(a[3],1).call()==5
    assert token.functions.definition(1).call()[0]==a[2]
    assert token.functions.definition(1).call()[3]=='Coffee on me'
    assert token.functions.uri(1).call()=='ipfs://test/token.json'
    with pytest.raises(TransactionFailed):token.functions.createType(*args).transact({'from':a[1]})
    with pytest.raises(TransactionFailed):token.functions.safeTransferFrom(a[3],a[0],1,1,b'').transact({'from':a[0]})
    with pytest.raises(TransactionFailed):token.functions.safeTransferFrom(a[3],a[1],1,1,b'').transact({'from':a[1]})
    token.functions.safeTransferFrom(a[3],a[4],1,2,b'').transact({'from':a[3]})
    assert token.functions.balanceOf(a[4],1).call()==2
    replacement=deploy('MomentInventoryToken')
    admin.functions.upgrade(proxy.address,replacement.address).transact({'from':a[0]})
    assert token.functions.balanceOf(a[4],1).call()==2
    assert token.functions.nextId().call()==2
    assert token.functions.uri(1).call()=='ipfs://test/token.json'
    token.functions.createType(a[2],tenant,w3.keccak(text='second'),'Another coffee','ipfs://test/other.json',1,a[3]).transact({'from':a[2]})
    assert token.functions.nextId().call()==3
    assert token.functions.balanceOf(a[3],2).call()==1
    with pytest.raises(TransactionFailed):token.functions.createType(a[2],tenant,w3.keccak(text='third'),'Bad','ipfs://test/bad.json',1,a[4]).transact({'from':a[5]})
    token.functions.setRelayer(a[1],False).transact({'from':a[0]})
    with pytest.raises(TransactionFailed):token.functions.createType(a[2],tenant,w3.keccak(text='fourth'),'No','ipfs://test/no.json',1,a[4]).transact({'from':a[1]})

def test_projects_isolate_owners_preserve_revisions_and_survive_upgrade(chain,builds):
    w3,a,deploy=chain;impl=deploy('MomentProjectRegistry');admin=deploy('MomentProjectAdmin',a[0])
    initialization=bytes.fromhex(impl.functions.initialize(a[0],a[1])._encode_transaction_data()[2:])
    proxy=deploy('MomentProjectProxy',impl.address,admin.address,initialization)
    registry=w3.eth.contract(address=proxy.address,abi=builds['MomentProjectRegistry']['abi'])
    tenant=w3.keccak(text='moment.cards');pid=w3.keccak(text='project');digest=w3.keccak(text='public metadata')
    with pytest.raises(TransactionFailed):impl.functions.initialize(a[0],a[1]).transact({'from':a[0]})
    with pytest.raises(TransactionFailed):registry.functions.initialize(a[0],a[1]).transact({'from':a[0]})
    registry.functions.save(a[2],tenant,pid,0,digest,'ipfs://design/v1').transact({'from':a[1]})
    with pytest.raises(TransactionFailed):registry.functions.save(a[2],tenant,pid,0,digest,'ipfs://design/race').transact({'from':a[2]})
    with pytest.raises(TransactionFailed):registry.functions.save(a[2],tenant,pid,1,digest,'ipfs://design/forged').transact({'from':a[3]})
    registry.functions.save(a[3],tenant,pid,0,digest,'ipfs://other/v1').transact({'from':a[3]})
    registry.functions.save(a[2],tenant,pid,1,digest,'ipfs://design/v2').transact({'from':a[2]})
    assert registry.functions.revision(tenant,a[2],pid,0).call()[1]=='ipfs://design/v1'
    assert registry.functions.projects(tenant,a[2],0,10).call()==[[pid],1]
    replacement=deploy('MomentProjectRegistry')
    with pytest.raises(TransactionFailed):admin.functions.upgrade(proxy.address,replacement.address).transact({'from':a[2]})
    admin.functions.upgrade(proxy.address,replacement.address).transact({'from':a[0]})
    assert registry.functions.version(tenant,a[2],pid).call()==2
    assert registry.functions.revision(tenant,a[3],pid,0).call()[1]=='ipfs://other/v1'
    assert registry.functions.owner().call()==a[0]
    with pytest.raises(TransactionFailed):admin.functions.renounceOwnership().transact({'from':a[0]})
    registry.functions.transferOwnership(a[4]).transact({'from':a[0]})
    with pytest.raises(TransactionFailed):registry.functions.acceptOwnership().transact({'from':a[3]})
    registry.functions.acceptOwnership().transact({'from':a[4]})
    assert registry.functions.owner().call()==a[4]


def allocated_chain(chain):
    w3,a,deploy=chain
    legacy=deploy('LegacyInventory');admin=deploy('MomentProjectAdmin',a[0])
    proxy=deploy('MomentProjectProxy',legacy.address,admin.address,bytes.fromhex(legacy.functions.initialize(a[0],a[1])._encode_transaction_data()[2:]))
    old=w3.eth.contract(address=proxy.address,abi=legacy.abi)
    old.functions.createType(a[2],w3.keccak(text='tenant'),w3.keccak(text='legacy'),'Coffee','ipfs://legacy/token.json',10000,a[2]).transact({'from':a[1]})
    upgraded=deploy('MomentInventoryToken')
    admin.functions.upgrade(proxy.address,upgraded.address).transact({'from':a[0]})
    token=w3.eth.contract(address=proxy.address,abi=upgraded.abi)
    assert token.functions.balanceOf(a[2],1).call()==10000
    assert token.functions.definition(1).call()[3]=='Coffee'
    assert token.functions.owner().call()==a[0] and token.functions.relayers(a[1]).call()
    return w3,a,deploy,token


def test_atomic_allocation_surplus_and_upgrade_preserve_existing_tokens(chain):
    w3,a,deploy,token=allocated_chain(chain)
    receivers=sorted([deploy('AllocationReceiver').address for _ in range(2)],key=lambda address:int(address,16))
    args=(a[2],w3.keccak(text='tenant'),w3.keccak(text='allocation'),'Coffee','ipfs://coffee/token.json',10000,receivers,1500)
    token.functions.createTypeAllocated(args).transact({'from':a[1]})
    assert [token.functions.balanceOf(r,2).call() for r in receivers]==[1500,1500]
    assert token.functions.balanceOf(a[2],2).call()==7000
    assert token.functions.balanceOf(a[1],2).call()==0
    assert token.functions.definition(2).call()[2:]==(10000,'Coffee','ipfs://coffee/token.json')
    with pytest.raises(TransactionFailed):token.functions.createTypeAllocated(args).transact({'from':a[1]})
    with pytest.raises(TransactionFailed):token.functions.safeTransferFrom(a[2],a[1],2,1,b'').transact({'from':a[1]})
    with pytest.raises(TransactionFailed):token.functions.createTypeAllocated((a[2],*args[1:])).transact({'from':a[4]})


def test_failed_receiver_rolls_back_whole_supply_and_rejects_bad_plans(chain):
    w3,a,deploy,token=allocated_chain(chain)
    receivers=sorted([deploy('AllocationReceiver'),deploy('AllocationReceiver')],key=lambda r:int(r.address,16))
    receivers[1].functions.configure(True,b'').transact({'from':a[0]})
    args=(a[2],w3.keccak(text='tenant'),w3.keccak(text='retryable'),'Coffee','ipfs://coffee/token.json',10000,[r.address for r in receivers],1500)
    with pytest.raises(TransactionFailed):token.functions.createTypeAllocated(args).transact({'from':a[1]})
    assert token.functions.nextId().call()==2 and token.functions.balanceOf(receivers[0].address,2).call()==0
    assert token.functions.balanceOf(a[2],2).call()==0
    receivers[1].functions.configure(False,b'').transact({'from':a[0]})
    for recipients,amount in [([receivers[0].address]*2,1500),(list(reversed(args[6])),1500),([],1),(args[6],0),(args[6],6000),([a[5]],1)]:
        with pytest.raises(TransactionFailed):token.functions.createTypeAllocated((*args[:6],recipients,amount)).transact({'from':a[1]})
    token.functions.createTypeAllocated(args).transact({'from':a[1]})
    assert token.functions.nextId().call()==3


def test_activation_is_idempotent_and_receiver_cannot_reenter_creation(chain):
    w3,a,deploy,token=allocated_chain(chain)
    registry=deploy('ERC6551Registry');impl=deploy('MomentCardAccount');salt=w3.keccak(text='moment.cards:tba:v1')
    args=(registry.address,impl.address,salt,w3.eth.chain_id,token.address,[36,37])
    addresses=token.functions.activateAccounts(*args).call({'from':a[4]})
    token.functions.activateAccounts(*args).transact({'from':a[4]})
    assert all(w3.eth.get_code(address) for address in addresses)
    token.functions.activateAccounts(*args).transact({'from':a[3]})
    assert token.functions.activateAccounts(*args).call()==addresses
    receiver=deploy('AllocationReceiver')
    data=token.functions.createType(receiver.address,w3.keccak(text='tenant'),w3.keccak(text='attack'),'No','ipfs://test/no.json',1,receiver.address)._encode_transaction_data()
    receiver.functions.configure(False,bytes.fromhex(data[2:])).transact({'from':a[0]})
    token.functions.createTypeAllocated((a[2],w3.keccak(text='tenant'),w3.keccak(text='guard'),'Coffee','ipfs://test/token.json',1500,[receiver.address],1500)).transact({'from':a[1]})
    assert receiver.functions.reentryBlocked().call() and token.functions.balanceOf(a[2],2).call()==0
    assert token.functions.nextId().call()==3
