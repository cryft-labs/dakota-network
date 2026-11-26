"""Local EVM governance/lockout regression tests. No RPC endpoints or real keys."""
from pathlib import Path
import importlib.util
import os
import json
import re

import pytest
from eth_tester import EthereumTester, PyEVMBackend
from eth_tester.exceptions import TransactionFailed
from web3 import Web3, EthereumTesterProvider
import solcx

REPO = Path(__file__).resolve().parents[2]
REGISTRY = Web3.to_checksum_address('0x' + '0' * 36 + '1111')
ADMIN = Web3.to_checksum_address('0x' + '0' * 34 + 'facade')
ADDRESSES = {name: Web3.to_checksum_address('0x' + value.zfill(40)) for name, value in {
    'GasManager': 'cafe', 'CodeManager': 'c0de', 'GasSponsor': 'feed',
    'CryftDelegationRegistry': 'de1e6a7e', 'proxy': 'face'}.items()}
PATHS = {
    'ValidatorSmartContractAllowList': 'Genesis/validatorContracts/ValidatorSmartContractAllowList.sol',
    'GasManager': 'Genesis/GasManager/GasManager.sol',
    'CodeManager': 'CodeManagement/CodeManager.sol',
    'TransparentUpgradeableProxy': 'Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol',
    'ProxyAdmin': 'Genesis/Upgradeable/Proxy/Transparent/ProxyAdmin.sol',
    'GasSponsor': 'Genesis/7702/GasSponsor.sol',
    'CryftDelegationRegistry': 'Genesis/7702/CryftDelegationRegistry.sol',
    'CryftDelegation': 'Genesis/7702/CryftDelegation.sol',
    'CryftDelegationBeacon': 'Genesis/7702/CryftDelegationBeacon.sol',
    'CryftBeaconDispatcher': 'Genesis/7702/CryftBeaconDispatcher.sol',
}
ENGINES = ['ValidatorSmartContractAllowList', 'GasManager', 'CodeManager']
# The validator is always built exactly as the genesis builds it: solc 0.8.19 / London through the official soljson
# (Tools/Genesis/build.py). CRYFT_TEST_LEGACY_SOLC only picks the compiler for the small 0.8.19-pragma test mocks
# (on a machine without the soljson shim, e.g. CRYFT_TEST_LEGACY_SOLC=0.8.37).
LEGACY_SOLC = os.environ.get('CRYFT_TEST_LEGACY_SOLC', '0.8.19')
HOUR = 3600
DAY = 86400
WINDOW = 7 * DAY          # genesis default ballot window (seconds)
GENESIS_INPUTS = json.loads((REPO / 'Tools/Genesis/inputs.json').read_text())


def genesis_builder():
    """Tools/Genesis/build.py as a module (its validator storage and standard input are reused, never re-typed)."""
    spec = importlib.util.spec_from_file_location('cryft_genesis_build', REPO / 'Tools/Genesis/build.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validator_artifact():
    """0x1111 runtime + ABI + storage layout, compiled from the genesis standard input (0.8.19 via soljson)."""
    builder = genesis_builder()
    settings = GENESIS_INPUTS['compilers']['validator']
    std = builder.standard_input(builder.VALIDATOR_SRC, settings['evm'], settings['runs'])
    out = builder.soljson.compile_standard(std, settings['version'])
    errors = [e['formattedMessage'] for e in out.get('errors', []) if e.get('severity') == 'error']
    assert not errors, errors
    unit = out['contracts'][builder.VALIDATOR_SRC]['ValidatorSmartContractAllowList']
    return {'abi': unit['abi'], 'creation_bytecode': None,
            'runtime_bytecode': '0x' + unit['evm']['deployedBytecode']['object'],
            'metadata': unit['metadata'], 'storageLayout': unit['storageLayout'],
            'methodIdentifiers': unit['evm']['methodIdentifiers']}


@pytest.fixture(scope='session')
def builds(tmp_path_factory):
    spec = importlib.util.spec_from_file_location('governance_compiler', REPO / 'Tools/SolcCompiler/compile.py')
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)
    output = {'ValidatorSmartContractAllowList': validator_artifact()}
    for name, relative in PATHS.items():
        if name == 'ValidatorSmartContractAllowList':
            continue
        contracts = compiler.compile_contract(REPO / 'Contracts' / relative,
                                              solc_version=compiler.DEFAULT_SOLC_VERSION, evm_version='osaka')
        output[name] = next(value for key, value in contracts.items() if key.rsplit(':', 1)[-1] == name)
    mock = '''pragma solidity ^0.8.19;
contract Provider {
    address[] people; bool broken;
    function set(address[] memory next, bool fail) external { people=next; broken=fail; }
    function getVoters() external view returns(address[] memory) { require(!broken); return people; }
    function getValidators() external view returns(address[] memory) { require(!broken); return people; }
    function getRootOverlords() external view returns(address[] memory) { require(!broken); return people; }
}
contract RecursiveProvider { function getVoters() external view returns(address[] memory) {
    return RecursiveProvider(address(this)).getVoters();
} }
contract InvalidProvider { fallback() external { assembly { mstore(0,32) mstore(32,10000) return(0,64) } } }
contract Value { function value() external pure returns(uint) { return 42; } }
'''
    for key, artifact in solcx.compile_source(mock, solc_version=LEGACY_SOLC, output_values=['abi','bin','bin-runtime']).items():
        output[key.split(':')[-1]] = {'abi':artifact['abi'], 'creation_bytecode':'0x'+artifact['bin'], 'runtime_bytecode':'0x'+artifact['bin-runtime']}
    evidence = {name:{'runtime_bytes':len(bytes.fromhex(a['runtime_bytecode'].removeprefix('0x'))),
                     'runtime_keccak256':'0x'+Web3.keccak(hexstr=a['runtime_bytecode']).hex().removeprefix('0x')}
                for name,a in output.items()}
    (tmp_path_factory.getbasetemp() / 'runtime-sizes.json').write_text(json.dumps(evidence,indent=2))
    return output

