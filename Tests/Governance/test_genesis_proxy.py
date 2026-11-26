"""Genesis proxy + 0x1111 governance fixes (audit X-1, X-13, X-14, X-16, X-17, X-53, X-6/H-3).

Local EVM only (eth-tester): 0x1111 is seeded from the genesis storage layout exactly as Tools/Genesis/build.py
does (no initialize()), the ProxyAdmin sits at 0x…FacAdE and the proxies start unlinked. No RPC, no real keys.
"""
from pathlib import Path
import sys

import pytest
from web3 import Web3

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_governance import (  # noqa: F401 (builds/chain are fixtures)
    builds, chain, tx, fails, deploy, at, travel, members_hash, configure, enum,
    ADDRESSES, ADMIN, REGISTRY, HOUR, DAY, WINDOW)

GRACE = 14 * DAY
MAX_DELAY = 30 * DAY


def proxy(c, key='proxy'):
    return at(c, 'TransparentUpgradeableProxy', ADDRESSES[key])


def calldata(fn):
    return bytes.fromhex(fn._encode_transaction_data()[2:])


def link_value(c, key='proxy'):
    """Links a proxy to the Value mock; the link carries (harmless) init data, as it must."""
    p = proxy(c, key)
    logic = deploy(c, 'Value')
    tx(c, p.functions.proxy_linkLogicAdmin(logic.address, calldata(logic.functions.value())))
    return p


def set_delay(c, seconds):
    tx(c, c['registry'].functions.voteToSetUpgradeDelay(seconds))  # accounts[0] is the only voter
    assert c['registry'].functions.getUpgradeDelay().call() == seconds


# ── Scheduled upgrades (X-1) ───────────────────────────────────────────────────

def test_unscheduled_upgrade_reverts(chain):
    c = chain; a = c['accounts'][0]
    p = link_value(c)
    target = deploy(c, 'Value')
    fails(c, c['admin'].functions.upgrade(p.address, target.address), a)
    fails(c, c['admin'].functions.upgradeAndCall(p.address, target.address,
                                                 calldata(target.functions.value())), a)
    # A schedule for different data does not authorise a plain upgrade, and vice versa.
    tx(c, p.functions.proxy_scheduleUpgrade(target.address, calldata(target.functions.value())), a)
    fails(c, c['admin'].functions.upgrade(p.address, target.address), a)


def test_scheduled_upgrade_waits_the_delay_and_expires_after_the_grace(chain):
    c = chain; a = c['accounts'][0]
    p = link_value(c)
    set_delay(c, DAY)
    assert p.functions.proxy_getUpgradeDelay().call() == DAY
    first, second = deploy(c, 'Value'), deploy(c, 'Value')
    tx(c, p.functions.proxy_scheduleUpgrade(first.address, b''), a)
    upgrade_id = p.functions.proxy_upgradeId(first.address, b'').call()
    assert upgrade_id == Web3.keccak(c['w3'].codec.encode(['address', 'bytes'], [first.address, b'']))
    scheduled_at, ready_at, expires_at, proposer = p.functions.proxy_getScheduledUpgrade(upgrade_id).call()
    assert (ready_at - scheduled_at, expires_at - ready_at, proposer) == (DAY, GRACE, a)
    fails(c, c['admin'].functions.upgrade(p.address, first.address), a)
    travel(c, DAY - 300)
    fails(c, c['admin'].functions.upgrade(p.address, first.address), a)
    travel(c, 600)
    tx(c, c['admin'].functions.upgrade(p.address, first.address), a)
    assert c['admin'].functions.getProxyImplementation(p.address).call() == first.address
    assert p.functions.proxy_getScheduledUpgrade(upgrade_id).call()[0] == 0
    fails(c, c['admin'].functions.upgrade(p.address, first.address), a)  # consumed: one schedule, one upgrade
    # Past the grace a ready schedule is dead, and its proposer may schedule again.
    tx(c, p.functions.proxy_scheduleUpgrade(second.address, b''), a)
    travel(c, DAY + GRACE + 300)
    fails(c, c['admin'].functions.upgrade(p.address, second.address), a)
    tx(c, p.functions.proxy_scheduleUpgrade(second.address, b''), a)
    travel(c, DAY + 300)
    tx(c, c['admin'].functions.upgrade(p.address, second.address), a)
    assert c['admin'].functions.getProxyImplementation(p.address).call() == second.address


