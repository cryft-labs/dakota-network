"""GasManager 2.6 / CodeManager 3.1 audit-fix tests (N-7, N-8). Local EVM only: no RPC, no real keys.

Builds with solc 0.8.37 (osaka, optimizer 200) only. A mock root registry stands at 0x1111 so these tests do not
depend on the validator contract's own compiler.
"""
from pathlib import Path
import importlib.util
import json

import pytest
from eth_tester import EthereumTester, PyEVMBackend
from eth_tester.exceptions import TransactionFailed
from web3 import Web3, EthereumTesterProvider
import solcx

REPO = Path(__file__).resolve().parents[2]
SOLC = '0.8.37'
REGISTRY = Web3.to_checksum_address('0x' + '0' * 36 + '1111')
ADMIN = Web3.to_checksum_address('0x' + '0' * 34 + 'facade')
FEED = Web3.to_checksum_address('0x' + '0' * 36 + 'feed')
ADDRESSES = {name: Web3.to_checksum_address('0x' + value.zfill(40)) for name, value in {
    'GasManager': 'cafe', 'CodeManager': 'c0de', 'spare': 'face'}.items()}
PATHS = {
    'GasManager': 'Genesis/GasManager/GasManager.sol',
    'CodeManager': 'CodeManagement/CodeManager.sol',
    'TransparentUpgradeableProxy': 'Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol',
    'ProxyAdmin': 'Genesis/Upgradeable/Proxy/Transparent/ProxyAdmin.sol',
}
DAY = 86400
HOUR = 3600

MOCKS = '''pragma solidity 0.8.37;
contract RootRegistry {
    address[] roots;
    function set(address[] memory next) external { roots = next; }
    function getRootOverlords() external view returns (address[] memory) { return roots; }
    function isRootOverlord(address a) external view returns (bool) {
        for (uint256 i; i < roots.length; ++i) if (roots[i] == a) return true;
        return false;
    }
}
/// Minimal host: proxy_isGuardian from a list, everything else delegatecalls the logic.
contract Host {
    address immutable logic; address immutable guardian;   // immutables: the logic's storage stays clean
    constructor(address l, address g) { logic = l; guardian = g; }
    function proxy_isGuardian(address a) external view returns (bool) { return a == guardian; }
    fallback() external payable {
        address l = logic;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), l, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
contract SponsorMock {
    mapping(address => bool) public isProgramSponsor;
    mapping(address => uint256) public credit;
    function setProgram(address s, bool v) external { isProgramSponsor[s] = v; }
    function depositGasCredit(address s) external payable { require(!isProgramSponsor[s]); credit[s] += msg.value; }
}
interface ICM { function registerUniqueIds(address, string memory, uint256) external payable; }
contract Gift {
    bool public broken; uint256 public delivered;
    function setBroken(bool b) external { broken = b; }
    function register(address cm, string memory chainId, uint256 q) external payable {
        ICM(cm).registerUniqueIds{value: msg.value}(address(this), chainId, q);
    }
    function recordRedemption(string memory, address) external { require(!broken, "broken"); ++delivered; }
    function isUniqueIdRedeemed(string memory) external pure returns (bool) { return false; }
}
contract Token {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v; balanceOf[to] += v; return true;
    }
}
'''


@pytest.fixture(scope='session')
def builds():
    spec = importlib.util.spec_from_file_location('manager_compiler', REPO / 'Tools/SolcCompiler/compile.py')
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)
    output = {}
    for name, relative in PATHS.items():
        contracts = compiler.compile_contract(REPO / 'Contracts' / relative, solc_version=SOLC, evm_version='osaka')
        output[name] = next(value for key, value in contracts.items() if key.rsplit(':', 1)[-1] == name)
    compiled = solcx.compile_source(MOCKS, solc_version=SOLC, evm_version='osaka', optimize=True,
                                    output_values=['abi', 'bin', 'bin-runtime'])
    for key, artifact in compiled.items():
        output[key.split(':')[-1]] = {'abi': artifact['abi'], 'creation_bytecode': '0x' + artifact['bin'],
                                      'runtime_bytecode': '0x' + artifact['bin-runtime']}
    return output


