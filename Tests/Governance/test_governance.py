"""Local EVM governance/lockout regression tests. No RPC endpoints or real keys."""
from pathlib import Path
import importlib.util
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
    'DakotaDelegationRegistry': 'de1e6a7e', 'proxy': 'face'}.items()}
PATHS = {
    'ValidatorSmartContractAllowList': 'Genesis/validatorContracts/ValidatorSmartContractAllowList.sol',
    'GasManager': 'Genesis/GasManager/GasManager.sol',
    'CodeManager': 'CodeManagement/CodeManager.sol',
    'TransparentUpgradeableProxy': 'Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol',
    'ProxyAdmin': 'Genesis/Upgradeable/Proxy/Transparent/ProxyAdmin.sol',
    'GasSponsor': 'Genesis/7702/GasSponsor.sol',
    'DakotaDelegationRegistry': 'Genesis/7702/DakotaDelegationRegistry.sol',
    'DakotaDelegation': 'Genesis/7702/DakotaDelegation.sol',
    'DakotaDelegationBeacon': 'Genesis/7702/DakotaDelegationBeacon.sol',
    'DakotaDelegationBeaconDispatcher': 'Genesis/7702/DakotaDelegationBeaconDispatcher.sol',
}
ENGINES = ['ValidatorSmartContractAllowList', 'GasManager', 'CodeManager']

@pytest.fixture(scope='session')
def builds(tmp_path_factory):
    spec = importlib.util.spec_from_file_location('governance_compiler', REPO / 'Tools/SolcCompiler/compile.py')
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)
    output = {}
    for name, relative in PATHS.items():
        validator = name == 'ValidatorSmartContractAllowList'
        contracts = compiler.compile_contract(
            REPO / 'Contracts' / relative,
            solc_version='0.8.19' if validator else '0.8.34',
            evm_version='london' if validator else 'osaka',
        )
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
    for key, artifact in solcx.compile_source(mock, solc_version='0.8.19', output_values=['abi','bin','bin-runtime']).items():
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

@pytest.fixture
def chain(builds):
    state = PyEVMBackend.generate_genesis_state()
    accounts = list(state)
    slots = {1:4}
    base = int.from_bytes(Web3.keccak((1).to_bytes(32,'big')), 'big')
    for i, address in enumerate(accounts[-4:]): slots[base+i] = int.from_bytes(address,'big')
    for address, name, storage in [(REGISTRY,'ValidatorSmartContractAllowList',slots), (ADMIN,'ProxyAdmin',{})] + [
        (address,'TransparentUpgradeableProxy',{}) for address in ADDRESSES.values()]:
        state[bytes.fromhex(address[2:])] = {'balance':0,'nonce':0,'code':bytes.fromhex(builds[name]['runtime_bytecode'].removeprefix('0x')),'storage':storage}
    tester = EthereumTester(backend=PyEVMBackend(genesis_parameters={'gas_limit':64000000},genesis_state=state))
    w3 = Web3(EthereumTesterProvider(tester))
    result = {'w3':w3,'tester':tester,'accounts':w3.eth.accounts,'builds':builds}
    result['registry'] = at(result, 'ValidatorSmartContractAllowList', REGISTRY)
    tx(result, result['registry'].functions.initialize())
    tx(result, result['registry'].functions.voteToAddRootOverlord(w3.eth.accounts[0]))
    return result

def linked(chain, name, initializer='initialize', args=()):
    logic = deploy(chain, name)
    proxy = at(chain,'TransparentUpgradeableProxy',ADDRESSES[name])
    data = bytes.fromhex(getattr(logic.functions, initializer)(*args)._encode_transaction_data()[2:])
    tx(chain,proxy.functions.proxy_linkLogicAdmin(logic.address,data))
    return at(chain,name,proxy.address)

def engine(chain, name):
    return chain['registry'] if name == ENGINES[0] else linked(chain,name)

def enum(name, label):
    text=(REPO/'Contracts'/PATHS[name]).read_text(encoding='utf-8')
    body=re.search(r'enum VoteType\s*\{([^}]+)',text).group(1)
    return [item.strip() for item in body.split(',')].index(label)

def members_hash(chain, members):
    ordered = sorted(set(members),key=lambda value:int(value,16))
    return chain['w3'].keccak(chain['w3'].codec.encode(['address[]'],[ordered]))

def configure(chain, contract, members, providers=(), voters=None, effective=None):
    expected=members_hash(chain, effective if effective is not None else members)
    operation=contract.functions.voteToSetVoterConfiguration(members,list(providers),expected)
    for voter in voters or [chain['accounts'][0]]: tx(chain,operation,voter)