def test_cancel_by_guardian_or_overlord_and_outsiders_refused(chain):
    c = chain; a, guardian, overlord, outsider = c['accounts'][:4]
    p = link_value(c)
    set_delay(c, HOUR)
    tx(c, p.functions.proxy_proposeGuardianChange(guardian, True), a)
    tx(c, p.functions.proxy_addOverlord(overlord), a)
    target = deploy(c, 'Value')
    upgrade_id = p.functions.proxy_upgradeId(target.address, b'').call()
    fails(c, p.functions.proxy_scheduleUpgrade(target.address, b''), outsider)
    fails(c, p.functions.proxy_scheduleUpgrade(target.address, b''), overlord)  # overlords cancel, guardians schedule
    for canceller in (guardian, overlord, a):
        tx(c, p.functions.proxy_scheduleUpgrade(target.address, b''), a)
        fails(c, p.functions.proxy_cancelUpgrade(upgrade_id), outsider)
        tx(c, p.functions.proxy_cancelUpgrade(upgrade_id), canceller)
        assert p.functions.proxy_getScheduledUpgrade(upgrade_id).call()[0] == 0
        travel(c, HOUR + 60)
        fails(c, c['admin'].functions.upgrade(p.address, target.address), a)
    fails(c, p.functions.proxy_cancelUpgrade(upgrade_id), a)  # nothing scheduled
    # A guardian schedules and executes through the ProxyAdmin.
    tx(c, p.functions.proxy_scheduleUpgrade(target.address, b''), guardian)
    travel(c, HOUR + 60)
    fails(c, c['admin'].functions.upgrade(p.address, target.address), outsider)
    tx(c, c['admin'].functions.upgrade(p.address, target.address), guardian)
    assert c['admin'].functions.getProxyImplementation(p.address).call() == target.address


def test_one_schedule_per_proposer(chain):
    c = chain; a, guardian = c['accounts'][:2]
    p = link_value(c)
    set_delay(c, HOUR)
    tx(c, p.functions.proxy_proposeGuardianChange(guardian, True), a)
    x, y = deploy(c, 'Value'), deploy(c, 'Value')
    tx(c, p.functions.proxy_scheduleUpgrade(x.address, b''), a)
    fails(c, p.functions.proxy_scheduleUpgrade(y.address, b''), a)
    fails(c, p.functions.proxy_scheduleUpgrade(x.address, b''), guardian)  # same id already scheduled
    tx(c, p.functions.proxy_scheduleUpgrade(y.address, b''), guardian)
    # Cancelling frees the proposer's slot at once.
    tx(c, p.functions.proxy_cancelUpgrade(p.functions.proxy_upgradeId(x.address, b'').call()), guardian)
    tx(c, p.functions.proxy_scheduleUpgrade(x.address, calldata(x.functions.value())), a)


# ── Link and unlinked proxies (X-16, X-53) ─────────────────────────────────────

def test_link_requires_data_and_a_guardian(chain):
    c = chain; a, outsider = c['accounts'][0], c['accounts'][5]
    p = proxy(c)
    logic = deploy(c, 'Value')
    fails(c, p.functions.proxy_linkLogicAdmin(logic.address, b''), a)
    fails(c, p.functions.proxy_linkLogicAdmin(logic.address, calldata(logic.functions.value())), outsider)
    fails(c, p.functions.proxy_linkLogicAdmin('0x' + '0' * 40, calldata(logic.functions.value())), a)
    tx(c, p.functions.proxy_linkLogicAdmin(logic.address, calldata(logic.functions.value())), a)
    assert p.functions.proxy_getIsInit().call()
    fails(c, p.functions.proxy_linkLogicAdmin(logic.address, calldata(logic.functions.value())), a)


def test_unlinked_proxy_refuses_calls_coin_and_schedules(chain):
    c = chain; a = c['accounts'][0]; w3 = c['w3']
    p = proxy(c)
    logic = deploy(c, 'Value')
    with pytest.raises(Exception):
        at(c, 'Value', p.address).functions.value().call({'from': a})
    with pytest.raises(Exception):
        w3.eth.call({'from': a, 'to': p.address, 'value': 1, 'gas': 100000})
    with pytest.raises(Exception):
        w3.eth.call({'from': a, 'to': p.address, 'data': '0x', 'gas': 100000})
    fails(c, p.functions.proxy_scheduleUpgrade(logic.address, b''), a)
    fails(c, c['admin'].functions.upgrade(p.address, logic.address), a)
    # Governance views on the shell itself still answer.
    assert p.functions.proxy_getUpgradeDelay().call() == 0
    assert p.functions.proxy_isGuardian(a).call()


def test_upgrade_and_call_requires_data(chain):
    c = chain; a = c['accounts'][0]
    p = link_value(c)
    target = deploy(c, 'Value')
    tx(c, p.functions.proxy_scheduleUpgrade(target.address, b''), a)
    fails(c, c['admin'].functions.upgradeAndCall(p.address, target.address, b''), a)
    tx(c, p.functions.proxy_cancelUpgrade(p.functions.proxy_upgradeId(target.address, b'').call()), a)
    data = calldata(target.functions.value())
    tx(c, p.functions.proxy_scheduleUpgrade(target.address, data), a)
    tx(c, c['admin'].functions.upgradeAndCall(p.address, target.address, data), a)
    assert c['admin'].functions.getProxyImplementation(p.address).call() == target.address