def tx(chain, function, sender=None, value=0, gas=24000000):
    w3 = chain['w3']
    receipt = w3.eth.wait_for_transaction_receipt(function.transact(
        {'from': sender or chain['accounts'][0], 'gas': gas, 'value': value}))
    assert receipt.status == 1, 'Transaction reverted'
    return receipt


def fails(chain, function, sender=None, gas=24000000, match=None):
    with pytest.raises((TransactionFailed, ValueError, Exception)) as info:
        function.call({'from': sender or chain['accounts'][0], 'gas': gas})
    if match:
        assert revert_data(info.value).startswith(bytes.fromhex(match)), info.value


def revert_data(error):
    """Raw revert bytes from an eth-tester failure ("execution reverted: b'...'") or a web3 error."""
    import ast
    text = str(error.args[0]) if error.args else str(error)
    marker = text.find("b'") if "b'" in text else text.find('b"')
    if marker >= 0:
        return ast.literal_eval(text[marker:])
    data = getattr(error, 'data', None) or (error.args[1] if len(error.args) > 1 else '')
    return bytes.fromhex(str(data).removeprefix('0x'))


def error_selector(signature):
    return '0x' + Web3.keccak(text=signature).hex().removeprefix('0x')[:8]


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
    chain['tester'].time_travel(now(chain) + seconds)
    chain['tester'].mine_blocks(1)


def send(chain, to, value):
    w3 = chain['w3']
    receipt = w3.eth.wait_for_transaction_receipt(w3.eth.send_transaction(
        {'from': chain['accounts'][0], 'to': to, 'value': value, 'gas': 100000}))
    assert receipt.status == 1


@pytest.fixture
def chain(builds, monkeypatch):
    import eth.vm.forks.spurious_dragon.computation as spurious_computation
    monkeypatch.setattr(spurious_computation, 'EIP170_CODE_SIZE_LIMIT', 32768)
    state = PyEVMBackend.generate_genesis_state()
    placed = [(REGISTRY, 'RootRegistry'), (ADMIN, 'ProxyAdmin'), (FEED, 'SponsorMock')] + [
        (address, 'TransparentUpgradeableProxy') for address in ADDRESSES.values()]
    for address, name in placed:
        state[bytes.fromhex(address[2:])] = {'balance': 0, 'nonce': 0, 'storage': {},
                                             'code': bytes.fromhex(builds[name]['runtime_bytecode'].removeprefix('0x'))}
    tester = EthereumTester(backend=PyEVMBackend(genesis_parameters={'gas_limit': 64000000}, genesis_state=state))
    w3 = Web3(EthereumTesterProvider(tester))
    result = {'w3': w3, 'tester': tester, 'accounts': w3.eth.accounts, 'builds': builds}
    tx(result, at(result, 'RootRegistry', REGISTRY).functions.set([w3.eth.accounts[0]]))
    return result


def init_data(logic, name, voters, delay=0, cap=10**30, period=DAY):
    if name == 'GasManager':
        call = logic.functions.initializeWithVoters(voters, delay, cap, period)
    else:
        call = logic.functions.initializeWithVoters(voters)
    return bytes.fromhex(call._encode_transaction_data()[2:])


def linked(chain, name, voters=None, **params):
    voters = voters or [chain['accounts'][0]]
    logic = deploy(chain, name)
    proxy = at(chain, 'TransparentUpgradeableProxy', ADDRESSES[name])
    tx(chain, proxy.functions.proxy_linkLogicAdmin(logic.address, init_data(logic, name, voters, **params)))
    return at(chain, name, proxy.address)


def enum(name, label):
    import re
    text = (REPO / 'Contracts' / PATHS[name]).read_text(encoding='utf-8')
    body = re.search(r'enum VoteType\s*\{([^}]+)', text).group(1)
    return [item.strip() for item in body.split(',')].index(label)


# ── Initialization (X-16, X-4, X-5) ─────────────────────────────────────────

