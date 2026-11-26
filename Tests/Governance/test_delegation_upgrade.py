"""Two-phase 7702 delegation upgrades, registry-owned beacon, transient guard (audit X-2, X-54, N-6).

Local EVM only (eth-tester, py-evm Prague/7702). Ephemeral keys; no RPC endpoints.
Compiles with solc 0.8.37; 0x1111 is the genesis validator build (0.8.19 via soljson, Tools/Genesis/build.py).
"""
from pathlib import Path
import importlib.util
import sys

import pytest
import solcx
from eth_account import Account
from web3 import Web3

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Readiness'))
from test_governance import REPO, PATHS, chain, tx, fails, deploy, at, linked, ADDRESSES, validator_artifact  # noqa: F401 (fixture)
from test_native_sponsorship import authorize  # noqa: E402

SOLC = '0.8.37'
NEEDED = ['TransparentUpgradeableProxy', 'ProxyAdmin', 'CryftDelegationRegistry', 'CryftDelegation',
          'CryftDelegationBeacon', 'CryftBeaconDispatcher']
MOCKS = '''pragma solidity ^0.8.24;
contract Value { function value() external pure returns(uint) { return 42; } }
contract SlotWriter { function poke(bytes32 slot, uint256 value) external { assembly { sstore(slot, value) } } }
contract Sink { uint256 public hits; function hit() external payable { hits += 1; } }
'''


@pytest.fixture(scope='module')
def builds():
    """Only what these tests need (overrides test_governance.builds for this module)."""
    spec = importlib.util.spec_from_file_location('delegation_compiler', REPO / 'Tools/SolcCompiler/compile.py')
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)
    output = {}
    for name in NEEDED:
        contracts = compiler.compile_contract(REPO / 'Contracts' / PATHS[name], solc_version=SOLC, evm_version='osaka')
        output[name] = next(v for k, v in contracts.items() if k.rsplit(':', 1)[-1] == name)
    output['ValidatorSmartContractAllowList'] = validator_artifact()
    for key, artifact in solcx.compile_source(MOCKS, solc_version=SOLC, evm_version='osaka', output_values=['abi', 'bin', 'bin-runtime']).items():
        output[key.split(':')[-1]] = {'abi': artifact['abi'], 'creation_bytecode': '0x' + artifact['bin'],
                                      'runtime_bytecode': '0x' + artifact['bin-runtime']}
    return output


ENTRY = ADDRESSES['CryftDelegationRegistry']
assert ENTRY == Web3.to_checksum_address('0x00000000000000000000000000000000de1E6A7E')
DELAY = 3600
SPONSOR = ADDRESSES['GasSponsor']  # any contract stands in (sponsor readiness is covered in Readiness tests)
MAX_DELAY = 30 * 24 * 3600
OLD_REENTRANCY_SLOT = 0x2d5df833376e6c9531b3cb92f5745ecf8ad8197730684ec3db99cc12d4e93d01



def code_hash(c, address):
    return Web3.keccak(c['w3'].eth.get_code(address))


def advance(c, seconds):
    c['tester'].time_travel(c['w3'].eth.get_block('latest').timestamp + seconds)
    c['tester'].mine_blocks(1)


def stack(c, delay=DELAY, admin=None, sponsor=None):
    """Implementation + registry-owned beacon + dispatcher, registry linked WITH init data."""
    logic = deploy(c, 'CryftDelegation')
    beacon = deploy(c, 'CryftDelegationBeacon', logic.address)
    dispatcher = deploy(c, 'CryftBeaconDispatcher', beacon.address)
    registry = linked(c, 'CryftDelegationRegistry', initializer='initializeWithAdmin',
                      args=(dispatcher.address, beacon.address, sponsor or SPONSOR,
                            admin or c['accounts'][0], delay))
    return registry, beacon, dispatcher, logic