def tx(chain, function, sender=None):
    w3 = chain['w3']
    receipt = w3.eth.wait_for_transaction_receipt(function.transact({'from':sender or chain['accounts'][0], 'gas':24000000}))
    assert receipt.status == 1, 'Transaction reverted'
    return receipt

def fails(chain, function, sender=None):
    with pytest.raises((TransactionFailed, ValueError)):
        function.call({'from':sender or chain['accounts'][0], 'gas':24000000})

def deploy(chain, name, *args):
    artifact = chain['builds'][name]
    factory = chain['w3'].eth.contract(abi=artifact['abi'], bytecode=artifact['creation_bytecode'])
    receipt = tx(chain, factory.constructor(*args))
    return chain['w3'].eth.contract(address=receipt.contractAddress, abi=artifact['abi'])

def at(chain, name, address):
    return chain['w3'].eth.contract(address=address, abi=chain['builds'][name]['abi'])

def now(chain):
    return chain['w3'].eth.get_block('latest')['timestamp']

def travel(chain, seconds):
    """Advance block.timestamp (all ballot windows and upgrade delays are in seconds)."""
    chain['tester'].time_travel(now(chain) + seconds)
    chain['tester'].mine_blocks(1)

def validator_storage(builds, validators, voters, roots, window=WINDOW, upgrade_delay=0, max_validators=None):
    """0x1111 genesis storage, from Tools/Genesis/build.py and the compiler's storage layout (no initialize())."""
    governance = {'roots': roots, 'voters': voters,
                  'maxValidators': max_validators or GENESIS_INPUTS['governance']['maxValidators'],
                  'voteWindowSeconds': window, 'upgradeDelaySeconds': upgrade_delay}
    storage = genesis_builder().validator_storage(builds['ValidatorSmartContractAllowList']['storageLayout'],
                                                  validators, governance)
    return {int(slot, 16): int(value, 16) for slot, value in storage.items()}

def genesis_chain(builds, monkeypatch, upgrade_delay=0, window=WINDOW):
    """A local chain laid out like CryftGenesis.json: 0x1111 seeded by storage, ProxyAdmin, unlinked proxies.

    accounts[0] is the only voter and root; the last four accounts are the validators."""
    import eth.vm.forks.spurious_dragon.computation as spurious_computation
    limit = json.loads((REPO/'Contracts/Genesis/CryftGenesis.json').read_text())['config']['contractSizeLimit']
    assert limit == 32768
    monkeypatch.setattr(spurious_computation,'EIP170_CODE_SIZE_LIMIT',limit)
    state = PyEVMBackend.generate_genesis_state()
    keys = [Web3.to_checksum_address(address) for address in state]
    storage = validator_storage(builds, keys[-4:], [keys[0]], [keys[0]], window, upgrade_delay)
    for address, name, slots in [(REGISTRY,'ValidatorSmartContractAllowList',storage), (ADMIN,'ProxyAdmin',{})] + [
        (address,'TransparentUpgradeableProxy',{}) for address in ADDRESSES.values()]:
        state[bytes.fromhex(address[2:])] = {'balance':0,'nonce':0,'code':bytes.fromhex(builds[name]['runtime_bytecode'].removeprefix('0x')),'storage':slots}
    tester = EthereumTester(backend=PyEVMBackend(genesis_parameters={'gas_limit':64000000},genesis_state=state))
    w3 = Web3(EthereumTesterProvider(tester))
    assert w3.eth.accounts[0] == keys[0]
    result = {'w3':w3,'tester':tester,'accounts':w3.eth.accounts,'builds':builds}
    result['registry'] = at(result, 'ValidatorSmartContractAllowList', REGISTRY)
    result['admin'] = at(result, 'ProxyAdmin', ADMIN)
    return result