@pytest.mark.parametrize('name', ['GasManager', 'CodeManager'])
def test_implementation_init_locked_and_front_run_impossible(chain, name):
    a, outsider = chain['accounts'][0], chain['accounts'][5]
    logic = deploy(chain, name)
    data = init_data(logic, name, [a])
    # The implementation itself is locked.
    with pytest.raises((TransactionFailed, ValueError)):
        chain['w3'].eth.call({'from': a, 'to': logic.address, 'data': data, 'gas': 5000000})
    # Through a host whose guardian is `a`: an outsider's initializer call is refused, the guardian's succeeds.
    host = deploy(chain, 'Host', logic.address, a)
    with pytest.raises((TransactionFailed, ValueError)):
        chain['w3'].eth.call({'from': outsider, 'to': host.address, 'data': data, 'gas': 5000000})
    tx(chain, at(chain, name, host.address).functions.initializeWithVoters(
        *([[a], 0, 10**30, DAY] if name == 'GasManager' else [[a]])), a)
    assert at(chain, name, host.address).functions.getVoters().call() == [a]
    # Real genesis proxy: only a guardian may link, and the link carries the init data.
    proxy = at(chain, 'TransparentUpgradeableProxy', ADDRESSES[name])
    fails(chain, proxy.functions.proxy_linkLogicAdmin(logic.address, data), outsider)
    c = linked(chain, name)
    fails(chain, c.functions.initializeWithVoters(*([[outsider], 0, 1, DAY] if name == 'GasManager' else [[outsider]])), outsider)
    assert not any(entry.get('name') == 'initialize' for entry in c.abi)
    assert not any(entry.get('name') == 'initializeWithVoter' for entry in c.abi)


@pytest.mark.parametrize('name', ['GasManager', 'CodeManager'])
def test_three_initial_voters(chain, name):
    a, b, d = chain['accounts'][:3]
    c = linked(chain, name, [a, b, d])
    assert set(c.functions.getVoters().call()) == {a, b, d}
    assert c.functions.getSupermajorityThreshold().call() == 2
    assert c.functions.voteTallyBlockThreshold().call() == 7 * DAY
    tx(chain, c.functions.voteToSetVoteWindow(2 * DAY), a)
    assert c.functions.voteTallyBlockThreshold().call() == 7 * DAY
    tx(chain, c.functions.voteToSetVoteWindow(2 * DAY), b)
    assert c.functions.voteTallyBlockThreshold().call() == 2 * DAY
    # Duplicate or invalid initial voters are refused.
    logic = deploy(chain, name)
    host = deploy(chain, 'Host', logic.address, a)
    for bad in ([a, a], [], ['0x' + '0' * 40]):
        with pytest.raises((TransactionFailed, ValueError)):
            chain['w3'].eth.call({'from': a, 'to': host.address, 'data': init_data(logic, name, bad), 'gas': 5000000})


# ── Governance windows and caps (X-13, X-14) ────────────────────────────────

@pytest.mark.parametrize('name', ['GasManager', 'CodeManager'])
def test_window_expiry_by_timestamp(chain, name):
    a, b, d = chain['accounts'][:3]
    c = linked(chain, name, [a, b, d])
    fails(chain, c.functions.voteToSetVoteWindow(HOUR - 1))
    fails(chain, c.functions.voteToSetVoteWindow(30 * DAY + 1))
    tx(chain, c.functions.voteToSetVoteWindow(HOUR), a)
    vote_type = enum(name, 'SetVoteWindow')
    _, start, expires, _ = c.functions.getVoteTally(vote_type, HOUR).call()
    assert expires - start == 7 * DAY
    chain['tester'].mine_blocks(2000)  # block count alone never expires a ballot
    fails(chain, c.functions.resetExpiredTally(vote_type, HOUR), chain['accounts'][9])
    travel(chain, 7 * DAY + 1)
    tx(chain, c.functions.resetExpiredTally(vote_type, HOUR), chain['accounts'][9])
    assert c.functions.activeVoteCount().call() == 0