def test_beacon_owner_is_registry_at_deploy_with_no_handover(chain):
    c = chain; a = c['accounts']
    logic = deploy(c, 'CryftDelegation')
    # Anyone may deploy the beacon: a plain non-root account here.
    assert not c['registry'].functions.isRootOverlord(a[7]).call()
    factory = c['w3'].eth.contract(abi=c['builds']['CryftDelegationBeacon']['abi'],
                                   bytecode=c['builds']['CryftDelegationBeacon']['creation_bytecode'])
    receipt = tx(c, factory.constructor(logic.address), a[7])
    beacon = at(c, 'CryftDelegationBeacon', receipt.contractAddress)
    assert beacon.functions.owner().call() == ENTRY
    assert beacon.functions.implementation().call() == logic.address
    names = {item.get('name') for item in beacon.abi}
    for gone in ['transferOwnership', 'acceptOwnership', 'cancelOwnershipTransfer', 'renounceOwnership', 'pendingOwner']:
        assert gone not in names
    other = deploy(c, 'CryftDelegation')
    for sender in [a[0], a[7]]:  # neither the root nor the deployer can move the implementation
        fails(c, beacon.functions.upgradeTo(other.address), sender)
    # The registry links against it with no handover step.
    dispatcher = deploy(c, 'CryftBeaconDispatcher', beacon.address)
    registry = linked(c, 'CryftDelegationRegistry', initializer='initializeWithAdmin',
                      args=(dispatcher.address, beacon.address, SPONSOR, a[0], 0))
    snapshot = registry.functions.currentSnapshot().call()
    assert snapshot[5] == ENTRY and snapshot[14]  # beaconOwner, registryControlsBeacon
    assert 'acceptBeaconOwnership' not in {item.get('name') for item in registry.abi}


def test_registry_rejects_beacon_it_does_not_own(chain):
    c = chain; a = c['accounts']
    logic = deploy(c, 'CryftDelegation')
    fake = deploy(c, 'Value')  # no owner() at all
    dispatcher = deploy(c, 'CryftBeaconDispatcher', deploy(c, 'CryftDelegationBeacon', logic.address).address)
    reg_logic = deploy(c, 'CryftDelegationRegistry')
    data = bytes.fromhex(reg_logic.functions.initializeWithAdmin(dispatcher.address, fake.address, SPONSOR, a[0], 0)._encode_transaction_data()[2:])
    proxy = at(c, 'TransparentUpgradeableProxy', ENTRY)
    fails(c, proxy.functions.proxy_linkLogicAdmin(reg_logic.address, data))