@pytest.mark.parametrize('name',ENGINES)
def test_membership_votes_complete_and_invalidate_other_proposals(chain,name):
    c=engine(chain,name); a,b,d=chain['accounts'][:3]
    tx(chain,c.functions.voteToAddVoter(b),a)
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(400),a)
    tx(chain,c.functions.voteToAddVoter(d),a)
    assert c.functions.activeVoteCount().call()==2
    tx(chain,c.functions.voteToAddVoter(d),b)
    assert set(c.functions.getVoters().call())=={a,b,d}
    assert c.functions.activeVoteCount().call()==0
    assert c.functions.getVoteTally(enum(name,'UPDATE_VOTE_TALLY_BLOCK_THRESHOLD'),400).call()[0]==0
    assert not c.functions.hasVoted(enum(name,'UPDATE_VOTE_TALLY_BLOCK_THRESHOLD'),400,a).call()
    fails(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(700),chain['accounts'][8])

@pytest.mark.parametrize('name',ENGINES)
def test_duplicate_provider_members_are_unique_and_failure_keeps_authority(chain,name):
    c=engine(chain,name); a,b=chain['accounts'][:2]; p=deploy(chain,'Provider')
    tx(chain,p.functions.set([a,b,a],False))
    tx(chain,c.functions.voteToAddOtherVoterContract(p.address))
    assert c.functions.getVoterCount().call()==2
    assert c.functions.getSupermajorityThreshold().call()==2
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(500),a)
    tx(chain,p.functions.set([],True))
    assert set(c.functions.getVoters().call())=={a,b}
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(500),b)
    assert c.functions.voteTallyBlockThreshold().call()==500
    configure(chain,c,[a,b],[],[a,b])
    assert set(c.functions.getVoters().call())=={a,b}

@pytest.mark.parametrize('name',ENGINES)
def test_provider_failure_does_not_lower_three_of_four_quorum(chain,name):
    c=engine(chain,name); a,b,d,e=chain['accounts'][:4]; p=deploy(chain,'Provider')
    tx(chain,p.functions.set([d,e],False))
    configure(chain,c,[a,b],[p.address],effective=[a,b,d,e])
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(500),a)
    tx(chain,p.functions.set([],True))
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(500),b)
    assert c.functions.voteTallyBlockThreshold().call()==1000
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(500),d)
    assert c.functions.voteTallyBlockThreshold().call()==500

@pytest.mark.parametrize('name',ENGINES)
def test_refresh_requires_old_electorate_and_exact_new_hash(chain,name):
    c=engine(chain,name); a,b,d=chain['accounts'][:3]; p=deploy(chain,'Provider')
    tx(chain,p.functions.set([b],False)); tx(chain,c.functions.voteToAddOtherVoterContract(p.address))
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
    vote_type=enum(name,'ADD_VOTER'); target=int(chain['accounts'][2],16)
    expires=c.functions.getVoteTally(vote_type,target).call()[2]
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(5),a)
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(5),b)
    assert c.functions.getVoteTally(vote_type,target).call()[2]==expires
    fails(chain,c.functions.resetExpiredTally(vote_type,target),chain['accounts'][9])
    chain['tester'].mine_blocks(expires-chain['w3'].eth.block_number+1)
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
    fails(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(500),a)
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(500),b)

@pytest.mark.parametrize('name',ENGINES)
def test_bad_providers_cannot_enter_configuration(chain,name):
    c=engine(chain,name)
    for provider in [c.address,chain['accounts'][8],deploy(chain,'RecursiveProvider').address,deploy(chain,'InvalidProvider').address]:
        fails(chain,c.functions.voteToAddOtherVoterContract(provider))
    p=deploy(chain,'Provider'); tx(chain,p.functions.set(['0x'+'0'*40],False))
    fails(chain,c.functions.voteToAddOtherVoterContract(p.address))
    tx(chain,p.functions.set(chain['accounts'][:2],False))
    fails(chain,c.functions.voteToSetVoterConfiguration([chain['accounts'][0]],[p.address,p.address],members_hash(chain,chain['accounts'][:2])))

def test_besu_validator_abi_floor_atomic_replacement_and_provider_outage(chain):
    c=chain['registry']; a=chain['accounts']
    abi=next(item for item in c.abi if item.get('name')=='getValidators')
    assert abi['inputs']==[] and abi['outputs'][0]['type']=='address[]' and abi['stateMutability']=='view'
    old=c.functions.getValidators().call()
    assert len(old)==4
    fails(chain,c.functions.voteToRemoveValidator(old[0]))
    fails(chain,c.functions.voteToUpdateMaxValidators(3))
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
    logic=deploy(chain,name)
    fails(chain,logic.functions.initialize())
    c=linked(chain,name,'initializeWithVoter',(chain['accounts'][1],))
    assert c.functions.getVoters().call()==[chain['accounts'][1]]
    fails(chain,c.functions.initialize())

