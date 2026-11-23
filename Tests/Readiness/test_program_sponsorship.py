"""GasSponsor 1.4.0 and 1.5.0 (ProgramGasSponsor, 2026-11-22 and 2026-11-23: the developer gas program) in a real isolated EVM with real EIP-7702 accounts.

The live path is reproduced: GasSponsor 1.1.0 linked at 0x…FEeD, upgraded to the VERIFIED WorkerGasSponsor 1.3.0 (what runs on the
chain), then to ProgramGasSponsor 1.4.0 from source. A mock program stands in for DeveloperGasProgram (its one read,
sponsorLimits). No live keys or RPC.

    DAKOTA_TEST_LEGACY_SOLC=0.8.37 python -m pytest -q Tests/Readiness/test_program_sponsorship.py   # on Apple Silicon without Rosetta
"""
import importlib.util
import json
from pathlib import Path

import pytest
import solcx
from eth_account import Account
from web3 import Web3
from web3.logs import DISCARD

from test_native_sponsorship import builds, chain, setup, tx, fails, paid, at  # noqa: F401  (fixtures)
from test_governance import ADMIN

REPO = Path(__file__).resolve().parents[2]
VERIFIED = REPO / 'Contracts/Verification/20260915'
GWEI = 10 ** 9
HARD_OP, HARD_DAY = 10 ** 16, 10 ** 18          # 0.01 and 1 CRYFT, the plan's program-wide hard caps

MOCK = '''pragma solidity >=0.8.20;
interface IProgramSponsor {
    function openProgramSponsor(address,bytes32,address,uint256,uint256) external;
    function setProgramSponsorCaps(address,uint256,uint256) external;
    function depositGasCredit(address) external payable;
    function depositFor(address) external payable;
    function recoverGasCredit(address,address,uint256) external;
}
contract MockProgram {
    bool public eligible = true; uint256 public fee = 1e9; uint256 public ops = 3; uint8 public mode;  // 1 revert, 2 short, 3 flag 2, 4 gas
    function set(bool e, uint256 f, uint256 o, uint8 m) external { eligible = e; fee = f; ops = o; mode = m; }
    function sponsorLimits(address) external view returns (bool, uint256, uint256) {
        if (mode == 1) revert("no");
        if (mode == 2) assembly { mstore(0, 1) return(0, 32) }
        if (mode == 3) assembly { mstore(0, 2) mstore(32, 1000000000) mstore(64, 100) return(0, 96) }
        if (mode == 4) { uint256 x; while (gasleft() > 1000) { x++; } }
        return (eligible, fee, ops);
    }
    function open(address s, address sponsor, bytes32 tenant, address manager, uint256 op, uint256 day) external {
        IProgramSponsor(s).openProgramSponsor(sponsor, tenant, manager, op, day); }
    function caps(address s, address sponsor, uint256 op, uint256 day) external { IProgramSponsor(s).setProgramSponsorCaps(sponsor, op, day); }
    function fund(address s, address sponsor) external payable { IProgramSponsor(s).depositGasCredit{value: msg.value}(sponsor); }
    function refundable(address s, address sponsor) external payable { IProgramSponsor(s).depositFor{value: msg.value}(sponsor); }
    function recover(address s, address sponsor, address to, uint256 amount) external { IProgramSponsor(s).recoverGasCredit(sponsor, to, amount); }
    receive() external payable {}
}
contract PolicyV2 {
    address public gasSponsor; address public sponsor; bool public v2 = true;
    address[] public lastTargets; bytes4[] public lastSelectors; uint256 public v1Calls; uint256 public v2Calls;
    constructor(address g, address s) { gasSponsor = g; sponsor = s; }
    function setV2(bool on) external { v2 = on; }
    function supportsInterface(bytes4 id) external view returns (bool) {
        if (id == 0x01ffc9a7) return true;
        if (id == 0xffffffff) return false;
        return v2 && id == this.reserveCalls.selector;
    }
    function reserve(bytes32, address, uint256) external returns (bytes4) { v1Calls++; return this.reserve.selector; }
    function reserveCalls(bytes32, address, uint256, address[] calldata t, bytes4[] calldata s) external returns (bytes4) {
        v2Calls++; delete lastTargets; delete lastSelectors;
        for (uint256 i; i < t.length; ++i) { lastTargets.push(t[i]); lastSelectors.push(s[i]); }
        return this.reserveCalls.selector;
    }
    function settle(bytes32, uint256) external pure returns (bytes4) { return this.settle.selector; }
    function workerSettlementVersion() external pure returns (uint256) { return 0; }
}
'''