# ── Root renounce (X-17) ───────────────────────────────────────────────────────

def test_root_renounce_is_per_proxy_and_per_root_and_restore_clears_it(chain):
    c = chain; a, b, o1, o2 = c['accounts'][:4]
    tx(c, c['registry'].functions.voteToAddRootOverlord(b))
    p1, p2 = proxy(c, 'proxy'), proxy(c, 'GasSponsor')
    fails(c, p1.functions.proxy_revokeRootOverlord(), o1)  # not a root
    tx(c, p1.functions.proxy_revokeRootOverlord(), a)
    assert p1.functions.proxy_getRenouncedRoots().call() == [a]
    assert not p1.functions.proxy_isOverlord(a).call() and not p1.functions.proxy_isGuardian(a).call()
    assert p1.functions.proxy_isOverlord(b).call()                      # the other root keeps its power here
    assert p2.functions.proxy_isOverlord(a).call() and p2.functions.proxy_getRenouncedRoots().call() == []
    assert not p1.functions.proxy_isRootOverlordRevoked().call()
    fails(c, p1.functions.proxy_addOverlord(o1), a)
    fails(c, p1.functions.proxy_revokeRootOverlord(), a)                # already renounced here
    tx(c, p2.functions.proxy_addOverlord(o1), a)                        # still a root on the other proxy
    tx(c, p1.functions.proxy_addOverlord(o1), b)
    tx(c, p1.functions.proxy_addOverlord(o2), b)
    # Restore-root (electorate b, o1, o2 -> threshold 2; the renounced root a cannot vote) clears every renounce.
    fails(c, p1.functions.proxy_proposeRestoreRootOverlord(), a)
    tx(c, p1.functions.proxy_proposeRestoreRootOverlord(), o1)
    assert p1.functions.proxy_getRenouncedRoots().call() == [a]
    tx(c, p1.functions.proxy_proposeRestoreRootOverlord(), o2)
    assert p1.functions.proxy_getRenouncedRoots().call() == []
    assert p1.functions.proxy_isOverlord(a).call() and p1.functions.proxy_isGuardian(a).call()
    fails(c, p1.functions.proxy_proposeRestoreRootOverlord(), o1)       # nothing left to restore


# ── Exempt removal ballots (X-13) ──────────────────────────────────────────────

def test_rogue_overlord_holding_the_session_cannot_block_its_removal(chain):
    c = chain; a, o1, o2, rogue, guardian = c['accounts'][:5]
    p = proxy(c)
    for overlord in (o1, o2, rogue):
        tx(c, p.functions.proxy_addOverlord(overlord), a)
    assert p.functions.proxy_getOverlordThreshold().call() == 3
    tx(c, p.functions.proxy_proposeExpiryChange(2 * DAY), rogue)       # junk ballot takes the session lock
    assert p.functions.proxy_isVotingSessionActive().call()
    fails(c, p.functions.proxy_proposeGuardianChange(guardian, True), a)  # ordinary ballots wait
    for voter in (a, o1):
        tx(c, p.functions.proxy_proposeOverlordChange(rogue, False), voter)
    assert p.functions.proxy_isOverlord(rogue).call()
    tx(c, p.functions.proxy_proposeOverlordChange(rogue, False), o2)
    assert not p.functions.proxy_isOverlord(rogue).call()
    fails(c, p.functions.proxy_proposeExpiryChange(2 * DAY), rogue)
    tx(c, p.functions.proxy_proposeGuardianChange(guardian, True), a)  # the lock died with the epoch


def test_guardian_removal_is_exempt_from_the_session_lock(chain):
    c = chain; a, o1, guardian = c['accounts'][:3]
    p = proxy(c)
    tx(c, p.functions.proxy_proposeGuardianChange(guardian, True), a)
    tx(c, p.functions.proxy_addOverlord(o1), a)
    tx(c, p.functions.proxy_proposeExpiryChange(2 * DAY), o1)           # holds the session
    tx(c, p.functions.proxy_proposeGuardianChange(guardian, False), a)
    tx(c, p.functions.proxy_proposeGuardianChange(guardian, False), o1)
    assert not p.functions.proxy_isGuardian(guardian).call()


# ── 0x1111 (X-13, X-1, X-6) ────────────────────────────────────────────────────