def test_beacon_acceptance_cancellation_and_renunciation(chain):
    logic=deploy(chain,'Value'); beacon=deploy(chain,'DakotaDelegationBeacon',logic.address)
    a,b=chain['accounts'][:2]
    fails(chain,beacon.functions.renounceOwnership())
    for invalid in ['0x'+'0'*40,beacon.address,a]: fails(chain,beacon.functions.transferOwnership(invalid))
    tx(chain,beacon.functions.transferOwnership(b)); assert beacon.functions.owner().call()==a
    fails(chain,beacon.functions.acceptOwnership(),chain['accounts'][2])
    tx(chain,beacon.functions.cancelOwnershipTransfer())
    fails(chain,beacon.functions.acceptOwnership(),b)
    tx(chain,beacon.functions.transferOwnership(b)); tx(chain,beacon.functions.acceptOwnership(),b)
    assert beacon.functions.owner().call()==b
    fails(chain,beacon.functions.upgradeTo(logic.address),a)

def test_sponsor_admin_handover_keeps_pause_recovery(chain):
    a,b=chain['accounts'][:2]; delegate=deploy(chain,'Value')
    c=linked(chain,'GasSponsor',args=(a,a,delegate.address,100000))
    for invalid in ['0x'+'0'*40,c.address,ADMIN]: fails(chain,c.functions.proposePlatformAdmin(invalid))
    tx(chain,c.functions.proposePlatformAdmin(b)); assert c.functions.platformAdmin().call()==a
    tx(chain,c.functions.cancelPlatformAdminTransfer()); fails(chain,c.functions.acceptPlatformAdmin(),b)
    tx(chain,c.functions.proposePlatformAdmin(b)); tx(chain,c.functions.acceptPlatformAdmin(),b)
    tx(chain,c.functions.setPaused(False),b)
    fails(chain,c.functions.setPaused(True),a)

def test_registry_accepts_and_can_cancel_beacon_handover(chain):
    a,b=chain['accounts'][:2]
    logic=deploy(chain,'DakotaDelegation'); beacon=deploy(chain,'DakotaDelegationBeacon',logic.address)
    dispatcher=deploy(chain,'DakotaDelegationBeaconDispatcher',beacon.address)
    c=linked(chain,'DakotaDelegationRegistry',args=(dispatcher.address,beacon.address,ADDRESSES['GasSponsor']))
    tx(chain,beacon.functions.transferOwnership(c.address))
    tx(chain,c.functions.acceptBeaconOwnership())
    assert beacon.functions.owner().call()==c.address
    tx(chain,c.functions.transferBeaconOwnership(b))
    assert beacon.functions.owner().call()==c.address
    tx(chain,c.functions.cancelBeaconOwnershipTransfer())
    fails(chain,beacon.functions.acceptOwnership(),b)
    tx(chain,c.functions.transferBeaconOwnership(b)); tx(chain,beacon.functions.acceptOwnership(),b)
    assert beacon.functions.owner().call()==b
    fails(chain,c.functions.transferBeaconOwnership(a))
    tx(chain,beacon.functions.transferOwnership(c.address),b); tx(chain,c.functions.acceptBeaconOwnership())
    for invalid in ['0x'+'0'*40,c.address,ADMIN]: fails(chain,c.functions.proposeAdmin(invalid))
    tx(chain,c.functions.proposeAdmin(b)); tx(chain,c.functions.cancelAdminTransfer()); fails(chain,c.functions.acceptAdmin(),b)
    tx(chain,c.functions.proposeAdmin(b)); tx(chain,c.functions.acceptAdmin(),b)
    # Re-recording the same implementation must fail even for the new admin.
    fails(chain,c.functions.recordCurrentImplementation(),b)
    next_logic=deploy(chain,'DakotaDelegation')
    code_hash=chain['w3'].keccak(chain['w3'].eth.get_code(next_logic.address))
    fails(chain,c.functions.upgradeDelegation(next_logic.address,code_hash),a)
    tx(chain,c.functions.upgradeDelegation(next_logic.address,code_hash),b)
    assert beacon.functions.implementation().call()==next_logic.address