@pytest.fixture
def chain(builds, monkeypatch):
    return genesis_chain(builds, monkeypatch)

def init_call(chain, logic, name, initializer=None, args=()):
    """Encoded link data. Managers initialize only through the proxy link with their full voter list."""
    if initializer is None:
        if name == 'GasManager':
            initializer, args = 'initializeWithVoters', ([chain['accounts'][0]], 0, 10**30, DAY)
        elif name == 'CodeManager':
            initializer, args = 'initializeWithVoters', ([chain['accounts'][0]],)
        else:
            initializer = 'initialize'
    return bytes.fromhex(getattr(logic.functions, initializer)(*args)._encode_transaction_data()[2:])

def linked(chain, name, initializer=None, args=()):
    logic = deploy(chain, name)
    proxy = at(chain,'TransparentUpgradeableProxy',ADDRESSES[name])
    tx(chain,proxy.functions.proxy_linkLogicAdmin(logic.address,init_call(chain, logic, name, initializer, args)))
    return at(chain,name,proxy.address)

def upgrade(chain, proxy_address, implementation, data=b'', sender=None):
    """Scheduled upgrade (audit X-1): schedule on the proxy, wait the 0x1111 delay, execute via the ProxyAdmin."""
    sender = sender or chain['accounts'][0]
    proxy = at(chain, 'TransparentUpgradeableProxy', proxy_address)
    tx(chain, proxy.functions.proxy_scheduleUpgrade(implementation, data), sender)
    delay = proxy.functions.proxy_getUpgradeDelay().call()
    if delay:
        travel(chain, delay)
    admin = at(chain, 'ProxyAdmin', ADMIN)
    call = admin.functions.upgradeAndCall(proxy_address, implementation, data) if data else \
        admin.functions.upgrade(proxy_address, implementation)
    return tx(chain, call, sender)

def engine(chain, name):
    return chain['registry'] if name == ENGINES[0] else linked(chain,name)

def enum(name, label):
    text=(REPO/'Contracts'/PATHS[name]).read_text(encoding='utf-8')
    text=re.sub(r'//[^\n]*|/\*.*?\*/','',text,flags=re.S)
    body=re.search(r'enum VoteType\s*\{([^}]+)',text).group(1)
    return [item.strip() for item in body.split(',')].index(label)

def members_hash(chain, members):
    ordered = sorted(set(members),key=lambda value:int(value,16))
    return chain['w3'].keccak(chain['w3'].codec.encode(['address[]'],[ordered]))

def configure(chain, contract, members, providers=(), voters=None, effective=None):
    expected=members_hash(chain, effective if effective is not None else members)
    operation=contract.functions.voteToSetVoterConfiguration(members,list(providers),expected)
    for voter in voters or [chain['accounts'][0]]: tx(chain,operation,voter)

def add_provider(chain, c, name, provider, local, effective):
    """Adds a voter provider. 0x1111 has only the hash-bound configuration ballot (audit X-55)."""
    if name == ENGINES[0]:
        configure(chain, c, local, [provider], effective=effective)
    else:
        tx(chain, c.functions.voteToAddOtherVoterContract(provider))

def add_provider_fails(chain, c, name, provider, local, effective):
    if name == ENGINES[0]:
        fails(chain, c.functions.voteToSetVoterConfiguration(local, [provider], members_hash(chain, effective)))
    else:
        fails(chain, c.functions.voteToAddOtherVoterContract(provider))

