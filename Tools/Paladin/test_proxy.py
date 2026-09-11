"""Exercise proxy initialization, takeover rejection, upgrades and ownership safety locally."""
import json
from pathlib import Path
from web3 import Web3, EthereumTesterProvider

def test_managed_private_proxy():
    root=Path(__file__).resolve().parents[5]
    artifacts=root/'outputs/paladin-live-20260911/artifacts'
    art={name:json.loads((artifacts/name/'artifact.json').read_text()) for name in ['ManagedProxyAdmin','ManagedApplicationProxy','PrivateComboStorage']}
    w=Web3(EthereumTesterProvider()); a,b,c=w.eth.accounts[:3]
    def send(fn,sender=a):
        r=w.eth.wait_for_transaction_receipt(fn.transact({'from':sender,'gas':12000000})); assert r.status==1; return r
    def deploy(name,*args):
        build=art[name]; r=send(w.eth.contract(abi=build['abi'],bytecode=build['creation_bytecode']).constructor(*args))
        return w.eth.contract(address=r.contractAddress,abi=build['abi'])
    def reject(fn,sender=b):
        try: fn.call({'from':sender})
        except Exception as e:
            assert 'revert' in str(e).lower(); return
        raise AssertionError('Expected revert')
    logic=deploy('PrivateComboStorage'); manager=deploy('ManagedProxyAdmin',a)
    zero='0x'+'0'*40
    init=bytes.fromhex(logic.functions.initialize(a,b,zero)._encode_transaction_data()[2:])
    shell=deploy('ManagedApplicationProxy',logic.address,manager.address,init)
    private=w.eth.contract(address=shell.address,abi=art['PrivateComboStorage']['abi'])
    assert private.functions.ADMIN().call()==a and private.functions.AUTHORIZED().call()==b
    reject(logic.functions.initialize(a,b,zero)); reject(private.functions.initialize(b,b,zero))
    replacement=deploy('PrivateComboStorage')
    reject(manager.functions.upgrade(shell.address,replacement.address))
    send(manager.functions.upgrade(shell.address,replacement.address))
    assert private.functions.ADMIN().call()==a and private.functions.AUTHORIZED().call()==b
    reject(manager.functions.renounceOwnership(),a); reject(manager.functions.transferOwnership(zero),a)
    send(manager.functions.transferOwnership(c)); assert manager.functions.owner().call()==a
    reject(manager.functions.acceptOwnership(),b); send(manager.functions.acceptOwnership(),c)
    assert manager.functions.owner().call()==c and manager.functions.pendingOwner().call()==zero
    reject(manager.functions.upgrade(shell.address,logic.address),a)
    send(manager.functions.upgrade(shell.address,logic.address),c)
    assert private.functions.ADMIN().call()==a