def test_upgrade_before_delay_reverts_and_after_delay_executes(chain):
    c = chain; a = c['accounts']
    registry, beacon, _, logic = stack(c)
    assert registry.functions.upgradeDelay().call() == DELAY
    assert registry.functions.MAX_UPGRADE_DELAY().call() == MAX_DELAY
    assert 'upgradeDelegation' not in {item.get('name') for item in registry.abi}
    nxt = deploy(c, 'CryftDelegation'); h = code_hash(c, nxt.address)
    fails(c, registry.functions.executeDelegationUpgrade(nxt.address, h))          # nothing scheduled
    fails(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h), a[1])  # not admin
    fails(c, registry.functions.scheduleDelegationUpgrade(nxt.address, b'\x01' * 32))  # wrong hash
    fails(c, registry.functions.scheduleDelegationUpgrade(logic.address, code_hash(c, logic.address)))  # same
    r = tx(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h))
    event = registry.events.DelegationUpgradeScheduled().process_receipt(r)[0]['args']
    assert event['implementation'] == nxt.address and event['readyAt'] == event['scheduledAt'] + DELAY
    pending = registry.functions.pendingDelegationUpgrade().call()
    assert pending[0] == nxt.address and pending[1] == h and pending[3] == event['readyAt']
    fails(c, registry.functions.scheduleDelegationUpgrade(deploy(c, 'CryftDelegation').address, h))  # one at a time
    fails(c, registry.functions.executeDelegationUpgrade(nxt.address, h))          # before the delay
    advance(c, DELAY // 2)
    fails(c, registry.functions.executeDelegationUpgrade(nxt.address, h))
    advance(c, DELAY)
    fails(c, registry.functions.executeDelegationUpgrade(logic.address, h))        # must match the schedule
    fails(c, registry.functions.executeDelegationUpgrade(nxt.address, h), a[1])    # admin only
    tx(c, registry.functions.executeDelegationUpgrade(nxt.address, h))
    assert beacon.functions.implementation().call() == nxt.address
    assert registry.functions.pendingDelegationUpgrade().call()[0] == '0x' + '0' * 40
    assert registry.functions.releaseCount().call() == 2
    assert registry.functions.currentSnapshot().call()[16]  # matchesLatestRelease
    # Known-good rollback: the earlier release, through the same two-phase path.
    first = registry.functions.releaseAt(0).call()[0]
    tx(c, registry.functions.scheduleDelegationUpgrade(first[3], first[4]))
    fails(c, registry.functions.executeDelegationUpgrade(first[3], first[4]))
    advance(c, DELAY + 1)
    tx(c, registry.functions.executeDelegationUpgrade(first[3], first[4]))
    assert beacon.functions.implementation().call() == logic.address


def test_cancel_by_admin_and_by_genesis_guardian(chain):
    c = chain; a = c['accounts']
    registry, beacon, _, logic = stack(c, admin=a[1])  # a[0] is the root (a guardian), not the admin
    nxt = deploy(c, 'CryftDelegation'); h = code_hash(c, nxt.address)
    fails(c, registry.functions.cancelDelegationUpgrade(), a[1])  # nothing to cancel
    tx(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h), a[1])
    fails(c, registry.functions.cancelDelegationUpgrade(), a[6])   # stranger
    r = tx(c, registry.functions.cancelDelegationUpgrade(), a[1])  # admin
    assert registry.events.DelegationUpgradeCancelled().process_receipt(r)[0]['args']['cancelledBy'] == a[1]
    advance(c, DELAY + 1)
    fails(c, registry.functions.executeDelegationUpgrade(nxt.address, h), a[1])
    tx(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h), a[1])
    fails(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h), a[0])  # a guardian cannot schedule
    tx(c, registry.functions.cancelDelegationUpgrade(), a[0])      # guardian (root) cancels
    advance(c, DELAY + 1)
    fails(c, registry.functions.executeDelegationUpgrade(nxt.address, h), a[1])
    assert beacon.functions.implementation().call() == logic.address


def test_delay_raise_is_immediate_and_lowering_waits(chain):
    c = chain; a = c['accounts']
    registry, beacon, _, _ = stack(c)
    fails(c, registry.functions.setUpgradeDelay(MAX_DELAY + 1))
    fails(c, registry.functions.setUpgradeDelay(DELAY))            # same
    fails(c, registry.functions.setUpgradeDelay(10), a[1])         # not admin
    # Lowering: scheduled, waits the CURRENT delay, cancellable.
    tx(c, registry.functions.setUpgradeDelay(10))
    assert registry.functions.upgradeDelay().call() == DELAY
    assert registry.functions.pendingUpgradeDelayDecrease().call()[:2] == [True, 10]
    fails(c, registry.functions.executeUpgradeDelayDecrease())
    fails(c, registry.functions.cancelUpgradeDelayDecrease(), a[6])
    tx(c, registry.functions.cancelUpgradeDelayDecrease())
    advance(c, DELAY + 1)
    fails(c, registry.functions.executeUpgradeDelayDecrease())
    tx(c, registry.functions.setUpgradeDelay(10))
    advance(c, DELAY // 2)
    fails(c, registry.functions.executeUpgradeDelayDecrease())
    advance(c, DELAY)
    tx(c, registry.functions.executeUpgradeDelayDecrease())
    assert registry.functions.upgradeDelay().call() == 10
    assert not registry.functions.pendingUpgradeDelayDecrease().call()[0]
    # Raising is immediate and also holds back an upgrade scheduled under the shorter delay.
    nxt = deploy(c, 'CryftDelegation'); h = code_hash(c, nxt.address)
    tx(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h))
    tx(c, registry.functions.setUpgradeDelay(MAX_DELAY))
    assert registry.functions.upgradeDelay().call() == MAX_DELAY
    advance(c, 20)
    fails(c, registry.functions.executeDelegationUpgrade(nxt.address, h))
    advance(c, MAX_DELAY)
    tx(c, registry.functions.executeDelegationUpgrade(nxt.address, h))
    assert beacon.functions.implementation().call() == nxt.address


