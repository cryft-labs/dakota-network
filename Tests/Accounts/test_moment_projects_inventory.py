"""Local chain tests for shared fixed-supply tokens and upgradeable public projects."""
import importlib.util
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
    for name in ('MomentInventoryToken','MomentProjectRegistry','MomentProjectProxy'):
        output=compiler.compile_contract(REPO/'Contracts/Accounts'/(name+'.sol'),solc_version='0.8.37',evm_version='osaka')
        result.update({key.rsplit(':',1)[-1]:value for key,value in output.items()})
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