@pytest.mark.parametrize('name', ['GasManager', 'CodeManager'])
def test_junk_flood_cannot_block_removing_the_flooder(chain, name):
    a, b, rogue = chain['accounts'][:3]
    c = linked(chain, name, [a, b, rogue])
    cap = 64 // 3
    for i in range(cap):
        tx(chain, c.functions.voteToSetVoteWindow(HOUR + i), rogue)
    fails(chain, c.functions.voteToSetVoteWindow(HOUR + cap), rogue)
    assert c.functions.openBallots(rogue).call() == [cap, 0]
    # Other voters still have counted room, and voter removal is exempt from every counted cap.
    tx(chain, c.functions.voteToRemoveVoter(rogue), a)
    tx(chain, c.functions.voteToRemoveVoter(rogue), b)
    assert set(c.functions.getVoters().call()) == {a, b}
    assert c.functions.activeVoteCount().call() == 0
    fails(chain, c.functions.voteToSetVoteWindow(HOUR), rogue)


# ── GasManager treasury (N-7) ───────────────────────────────────────────────

def _fund(chain, c, voter, recipient, amount, fid='grant'):
    operation = c.functions.proposeGasFunding(fid, recipient, amount, 'note')
    fund_key, _ = operation.call({'from': voter})
    tx(chain, operation, voter)
    return fund_key


def test_fund_before_delay_reverts_and_cancel_during_delay(chain):
    a, recipient = chain['accounts'][0], chain['accounts'][3]
    c = linked(chain, 'GasManager', delay=2 * DAY)
    send(chain, c.address, 10**18)
    key = _fund(chain, c, a, recipient, 10**15)
    approved, executable_at, expires_at, _, _ = c.functions.getFundApprovalStatus(key).call()
    assert approved and executable_at == now(chain) + 2 * DAY and expires_at == executable_at + 3 * DAY
    fails(chain, c.functions.executeGasFunding(key), recipient, match=error_selector('ExecutionDelayActive(uint256)')[2:])
    travel(chain, 2 * DAY)
    before = chain['w3'].eth.get_balance(recipient)
    tx(chain, c.functions.executeGasFunding(key), recipient)
    assert chain['w3'].eth.get_balance(recipient) > before - 10**16
    assert c.functions.totalGasFunded().call() == 10**15
    # A second approval cancelled during its delay can never execute.
    key2 = _fund(chain, c, a, recipient, 10**15, 'grant2')
    tx(chain, c.functions.voteToCancelApproval(key2), a)
    travel(chain, 2 * DAY)
    fails(chain, c.functions.executeGasFunding(key2), recipient)


def test_delay_and_window_are_configurable_by_vote(chain):
    a, b = chain['accounts'][:2]
    c = linked(chain, 'GasManager', [a, b], delay=0)
    fails(chain, c.functions.voteToSetParameter(0, 30 * DAY + 1))      # ExecutionDelay bound
    fails(chain, c.functions.voteToSetParameter(1, HOUR - 1))          # ApprovalWindow bound
    fails(chain, c.functions.voteToSetParameter(2, 0))                 # OutflowCap > 0
    tx(chain, c.functions.voteToSetParameter(0, DAY), a)
    assert c.functions.executionDelay().call() == 0
    tx(chain, c.functions.voteToSetParameter(0, DAY), b)
    assert c.functions.executionDelay().call() == DAY
    tx(chain, c.functions.voteToSetParameter(0, 0), a)
    tx(chain, c.functions.voteToSetParameter(0, 0), b)
    assert c.functions.executionDelay().call() == 0


def test_outflow_cap_per_period(chain):
    a, recipient = chain['accounts'][0], chain['accounts'][3]
    c = linked(chain, 'GasManager', cap=10**16, period=DAY)
    send(chain, c.address, 10**18)
    k1 = _fund(chain, c, a, recipient, 6 * 10**15, 'one')
    k2 = _fund(chain, c, a, recipient, 6 * 10**15, 'two')
    tx(chain, c.functions.executeGasFunding(k1), recipient)
    assert c.functions.outflowRemaining().call() == 4 * 10**15
    fails(chain, c.functions.executeGasFunding(k2), recipient, match=error_selector('OutflowCapExceeded(uint256)')[2:])
    travel(chain, DAY)
    tx(chain, c.functions.executeGasFunding(k2), recipient)
    assert c.functions.totalGasFunded().call() == 12 * 10**15