def verified(name): return json.loads((VERIFIED / name / 'artifact.json').read_text())


@pytest.fixture(scope='session')
def program_build():
    spec = importlib.util.spec_from_file_location('program_compiler', REPO / 'Tools/SolcCompiler/compile.py')
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)
    out = compiler.compile_contract(REPO / 'Contracts/Genesis/7702/ProgramGasSponsor.sol', solc_version='0.8.37', evm_version='osaka')
    sponsor = next(v for k, v in out.items() if k.rsplit(':', 1)[-1] == 'ProgramGasSponsor')
    mock = next(iter(solcx.compile_source(MOCK, solc_version='0.8.37', output_values=['abi', 'bin']).items()))
    found = {k.split(':')[-1]: v for k, v in solcx.compile_source(MOCK, solc_version='0.8.37', output_values=['abi', 'bin']).items()}
    return {'ProgramGasSponsor': sponsor, 'MockProgram': {'abi': found['MockProgram']['abi'], 'creation_bytecode': '0x' + found['MockProgram']['bin']},
            'PolicyV2': {'abi': found['PolicyV2']['abi'], 'creation_bytecode': '0x' + found['PolicyV2']['bin']}}


def create(c, artifact, *args):
    receipt = tx(c, c['w3'].eth.contract(abi=artifact['abi'], bytecode=artifact['creation_bytecode']).constructor(*args))
    return c['w3'].eth.contract(address=receipt.contractAddress, abi=artifact['abi'])


@pytest.fixture
def world(chain, program_build):
    """The live upgrade path, then a program (the mock) with the plan's hard caps, and one program sponsor of manager a[6]."""
    c = chain; account, old, _, dispatcher = setup(c); a = c['accounts']
    admin = at(c, 'ProxyAdmin', ADMIN)
    tx(c, admin.functions.upgrade(old.address, create(c, verified('WorkerGasSponsor')).address))
    worker = c['w3'].eth.contract(address=old.address, abi=verified('WorkerGasSponsor')['abi'])
    assert worker.functions.implementationVersion().call() == '1.3.0'
    before = {'account': worker.functions.getSponsorAccount(a[4]).call(), 'funding': worker.functions.getSponsorFunding(a[4]).call(),
              'location': worker.functions.sponsorStorageLocation().call(), 'admin': worker.functions.platformAdmin().call(),
              'signer': worker.functions.voucherSigner().call()}
    tx(c, admin.functions.upgrade(old.address, create(c, program_build['ProgramGasSponsor']).address))
    sponsor = c['w3'].eth.contract(address=old.address, abi=program_build['ProgramGasSponsor']['abi'])
    program = create(c, program_build['MockProgram'])
    tx(c, sponsor.functions.setProgram(program.address, HARD_OP, HARD_DAY))
    dev = Web3.to_checksum_address('0x' + Web3.keccak(text='cryft.dev.sponsor test').hex()[-40:])
    tenant = Web3.keccak(text='dev:test')
    return {'c': c, 'a': a, 'account': account, 'sponsor': sponsor, 'dispatcher': dispatcher, 'program': program, 'dev': dev,
            'tenant': tenant, 'before': before}


def open_dev(w, op=2 * 10 ** 15, day=4 * 10 ** 15, credit=10 ** 17):
    tx(w['c'], w['program'].functions.open(w['sponsor'].address, w['dev'], w['tenant'], w['a'][6], op, day))
    if credit: paid(w['c'], w['program'].functions.fund(w['sponsor'].address, w['dev']), credit)


