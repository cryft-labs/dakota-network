"""Additive transparent-proxy deployment for public projects and named inventory tokens.

Uses only the existing development signer. Root owns both applications and the
two-step ProxyAdmin immediately; the deployer never receives an admin role.
"""
import argparse
import hashlib
import json
from pathlib import Path

import requests
import solcx
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from common import ADMIN, DEPLOYER, GENESIS_HASH, IMPL_SLOT, REPO, ZERO, Deployment, git, hx, unlock

WORKER = Web3.to_checksum_address('0xe7850ecede5d6f7d0b2d2ccabfc2f29d2c345125')
ADMIN_SLOT = int.from_bytes(Web3.keccak(text='eip1967.proxy.admin'), 'big') - 1
NAMES = ('MomentInventoryToken', 'MomentProjectRegistry', 'MomentProjectAdmin', 'MomentProjectProxy')


class MomentDeployment(Deployment):
    def __init__(self, workspace, execute=False):
        self.workspace = Path(workspace).resolve()
        self.execute = execute
        self.out = self.workspace / 'outputs/moment-projects-inventory-20260916'
        self.out.mkdir(exist_ok=True)
        self.path = self.out / 'deployment.json'
        self.journal = json.loads(self.path.read_text()) if self.path.exists() else {
            'chain_id': 112311, 'genesis_hash': GENESIS_HASH,
            'transactions': {}, 'deployments': {}, 'checks': {}}
        self.commit = git('rev-parse', 'HEAD')
        if execute:
            branch = git('branch', '--show-current')
            assert branch.startswith('review/') and not git('status', '--porcelain'), 'Commit the reviewed release first'
            assert git('ls-remote', 'origin', 'refs/heads/' + branch).split()[0] == self.commit, 'Push the reviewed release first'
        self.base = REPO / 'Contracts/Accounts/projects-inventory-artifacts/osaka/Accounts'
        self.artifacts, self.lock = {}, {}
        for name in NAMES:
            directory = self.base / name
            artifact_path = directory / (name + '_artifact.json')
            artifact = json.loads(artifact_path.read_text())
            standard = json.loads((directory / (name + '_standard_input.json')).read_text())
            standard['settings']['outputSelection'] = {'*': {'*': ['evm.bytecode.object', 'evm.deployedBytecode.object', 'evm.deployedBytecode.immutableReferences']}}
            output = solcx.compile_standard(standard, solc_version=artifact['compiler_version'])
            source, contract = artifact['fully_qualified_name'].rsplit(':', 1)
            evm = output['contracts'][source][contract]['evm']
            assert artifact['creation_bytecode'].removeprefix('0x') == evm['bytecode']['object'], name
            assert artifact['runtime_bytecode'].removeprefix('0x') == evm['deployedBytecode']['object'], name
            self.artifacts[name] = artifact
            self.lock[name] = {
                'immutable_references': evm['deployedBytecode'].get('immutableReferences', {}),
                'artifact_sha256': hashlib.sha256(artifact_path.read_bytes()).hexdigest()}
        session = requests.Session()
        session.trust_env = False
        self.w3 = Web3(Web3.HTTPProvider('http://100.111.69.1:8547/', session=session,
            request_kwargs={'timeout': 25}, exception_retry_configuration=None))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        assert self.w3.eth.chain_id == 112311 and hx(self.w3.eth.get_block(0)['hash']) == GENESIS_HASH
        self.accounts = {}
        if execute:
            entries = json.loads((self.workspace / 'outputs/cryft-wallets/deployment-wallets.json').read_text())['wallets']
            self.accounts[DEPLOYER] = unlock(next(e for e in entries if e['address'] == DEPLOYER))

    def run(self):
        if not self.execute:
            print(json.dumps({'contracts': list(NAMES), 'source_commit': self.commit,
                'chain_id': 112311, 'owner': ADMIN, 'relayer': WORKER, 'deployer': DEPLOYER,
                'deployer_balance_wei': str(self.w3.eth.get_balance(DEPLOYER)), 'submitted': False}, indent=2))
            return
        admin = self.deploy('MomentProjectAdmin', ADMIN)
        implementations = {name: self.deploy(name) for name in NAMES[:2]}
        config = {'chain_id': 112311, 'source_commit': self.commit, 'admin': admin.address,
            'owner': ADMIN, 'relayer': WORKER, 'contracts': {}, 'environment': {}}
        for name, implementation in implementations.items():
            initialization = implementation.functions.initialize(ADMIN, WORKER)._encode_transaction_data()
            proxy = self.deploy('MomentProjectProxy', implementation.address, admin.address,
                initialization, label=name + 'Proxy')
            app = self.at(name, proxy.address)
            self.check(name + ':owner_is_root', app.functions.owner().call() == ADMIN)
            self.check(name + ':no_pending_owner', app.functions.pendingOwner().call() == ZERO)
            self.check(name + ':worker_authorized', app.functions.relayers(WORKER).call())
            self.check(name + ':deployer_not_relayer', not app.functions.relayers(DEPLOYER).call())
            self.check(name + ':implementation_slot', int.from_bytes(self.w3.eth.get_storage_at(proxy.address, IMPL_SLOT), 'big') == int(implementation.address, 16))
            self.check(name + ':admin_slot', int.from_bytes(self.w3.eth.get_storage_at(proxy.address, ADMIN_SLOT), 'big') == int(admin.address, 16))
            self.reject(name + ':implementation_locked', implementation.functions.initialize(DEPLOYER, DEPLOYER), sender=DEPLOYER)
            self.reject(name + ':proxy_initialized_once', app.functions.initialize(DEPLOYER, DEPLOYER), sender=DEPLOYER)
            self.reject(name + ':deployer_cannot_add_relayer', app.functions.setRelayer(DEPLOYER, True), sender=DEPLOYER)
            self.reject(name + ':deployer_cannot_upgrade', admin.functions.upgrade(proxy.address, implementation.address), sender=DEPLOYER)
            prefix = 'PLATFORM_PROJECT_REGISTRY' if name == 'MomentProjectRegistry' else 'PLATFORM_INVENTORY_TOKEN'
            pins = {
                prefix + '_ADDRESS': proxy.address,
                prefix + '_RUNTIME_SHA256': hashlib.sha256(self.w3.eth.get_code(implementation.address)).hexdigest(),
                prefix + '_PROXY_SHA256': hashlib.sha256(self.w3.eth.get_code(proxy.address)).hexdigest()}
            config['environment'].update(pins)
            config['contracts'][name] = {'proxy': proxy.address, 'implementation': implementation.address,
                'license': 'Apache-2.0', 'artifact': self.lock[name]}
        self.check('admin:owner_is_root', admin.functions.owner().call() == ADMIN)
        self.check('admin:no_pending_owner', admin.functions.pendingOwner().call() == ZERO)
        self.reject('admin:renounce_disabled', admin.functions.renounceOwnership(), sender=ADMIN)
        self.journal['configuration'] = config
        self.save()
        (self.out / 'configuration.json').write_text(json.dumps(config, indent=2) + '\n')
        print(json.dumps(config, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    MomentDeployment(args.workspace, args.execute).run()
