"""GasSponsor 1.5.2 (ProgramGasSponsor, 2026-11-25): the contract audit's P-1 for the fresh chain 113211, one targeted test per
finding, each a case 1.5.1 got wrong (failing before) that 1.5.2 gets right. THIS source's build, linked fresh at 0x…FEeD, with
real EIP-7702 accounts (test_program_sponsorship.world). X-57's release-without-charge is in test_gas_sponsor_1_5_1.py, its
revenue redirect and X-19's worker count in test_worker_sponsorship.py, X-66 in test_approved_sponsorship.py.

    DAKOTA_TEST_LEGACY_SOLC=0.8.37 python -m pytest -q Tests/Readiness/test_gas_sponsor_1_5_2.py
"""
import pytest
import solcx
from web3 import Web3
from web3.logs import DISCARD

from test_program_gas_only import E17, funding, reverts
from test_program_sponsorship import (GWEI, HARD_DAY, HARD_OP, MOCK, builds, chain, create, fails, open_dev, paid, ping,  # noqa: F401
                                      program_build, refused, run, tx, voucher_for, world)

TENANT = Web3.keccak(text='tenant')
ZERO = '0x' + '0' * 40


def mock_program(w):
    """A second program contract (the MockProgram), e.g. what a rogue admin would point setProgram at."""
    art = next(v for k, v in solcx.compile_source(MOCK, solc_version='0.8.37', output_values=['abi', 'bin']).items()
               if k.endswith(':MockProgram'))
    return create(w['c'], {'abi': art['abi'], 'creation_bytecode': '0x' + art['bin']})


# ── X-9: a pauser that can only stop ──

