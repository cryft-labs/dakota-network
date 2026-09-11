"""Pinned development deployment support with a durable, nonce-aware journal."""
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
from eth_account import Account
from web3 import Web3
from web3.exceptions import ContractLogicError
from web3.middleware import ExtraDataToPOAMiddleware

REPO = Path(__file__).resolve().parents[2]
ADDR = {k: Web3.to_checksum_address('0x' + v.zfill(40)) for k, v in {
    'ValidatorSmartContractAllowList': '1111', 'ProxyAdmin': 'facade',
    'GasManager': 'cafe', 'CodeManager': 'c0de', 'GasSponsor': 'feed',
    'DakotaDelegationRegistry': 'de1e6a7e', 'ReservedAgentRegistry': 'face'}.items()}
ADMIN = Web3.to_checksum_address('0x9247524040D91D5dd1521A25f2e7711d4a0fe921')
DEPLOYER = Web3.to_checksum_address('0x633309d1155fD658a717e4f5E4FA853615400867')
TESTER = Web3.to_checksum_address('0x991acc255761dEE0421Ccd3F436788C24425122E')
ZERO = '0x' + '0' * 40
GENESIS_HASH = '0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8'
IMPL_SLOT = int.from_bytes(Web3.keccak(text='eip1967.proxy.implementation'), 'big') - 1

def hx(value):
    return '0x' + bytes(value).hex()

def serial(value):
    if isinstance(value, bytes): return hx(value)
    if isinstance(value, dict) or hasattr(value, 'items'): return {k: serial(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)): return [serial(v) for v in value]
    return value

def git(*args):
    return subprocess.check_output(['git', '-c', 'safe.directory=' + REPO.as_posix(), '-C', str(REPO), *args], text=True).strip()