@pytest.mark.parametrize('name',ENGINES)
def test_membership_votes_complete_and_invalidate_other_proposals(chain,name):
    c=engine(chain,name); a,b,d=chain['accounts'][:3]
    tx(chain,c.functions.voteToAddVoter(b),a)
    tx(chain,c.functions.voteToSetVoteWindow(2*HOUR),a)
    tx(chain,c.functions.voteToAddVoter(d),a)
    assert c.functions.activeVoteCount().call()==2
    tx(chain,c.functions.voteToAddVoter(d),b)
    assert set(c.functions.getVoters().call())=={a,b,d}
    assert c.functions.activeVoteCount().call()==0
    assert c.functions.getVoteTally(enum(name,'SetVoteWindow'),2*HOUR).call()[0]==0
    assert not c.functions.hasVoted(enum(name,'SetVoteWindow'),2*HOUR,a).call()
    fails(chain,c.functions.voteToSetVoteWindow(3*HOUR),chain['accounts'][8])

@pytest.mark.parametrize('name',ENGINES)
def test_duplicate_provider_members_are_unique_and_failure_keeps_authority(chain,name):
    c=engine(chain,name); a,b=chain['accounts'][:2]; p=deploy(chain,'Provider')
    tx(chain,p.functions.set([a,b,a],False))
    add_provider(chain,c,name,p.address,[a],[a,b])
    assert c.functions.getVoterCount().call()==2
    assert c.functions.getSupermajorityThreshold().call()==2
    tx(chain,c.functions.voteToSetVoteWindow(5*HOUR),a)
    tx(chain,p.functions.set([],True))
    assert set(c.functions.getVoters().call())=={a,b}
    tx(chain,c.functions.voteToSetVoteWindow(5*HOUR),b)
    assert c.functions.voteTallyBlockThreshold().call()==5*HOUR
    configure(chain,c,[a,b],[],[a,b])
    assert set(c.functions.getVoters().call())=={a,b}

@pytest.mark.parametrize('name',ENGINES)
def test_provider_failure_does_not_lower_three_of_four_quorum(chain,name):
    c=engine(chain,name); a,b,d,e=chain['accounts'][:4]; p=deploy(chain,'Provider')
    tx(chain,p.functions.set([d,e],False))
    configure(chain,c,[a,b],[p.address],effective=[a,b,d,e])
    tx(chain,c.functions.voteToSetVoteWindow(5*HOUR),a)
    tx(chain,p.functions.set([],True))
    tx(chain,c.functions.voteToSetVoteWindow(5*HOUR),b)
    assert c.functions.voteTallyBlockThreshold().call()==WINDOW
    tx(chain,c.functions.voteToSetVoteWindow(5*HOUR),d)
    assert c.functions.voteTallyBlockThreshold().call()==5*HOUR

@pytest.mark.parametrize('name',ENGINES)
def test_refresh_requires_old_electorate_and_exact_new_hash(chain,name):
    c=engine(chain,name); a,b,d=chain['accounts'][:3]; p=deploy(chain,'Provider')
    tx(chain,p.functions.set([b],False)); add_provider(chain,c,name,p.address,[a],[a,b])
    tx(chain,p.functions.set([d],False))
    expected=c.functions.previewVoters().call()[1]
    fails(chain,c.functions.voteToRefreshVoters(expected),d)
    tx(chain,c.functions.voteToRefreshVoters(expected),a)
    tx(chain,p.functions.set([b,d],False))
    fails(chain,c.functions.voteToRefreshVoters(expected),b)
    tx(chain,p.functions.set([d],False))
    tx(chain,c.functions.voteToRefreshVoters(expected),b)
    assert set(c.functions.getVoters().call())=={a,d}

@pytest.mark.parametrize('name',ENGINES)
def test_expiry_is_frozen_and_cleanup_cannot_change_membership(chain,name):
    c=engine(chain,name); a,b=chain['accounts'][:2]
    tx(chain,c.functions.voteToAddVoter(b))
    tx(chain,c.functions.voteToAddVoter(chain['accounts'][2]))
    vote_type=enum(name,'AddVoter'); target=int(chain['accounts'][2],16)
    expires=c.functions.getVoteTally(vote_type,target).call()[2]
    tx(chain,c.functions.voteToSetVoteWindow(HOUR),a)
    tx(chain,c.functions.voteToSetVoteWindow(HOUR),b)
    assert c.functions.getVoteTally(vote_type,target).call()[2]==expires
    fails(chain,c.functions.resetExpiredTally(vote_type,target),chain['accounts'][9])
    chain['tester'].mine_blocks(500)  # block counts never expire a ballot (audit X-14)
    fails(chain,c.functions.resetExpiredTally(vote_type,target),chain['accounts'][9])
    travel(chain,expires-now(chain)+1)
    tx(chain,c.functions.resetExpiredTally(vote_type,target),chain['accounts'][9])
    assert c.functions.activeVoteCount().call()==0
    assert set(c.functions.getVoters().call())=={a,b}

