"""GasSponsor 1.5.0 and 1.5.1 (ProgramGasSponsor, 2026-11-23): a program sponsor holds gas credit and nothing else (Chad: developer gas is
"only spendable and not transferrable"). On the live path (1.1.0 at 0x…FEeD, the VERIFIED 1.3.0, then this build) with real
EIP-7702 accounts, as test_program_sponsorship.py:

  * depositFor to a program sponsor reverts ProgramSponsorGasOnly (from anyone, the program included);
  * withdrawSponsor from it reverts ProgramSponsorNoWithdraw;
  * depositGasCredit for it is accepted from the program alone (NotProgram otherwise);
  * recoverGasCredit for it is the program's alone (1.5.1: NotProgram for the platform admin too), to the program alone;
  * an ineligible answer (a revoked Pass) stops spending at once, on chain, and charges nothing;
  * a sponsor the program never opened is exactly as before: refundable deposits, withdrawals, credit from anyone, recovery anywhere;
  * the committed build and its layout proof (Releases/GasSponsor/1.5.1) are this source's, append-only, within 32 KB.

    DAKOTA_TEST_LEGACY_SOLC=0.8.37 python -m pytest -q Tests/Readiness/test_program_gas_only.py
"""
import json

import pytest
from web3 import Web3

from test_program_sponsorship import (GWEI, REPO, builds, chain, fails, open_dev, paid, ping, program_build, refused, run, tx,  # noqa: F401
                                      voucher_for, world)

E17 = 10 ** 17


def selector(error):
    return Web3.keccak(text=error)[:4].hex().removeprefix('0x')


def reverts(c, fn, error, sender=None, value=0):
    """The call reverts with exactly `error` (its selector leads the revert data)."""
    try:
        fn.call({'from': sender or c['accounts'][0], 'value': value, 'gas': 24000000})
    except Exception as failure:                                       # noqa: BLE001 (web3 and eth-tester raise several kinds)
        parts = (getattr(failure, 'data', None), *failure.args)
        text = ' '.join(x.hex() if isinstance(x, (bytes, bytearray)) else str(x) for x in parts)
        for x in parts:                                                # 'execution reverted: b"…"' carries the bytes as text
            if isinstance(x, str) and "b'" in x:
                try: text += ' ' + __import__('ast').literal_eval(x[x.index("b'"):]).hex()
                except (ValueError, SyntaxError): pass
        assert selector(error) in text.lower(), f'{error}: {text[:200]}'
        return
    raise AssertionError(f'{error}: the call did not revert')


def funding(w, sponsor):
    return list(w['sponsor'].functions.getSponsorFunding(sponsor).call())


# ── the version ──

def test_the_version_is_1_5_1_and_every_record_survives(world):
    w = world; s, a, b = w['sponsor'], w['a'], w['before']
    assert s.functions.implementationVersion().call() == '1.5.1'
    assert s.functions.getSponsorAccount(a[4]).call() == b['account'] and s.functions.getSponsorFunding(a[4]).call() == b['funding']
    assert s.functions.platformAdmin().call() == b['admin'] and s.functions.voucherSigner().call() == b['signer']


# ── a program sponsor: gas credit only ──

def test_depositFor_to_a_program_sponsor_reverts_for_everyone(world):
    w = world; s, c, a, p = w['sponsor'], w['c'], w['a'], w['program']
    open_dev(w, credit=E17)
    for sender in (a[0], a[6], a[9]):                                  # the platform admin, the manager, a stranger
        reverts(c, s.functions.depositFor(w['dev']), 'ProgramSponsorGasOnly(address)', sender, value=1)
    reverts(c, p.functions.refundable(s.address, w['dev']), 'ProgramSponsorGasOnly(address)', value=1)   # the program too
    assert funding(w, w['dev']) == [0, E17]


def test_withdrawSponsor_from_a_program_sponsor_reverts(world):
    w = world; s, c, a = w['sponsor'], w['c'], w['a']
    open_dev(w, credit=E17)
    reverts(c, s.functions.withdrawSponsor(w['dev'], a[6], 1), 'ProgramSponsorNoWithdraw(address)', a[6])
    reverts(c, s.functions.withdrawSponsor(w['dev'], a[6], E17), 'ProgramSponsorNoWithdraw(address)', a[6])
    fails(c, s.functions.withdrawSponsor(w['dev'], a[6], 1), a[9])                      # a stranger: not the manager either
    assert funding(w, w['dev']) == [0, E17]


def test_depositGasCredit_for_a_program_sponsor_comes_from_the_program_alone(world):
    w = world; s, c, a, p = w['sponsor'], w['c'], w['a'], w['program']
    open_dev(w, credit=0)
    for sender in (a[0], a[6], a[9]):                                  # the platform admin, the manager, a stranger
        reverts(c, s.functions.depositGasCredit(w['dev']), 'NotProgram()', sender, value=1)
    paid(c, p.functions.fund(s.address, w['dev']), E17)                # the program
    assert funding(w, w['dev']) == [0, E17]
    tx(c, s.functions.setProgram('0x' + '0' * 39 + '1', 10 ** 16, 10 ** 18))             # another program: the old one is refused
    reverts(c, p.functions.fund(s.address, w['dev']), 'NotProgram()', value=1)