def test_burn_approval_expires_and_voter_change_clears_it(chain):
    a, b = chain['accounts'][:2]
    c = linked(chain, 'GasManager', delay=0)
    send(chain, c.address, 10**18)
    tx(chain, c.functions.voteToAddGuardian(a), a)
    key = Web3.solidity_keccak(['string', 'uint256'], ['nativeBurn', 10**15])
    tx(chain, c.functions.voteToBurnNativeCoin(10**15), a)
    assert c.functions.getBurnApproval(key).call()[0]
    travel(chain, 3 * DAY + 1)
    assert not c.functions.getBurnApproval(key).call()[0]
    fails(chain, c.functions.executeCoinBurn(10**15), a)
    # Re-approve, then a voter change voids it.
    tx(chain, c.functions.voteToBurnNativeCoin(10**15), a)
    assert c.functions.getBurnApproval(key).call()[0]
    tx(chain, c.functions.voteToAddVoter(b), a)
    assert not c.functions.getBurnApproval(key).call()[0]
    fails(chain, c.functions.executeCoinBurn(10**15), a)
    # Token burns follow the same rule.
    token = deploy(chain, 'Token'); tx(chain, token.functions.mint(c.address, 100))
    tx(chain, c.functions.voteToBurnTokens(token.address, 100), a)
    tx(chain, c.functions.voteToBurnTokens(token.address, 100), b)
    tx(chain, c.functions.executeTokenBurn(token.address, 100), a)
    assert token.functions.balanceOf(c.address).call() == 0


def test_guardians_capped_at_64(chain):
    c = linked(chain, 'GasManager')
    for i in range(64):
        tx(chain, c.functions.voteToAddGuardian(Web3.to_checksum_address('0x' + format(0x500000 + i, '040x'))))
    assert c.functions.getGuardianCount().call() == 64
    fails(chain, c.functions.voteToAddGuardian(chain['accounts'][7]))


def test_program_sponsor_refused_at_proposal(chain):
    a, sponsor, program_sponsor = chain['accounts'][0], chain['accounts'][4], chain['accounts'][6]
    feed = at(chain, 'SponsorMock', FEED)
    tx(chain, feed.functions.setProgram(program_sponsor, True))
    c = linked(chain, 'GasManager')
    send(chain, c.address, 10**18)
    fails(chain, c.functions.proposeSponsorFunding('prog', program_sponsor, 10**15, ''),
          match=error_selector('ProgramSponsorNotFundable(address)')[2:])
    operation = c.functions.proposeSponsorFunding('plain', sponsor, 10**15, '')
    key, _ = operation.call({'from': a}); tx(chain, operation, a)
    tx(chain, c.functions.executeSponsorFunding(key), sponsor)
    assert feed.functions.credit(sponsor).call() == 10**15


def test_legacy_paths_removed(chain):
    c = linked(chain, 'GasManager')
    names = {entry.get('name') for entry in c.abi}
    assert not names & {'initialize', 'initializeV2', 'voteToFundGasV1', 'executeFundGasV1', 'getLegacyFundKey',
                         'proposeFundGasV2', 'voteToFundGasV2', 'executeFundGasV2', 'voteToUpdateVoteTallyBlockThreshold'}
    assert c.functions.implementationVersion().call() == '2.6.0'


# ── CodeManager (N-8) ───────────────────────────────────────────────────────

def _registered(chain, c, count=3):
    a = chain['accounts'][0]
    tx(chain, c.functions.voteToSetFeeVault(chain['accounts'][8]), a)
    gift = deploy(chain, 'Gift')
    fee = c.functions.registrationFee().call()
    tx(chain, gift.functions.register(c.address, '113211', count), value=fee * count)
    identifier, _ = c.functions.getIdentifierCounter(gift.address, '113211').call()
    return gift, identifier


def test_global_privacy_group_grant_removed(chain):
    c = linked(chain, 'CodeManager')
    names = {entry.get('name') for entry in c.abi}
    assert not names & {'voteToAuthorizePrivacyGroup', 'isScopedPrivacyGroup', 'isWhitelistedAddress',
                        'voteToAddWhitelistedAddress', 'initialize', 'initializeWithVoter'}