@pytest.mark.parametrize('name',ENGINES)
def test_atomic_last_voter_handover_and_zero_rejection(chain,name):
    c=engine(chain,name); a,b=chain['accounts'][:2]
    fails(chain,c.functions.voteToRemoveVoter(a))
    fails(chain,c.functions.voteToSetVoterConfiguration([],[],members_hash(chain,[])))
    for invalid in ['0x'+'0'*40,c.address,ADMIN]:
        fails(chain,c.functions.voteToSetVoterConfiguration([invalid],[],members_hash(chain,[invalid])))
    configure(chain,c,[b])
    fails(chain,c.functions.voteToSetVoteWindow(5*HOUR),a)
    tx(chain,c.functions.voteToSetVoteWindow(5*HOUR),b)

@pytest.mark.parametrize('name',ENGINES)
def test_bad_providers_cannot_enter_configuration(chain,name):
    c=engine(chain,name); a=chain['accounts'][0]
    for provider in [c.address,chain['accounts'][8],deploy(chain,'RecursiveProvider').address,deploy(chain,'InvalidProvider').address]:
        add_provider_fails(chain,c,name,provider,[a],[a])
    p=deploy(chain,'Provider'); tx(chain,p.functions.set(['0x'+'0'*40],False))
    add_provider_fails(chain,c,name,p.address,[a],[a,'0x'+'0'*40])
    tx(chain,p.functions.set(chain['accounts'][:2],False))
    fails(chain,c.functions.voteToSetVoterConfiguration([a],[p.address,p.address],members_hash(chain,chain['accounts'][:2])))

def test_validator_unbound_provider_ballots_removed(builds):
    """Audit X-55: providers change only through the hash-bound configuration ballots."""
    names={entry.get('name') for entry in builds['ValidatorSmartContractAllowList']['abi']}
    for kind in ['Validator','Voter','Overlord']:
        assert f'voteToAddOther{kind}Contract' not in names and f'voteToRemoveOther{kind}Contract' not in names
    assert {'voteToSetVoterConfiguration','voteToSetValidatorConfiguration','voteToSetRootConfiguration'} <= names

def test_besu_validator_abi_floor_atomic_replacement_and_provider_outage(chain):
    c=chain['registry']; a=chain['accounts']
    abi=next(item for item in c.abi if item.get('name')=='getValidators')
    assert abi['inputs']==[] and abi['outputs'][0]['type']=='address[]' and abi['stateMutability']=='view'
    old=c.functions.getValidators().call()
    assert len(old)==4
    fails(chain,c.functions.voteToRemoveValidator(old[0]))
    fails(chain,c.functions.voteToSetMaxValidators(3))
    tx(chain,c.functions.voteToReplaceValidator(old[0],a[4]))
    assert len(c.functions.getValidators().call())==4 and a[4] in c.functions.getValidators().call()
    provider=deploy(chain,'Provider'); tx(chain,provider.functions.set(old,False))
    expected=members_hash(chain,old)
    tx(chain,c.functions.voteToSetValidatorConfiguration([], [provider.address],expected))
    tx(chain,provider.functions.set([],True))
    assert set(c.functions.getValidators().call())==set(old)
    fails(chain,c.functions.voteToRefreshValidators(expected))
    tx(chain,c.functions.voteToSetValidatorConfiguration(old,[],expected))
    assert set(c.functions.getValidators().call())==set(old)

def test_last_root_and_external_root_recovery(chain):
    c=chain['registry']; a,b=chain['accounts'][:2]
    fails(chain,c.functions.voteToRemoveRootOverlord(a))
    tx(chain,c.functions.voteToSetRootConfiguration([b],[],members_hash(chain,[b])))
    assert not c.functions.isRootOverlord(a).call() and c.functions.isRootOverlord(b).call()
    p=deploy(chain,'Provider'); tx(chain,p.functions.set([b],False))
    tx(chain,c.functions.voteToSetRootConfiguration([],[p.address],members_hash(chain,[b])))
    tx(chain,p.functions.set([],True))
    assert c.functions.isRootOverlord(b).call()
    tx(chain,c.functions.voteToSetRootConfiguration([a],[],members_hash(chain,[a])))