def test_zero_delay_dev_mode_still_two_phase(chain):
    c = chain
    registry, beacon, _, _ = stack(c, delay=0)
    nxt = deploy(c, 'CryftDelegation'); h = code_hash(c, nxt.address)
    tx(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h))
    tx(c, registry.functions.executeDelegationUpgrade(nxt.address, h))
    assert beacon.functions.implementation().call() == nxt.address
    fails(c, registry.functions.setUpgradeDelay(0))


def test_implementation_initializers_locked_and_entry_init_root_only(chain):
    c = chain; a = c['accounts']; w3 = c['w3']
    registry, beacon, dispatcher, logic = stack(c)
    reg_logic = at(c, 'CryftDelegationRegistry', registry.functions.registryImplementation().call())
    assert w3.eth.get_storage_at(reg_logic.address, 0)[-1] == 0xff  # Initializable._initialized == max
    for sender in [a[0], a[6]]:
        fails(c, reg_logic.functions.initializeWithAdmin(dispatcher.address, beacon.address, SPONSOR, sender, 0), sender)
        fails(c, reg_logic.functions.initialize(dispatcher.address, beacon.address, SPONSOR, 0), sender)
    fails(c, registry.functions.initializeWithAdmin(dispatcher.address, beacon.address, SPONSOR, a[6], 0), a[6])
    fails(c, registry.functions.initialize(dispatcher.address, beacon.address, SPONSOR, 0))
    # The shared account logic has no initializer and refuses direct execution.
    assert not any(item.get('name', '').startswith('initialize') for item in logic.abi)
    fails(c, logic.functions.executeSponsored((b'\x01' * 32, a[0], [(a[1], 0, b'')], 0, 2**40, 100000), b''))


def test_entry_initializer_cannot_be_front_run(chain):
    c = chain; a = c['accounts']
    logic = deploy(c, 'CryftDelegation')
    beacon = deploy(c, 'CryftDelegationBeacon', logic.address)
    dispatcher = deploy(c, 'CryftBeaconDispatcher', beacon.address)
    reg_logic = deploy(c, 'CryftDelegationRegistry')
    proxy = at(c, 'TransparentUpgradeableProxy', ENTRY)
    registry = at(c, 'CryftDelegationRegistry', ENTRY)
    good = bytes.fromhex(reg_logic.functions.initializeWithAdmin(dispatcher.address, beacon.address, SPONSOR, a[0], DELAY)._encode_transaction_data()[2:])
    fails(c, proxy.functions.proxy_linkLogicAdmin(reg_logic.address, good), a[6])  # strangers cannot link
    receipt = c['w3'].eth.wait_for_transaction_receipt(proxy.functions.proxy_linkLogicAdmin(reg_logic.address, b'').transact({'from': a[0], 'gas': 24000000}))
    if receipt.status == 0:
        # The genesis proxy itself requires init data at link (audit X-16): no open-initializer window.
        tx(c, proxy.functions.proxy_linkLogicAdmin(reg_logic.address, good))
        assert registry.functions.registryAdmin().call() == a[0]
        fails(c, registry.functions.initializeWithAdmin(dispatcher.address, beacon.address, SPONSOR, a[6], 0), a[6])
        return
    # Worst case, linked without data: the registry initializer still only runs for a live root.
    fails(c, registry.functions.initializeWithAdmin(dispatcher.address, beacon.address, SPONSOR, a[6], 0), a[6])
    fails(c, registry.functions.initialize(dispatcher.address, beacon.address, SPONSOR, 0), a[6])
    fails(c, registry.functions.initializeWithAdmin(dispatcher.address, beacon.address, SPONSOR, a[0], MAX_DELAY + 1))
    tx(c, registry.functions.initializeWithAdmin(dispatcher.address, beacon.address, SPONSOR, a[0], DELAY))
    assert registry.functions.registryAdmin().call() == a[0]