def test_deauth_reauth_does_not_restore_scopes(chain):
    a, group = chain['accounts'][0], chain['accounts'][5]
    c = linked(chain, 'CodeManager')
    gift_a, _ = _registered(chain, c)
    gift_b = deploy(chain, 'Gift')
    tx(chain, c.functions.voteToSetPrivacyGroupGift(group, gift_a.address, True), a)
    assert c.functions.canPrivacyGroupAccessGift(group, gift_a.address).call()
    tx(chain, c.functions.voteToDeauthorizePrivacyGroup(group), a)
    assert c.functions.privacyGroupEpoch(group).call() == 1
    assert not c.functions.canPrivacyGroupAccessGift(group, gift_a.address).call()
    tx(chain, c.functions.voteToSetPrivacyGroupGift(group, gift_b.address, True), a)
    assert c.functions.canPrivacyGroupAccessGift(group, gift_b.address).call()
    assert not c.functions.canPrivacyGroupAccessGift(group, gift_a.address).call()
    assert not c.functions.privacyGroupGifts(group, gift_a.address).call()


def test_low_gas_delivery_reverts_and_retry_forwards_exact_limit(chain):
    a, group, recipient = chain['accounts'][0], chain['accounts'][5], chain['accounts'][6]
    c = linked(chain, 'CodeManager')
    gift, identifier = _registered(chain, c)
    tx(chain, c.functions.voteToSetPrivacyGroupGift(group, gift.address, True), a)
    uid = identifier + '-1'
    # A starved recordRedemption reverts, so the code is never consumed.
    fails(chain, c.functions.recordRedemption(uid, recipient), group, gas=900000,
          match=error_selector('InsufficientDeliveryGas()')[2:])
    assert c.functions.isUniqueIdActive(uid).call()
    tx(chain, gift.functions.setBroken(True))
    tx(chain, c.functions.recordRedemption(uid, recipient), group, gas=3000000)
    assert c.functions.getRedemptionDelivery(uid).call() == [recipient, False, 1]
    tx(chain, gift.functions.setBroken(False))
    fails(chain, c.functions.retryRedemptionDelivery(uid), chain['accounts'][9], gas=1000000,
          match=error_selector('InsufficientDeliveryGas()')[2:])
    tx(chain, c.functions.retryRedemptionDelivery(uid), chain['accounts'][9], gas=3000000)
    assert c.functions.getRedemptionDelivery(uid).call() == [recipient, True, 2]
    assert gift.functions.delivered().call() == 1


def test_registration_fee_cap(chain):
    a = chain['accounts'][0]
    c = linked(chain, 'CodeManager')
    cap = c.functions.MAX_REGISTRATION_FEE().call()
    assert cap == 10**18
    fails(chain, c.functions.voteToSetRegistrationFee(cap + 1), a)
    tx(chain, c.functions.voteToSetRegistrationFee(cap), a)
    assert c.functions.registrationFee().call() == cap


def test_code_manager_version_and_renamed_ballots(chain):
    c = linked(chain, 'CodeManager')
    names = {entry.get('name') for entry in c.abi}
    assert c.functions.implementationVersion().call() == '3.1.0'
    assert {'voteToSetRegistrationFee', 'voteToSetFeeVault', 'voteToSetVoteWindow', 'VoteWindowUpdated'} <= names
    assert not names & {'voteToUpdateRegistrationFee', 'voteToUpdateFeeVault', 'voteToUpdateVoteTallyBlockThreshold',
                        'VoteTallyBlockThresholdUpdated'}
    assert 'RedemptionAlreadyCommitted' in {e['name'] for e in c.abi if e['type'] == 'error'}


def test_runtime_sizes(builds, tmp_path):
    sizes = {name: len(bytes.fromhex(builds[name]['runtime_bytecode'].removeprefix('0x')))
             for name in ('GasManager', 'CodeManager')}
    (tmp_path / 'manager-sizes.json').write_text(json.dumps(sizes))
    for name, size in sizes.items():
        assert size <= 32768, (name, size)
    for name in ('GasManager', 'CodeManager'):
        metadata = json.loads(builds[name]['metadata'])
        assert metadata['compiler']['version'].startswith('0.8.37')
        assert metadata['settings']['evmVersion'] == 'osaka'