def test_proxy_root_overlap_counts_once_and_rotation_invalidates_votes(chain):
    p=at(chain,'TransparentUpgradeableProxy',ADDRESSES['proxy']); c=chain['registry']; a,b,d=chain['accounts'][:3]
    tx(chain,p.functions.proxy_addOverlord(b))
    tx(chain,c.functions.voteToAddRootOverlord(b))
    assert p.functions.proxy_getOverlordCount().call()==2
    tx(chain,p.functions.proxy_proposeGuardianChange(d,True),a)
    assert p.functions.proxy_getGuardianProposalVotes(d,True).call()==1
    tx(chain,c.functions.voteToRemoveRootOverlord(a))
    assert p.functions.proxy_getGuardianProposalVotes(d,True).call()==0
    fails(chain,p.functions.proxy_proposeGuardianChange(d,True),a)
    tx(chain,p.functions.proxy_proposeGuardianChange(d,True),b)
    assert p.functions.proxy_isGuardian(d).call()

def test_proxy_revocation_requires_recovery_controller_and_restores(chain):
    p=at(chain,'TransparentUpgradeableProxy',ADDRESSES['proxy']); a,b=chain['accounts'][:2]
    fails(chain,p.functions.proxy_revokeRootOverlord(),a)
    tx(chain,p.functions.proxy_addOverlord(b))
    tx(chain,p.functions.proxy_revokeRootOverlord(),a)
    assert not p.functions.proxy_isGuardian(a).call()
    fails(chain,p.functions.proxy_proposeOverlordChange(b,False),b)
    tx(chain,p.functions.proxy_proposeRestoreRootOverlord(),b)
    assert p.functions.proxy_isGuardian(a).call()

@pytest.mark.parametrize('name',['GasManager','CodeManager'])
def test_explicit_initializer_works_and_implementation_stays_locked(chain,name):
    a,b=chain['accounts'][:2]
    logic=deploy(chain,name)
    args=([b],0,10**30,DAY) if name=='GasManager' else ([b],)
    fails(chain,logic.functions.initializeWithVoters(*args))
    assert not {'initialize','initializeWithVoter'} & {entry.get('name') for entry in logic.abi}
    c=linked(chain,name,'initializeWithVoters',args)
    assert c.functions.getVoters().call()==[b]
    fails(chain,c.functions.initializeWithVoters(*args))
    fails(chain,c.functions.initializeWithVoters(*args),b)

def test_beacon_is_registry_owned_from_construction(chain):
    """The beacon has no ownership handover: 0x…de1E6A7E owns it from the constructor (registry 3.0.0)."""
    logic=deploy(chain,'Value'); beacon=deploy(chain,'CryftDelegationBeacon',logic.address)
    assert beacon.functions.owner().call()==ADDRESSES['CryftDelegationRegistry']
    names={entry.get('name') for entry in beacon.abi}
    assert not {'transferOwnership','acceptOwnership','renounceOwnership','cancelOwnershipTransfer'} & names
    for sender in chain['accounts'][:2]:
        fails(chain,beacon.functions.upgradeTo(logic.address),sender)

def test_sponsor_admin_handover_keeps_pause_recovery(chain):
    a,b=chain['accounts'][:2]
    logic=deploy(chain,'CryftDelegation'); beacon=deploy(chain,'CryftDelegationBeacon',logic.address)
    delegate=deploy(chain,'CryftBeaconDispatcher',beacon.address)
    c=linked(chain,'GasSponsor',args=(a,a,delegate.address,100000))
    for invalid in ['0x'+'0'*40,c.address,ADMIN]: fails(chain,c.functions.proposePlatformAdmin(invalid))
    tx(chain,c.functions.proposePlatformAdmin(b)); assert c.functions.platformAdmin().call()==a
    tx(chain,c.functions.cancelPlatformAdminTransfer()); fails(chain,c.functions.acceptPlatformAdmin(),b)
    tx(chain,c.functions.proposePlatformAdmin(b)); tx(chain,c.functions.acceptPlatformAdmin(),b)
    tx(chain,c.functions.setPaused(False),b)
    fails(chain,c.functions.setPaused(True),a)