def test_validator_flooder_hits_its_cap_and_its_removal_still_passes(chain):
    c = chain; r = c['registry']; a, b, d, rogue, outsider = c['accounts'][:5]
    configure(c, r, [a, b, d, rogue])
    assert r.functions.getVoterCount().call() == 4
    cap = 64 // 4
    for i in range(cap):
        tx(c, r.functions.voteToSetVoteWindow(HOUR + i), rogue)
    assert r.functions.openBallots(rogue).call() == [cap, 0]
    fails(c, r.functions.voteToSetVoteWindow(HOUR + cap), rogue)
    fails(c, r.functions.voteToSetVoteWindow(2 * HOUR), outsider)  # non-members open nothing
    tx(c, r.functions.voteToRemoveVoter(rogue), a)
    assert r.functions.openBallots(a).call() == [0, 1]                  # exempt, outside the cap
    tx(c, r.functions.voteToRemoveVoter(rogue), b)
    assert r.functions.isVoter(rogue).call()
    tx(c, r.functions.voteToRemoveVoter(rogue), d)
    assert not r.functions.isVoter(rogue).call()
    assert r.functions.activeVoteCount().call() == 0                    # voter change starts a new epoch
    assert r.functions.openBallots(rogue).call() == [0, 0]
    tx(c, r.functions.voteToSetVoteWindow(2 * HOUR), a)


def test_single_voter_cap_is_one_when_electorate_is_large(chain):
    """max(1, 64 / n): with 64 voters every proposer holds one open ballot."""
    c = chain; r = c['registry']; a = c['accounts'][0]
    others = [Web3.to_checksum_address('0x' + hex(0x200000 + i)[2:].zfill(40)) for i in range(63)]
    configure(c, r, [a] + others)
    tx(c, r.functions.voteToSetVoteWindow(2 * HOUR), a)
    fails(c, r.functions.voteToSetVoteWindow(3 * HOUR), a)
    assert r.functions.openBallots(a).call() == [1, 0]


def test_vote_to_set_upgrade_delay_bounds(chain):
    c = chain; r = c['registry']; a, b, outsider = c['accounts'][0], c['accounts'][1], c['accounts'][5]
    p = proxy(c)
    assert r.functions.getUpgradeDelay().call() == 0
    fails(c, r.functions.voteToSetUpgradeDelay(MAX_DELAY + 1))
    fails(c, r.functions.voteToSetUpgradeDelay(HOUR), outsider)
    set_delay(c, MAX_DELAY)
    assert p.functions.proxy_getUpgradeDelay().call() == MAX_DELAY
    set_delay(c, 0)                                                      # 0 is allowed (target is delay + 1)
    # With two voters, one vote changes nothing.
    tx(c, r.functions.voteToAddVoter(b))
    tx(c, r.functions.voteToSetUpgradeDelay(7 * DAY), a)
    assert r.functions.getUpgradeDelay().call() == 0
    assert r.functions.getVoteTally(enum('ValidatorSmartContractAllowList', 'SetUpgradeDelay'), 7 * DAY + 1).call()[0] == 1
    tx(c, r.functions.voteToSetUpgradeDelay(7 * DAY), b)
    assert r.functions.getUpgradeDelay().call() == 7 * DAY == p.functions.proxy_getUpgradeDelay().call()


def test_validator_has_no_initializer_and_genesis_window(chain, builds):
    selectors = builds['ValidatorSmartContractAllowList']['methodIdentifiers']
    assert not [signature for signature in selectors if signature.startswith('initialize')]
    with pytest.raises(Exception):
        chain['w3'].eth.call({'from': chain['accounts'][5], 'to': REGISTRY,
                              'data': Web3.keccak(text='initialize()')[:4], 'gas': 1000000})
    r = chain['registry']
    assert r.functions.voteTallyBlockThreshold().call() == WINDOW
    assert r.functions.getVoters().call() == [chain['accounts'][0]]
    assert r.functions.getRootOverlords().call() == [chain['accounts'][0]]
    assert len(r.functions.getValidators().call()) == 4


def test_restore_after_partial_renounce_counts_active_roots_as_voters(chain):
    """One root renounces; the other active root and a local overlord form the electorate and can restore."""
    c = chain; a, b, o = c['accounts'][:3]
    tx(c, c['registry'].functions.voteToAddRootOverlord(b))
    p = at(c, 'TransparentUpgradeableProxy', ADDRESSES['proxy'])
    tx(c, p.functions.proxy_revokeRootOverlord(), a)
    tx(c, p.functions.proxy_addOverlord(o), b)
    assert p.functions.proxy_getOverlordThreshold().call() == 2
    tx(c, p.functions.proxy_proposeRestoreRootOverlord(), o)
    tx(c, p.functions.proxy_proposeRestoreRootOverlord(), b)
    assert p.functions.proxy_getRenouncedRoots().call() == []
    assert p.functions.proxy_isGuardian(a).call()
    fails(c, p.functions.proxy_proposeRestoreRootOverlord(), c['accounts'][7])
