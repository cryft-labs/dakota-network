"""GasSponsor 1.5.1 (ProgramGasSponsor, 2026-11-23): the safe-coding review's C3 and C4, on THIS source's build linked fresh at
0x…FEeD with real EIP-7702 accounts, as test_program_sponsorship.py:

  C3  the platform's CALL APPROVALS (ApprovedGasSponsor: target, selector, value, code hash) are enforced again for every sponsor
      but a developer program's; only the platform administrator sets them; their storage is ApprovedGasSponsor's own namespace;
  C4  releaseWorker(id): a stuck worker reservation settled at its maximum, by the platform administrator at any time or by anyone
      after RESERVATION_RELEASE_AFTER (7 days); idempotent; one WorkerReleased each; a refusing policy never keeps it stuck.

    CRYFT_TEST_LEGACY_SOLC=0.8.37 python -m pytest -q Tests/Readiness/test_gas_sponsor_1_5_1.py

1.5.2 (X-57): ANYONE's release after the 7 days charges NOTHING (a lost worker is the platform's failure); only the platform
administrator's release charges the maximum. The engine is linked fresh (test_program_sponsorship.world).
"""
import pytest
import solcx
from web3 import Web3
from web3.logs import DISCARD

from test_program_gas_only import E17, funding, reverts
from test_program_sponsorship import (GWEI, PING, approve, builds, chain, create, fails, open_dev, paid, ping, program_build,  # noqa: F401
                                      refused, run, tx, voucher_for, world)

DAY = 86400
TENANT = Web3.keccak(text='tenant')
POLICY = '''pragma solidity >=0.8.20;
contract WorkerPolicy {
    address public gasSponsor; address public sponsor; bool public refuseSettle; uint256 public settled;
    constructor(address g, address s) { gasSponsor = g; sponsor = s; }
    function setRefuse(bool r) external { refuseSettle = r; }
    function workerSettlementVersion() external pure returns (uint256) { return 1; }
    function reserve(bytes32, address, uint256) external pure returns (bytes4) { return this.reserve.selector; }
    function settle(bytes32, uint256) external returns (bytes4) { if (refuseSettle) revert("no"); settled++; return this.settle.selector; }
}
'''


def later(w, seconds):
    c = w['c']
    c['tester'].time_travel(c['w3'].eth.get_block('latest').timestamp + seconds); c['tester'].mine_blocks(1)


# ── C3: call approvals ──

def test_approvals_are_enforced_for_a_platform_sponsor(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    before = funding(w, a[4])
    refused(w, voucher_for(w, a[4], TENANT, 'eoa'))                                          # an EOA, no data: never approvable
    refused(w, voucher_for(w, a[4], TENANT, 'unlisted', calls=[(w['sinks'][0], 0, bytes.fromhex('deadbeef'))]))   # a selector not approved
    refused(w, voucher_for(w, a[4], TENANT, 'too-much', calls=[ping(w, 0, 2)]))              # a value above maxValue
    assert funding(w, a[4]) == before
    assert run(w, voucher_for(w, a[4], TENANT, 'approved', calls=[ping(w)])) == (1, True)
    assert w['sink'].functions.pings().call() == 1


def test_a_revoked_approval_refuses_again_and_only_the_platform_admin_sets_them(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    zero = (b'\0' * 32, '0x' + '0' * 40, b'\0' * 32, 0, False, '0x' + '0' * 40, b'\0' * 32)
    fails(c, s.functions.setCallApprovals([(w['sinks'][0], PING, zero)]), a[5])              # a manager is not the platform admin
    fails(c, s.functions.setCallApprovals([(w['sinks'][0], PING, zero)]), a[9])
    tx(c, s.functions.setCallApprovals([(w['sinks'][0], PING, zero)]))                       # revoked: a zero code hash
    refused(w, voucher_for(w, a[4], TENANT, 'revoked', calls=[ping(w)]))
    assert s.functions.getCallApproval(w['sinks'][0], PING).call()[0] == b'\0' * 32
    approve(w, [(w['sinks'][0], PING)])
    assert run(w, voucher_for(w, a[4], TENANT, 'again', calls=[ping(w)])) == (1, True)
    assert s.functions.approvedCall(w['sinks'][0], 1, PING).call() and not s.functions.approvedCall(w['sinks'][0], 2, PING).call()


def test_an_approval_needs_the_targets_code_as_reviewed(world):
    w = world; s, c = w['sponsor'], w['c']
    wrong = (b'\x11' * 32, '0x' + '0' * 40, b'\0' * 32, 0, False, '0x' + '0' * 40, b'\0' * 32)
    reverts(c, s.functions.setCallApprovals([(w['sinks'][0], PING, wrong)]), 'InvalidApproval()')
    reverts(c, s.functions.setCallApprovals([]), 'InvalidApproval()')


def test_a_program_sponsor_needs_no_platform_approval(world):
    """A developer's own contracts are governed by the program's deny list, the manager's targets and the router's lists."""
    w = world; c, a = w['c'], w['a']
    open_dev(w, credit=E17)
    tx(c, w['program'].functions.set(True, GWEI, 10, 0))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'dev-eoa')) == (1, True)            # an unapproved EOA call: paid
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'dev-sink', calls=[(w['sinks'][1], 0, bytes.fromhex('deadbeef'))])) == (1, True)