def test_the_pauser_pauses_and_disables_but_cannot_resume_or_move_anything(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    assert s.functions.pauser().call() == ZERO
    fails(c, s.functions.setPaused(True), a[7])                                     # no pauser yet: only the admin
    fails(c, s.functions.setPauser(a[7]), a[7])                                     # the admin's alone
    tx(c, s.functions.setPauser(a[7]))
    tx(c, s.functions.setPaused(True), a[7])                                        # the guardian stops it at once
    assert s.functions.paused().call()
    reverts(c, s.functions.setPaused(False), 'NotPlatformAdmin()', a[7])           # but cannot resume
    tx(c, s.functions.setPaused(False))
    tx(c, s.functions.setSponsorAdminEnabled(a[4], False), a[7])                   # disables one sponsor
    reverts(c, s.functions.setSponsorAdminEnabled(a[4], True), 'NotPlatformAdmin()', a[7])
    for call in (s.functions.setRelayer(a[7], True), s.functions.setVoucherSigner(a[7]), s.functions.setSponsorManager(a[4], a[7]),
                 s.functions.recoverGasCredit(a[4], a[7], 1), s.functions.setPauser(a[8]), s.functions.proposePlatformAdmin(a[7]),
                 s.functions.setSponsorOpsPerDay(a[4], 10 ** 6)):
        fails(c, call, a[7])                                                        # no money, no roles
    tx(c, s.functions.setPauser(ZERO))
    fails(c, s.functions.setPaused(True), a[7])                                     # removed


# ── X-18: a program sponsor is its opener's; setProgram once ──

def test_a_rogue_setProgram_cannot_take_program_credit(world):
    """1.5.1: setProgram(attacker) then attacker.recoverGasCredit(sponsor, attacker, credit) took every program sponsor's credit."""
    w = world; s, c, a, p = w['sponsor'], w['c'], w['a'], w['program']
    open_dev(w, credit=E17)
    assert s.functions.programSponsorOpener(w['dev']).call()[0] == p.address
    rogue = mock_program(w)
    fails(c, s.functions.setProgram(rogue.address, HARD_OP, HARD_DAY))             # the program is set once
    reverts(c, rogue.functions.recover(s.address, w['dev'], rogue.address, 1), 'NotProgram()')
    reverts(c, rogue.functions.caps(s.address, w['dev'], 1, 1), 'NotProgram()')
    reverts(c, rogue.functions.fund(s.address, w['dev']), 'NotProgram()', value=1)
    tx(c, s.functions.setProgram(p.address, HARD_OP // 2, HARD_DAY))               # the same program: its hard caps only
    assert s.functions.programConfiguration().call() == [p.address, HARD_OP // 2, HARD_DAY]
    tx(c, p.functions.recover(s.address, w['dev'], p.address, E17))                # the opener recovers, to itself
    assert funding(w, w['dev']) == [0, 0]


# ── X-20: the deny list must be seeded; reserved addresses always denied ──

def test_program_credit_never_pays_a_reserved_low_address(world):
    """1.5.1 on a fresh genesis: programDenied was empty, so program credit paid calls to 0x…1111, cafE, c0DE, FacAdE, de1E6A7E."""
    w = world; s, c = w['sponsor'], w['c']
    open_dev(w)
    tx(c, w['program'].functions.set(True, GWEI, 10, 0))
    for low in (0x1111, 0xcafe, 0xc0de, 0xfacade, 0xde1e6a7e, 0x01, 0xffffffff):
        target = Web3.to_checksum_address('0x' + hex(low)[2:].zfill(40))
        refused(w, voucher_for(w, w['dev'], w['tenant'], f'low-{low}', calls=[(target, 0, b'')]))
    above = Web3.to_checksum_address('0x' + hex(2 ** 32)[2:].zfill(40))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'above', calls=[(above, 0, b'')])) == (1, True)


def test_the_deny_count_moves_only_on_a_change(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    assert s.functions.programSponsorOpener(a[4]).call() == [ZERO, 1]               # the fixture seeded one entry
    tx(c, s.functions.setProgramDeniedTargets([a[9], a[9]], True))                  # twice in one batch: one entry
    tx(c, s.functions.setProgramDeniedTargets([a[9]], True))
    assert s.functions.programSponsorOpener(a[4]).call()[1] == 2
    tx(c, s.functions.setProgramDeniedTargets([a[9], a[8]], False))                # a[8] never denied: no underflow
    assert s.functions.programSponsorOpener(a[4]).call()[1] == 1


# ── X-60: a program sponsor is never reconfigured by the admin; hard caps clamp ──

def test_the_admin_cannot_reconfigure_a_program_sponsor(world):
    """1.5.1: configureSponsor raised a program sponsor past the hard caps and setSponsorManager handed it to anyone."""
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    open_dev(w)
    locked = 'ProgramSponsorAdminLocked(address)'
    reverts(c, s.functions.configureSponsor(w['dev'], w['tenant'], a[6], HARD_OP * 10, HARD_DAY * 10, True), locked)
    reverts(c, s.functions.setSponsorManager(w['dev'], a[9]), locked)
    reverts(c, s.functions.setSponsorOpsPerDay(w['dev'], 10 ** 9), locked)
    assert s.functions.getSponsorAccount(w['dev']).call()[1] == a[6]


def test_a_lowered_hard_cap_binds_open_program_sponsors_at_once(world):
    w = world; s, c, p = w['sponsor'], w['c'], w['program']
    open_dev(w, op=HARD_OP, day=HARD_DAY)
    tx(c, p.functions.set(True, GWEI, 10, 0))
    args = voucher_for(w, w['dev'], w['tenant'], 'big', inner=1_000_000)           # maxCost ~1.4e15: under 1e16, over 1e15
    small = 10 ** 15
    tx(c, s.functions.setProgram(p.address, small, HARD_DAY))
    account = s.functions.getSponsorAccount(w['dev']).call()
    assert account[3] == HARD_OP and account[5] == small                           # stored cap kept, effective clamped
    assert args[0][10] > small
    refused(w, args)
    tx(c, s.functions.setProgram(p.address, HARD_OP, HARD_DAY))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'big-again', inner=1_000_000)) == (1, True)


# ── X-19: ops per day for every sponsor; wallet approval by default ──

def test_every_sponsor_has_an_ops_per_day_and_a_new_one_runs_none(world):
    """1.5.1 limited only program sponsors' operations; the others' wei caps bind nothing when coin is free."""
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    tx(c, s.functions.setSponsorOpsPerDay(a[4], 1))
    assert run(w, voucher_for(w, a[4], TENANT, 'first', calls=[ping(w)])) == (1, True)
    assert s.functions.sponsorOps(a[4]).call() == [1, 1]
    refused(w, voucher_for(w, a[4], TENANT, 'second', calls=[ping(w)]))
    # a freshly configured sponsor: no operation until the admin sets its ops/day, and approved wallets only
    fresh = a[7]
    tx(c, s.functions.configureSponsor(fresh, TENANT, a[5], 10 ** 17, 10 ** 18, True))
    paid(c, s.functions.depositFor(fresh), E17)
    assert s.functions.getSponsorPolicy(fresh).call()[1] is True and s.functions.sponsorOps(fresh).call() == [0, 0]
    tx(c, s.functions.setSponsoredWallet(fresh, w['account'].address, 1), a[5])
    refused(w, voucher_for(w, fresh, TENANT, 'no-ops-yet', calls=[ping(w)]))
    tx(c, s.functions.setSponsorOpsPerDay(fresh, 5))
    assert run(w, voucher_for(w, fresh, TENANT, 'now', calls=[ping(w)])) == (1, True)


def test_a_program_sponsor_always_requires_an_approved_wallet(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    open_dev(w)
    tx(c, w['program'].functions.set(True, GWEI, 10, 0))
    tx(c, s.functions.setWalletApprovalRequired(w['dev'], False), a[6])             # the manager opts out: ignored
    assert s.functions.getSponsorPolicy(w['dev']).call()[1] is True
    tx(c, s.functions.setSponsoredWallet(w['dev'], w['account'].address, 0), a[6])
    refused(w, voucher_for(w, w['dev'], w['tenant'], 'unapproved'))
    tx(c, s.functions.setSponsoredWallet(w['dev'], w['account'].address, 1), a[6])
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'approved')) == (1, True)