def voucher_for(w, sponsor_address, tenant, tag, fee=GWEI, inner=100000, calls=None):
    c, a, account, sponsor = w['c'], w['a'], w['account'], w['sponsor']
    w3 = c['w3']; op = Web3.keccak(text=tag); deadline = w3.eth.get_block('latest').timestamp + 3600
    request = (op, sponsor.address, calls or [(a[9], 1, b'')], account.functions.getNonce().call(), deadline, inner)
    digest = account.functions.getExecutionDigest(*request).call()
    signature = Account.unsafe_sign_hash(digest, c['tester'].backend.account_keys[3]).signature
    data = bytes.fromhex(account.functions.executeSponsored(request, signature)._encode_transaction_data()[2:])
    outer = sponsor.functions.minimumCallGas(inner, len(data)).call()
    overhead = sponsor.functions.costOverheadGas(sponsor_address).call()
    voucher = (op, tenant, Web3.keccak(text='campaign'), sponsor_address, account.address, a[2], w['dispatcher'].address, Web3.keccak(data),
               outer, fee, (outer + overhead) * fee, deadline)
    vsig = Account.unsafe_sign_hash(sponsor.functions.voucherDigest(voucher).call(), c['tester'].backend.account_keys[1]).signature
    return voucher, data, vsig


def run(w, args, gas_price=GWEI):
    """(status, success) of the relayer's executeSponsored: status 0 is a refusal (nothing consumed, nothing charged)."""
    r = w['c']['w3'].eth.wait_for_transaction_receipt(w['sponsor'].functions.executeSponsored(*args).transact(
        {'from': w['a'][2], 'gas': 12000000, 'gasPrice': gas_price}))
    if r.status == 0: return 0, None
    return 1, w['sponsor'].events.SponsoredOperation().process_receipt(r, errors=DISCARD)[0]['args']['success']


def refused(w, args, gas_price=GWEI):
    sponsor, a = w['sponsor'], w['a']
    balance = sponsor.functions.getSponsorAccount(args[0][3]).call()[2]
    assert run(w, args, gas_price)[0] == 0
    assert sponsor.functions.getSponsorAccount(args[0][3]).call()[2] == balance and not sponsor.functions.isOperationConsumed(args[0][0]).call()


# ── the upgrade ──

def test_the_upgrade_from_the_live_worker_sponsor_keeps_every_record(world):
    w = world; s, a, b = w['sponsor'], w['a'], w['before']
    assert s.functions.implementationVersion().call() == '1.5.1'
    assert s.functions.getSponsorAccount(a[4]).call() == b['account'] and s.functions.getSponsorFunding(a[4]).call() == b['funding']
    assert s.functions.sponsorStorageLocation().call() == b['location'] and s.functions.platformAdmin().call() == b['admin']
    assert s.functions.voucherSigner().call() == b['signer'] and s.functions.isRelayer(a[2]).call()
    assert s.functions.workerConfiguration(a[4], a[2]).call()[1] is False
    assert s.functions.programConfiguration().call() == [w['program'].address, HARD_OP, HARD_DAY]


def test_a_non_program_sponsor_is_exactly_as_before(world):
    w = world
    w['program'].functions.set(False, 1, 0, 1).transact({'from': w['a'][0]})                  # the program says no to everything
    args = voucher_for(w, w['a'][4], Web3.keccak(text='tenant'), 'plain', fee=3 * GWEI)       # any fee the sponsor's own caps allow
    assert run(w, args) == (1, True)
    assert not w['sponsor'].functions.isProgramSponsor(w['a'][4]).call()


# ── the program's powers ──