# ── C4: releasing a stuck worker reservation ──

@pytest.fixture
def reserved(world):
    """Sponsor a[4] (manager a[5]) with a worker a[7] (treasury a[8]) and a worker policy; one reservation of 1e15 by a[7]."""
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    out = solcx.compile_source(POLICY, solc_version='0.8.37', output_values=['abi', 'bin'])
    art = next(iter(out.values()))
    policy = create(c, {'abi': art['abi'], 'creation_bytecode': '0x' + art['bin']}, s.address, a[4])
    tx(c, s.functions.configureWorker(a[7], a[8]))
    tx(c, s.functions.setTenantWorker(a[4], a[7], True), a[5])
    tx(c, s.functions.setSponsorPolicy(a[4], policy.address), a[5])
    paid(c, s.functions.depositFor(a[4]), E17, a[9])
    op = Web3.keccak(text='stuck')
    tx(c, s.functions.reserveWorker(a[4], a[3], op, Web3.keccak(text='request'), 10 ** 15), a[7])
    assert s.functions.pendingWorkerCost(a[4]).call() == 10 ** 15
    w.update(policy=policy, op=op)
    return w


def released(w, receipt):
    return w['sponsor'].events.WorkerReleased().process_receipt(receipt, errors=DISCARD)


def test_anyone_releases_a_stuck_reservation_after_seven_days_without_charge(reserved):
    w = reserved; s, c, a, w3 = w['sponsor'], w['c'], w['a'], w['c']['w3']
    assert s.functions.RESERVATION_RELEASE_AFTER().call() == 7 * DAY
    reverts(c, s.functions.releaseWorker(w['op']), 'WorkerNotAuthorized()', a[9])           # a stranger, too soon
    later(w, 7 * DAY - 60)
    reverts(c, s.functions.releaseWorker(w['op']), 'WorkerNotAuthorized()', a[9])
    later(w, 120)
    balance, treasury = s.functions.getSponsorAccount(a[4]).call()[2], w3.eth.get_balance(a[8])
    events = released(w, tx(c, s.functions.releaseWorker(w['op']), a[9]))
    assert len(events) == 1 and events[0]['args']['cost'] == 0 and events[0]['args']['policySettled'] is True   # X-57: no charge
    assert events[0]['args']['by'] == a[9] and events[0]['args']['sponsor'] == a[4]
    assert s.functions.getSponsorAccount(a[4]).call()[2] == balance and w3.eth.get_balance(a[8]) == treasury
    assert s.functions.pendingWorkerCost(a[4]).call() == 0 and w['policy'].functions.settled().call() == 1
    # idempotent: again, nothing changes and nothing is said
    assert s.functions.releaseWorker(w['op']).call({'from': a[9]}) == 0
    assert len(released(w, tx(c, s.functions.releaseWorker(w['op']), a[9]))) == 0
    assert s.functions.getSponsorAccount(a[4]).call()[2] == balance
    fails(c, s.functions.settleWorker(w['op'], 1, Web3.keccak(text='late')), a[7])        # nor can it be settled after


def test_the_platform_admin_releases_at_once_and_a_refusing_policy_never_keeps_it_stuck(reserved):
    w = reserved; s, c, a = w['sponsor'], w['c'], w['a']
    tx(c, w['policy'].functions.setRefuse(True))
    events = released(w, tx(c, s.functions.releaseWorker(w['op'])))                         # the platform admin, at once
    assert len(events) == 1 and events[0]['args']['policySettled'] is False and events[0]['args']['cost'] == 10 ** 15
    assert s.functions.pendingWorkerCost(a[4]).call() == 0
    assert s.functions.releaseWorker(Web3.keccak(text='never')).call({'from': a[9]}) == 0     # never reserved: nothing