# ── X-58: operation ids per sponsor ──

def test_a_worker_cannot_burn_another_sponsors_operation_id(world):
    """1.5.1: a worker of sponsor A reserving id X made sponsor B's voucher X revert OperationAlreadyConsumed."""
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    policy_src = '''pragma solidity >=0.8.20;
    contract WP { address public gasSponsor; address public sponsor; constructor(address g, address s) { gasSponsor = g; sponsor = s; }
      function workerSettlementVersion() external pure returns (uint256) { return 1; }
      function reserve(bytes32, address, uint256) external pure returns (bytes4) { return this.reserve.selector; }
      function settle(bytes32, uint256) external pure returns (bytes4) { return this.settle.selector; } }'''
    art = next(iter(solcx.compile_source(policy_src, solc_version='0.8.37', output_values=['abi', 'bin']).values()))
    policy = create(c, {'abi': art['abi'], 'creation_bytecode': '0x' + art['bin']}, s.address, a[4])
    tx(c, s.functions.configureWorker(a[7], a[8]))
    tx(c, s.functions.setTenantWorker(a[4], a[7], True), a[5])
    tx(c, s.functions.setSponsorPolicy(a[4], policy.address), a[5])
    open_dev(w)
    tx(c, w['program'].functions.set(True, GWEI, 10, 0))
    shared = Web3.keccak(text='shared')                                              # voucher_for's id for the tag 'shared'
    tx(c, s.functions.reserveWorker(a[4], a[3], shared, Web3.keccak(text='request'), 10 ** 15), a[7])
    assert s.functions.isOperationConsumed(a[4], shared).call() and not s.functions.isOperationConsumed(w['dev'], shared).call()
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'shared')) == (1, True)     # sponsor B's voucher still runs
    assert s.functions.isOperationConsumed(w['dev'], shared).call()


# ── X-59: the policy's settle is bounded inside what it is charged, and best-effort ──

SETTLE_POLICY = '''pragma solidity >=0.8.20;
contract SettlePolicy {
    address public gasSponsor; address public sponsor; uint8 public mode;           // 0 ok, 1 revert, 2 burn every gas it gets
    constructor(address g, address s) { gasSponsor = g; sponsor = s; }
    function setMode(uint8 m) external { mode = m; }
    function reserve(bytes32, address, uint256) external pure returns (bytes4) { return this.reserve.selector; }
    function settle(bytes32, uint256) external view returns (bytes4) {
        if (mode == 1) revert("no");
        if (mode == 2) { uint256 x; while (x < type(uint256).max) { x++; } }
        return this.settle.selector;
    }
}
'''


@pytest.mark.parametrize('mode', [1, 2])
def test_a_policy_settle_cannot_sink_or_underpay_the_relayer(world, mode):
    """1.5.1: a settle that reverted reverted the relayer's whole transaction (relayer gas lost); one that burned its 350,000 gas
    was charged as 150,000 (relayer underpaid ~200,000 gas a time). Now settle gets 120,000 (inside the 150,000 charged) and a
    failure is reported, not fatal."""
    w = world; s, c, a, w3 = w['sponsor'], w['c'], w['a'], w['c']['w3']
    art = next(iter(solcx.compile_source(SETTLE_POLICY, solc_version='0.8.37', output_values=['abi', 'bin']).values()))
    policy = create(c, {'abi': art['abi'], 'creation_bytecode': '0x' + art['bin']}, s.address, a[4])
    tx(c, s.functions.setSponsorPolicy(a[4], policy.address), a[5])
    tx(c, policy.functions.setMode(mode))
    args = voucher_for(w, a[4], TENANT, f'settle-{mode}', calls=[ping(w)])
    receipt = w3.eth.wait_for_transaction_receipt(s.functions.executeSponsored(*args).transact(
        {'from': a[2], 'gas': 12_000_000, 'gasPrice': GWEI}))
    assert receipt.status == 1
    failed = s.events.AllowancePolicySettleFailed().process_receipt(receipt, errors=DISCARD)
    assert len(failed) == 1 and failed[0]['args']['policy'] == policy.address
    paid_back = s.events.RelayerReimbursed().process_receipt(receipt, errors=DISCARD)[0]['args']['reimbursement']
    assert paid_back >= receipt.gasUsed * GWEI                                       # the relayer is never out of pocket