def test_recoverGasCredit_for_a_program_sponsor_is_the_programs_alone_and_goes_to_it(world):
    """1.5.1 (the review's P2-D): the platform administrator has no recovery path for a program sponsor; the program alone
    recovers, and only to itself, so its own rules (the 90-day freeze, a top-up's refund) are the only way credit leaves."""
    w = world; s, c, a, p, w3 = w['sponsor'], w['c'], w['a'], w['program'], w['c']['w3']
    open_dev(w, credit=E17)
    reverts(c, p.functions.recover(s.address, w['dev'], a[8], 1), 'ProgramSponsorRecoverToProgram(address,address)')
    for sender in (a[0], a[6], a[9]):                                  # the platform admin, the manager, a stranger
        reverts(c, s.functions.recoverGasCredit(w['dev'], p.address, 1), 'NotProgram()', sender)
        reverts(c, s.functions.recoverGasCredit(w['dev'], a[8], 1), 'NotProgram()', sender)
    before = w3.eth.get_balance(p.address)
    tx(c, p.functions.recover(s.address, w['dev'], p.address, E17 // 4))                                 # the program, to itself
    assert w3.eth.get_balance(p.address) - before == E17 // 4 and funding(w, w['dev']) == [0, E17 - E17 // 4]
    fails(c, p.functions.recover(s.address, w['dev'], p.address, E17))                                   # never more than the credit
    tx(c, s.functions.setProgram('0x' + '0' * 39 + '1', 10 ** 16, 10 ** 18))                            # the program changed:
    reverts(c, p.functions.recover(s.address, w['dev'], p.address, 1), 'NotProgram()')                  # the old one can't
    reverts(c, s.functions.recoverGasCredit(w['dev'], p.address, 1), 'NotProgram()')                    # nor the admin


def test_the_program_recovers_only_its_own_sponsors(world):
    w = world; s, c, a, p = w['sponsor'], w['c'], w['a'], w['program']
    paid(c, s.functions.depositGasCredit(a[4]), E17)                   # a non-program sponsor's credit, from anyone
    reverts(c, p.functions.recover(s.address, a[4], p.address, 1), 'NotPlatformAdmin()')


def test_a_revoked_pass_stops_spending_at_once_on_chain(world):
    """The program's isEligible / sponsorLimits answers false on a revoked or locked Pass: the very next execution is refused by
    GasSponsor itself, nothing consumed or charged; the credit stays, frozen."""
    w = world; s, c = w['sponsor'], w['c']
    open_dev(w, credit=E17)
    tx(c, w['program'].functions.set(True, GWEI, 10, 0))
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'before')) == (1, True)
    left = funding(w, w['dev'])[1]
    tx(c, w['program'].functions.set(False, GWEI, 10, 0))              # the Pass revoked: the program says ineligible
    refused(w, voucher_for(w, w['dev'], w['tenant'], 'after'))
    assert funding(w, w['dev'])[1] == left                              # frozen, not gone
    tx(c, w['program'].functions.set(True, GWEI, 10, 0))               # reinstated: spendable again
    assert run(w, voucher_for(w, w['dev'], w['tenant'], 'reinstated')) == (1, True)


# ── every other sponsor: unchanged ──

def test_a_non_program_sponsor_is_unchanged(world):
    w = world; s, c, a, p, w3 = w['sponsor'], w['c'], w['a'], w['program'], w['c']['w3']
    before = funding(w, a[4])
    paid(c, s.functions.depositFor(a[4]), E17, a[9])                   # refundable, from anyone
    paid(c, s.functions.depositGasCredit(a[4]), E17, a[9])             # credit, from anyone
    paid(c, p.functions.refundable(s.address, a[4]), 1)                # the program too, like anyone
    assert funding(w, a[4]) == [before[0] + E17 + 1, before[1] + E17]
    tx(c, s.functions.withdrawSponsor(a[4], a[7], E17), a[5])          # the manager withdraws refundable coin
    reverts(c, s.functions.withdrawSponsor(a[4], a[7], before[0] + 2), 'InsufficientSponsorBalance(uint256,uint256)', a[5])
    held = w3.eth.get_balance(a[8])
    tx(c, s.functions.recoverGasCredit(a[4], a[8], E17))               # the admin recovers credit to any address
    assert w3.eth.get_balance(a[8]) - held == E17 and funding(w, a[4]) == [before[0] + 1, before[1]]
    reverts(c, s.functions.recoverGasCredit(a[4], a[8], 1), 'NotPlatformAdmin()', a[5])
    w['program'].functions.set(False, 1, 0, 1).transact({'from': a[0]})        # the program says no: irrelevant to it
    assert run(w, voucher_for(w, a[4], Web3.keccak(text='tenant'), 'plain', fee=3 * GWEI, calls=[ping(w)])) == (1, True)   # approved (C3)


# ── the committed build ──

def test_the_committed_build_is_this_source_and_append_only(program_build):
    folder = REPO / 'Releases/GasSponsor/1.5.1'
    proof = json.loads((folder / 'layout-proof.json').read_text())
    artifact = json.loads((folder / 'ProgramGasSponsor.json').read_text())
    standard = json.loads((folder / 'standard-input.json').read_text())
    assert proof['append_only'] is True and proof['problems'] == []
    assert set(proof['predecessors']) == {'1.3.0', '1.4.0', '1.5.0'}
    for path, entry in standard['sources'].items():
        assert (REPO / path).read_text() == entry['content'], path                    # the committed input is this checkout
    built = program_build['ProgramGasSponsor']['runtime_bytecode'].removeprefix('0x').lower()
    assert artifact['runtime_bytecode'].removeprefix('0x').lower()[:-106] == built[:-106]  # the same code (metadata aside)
    assert artifact['runtime_bytes'] <= 32768 and artifact['version'] == '1.5.1'