def test_registry_admin_two_step_handover(chain):
    a,b=chain['accounts'][:2]
    logic=deploy(chain,'CryftDelegation'); beacon=deploy(chain,'CryftDelegationBeacon',logic.address)
    dispatcher=deploy(chain,'CryftBeaconDispatcher',beacon.address)
    c=linked(chain,'CryftDelegationRegistry',initializer='initializeWithAdmin',
             args=(dispatcher.address,beacon.address,ADDRESSES['GasSponsor'],a,HOUR))
    assert beacon.functions.owner().call()==c.address
    for invalid in ['0x'+'0'*40,c.address,ADMIN]: fails(chain,c.functions.proposeAdmin(invalid))
    tx(chain,c.functions.proposeAdmin(b)); tx(chain,c.functions.cancelAdminTransfer()); fails(chain,c.functions.acceptAdmin(),b)
    tx(chain,c.functions.proposeAdmin(b)); tx(chain,c.functions.acceptAdmin(),b)
    assert c.functions.registryAdmin().call()==b
    fails(chain,c.functions.proposeAdmin(a),a)

def test_runtime_limits_and_validator_compiler(builds):
    for name in PATHS:
        # Cryft's genesis sets a 32 KiB deployed contract limit.
        assert len(bytes.fromhex(builds[name]['runtime_bytecode'].removeprefix('0x'))) <= 32768, name
    metadata=json.loads(builds['ValidatorSmartContractAllowList']['metadata'])
    assert metadata['compiler']['version'].startswith('0.8.19')
    assert metadata['settings']['evmVersion']=='london'
    # The tested runtime IS the committed genesis runtime.
    manifest=json.loads((REPO/'Contracts/Genesis/genesis-release.json').read_text())
    runtime=builds['ValidatorSmartContractAllowList']['runtime_bytecode']
    assert '0x'+Web3.keccak(hexstr=runtime).hex().removeprefix('0x')==manifest['runtimes']['ValidatorSmartContractAllowList']['runtime_keccak256']

def test_besu_validator_selector_returns_standard_address_array(chain):
    selector=Web3.keccak(text='getValidators()')[:4]
    expected=chain['registry'].functions.getValidators().call()
    result=chain['w3'].eth.call({'to':REGISTRY,'data':selector})
    assert result==chain['w3'].codec.encode(['address[]'],[expected])
    assert len(expected)==4

@pytest.mark.parametrize('name',ENGINES)
def test_provider_member_and_configuration_limits(chain,name):
    c=engine(chain,name); a=chain['accounts'][0]; p=deploy(chain,'Provider')
    members=[Web3.to_checksum_address('0x'+hex(0x100000+i)[2:].zfill(40)) for i in range(64)]
    tx(chain,p.functions.set(members,False))
    fails(chain,c.functions.voteToSetVoterConfiguration([a],[p.address]*17,members_hash(chain,[a])))
    # A provider may return at most 64, and the combined unique pool is also capped.
    add_provider_fails(chain,c,name,p.address,[a],members+[a])
    configure(chain,c,[],[p.address],effective=members)
    assert c.functions.getVoterCount().call()==64
    tx(chain,p.functions.set(members+[a],False))
    fails(chain,c.functions.previewVoters())
    assert c.functions.getVoterCount().call()==64

def test_gas_funding_binds_recipient_and_runs_once(chain):
    c=linked(chain,'GasManager'); a,b,recipient,outsider=chain['accounts'][:4]
    amount=10**15
    receipt=chain['w3'].eth.wait_for_transaction_receipt(chain['w3'].eth.send_transaction({
        'from':a,'to':c.address,'value':3*amount,'gas':100000}))
    assert receipt.status==1
    names={entry.get('name') for entry in c.abi}
    assert 'voteToFundGasV1' not in names and 'executeFundGasV1' not in names  # V1 funding removed
    configure(chain,c,[b])
    operation=c.functions.proposeGasFunding('handover',recipient,amount,'same recipient after rotation')
    fund_key,_=operation.call({'from':b})
    tx(chain,operation,b)
    fails(chain,c.functions.executeGasFunding(fund_key),outsider)
    tx(chain,c.functions.executeGasFunding(fund_key),recipient)
    fails(chain,c.functions.executeGasFunding(fund_key),recipient)
    assert c.functions.totalGasFunded().call()==amount