def test_only_the_program_opens_and_only_an_address_that_never_was_a_sponsor(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    fails(c, s.functions.openProgramSponsor(w['dev'], w['tenant'], a[6], 10 ** 15, 10 ** 16))                    # the admin is not the program
    fails(c, s.functions.setProgramSponsorCaps(w['dev'], 10 ** 15, 10 ** 16))
    fails(c, w['program'].functions.open(s.address, a[4], w['tenant'], a[6], 10 ** 15, 10 ** 16))                 # an existing sponsor
    fails(c, w['program'].functions.open(s.address, w['dev'], w['tenant'], a[6], HARD_OP + 1, HARD_DAY))          # past the hard caps
    fails(c, w['program'].functions.open(s.address, w['dev'], w['tenant'], a[6], 10 ** 15, HARD_DAY + 1))
    fails(c, w['program'].functions.open(s.address, w['dev'], w['tenant'], a[6], 10 ** 15, 10 ** 14))             # day < op
    open_dev(w, credit=0)
    assert s.functions.isProgramSponsor(w['dev']).call()
    assert list(s.functions.getSponsorAccount(w['dev']).call()[:2]) == [w['tenant'], a[6]]
    fails(c, w['program'].functions.open(s.address, w['dev'], w['tenant'], a[6], 10 ** 15, 10 ** 16))             # never twice
    fails(c, w['program'].functions.caps(s.address, a[4], 10 ** 15, 10 ** 16))                                    # not a program sponsor
    fails(c, s.functions.setProgram(w['program'].address, 0, 1))
    fails(c, s.functions.setProgram(w['program'].address, 1, 1), a[6])                                            # the admin's alone


def test_caps_change_within_the_hard_caps_and_clamp_the_managers_own(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    open_dev(w, op=3 * 10 ** 15, day=15 * 10 ** 16, credit=0)
    tx(c, s.functions.setTenantLimits(w['dev'], 2 * 10 ** 15, 10 ** 17), a[6])
    tx(c, w['program'].functions.caps(s.address, w['dev'], 10 ** 15, 4 * 10 ** 15))                               # a downgrade
    account = s.functions.getSponsorAccount(w['dev']).call()
    # adminMax, tenantMax, effectiveMax, adminDaily, tenantDaily, effectiveDaily
    assert list(account[3:9]) == [10 ** 15, 10 ** 15, 10 ** 15, 4 * 10 ** 15, 4 * 10 ** 15, 4 * 10 ** 15]
    fails(c, w['program'].functions.caps(s.address, w['dev'], HARD_OP * 2, HARD_DAY))


def test_program_credit_is_gas_only_and_never_the_managers_to_withdraw(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    open_dev(w, credit=10 ** 17)
    assert s.functions.getSponsorFunding(w['dev']).call() == [0, 10 ** 17]
    fails(c, s.functions.withdrawSponsor(w['dev'], a[6], 1), a[6])
    fails(c, s.functions.recoverGasCredit(w['dev'], a[8], 10 ** 17))                                              # 1.5.0: never to another address
    fails(c, s.functions.recoverGasCredit(w['dev'], w['program'].address, 10 ** 17))                              # 1.5.1: not the admin
    tx(c, w['program'].functions.recover(s.address, w['dev'], w['program'].address, 10 ** 17))                    # the program brings it back
    assert s.functions.getSponsorFunding(w['dev']).call() == [0, 0]


# ── spending from a program sponsor ──

def test_eligible_within_the_fee_and_the_day_ops_spends_and_the_counter_resets_by_the_day(world):
    w = world; s, c = w['sponsor'], w['c']
    open_dev(w)
    tx(c, w['program'].functions.set(True, GWEI, 2, 0))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'one')) == (1, True)
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'two')) == (1, True)
    assert s.functions.programOpsToday(w['dev']).call() == 2
    refused(w, voucher_for(w, w['dev'], w['tenant'], 'three'))                                                    # the day's ops reached
    c['tester'].time_travel(c['w3'].eth.get_block('latest').timestamp + 86400); c['tester'].mine_blocks(1)
    assert s.functions.programOpsToday(w['dev']).call() == 0
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'next-day')) == (1, True)


def test_a_fee_above_the_tiers_is_refused(world):
    w = world
    open_dev(w)
    tx(w['c'], w['program'].functions.set(True, GWEI, 10, 0))
    refused(w, voucher_for(w, w['dev'], w['tenant'], 'dear', fee=GWEI + 1))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'fair', fee=GWEI)) == (1, True)