def test_runtime_limits_and_validator_compiler(builds):
    for name in PATHS:
        # Dakota's README specifies a 32 KiB deployed contract limit.
        assert len(bytes.fromhex(builds[name]['runtime_bytecode'].removeprefix('0x'))) <= 32768, name
    metadata=json.loads(builds['ValidatorSmartContractAllowList']['metadata'])
    assert metadata['compiler']['version'].startswith('0.8.19')
    assert metadata['settings']['evmVersion']=='london'

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
    fails(chain,c.functions.voteToAddOtherVoterContract(p.address))
    configure(chain,c,[],[p.address],effective=members)
    assert c.functions.getVoterCount().call()==64
    tx(chain,p.functions.set(members+[a],False))
    fails(chain,c.functions.previewVoters())
    assert c.functions.getVoterCount().call()==64

def test_gas_funding_survives_voter_rotation_and_binds_recipient(chain):
    c=linked(chain,'GasManager'); a,b,recipient,outsider=chain['accounts'][:4]
    amount=10**15
    receipt=chain['w3'].eth.wait_for_transaction_receipt(chain['w3'].eth.send_transaction({
        'from':a,'to':c.address,'value':3*amount,'gas':100000}))
    assert receipt.status==1
    tx(chain,c.functions.voteToFundGasV1(recipient,amount))
    configure(chain,c,[b])
    fails(chain,c.functions.executeFundGasV1(recipient,amount),outsider)
    tx(chain,c.functions.executeFundGasV1(recipient,amount),recipient)
    fails(chain,c.functions.executeFundGasV1(recipient,amount),recipient)
    operation=c.functions.proposeFundGasV2('handover',recipient,amount,'same recipient after rotation')
    fund_key,_=operation.call({'from':b})
    tx(chain,operation,b)
    fails(chain,c.functions.executeFundGasV2(fund_key),outsider)
    tx(chain,c.functions.executeFundGasV2(fund_key),recipient)
    fails(chain,c.functions.executeFundGasV2(fund_key),recipient)
    assert c.functions.totalGasFunded().call()==2*amount

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
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(750),b)
    assert c.functions.getVoters().call()==[b]
    assert c.functions.getValidators().call()==sorted(validators,key=lambda value:int(value,16))

@pytest.mark.parametrize('name',['GasManager','CodeManager'])
def test_proxy_and_application_ballots_are_independent(chain,name):
    c=linked(chain,name); a,b,guardian=chain['accounts'][:3]
    p=at(chain,'TransparentUpgradeableProxy',c.address)
    configure(chain,c,[a,b])
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(800),a)
    epoch=c.functions.governanceEpoch().call()
    tx(chain,p.functions.proxy_proposeGuardianChange(guardian,True),a)
    assert c.functions.governanceEpoch().call()==epoch
    assert c.functions.activeVoteCount().call()==1
    tx(chain,c.functions.voteToUpdateVoteTallyBlockThreshold(800),b)
    assert c.functions.voteTallyBlockThreshold().call()==800
    tx(chain,p.functions.proxy_addOverlord(b),a)
    tx(chain,p.functions.proxy_proposeGuardianChange(guardian,False),a)
    configure(chain,c,[b],voters=[a,b])
    assert p.functions.proxy_getGuardianProposalVotes(guardian,False).call()==1
    tx(chain,p.functions.proxy_proposeGuardianChange(guardian,False),b)
    assert not p.functions.proxy_isGuardian(guardian).call()
    assert c.functions.getVoters().call()==[b]

def test_proxy_expiry_cannot_disable_subsequent_voting(chain):
    p=at(chain,'TransparentUpgradeableProxy',ADDRESSES['proxy'])
    fails(chain,p.functions.proxy_proposeExpiryChange(100001))
    fails(chain,p.functions.proxy_proposeExpiryChange(99))
    tx(chain,p.functions.proxy_proposeExpiryChange(100000))
    tx(chain,p.functions.proxy_proposeGuardianChange(chain['accounts'][1],True))
    assert p.functions.proxy_isGuardian(chain['accounts'][1]).call()

def test_proxy_admin_keeps_dynamic_root_upgrade_authority(chain):
    p=at(chain,'TransparentUpgradeableProxy',ADDRESSES['proxy'])
    admin=at(chain,'ProxyAdmin',ADMIN); a,b=chain['accounts'][:2]
    original=deploy(chain,'Value'); next_logic=deploy(chain,'Value')
    tx(chain,p.functions.proxy_linkLogicAdmin(original.address,b''))
    fails(chain,admin.functions.upgrade(p.address,next_logic.address),b)
    tx(chain,chain['registry'].functions.voteToSetRootConfiguration([b],[],members_hash(chain,[b])))
    fails(chain,admin.functions.upgrade(p.address,next_logic.address),a)
    tx(chain,admin.functions.upgrade(p.address,next_logic.address),b)
    assert admin.functions.getProxyImplementation(p.address).call()==next_logic.address
    assert at(chain,'Value',p.address).functions.value().call()==42