def direct_execute(c, account, sink, tag, nonce=None, signature=None):
    """Delegated execution by an executor (a[2]) with the account owner's signature."""
    a = c['accounts']; keys = c['tester'].backend.account_keys
    calls = [(sink.address, 7, bytes.fromhex(sink.functions.hit()._encode_transaction_data()[2:]))]
    nonce = account.functions.getNonce().call() if nonce is None else nonce
    request = (Web3.keccak(text=tag), a[2], calls, nonce, c['w3'].eth.get_block('latest').timestamp + 3600, 200000)
    if signature is None:
        signature = Account.unsafe_sign_hash(account.functions.getExecutionDigest(*request).call(), keys[3]).signature
    return account.functions.executeSponsored(request, signature)


def test_7702_acceptance_through_two_phase_upgrade_and_stale_slot(chain):
    c = chain; a = c['accounts']; w3 = c['w3']
    registry, beacon, dispatcher, logic = stack(c)
    authorize(c, dispatcher.address)
    account = at(c, 'CryftDelegation', a[3])
    w3.eth.wait_for_transaction_receipt(w3.eth.send_transaction({'from': a[0], 'to': a[3], 'value': 10**18, 'gas': 100000}))
    sink = deploy(c, 'Sink')
    status = registry.functions.accountStatus(account.address).call()
    assert status[0] and status[1] and status[2] and status[3]  # delegated, route, protocol, interfaces
    assert w3.eth.get_code(account.address).hex() == 'ef0100' + dispatcher.address[2:].lower()
    fails(c, direct_execute(c, account, sink, 'bad-sig', signature=b''), a[2])
    tx(c, direct_execute(c, account, sink, 'first'), a[2])
    assert account.functions.getNonce().call() == 1 and sink.functions.hits().call() == 1
    fails(c, direct_execute(c, account, sink, 'stale', nonce=0), a[2])
    # A stale value in the old storage reentrancy slot (left by any earlier delegate) cannot brick execution.
    writer = deploy(c, 'SlotWriter')
    poke = bytes.fromhex(writer.functions.poke(OLD_REENTRANCY_SLOT.to_bytes(32, 'big'), 1)._encode_transaction_data()[2:])
    authorize(c, writer.address, poke)
    assert int.from_bytes(w3.eth.get_storage_at(account.address, OLD_REENTRANCY_SLOT), 'big') == 1
    authorize(c, dispatcher.address)
    tx(c, direct_execute(c, account, sink, 'stale-slot'), a[2])
    assert account.functions.getNonce().call() == 2
    # Two-phase upgrade keeps the account working and its nonce.
    nxt = deploy(c, 'CryftDelegation'); h = code_hash(c, nxt.address)
    tx(c, registry.functions.scheduleDelegationUpgrade(nxt.address, h))
    tx(c, direct_execute(c, account, sink, 'while-pending'), a[2])  # still the old logic
    assert beacon.functions.implementation().call() == logic.address
    advance(c, DELAY + 1)
    tx(c, registry.functions.executeDelegationUpgrade(nxt.address, h))
    assert beacon.functions.implementation().call() == nxt.address
    assert account.functions.implementationVersion().call() == '1.2.0'
    tx(c, direct_execute(c, account, sink, 'after-upgrade'), a[2])
    assert account.functions.getNonce().call() == 4 and sink.functions.hits().call() == 4