def unlock(entry):
    """Decrypt an existing project key in memory only; never generate a replacement."""
    class Blob(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]
    raw = Path(entry['password_dpapi']).read_bytes()
    buffer = (ctypes.c_ubyte * len(raw)).from_buffer_copy(raw)
    encrypted, clear = Blob(len(raw), buffer), Blob()
    library = ctypes.WinDLL('crypt32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    library.CryptUnprotectData.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                                          ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    library.CryptUnprotectData.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    assert library.CryptUnprotectData(ctypes.byref(encrypted), None, None, None, None, 1, ctypes.byref(clear))
    try: password = ctypes.string_at(clear.data, clear.size).decode()
    finally: kernel.LocalFree(clear.data)
    account = Account.from_key(Account.decrypt(json.loads(Path(entry['keystore']).read_text()), password))
    assert account.address == entry['address']
    return account

class Deployment:
    def __init__(self, workspace, execute=False):
        self.workspace = Path(workspace).resolve()
        self.out = self.workspace / 'outputs/live-genesis-20260911'
        self.out.mkdir(exist_ok=True)
        self.lock = json.loads((Path(__file__).with_name('artifact-lock.json')).read_text())
        self.artifacts = {}
        for name, record in self.lock.items():
            path = self.out / name / 'artifact.json'
            assert hashlib.sha256(path.read_bytes()).hexdigest() == record['artifact_sha256'], name
            self.artifacts[name] = json.loads(path.read_text())
        self.w3 = Web3(Web3.HTTPProvider('http://100.111.69.1:8547/', request_kwargs={'timeout': 35}, exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        assert self.w3.eth.chain_id == 112311
        assert hx(self.w3.eth.get_block(0)['hash']) == GENESIS_HASH
        self.path = self.out / 'transactions.json'
        self.journal = json.loads(self.path.read_text()) if self.path.exists() else {'chain_id': 112311, 'genesis_hash': GENESIS_HASH, 'transactions': {}, 'deployments': {}, 'checks': {}}
        self.accounts = {}
        self.execute = execute
        if execute:
            assert git('branch', '--show-current') == 'review/compiler-standard-json'
            assert not git('diff', 'HEAD', '--', 'Contracts', 'Tools/LiveGenesis'), 'Publish all deployment changes first'
            assert not git('ls-files', '--others', '--exclude-standard', '--', 'Tools/LiveGenesis'), 'Commit new deployment tools first'
            self.commit = git('rev-parse', 'HEAD')
            assert git('ls-remote', 'origin', 'refs/heads/review/compiler-standard-json').split()[0] == self.commit
            entries = json.loads((self.workspace / 'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            for entry in entries:
                self.accounts[entry['address']] = unlock(entry)
            assert set(self.accounts) == {DEPLOYER, TESTER}
        else: self.commit = git('rev-parse', 'HEAD')

    def save(self):
        self.journal['updated_at'] = datetime.now(timezone.utc).isoformat()
        temporary = self.path.with_suffix('.tmp')
        temporary.write_text(json.dumps(serial(self.journal), indent=2) + '\n')
        temporary.replace(self.path)

    def at(self, name, address=None):
        return self.w3.eth.contract(address=address or ADDR[name], abi=self.artifacts[name]['abi'])

    def check(self, name, condition, evidence=None):
        assert condition, name
        self.journal['checks'][name] = {'passed': True, 'evidence': serial(evidence)}
        self.save()
        print('PASS ' + name, flush=True)

    def reject(self, name, function, sender=TESTER, value=0):
        try: function.call({'from': sender, 'value': value, 'gas': 12000000})
        except Exception as error:
            # Do not count network/timeout failures as authorization reverts.
            msg = str(error).lower()
            assert isinstance(error, ContractLogicError) or any(x in msg for x in ['revert', 'execution reverted']), type(error).__name__ + ': ' + str(error)
            self.check(name, True, {'read_only_revert': True, 'error': str(error)[:500]})
        else: raise AssertionError('Expected rejection: ' + name)

    def tx(self, label, function=None, *, sender=DEPLOYER, value=0, transaction=None):
        assert self.execute
        previous = self.journal['transactions'].get(label)
        if previous:
            receipt = self.w3.eth.get_transaction_receipt(previous['hash'])
            assert receipt['status'] == 1, label + ': prior transaction failed; review before retry'
            previous['receipt'] = serial(receipt); previous['state'] = 'mined'; self.save()
            return receipt
        assert self.w3.eth.get_transaction_count(sender, 'pending') == self.w3.eth.get_transaction_count(sender, 'latest'), 'Reconcile pending transactions first'
        if transaction is None:
            transaction = function.build_transaction({'from': sender, 'value': value, 'gas': 12000000, 'gasPrice': 10**9,
                                                       'nonce': self.w3.eth.get_transaction_count(sender), 'chainId': 112311})
        else:
            transaction = dict(transaction, **{'from': sender, 'nonce': self.w3.eth.get_transaction_count(sender), 'chainId': 112311})
        if 'authorizationList' not in transaction:
            # First simulate the exact call/create, then bound the estimated gas.
            self.w3.eth.call(transaction)
            estimate = self.w3.eth.estimate_gas(transaction)
            # Delivery routers may catch target failures, so successful estimation
            # alone is not proof of sufficient target gas. Keep a conservative floor.
            transaction['gas'] = min(12000000, max(1000000, estimate * 5 // 4 + 50000))
        assert transaction['gas'] <= 12000000
        gas_price = transaction.get('gasPrice', transaction.get('maxFeePerGas'))
        assert self.w3.eth.get_balance(sender) > transaction['gas'] * gas_price + transaction.get('value', 0)
        signed = self.accounts[sender].sign_transaction(transaction)
        tx_hash = hx(signed.hash)
        data = transaction.get('data', '0x')
        data = bytes.fromhex(data.removeprefix('0x')) if isinstance(data, str) else bytes(data)
        record = {'hash': tx_hash, 'from': sender, 'nonce': transaction['nonce'], 'to': transaction.get('to'),
                  'value': transaction.get('value', 0), 'gas_limit': transaction['gas'], 'source_commit': self.commit,
                  'state': 'prepared', 'input_sha256': hashlib.sha256(data).hexdigest()}
        self.journal['transactions'][label] = record; self.save()
        # One broadcast only. An uncertain outcome remains journaled by signed hash.
        sent = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        assert hx(sent) == tx_hash
        record['state'] = 'submitted'; self.save()
        print('SENT ' + label + ' ' + tx_hash, flush=True)
        receipt = self.w3.eth.wait_for_transaction_receipt(sent, timeout=50, poll_latency=1)
        record['receipt'] = serial(receipt); record['state'] = 'mined' if receipt['status'] else 'reverted'; self.save()
        assert receipt['status'] == 1, label
        return receipt

    def deploy(self, name, *args, label=None):
        deployment_name = label or name
        receipt = self.tx('deploy:' + deployment_name, self.w3.eth.contract(abi=self.artifacts[name]['abi'], bytecode=self.artifacts[name]['creation_bytecode']).constructor(*args))
        address = receipt['contractAddress']
        actual = bytearray(self.w3.eth.get_code(address))
        template = bytes.fromhex(self.artifacts[name]['runtime_bytecode'].removeprefix('0x'))
        assert len(actual) == len(template)
        resolved = {}
        allowed = {int(address, 16)} | {int(x, 16) for x in args if isinstance(x, str) and x.startswith('0x')}
        for ast_id, spans in self.lock[name]['immutable_references'].items():
            values = {int.from_bytes(actual[x['start']:x['start'] + x['length']], 'big') for x in spans}
            assert len(values) == 1 and values.issubset(allowed), (name, ast_id, values)
            resolved[ast_id] = hex(next(iter(values)))
            for span in spans: actual[span['start']:span['start'] + span['length']] = template[span['start']:span['start'] + span['length']]
        assert bytes(actual) == template, name + ': deployed bytecode mismatch'
        self.journal['deployments'][deployment_name] = {'address': address, 'constructor_args': args, 'runtime_keccak256': hx(self.w3.keccak(self.w3.eth.get_code(address))),
                                            'immutable_values': resolved, 'artifact': self.lock[name], 'transaction_hash': hx(receipt['transactionHash'])}
        self.save()
        return self.at(name, address)

    def first_link(self, name, logic, initializer, args):
        proxy = self.at('TransparentUpgradeableProxy', ADDR[name])
        label = 'link:' + name
        if label not in self.journal['transactions']:
            assert not proxy.functions.proxy_getIsInit().call()
            assert int.from_bytes(self.w3.eth.get_storage_at(ADDR[name], IMPL_SLOT), 'big') == 0
        data = bytes.fromhex(getattr(logic.functions, initializer)(*args)._encode_transaction_data()[2:])
        self.tx(label, proxy.functions.proxy_linkLogicAdmin(logic.address, data))
        self.check(name + ':atomic_link', proxy.functions.proxy_getIsInit().call() and
                   int.from_bytes(self.w3.eth.get_storage_at(ADDR[name], IMPL_SLOT), 'big') == int(logic.address, 16))
        return self.at(name)

    def preflight(self):
        expected = json.loads((REPO / 'Contracts/Genesis/development-release.json').read_text())
        validator = self.at('ValidatorSmartContractAllowList')
        self.check('chain_identity', self.w3.eth.chain_id == 112311 and hx(self.w3.eth.get_block(0)['hash']) == GENESIS_HASH)
        self.check('validator_membership', validator.functions.getValidators().call() == expected['validators'])
        self.check('bootstrap_voters', validator.functions.getVoters().call() == [DEPLOYER])
        self.check('bootstrap_roots', set(validator.functions.getRootOverlords().call()) == {ADMIN, DEPLOYER})
        for name in ['ValidatorSmartContractAllowList', 'ProxyAdmin']:
            self.check(name + ':genesis_bytecode', hx(self.w3.keccak(self.w3.eth.get_code(ADDR[name]))) == expected['runtimes'][name]['runtime_keccak256'])
        for name in ['GasManager', 'CodeManager', 'GasSponsor', 'DakotaDelegationRegistry', 'ReservedAgentRegistry']:
            proxy = self.at('TransparentUpgradeableProxy', ADDR[name])
            self.check(name + ':proxy_shell', hx(self.w3.keccak(self.w3.eth.get_code(ADDR[name]))) == expected['runtimes']['TransparentUpgradeableProxy']['runtime_keccak256'])
            self.check(name + ':root_guardians', proxy.functions.proxy_isGuardian(ADMIN).call() and proxy.functions.proxy_isGuardian(DEPLOYER).call())
            if 'link:' + name not in self.journal['transactions']:
                self.check(name + ':unlinked', not proxy.functions.proxy_getIsInit().call() and int.from_bytes(self.w3.eth.get_storage_at(ADDR[name], IMPL_SLOT), 'big') == 0)
        self.check('management_funding', self.w3.eth.get_balance(ADMIN) >= 32 * 10**18)
        return validator