@pytest.mark.parametrize('mode', ['ineligible', 'reverts', 'short', 'bad-flag', 'burns-gas', 'no-program', 'zero-ops'])
def test_anything_but_a_clear_yes_from_the_program_refuses_and_charges_nothing(world, mode):
    w = world; s, c = w['sponsor'], w['c']
    open_dev(w)
    settings = {'ineligible': (False, GWEI, 10, 0), 'reverts': (True, GWEI, 10, 1), 'short': (True, GWEI, 10, 2),
                'bad-flag': (True, GWEI, 10, 3), 'burns-gas': (True, GWEI, 10, 4), 'no-program': (True, GWEI, 10, 0),
                'zero-ops': (True, GWEI, 0, 0)}[mode]
    tx(c, w['program'].functions.set(*settings))
    if mode == 'no-program': tx(c, s.functions.setProgram('0x' + '0' * 39 + '1', HARD_OP, HARD_DAY))
    refused(w, voucher_for(w, w['dev'], w['tenant'], mode))


def test_a_program_sponsor_takes_no_worker_reservation(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    open_dev(w)
    tx(c, s.functions.configureWorker(a[2], a[8]))
    tx(c, s.functions.setTenantWorker(w['dev'], a[2], True), a[6])
    fails(c, s.functions.reserveWorker(w['dev'], w['account'].address, Web3.keccak(text='r'), Web3.keccak(text='q'), 10 ** 15), a[2])


def test_the_counter_saturates_and_never_bricks(world):
    """Counters never fatal: the day's count only rises while below the tier's ops, so at the largest ops a day it still cannot wrap."""
    w = world; s, c = w['sponsor'], w['c']
    open_dev(w)
    tx(c, w['program'].functions.set(True, GWEI, 2 ** 256 - 1, 0))
    for tag in ('a', 'b'): assert run(w, voucher_for(w, w['dev'], w['tenant'], tag)) == (1, True)
    assert s.functions.programOpsToday(w['dev']).call() == 2


def test_storage_is_append_only(program_build):
    """The base namespace and the worker's slot are where 1.3.0 keeps them; 1.4.0's own slot is new."""
    source = (REPO / 'Contracts/Genesis/7702/ProgramGasSponsor.sol').read_text()
    assert 'keccak256("dakota.storage.ProgramGasSponsor.v1")' in source
    base = (REPO / 'Contracts/Genesis/7702/GasSponsor.sol').read_text()
    assert '0x1517881409dbca238e515328317c78f643c8aa79fdd0217b0d2dee62cd1df100' in base
    worker = (REPO / 'Contracts/Genesis/7702/WorkerGasSponsor.sol').read_text()
    assert 'keccak256("dakota.storage.WorkerGasSponsor.v1")' in worker
    # the base struct's fields, in their order, as 1.3.0 has them (no field added, moved or removed)
    fields = [line.strip() for line in base.split('struct GasSponsorStorage {')[1].split('}')[0].splitlines() if line.strip() and not line.strip().startswith('//')]
    assert fields == ['address platformAdmin;', 'address pendingPlatformAdmin;', 'address voucherSigner;', 'address approvedDelegate;',
                      'uint256 fixedOverheadGas;', 'bool paused;', 'mapping(address => bool) relayers;', 'mapping(bytes32 => bool) consumedOperations;',
                      'mapping(address => SponsorState) sponsors;', 'bytes32 approvedDelegateCodeHash;', 'mapping(address => uint256) restrictedGasCredit;',
                      'mapping(address => address) allowancePolicies;', 'mapping(address => bool) walletApprovalRequired;',
                      'mapping(address => mapping(address => uint8)) sponsoredWallets;']
    runtime = len(bytes.fromhex(program_build['ProgramGasSponsor']['runtime_bytecode'].removeprefix('0x')))
    assert runtime <= 32768, runtime                                                                             # Dakota's genesis limit


# ── allowed targets and the V2 policy (any sponsor; off by default) ──

def test_allowed_targets_are_the_managers_choice_and_every_call_is_checked(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    tenant = Web3.keccak(text='tenant')
    assert not s.functions.targetApprovalRequired(a[4]).call()
    fails(c, s.functions.setTargetApprovalRequired(a[4], True), a[6])                                            # the manager's alone
    tx(c, s.functions.setTargetApprovalRequired(a[4], True), a[5])
    refused(w, voucher_for(w, a[4], tenant, 'not-approved'))
    tx(c, s.functions.setSponsoredTarget(a[4], a[9], True), a[5])
    assert run(w, voucher_for(w, a[4], tenant, 'approved')) == (1, True)
    refused(w, voucher_for(w, a[4], tenant, 'one-of-two', calls=[(a[9], 1, b''), (a[8], 1, b'')]))               # every call, not the first
    tx(c, s.functions.setSponsoredTargets(a[4], [a[8], a[7]], True), a[5])
    assert run(w, voucher_for(w, a[4], tenant, 'both', calls=[(a[9], 1, b''), (a[8], 1, b'')])) == (1, True)
    tx(c, s.functions.setSponsoredTarget(a[4], a[9], False), a[5])
    refused(w, voucher_for(w, a[4], tenant, 'withdrawn'))
    fails(c, s.functions.setSponsoredTarget(a[4], '0x' + '0' * 40, True), a[5])
    fails(c, s.functions.setSponsoredTargets(a[4], [], True), a[5])
    tx(c, s.functions.setTargetApprovalRequired(a[4], False), a[5])
    assert run(w, voucher_for(w, a[4], tenant, 'off-again')) == (1, True)


def test_a_v2_policy_sees_the_calls_targets_and_selectors_and_a_v1_policy_is_unchanged(world, program_build):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    tenant = Web3.keccak(text='tenant')
    policy = create(c, program_build['PolicyV2'], s.address, a[4])
    tx(c, s.functions.setSponsorPolicy(a[4], policy.address), a[5])
    calls = [(a[9], 1, bytes.fromhex('a9059cbb') + b'\0' * 32), (a[8], 1, b'')]
    assert run(w, voucher_for(w, a[4], tenant, 'v2', calls=calls)) == (1, True)
    assert policy.functions.v2Calls().call() == 1 and policy.functions.v1Calls().call() == 0
    assert [policy.functions.lastTargets(i).call() for i in range(2)] == [a[9], a[8]]
    assert [policy.functions.lastSelectors(i).call() for i in range(2)] == [bytes.fromhex('a9059cbb'), b'\0' * 4]
    tx(c, policy.functions.setV2(False))
    assert run(w, voucher_for(w, a[4], tenant, 'v1')) == (1, True)
    assert policy.functions.v1Calls().call() == 1 and policy.functions.v2Calls().call() == 1


def test_program_sponsors_never_pay_for_a_denied_target_and_other_sponsors_are_untouched(world):
    """The rogue-gas audit: program credit never pays a call to the platform's own contracts (set by the platform admin)."""
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    open_dev(w)
    tx(c, w['program'].functions.set(True, GWEI, 10, 0))
    fails(c, s.functions.setProgramDeniedTargets([a[9]], True), a[6])                                            # the platform admin's alone
    tx(c, s.functions.setProgramDeniedTargets([a[9]], True))
    assert s.functions.isProgramDeniedTarget(a[9]).call()
    refused(w, voucher_for(w, w['dev'], w['tenant'], 'denied'))
    refused(w, voucher_for(w, w['dev'], w['tenant'], 'denied-second', calls=[(a[8], 1, b''), (a[9], 1, b'')]))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'allowed', calls=[(a[8], 1, b'')])) == (1, True)
    assert run(w, voucher_for(w, a[4], Web3.keccak(text='tenant'), 'not-a-program-sponsor')) == (1, True)       # a[9] still fine for others
    tx(c, s.functions.setProgramDeniedTargets([a[9]], False))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'undenied')) == (1, True)