def test_revocation_preserves_approved_lists_and_explicit_refresh(chain):
    c=chain['registry']; a,b=chain['accounts'][:2]
    validators=c.functions.getValidators().call()
    roots=deploy(chain,'Provider'); nodes=deploy(chain,'Provider'); voters=deploy(chain,'Provider')
    tx(chain,roots.functions.set([a],False)); tx(chain,nodes.functions.set(validators,False))
    tx(chain,voters.functions.set([a],False))
    tx(chain,c.functions.voteToSetRootConfiguration([],[roots.address],members_hash(chain,[a])))
    tx(chain,c.functions.voteToRevokeOverlordManagement())
    tx(chain,c.functions.voteToSetValidatorConfiguration([],[nodes.address],members_hash(chain,validators)))
    tx(chain,c.functions.voteToRevokeValidatorManagement())
    configure(chain,c,[],[voters.address],effective=[a])
    tx(chain,c.functions.voteToRevokeVoterManagement())
    assert c.functions.voterManagementRevoked().call()
    fails(chain,c.functions.voteToSetVoterConfiguration([a],[],members_hash(chain,[a])))
    tx(chain,roots.functions.set([b],False))
    assert c.functions.getRootOverlords().call()==[a]
    tx(chain,c.functions.voteToRefreshRoots(members_hash(chain,[b])))
    assert c.functions.getRootOverlords().call()==[b]
    tx(chain,voters.functions.set([b],False))
    tx(chain,c.functions.voteToRefreshVoters(members_hash(chain,[b])))
    tx(chain,voters.functions.set([],True))
    tx(chain,c.functions.voteToSetVoteWindow(3*HOUR),b)
    assert c.functions.getVoters().call()==[b]
    assert c.functions.getValidators().call()==sorted(validators,key=lambda value:int(value,16))

@pytest.mark.parametrize('name',['GasManager','CodeManager'])
def test_proxy_and_application_ballots_are_independent(chain,name):
    c=linked(chain,name); a,b,guardian=chain['accounts'][:3]
    p=at(chain,'TransparentUpgradeableProxy',c.address)
    configure(chain,c,[a,b])
    tx(chain,c.functions.voteToSetVoteWindow(8*HOUR),a)
    epoch=c.functions.governanceEpoch().call()
    tx(chain,p.functions.proxy_proposeGuardianChange(guardian,True),a)
    assert c.functions.governanceEpoch().call()==epoch
    assert c.functions.activeVoteCount().call()==1
    tx(chain,c.functions.voteToSetVoteWindow(8*HOUR),b)
    assert c.functions.voteTallyBlockThreshold().call()==8*HOUR
    tx(chain,p.functions.proxy_addOverlord(b),a)
    tx(chain,p.functions.proxy_proposeGuardianChange(guardian,False),a)
    configure(chain,c,[b],voters=[a,b])
    assert p.functions.proxy_getGuardianProposalVotes(guardian,False).call()==1
    tx(chain,p.functions.proxy_proposeGuardianChange(guardian,False),b)
    assert not p.functions.proxy_isGuardian(guardian).call()
    assert c.functions.getVoters().call()==[b]

def test_proxy_expiry_window_is_seconds_and_cannot_disable_voting(chain):
    p=at(chain,'TransparentUpgradeableProxy',ADDRESSES['proxy'])
    assert p.functions.proxy_getVoteExpiry().call()==WINDOW
    fails(chain,p.functions.proxy_proposeExpiryChange(30*DAY+1))
    fails(chain,p.functions.proxy_proposeExpiryChange(HOUR-1))
    fails(chain,p.functions.proxy_proposeExpiryChange(WINDOW))
    tx(chain,p.functions.proxy_proposeExpiryChange(30*DAY))
    assert p.functions.proxy_getVoteExpiry().call()==30*DAY
    tx(chain,p.functions.proxy_proposeGuardianChange(chain['accounts'][1],True))
    assert p.functions.proxy_isGuardian(chain['accounts'][1]).call()

def test_proxy_admin_keeps_dynamic_root_upgrade_authority(chain):
    p=at(chain,'TransparentUpgradeableProxy',ADDRESSES['proxy'])
    admin=chain['admin']; a,b=chain['accounts'][:2]
    original=deploy(chain,'Value'); next_logic=deploy(chain,'Value')
    init=bytes.fromhex(original.functions.value()._encode_transaction_data()[2:])
    tx(chain,p.functions.proxy_linkLogicAdmin(original.address,init))
    tx(chain,p.functions.proxy_scheduleUpgrade(next_logic.address,b''),a)
    fails(chain,admin.functions.upgrade(p.address,next_logic.address),b)
    tx(chain,chain['registry'].functions.voteToSetRootConfiguration([b],[],members_hash(chain,[b])))
    fails(chain,admin.functions.upgrade(p.address,next_logic.address),a)
    tx(chain,admin.functions.upgrade(p.address,next_logic.address),b)
    assert admin.functions.getProxyImplementation(p.address).call()==next_logic.address
    assert at(chain,'Value',p.address).functions.value().call()==42
