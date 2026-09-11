"""Bounded live development checks, with explicit stages and cleanup."""
import argparse
import json
from eth_account import Account
from web3.logs import DISCARD
from common import Deployment, ADDR, ADMIN, DEPLOYER, TESTER, ZERO, IMPL_SLOT, REPO, hx, serial

TENANT_LABEL = 'dakota-genesis-canary-20260911'

def recorded(d, name, abi=None):
    return d.at(abi or name, d.journal['deployments'][name]['address'])

def baseline(d, name, value):
    observations = d.journal.setdefault('observations', {})
    if name not in observations: observations[name] = serial(value); d.save()
    return observations[name]

def stage(d, name, action):
    if d.journal.setdefault('stages', {}).get(name) == 'passed':
        print('RECORDED ' + name, flush=True); return
    print('START ' + name, flush=True)
    action(d)
    d.journal['stages'][name] = 'passed'; d.save()

def governance(d):
    for name in ['ValidatorSmartContractAllowList', 'GasManager', 'CodeManager']:
        stage(d, 'governance:' + name, lambda d, name=name: voter_checks(d, name))
    validator = d.at('ValidatorSmartContractAllowList')
    members = validator.functions.getValidators().call()
    d.reject('Validator:four_validator_floor', validator.functions.voteToRemoveValidator(members[0]), sender=DEPLOYER)
    d.reject('Validator:cap_below_four', validator.functions.voteToUpdateMaxValidators(3), sender=DEPLOYER)
    empty_hash = d.w3.keccak(d.w3.codec.encode(['address[]'], [[]]))
    d.reject('Validator:empty_roots_rejected', validator.functions.voteToSetRootConfiguration([], [], empty_hash), sender=DEPLOYER)
    d.reject('Validator:already_initialized', validator.functions.initialize(), sender=DEPLOYER)
    cap = baseline(d, 'validator_cap', validator.functions.maxValidators().call())
    d.tx('validator:cap_change', validator.functions.voteToUpdateMaxValidators(cap + 1))
    d.check('Validator:governed_cap_change', validator.functions.maxValidators().call() == cap + 1)
    d.tx('validator:cap_restore', validator.functions.voteToUpdateMaxValidators(cap))
    expected = json.loads((REPO / 'Contracts/Genesis/development-release.json').read_text())['validators']
    raw = d.w3.eth.call({'to': validator.address, 'data': validator.functions.getValidators()._encode_transaction_data()})
    d.check('Validator:Besu_ABI_and_membership_unchanged', bytes(raw) == d.w3.codec.encode(['address[]'], [expected]), hx(raw))

def voter_checks(d, name):
    c = d.at(name); prefix = 'voters:' + name + ':'
    before = baseline(d, prefix + 'expiry', c.functions.voteTallyBlockThreshold().call())
    one_hash = d.w3.keccak(d.w3.codec.encode(['address[]'], [[DEPLOYER]]))
    empty_hash = d.w3.keccak(d.w3.codec.encode(['address[]'], [[]]))
    d.reject(name + ':unauthorized_voter', c.functions.voteToUpdateVoteTallyBlockThreshold(before + 1))
    d.reject(name + ':last_voter_protected', c.functions.voteToRemoveVoter(DEPLOYER), sender=DEPLOYER)
    d.reject(name + ':empty_voters_protected', c.functions.voteToSetVoterConfiguration([], [], empty_hash), sender=DEPLOYER)
    d.tx(prefix + 'duplicate_configuration', c.functions.voteToSetVoterConfiguration([DEPLOYER, DEPLOYER], [], one_hash))
    d.check(name + ':duplicate_voters_count_once', c.functions.getVoters().call() == [DEPLOYER] and c.functions.getSupermajorityThreshold().call() == 1)
    d.tx(prefix + 'canonical_configuration', c.functions.voteToSetVoterConfiguration([DEPLOYER], [], one_hash))
    d.tx(prefix + 'add_test_voter', c.functions.voteToAddVoter(TESTER))
    d.check(name + ':two_voter_quorum', c.functions.getSupermajorityThreshold().call() == 2)
    d.tx(prefix + 'first_vote', c.functions.voteToUpdateVoteTallyBlockThreshold(before + 1))
    d.check(name + ':first_vote_not_enough', c.functions.voteTallyBlockThreshold().call() == before)
    d.reject(name + ':duplicate_vote_rejected', c.functions.voteToUpdateVoteTallyBlockThreshold(before + 1), sender=DEPLOYER)
    d.tx(prefix + 'second_vote', c.functions.voteToUpdateVoteTallyBlockThreshold(before + 1), sender=TESTER)
    d.check(name + ':second_vote_executes', c.functions.voteTallyBlockThreshold().call() == before + 1)
    d.tx(prefix + 'remove_test_first', c.functions.voteToRemoveVoter(TESTER))
    d.check(name + ':membership_waits_for_second_vote', TESTER in c.functions.getVoters().call())
    d.tx(prefix + 'remove_test_second', c.functions.voteToRemoveVoter(TESTER), sender=TESTER)
    d.tx(prefix + 'restore_expiry', c.functions.voteToUpdateVoteTallyBlockThreshold(before))
    d.check(name + ':temporary_voter_removed', c.functions.getVoters().call() == [DEPLOYER] and c.functions.getSupermajorityThreshold().call() == 1)
    d.check(name + ':no_open_ballots', c.functions.activeVoteCount().call() == 0)

def proxies(d):
    facade = d.at('ProxyAdmin')
    for name in ['GasManager', 'CodeManager', 'GasSponsor', 'DakotaDelegationRegistry']:
        stage(d, 'proxy:' + name, lambda d, name=name: proxy_checks(d, name, facade))

def proxy_checks(d, name, facade):
    address = ADDR[name]; proxy = d.at('TransparentUpgradeableProxy', address)
    logic = d.journal['deployments'][name]['address']
    d.check(name + ':facade_introspection', facade.functions.getProxyImplementation(address).call() == logic and facade.functions.getProxyAdmin(address).call() == facade.address)
    d.reject(name + ':unauthorized_upgrade', facade.functions.upgrade(address, logic))
    d.reject(name + ':root_lockout_prevented', proxy.functions.proxy_revokeRootOverlord(), sender=DEPLOYER)
    d.tx('proxy:' + name + ':grant_canary_controller', proxy.functions.proxy_addOverlord(TESTER))
    d.check(name + ':recoverable_local_controller', proxy.functions.proxy_isGuardian(TESTER).call())
    d.tx('proxy:' + name + ':same_logic_upgrade', facade.functions.upgrade(address, logic), sender=TESTER)
    d.tx('proxy:' + name + ':remove_canary_controller', proxy.functions.proxy_removeOverlord(TESTER))
    d.check(name + ':controller_removed_roots_retained', not proxy.functions.proxy_isGuardian(TESTER).call() and proxy.functions.proxy_isGuardian(ADMIN).call())
    if name in ['GasManager', 'CodeManager']:
        d.check(name + ':proxy_application_storage_independent', d.at(name).functions.getVoters().call() == [DEPLOYER])
    d.check(name + ':linked_implementation_preserved', facade.functions.getProxyImplementation(address).call() == logic)

def funding(d):
    gm = d.at('GasManager')
    gift = d.deploy('GenesisCanary', DEPLOYER, TESTER, ADDR['CodeManager'], gm.address)
    d.tx('gas:temporary_guardian', gm.functions.voteToAddGuardian(DEPLOYER))
    d.check('GasManager:guardian_assignment', gm.functions.isGuardian(DEPLOYER).call())
    for version, amount in [(1, 10**12), (2, 2 * 10**12)]:
        before = baseline(d, 'gas:recipient_before_v' + str(version), d.w3.eth.get_balance(TESTER))
        if version == 1:
            d.tx('gas:v1_approval', gm.functions.voteToFundGasV1(TESTER, amount))
            fn = gm.functions.executeFundGasV1(TESTER, amount)
        else:
            funding_id = 'genesis-native-canary'
            d.tx('gas:v2_approval', gm.functions.proposeFundGasV2(funding_id, TESTER, amount, 'Development funding check'))
            key = gm.functions.getFundKey(funding_id, 1).call()
            fn = gm.functions.executeFundGasV2(key)
        d.reject('GasManager:v' + str(version) + '_unauthorized_execution', fn, sender=ADMIN)
        d.tx('gas:v' + str(version) + '_execution', fn)
        d.check('GasManager:v' + str(version) + '_recipient_exact', d.w3.eth.get_balance(TESTER) == before + amount)
        d.reject('GasManager:v' + str(version) + '_replay_rejected', fn, sender=DEPLOYER)
    dead = d.w3.to_checksum_address('0x000000000000000000000000000000000000dEaD')
    d.tx('gas:approve_dummy_token_burn', gm.functions.voteToBurnTokens(gift.address, 1))
    d.reject('GasManager:unauthorized_token_burn', gm.functions.executeTokenBurn(gift.address, 1))
    d.tx('gas:execute_dummy_token_burn', gm.functions.executeTokenBurn(gift.address, 1))
    d.check('GasManager:dummy_token_burn', gift.functions.balanceOf(dead).call() == 1 and gift.functions.balanceOf(gm.address).call() == 99)
    before = baseline(d, 'gas:dead_native_before', d.w3.eth.get_balance(dead))
    d.tx('gas:approve_one_wei_burn', gm.functions.voteToBurnNativeCoin(1))
    d.reject('GasManager:unauthorized_native_burn', gm.functions.executeCoinBurn(1))
    d.tx('gas:execute_one_wei_burn', gm.functions.executeCoinBurn(1))
    d.check('GasManager:one_wei_native_burn', d.w3.eth.get_balance(dead) == before + 1)
    d.check('GasManager:no_stale_funding_approvals', gm.functions.getActiveApprovedFundKeyCount().call() == 0)

def codes(d):
    cm = d.at('CodeManager'); gift = recorded(d, 'GenesisCanary')
    fee = cm.functions.registrationFee().call()
    d.reject('CodeManager:unauthorized_registration', cm.functions.registerUniqueIds(gift.address, '112311', 1), value=fee)
    d.reject('CodeManager:underpaid_registration', gift.functions.register(3), sender=DEPLOYER)
    r = d.tx('codes:register_three', gift.functions.register(3), value=fee * 3)
    identifier, count = cm.functions.getIdentifierCounter(gift.address, '112311').call()
    # CanonicalUid uses a decimal counter separated from the 32-byte identifier by '-'.
    uids = [identifier + '-' + str(i) for i in range(1, 4)]
    d.journal['canary_uids'] = uids; d.save()
    d.check('CodeManager:three_canonical_uids', count == 3 and all(cm.functions.validateUniqueId(x).call() for x in uids), uids)
    d.check('CodeManager:rejects_noncanonical_counter', not cm.functions.validateUniqueId(identifier + '-01').call())
    d.reject('CodeManager:unauthorized_redemption', cm.functions.recordRedemption(uids[0], TESTER))
    d.tx('codes:scope_test_account_to_canary', cm.functions.voteToSetPrivacyGroupGift(TESTER, gift.address, True))
    d.check('CodeManager:canary_scope_only', cm.functions.canPrivacyGroupAccessGift(TESTER, gift.address).call() and not cm.functions.canPrivacyGroupAccessGift(TESTER, ADDR['GasManager']).call())
    d.tx('codes:deactivate', cm.functions.setUniqueIdActiveBatch([uids[0]], [False]), sender=TESTER)
    d.check('CodeManager:inactive_state', not cm.functions.isUniqueIdActive(uids[0]).call())
    rejected = d.tx('codes:inactive_redeem_rejected', cm.functions.recordRedemption(uids[0], TESTER), sender=TESTER)
    d.check('CodeManager:inactive_not_spent', len(cm.events.RedemptionRejected().process_receipt(rejected, errors=DISCARD)) == 1 and not cm.functions.isUniqueIdRedeemed(uids[0]).call())
    d.tx('codes:reactivate', cm.functions.setUniqueIdActiveBatch([uids[0]], [True]), sender=TESTER)
    d.tx('codes:redeem_first', cm.functions.recordRedemption(uids[0], TESTER), sender=TESTER)
    d.check('CodeManager:first_delivery', cm.functions.getRedemptionDelivery(uids[0]).call() == [TESTER, True, 1] and gift.functions.deliveries().call() == 1)
    d.tx('codes:replay_first', cm.functions.recordRedemption(uids[0], DEPLOYER), sender=TESTER)
    d.check('CodeManager:replay_cannot_redirect', cm.functions.getRedemptionRecipient(uids[0]).call() == TESTER and gift.functions.deliveries().call() == 1)
    d.tx('codes:intentional_delivery_failure', gift.functions.setFailure(True))
    d.tx('codes:redeem_second_delivery_fails', cm.functions.recordRedemption(uids[1], TESTER), sender=TESTER)
    d.check('CodeManager:failed_delivery_commits_recipient', cm.functions.getRedemptionDelivery(uids[1]).call() == [TESTER, False, 1] and cm.functions.isUniqueIdRedeemed(uids[1]).call())
    d.tx('codes:restore_delivery_target', gift.functions.setFailure(False))
    d.tx('codes:retry_delivery', cm.functions.retryRedemptionDelivery(uids[1]), sender=TESTER)
    d.tx('codes:repeat_successful_retry', cm.functions.retryRedemptionDelivery(uids[1]), sender=TESTER)
    d.check('CodeManager:retry_is_idempotent', cm.functions.getRedemptionDelivery(uids[1]).call() == [TESTER, True, 2] and gift.functions.deliveries().call() == 2)
    d.journal['registration_fee_check'] = {'amount_wei': fee * 3, 'transaction_hash': hx(r['transactionHash']), 'recipient': ADDR['GasManager']}; d.save()

def signed_operation(d, sponsor, account, gift, tag, calls, *, signature=None):
    op = d.w3.keccak(text=TENANT_LABEL + ':' + tag)
    deadline = d.w3.eth.get_block('latest')['timestamp'] + 3600
    request = (op, sponsor.address, calls, account.functions.getNonce().call(), deadline, 900000)
    if signature is None:
        signature = d.accounts[TESTER].unsafe_sign_hash(account.functions.getExecutionDigest(*request).call()).signature
    data = bytes.fromhex(account.functions.executeSponsored(request, signature)._encode_transaction_data()[2:])
    outer = sponsor.functions.minimumCallGas(request[-1], len(data)).call()
    voucher = (op, d.w3.keccak(text=TENANT_LABEL), d.w3.keccak(text='genesis-validation'), gift.address,
               TESTER, DEPLOYER, sponsor.functions.approvedDelegate().call(), d.w3.keccak(data), outer, 10**9,
               (outer + 100000) * 10**9, deadline)
    voucher_signature = d.accounts[DEPLOYER].unsafe_sign_hash(sponsor.functions.voucherDigest(voucher).call()).signature
    return voucher, data, voucher_signature

def sponsorship(d):
    sponsor = d.at('GasSponsor'); gm = d.at('GasManager'); registry = d.at('DakotaDelegationRegistry')
    cm = d.at('CodeManager'); gift = recorded(d, 'GenesisCanary')
    dispatcher = recorded(d, 'DakotaDelegationBeaconDispatcher'); account = d.at('DakotaDelegation', TESTER)
    beacon = recorded(d, 'DakotaDelegationBeacon')
    if 'delegation:authorize_direct_dispatcher' not in d.journal['transactions']:
        d.check('Delegation:tester_initially_plain_EOA', not d.w3.eth.get_code(TESTER))
    auth = d.accounts[TESTER].sign_authorization({'chainId': 112311, 'address': dispatcher.address, 'nonce': d.w3.eth.get_transaction_count(TESTER)})
    d.tx('delegation:authorize_direct_dispatcher', transaction={'to': TESTER, 'data': account.functions.getNonce()._encode_transaction_data(),
         'gas': 1000000, 'maxFeePerGas': 10**9, 'maxPriorityFeePerGas': 10**9, 'authorizationList': [auth], 'value': 0})
    d.check('Delegation:real_EIP7702_designation', bytes(d.w3.eth.get_code(TESTER)) == bytes.fromhex('ef0100' + dispatcher.address[2:]))
    d.check('Delegation:no_per_account_proxy_link', int.from_bytes(d.w3.eth.get_storage_at(TESTER, IMPL_SLOT), 'big') == 0)
    d.check('Delegation:registry_sponsor_agree_ready', registry.functions.isAccountReady(TESTER).call() and sponsor.functions.isDelegationReady(TESTER).call(), registry.functions.accountStatus(TESTER).call())
    digest = d.w3.keccak(text='genesis-1271-check')
    signature = d.accounts[TESTER].unsafe_sign_hash(digest).signature
    d.check('Delegation:EIP1271_owner_signature', hx(account.functions.isValidSignature(digest, signature).call()) == '0x1626ba7e' and hx(account.functions.isValidSignature(digest, b'').call()) == '0xffffffff')
    d.tx('sponsor:configure_canary', sponsor.functions.configureSponsor(gift.address, d.w3.keccak(text=TENANT_LABEL), DEPLOYER, 5 * 10**15, 2 * 10**16, True))
    d.tx('sponsor:refundable_deposit', sponsor.functions.depositFor(gift.address), value=10**15)
    d.tx('sponsor:treasury_credit_approval', gm.functions.proposeSponsorFunding('genesis-sponsor-canary', gift.address, 10**16, 'Restricted development gas credit'))
    key = gm.functions.getFundKey('genesis-sponsor-canary', 1).call()
    d.reject('GasManager:credit_cannot_use_native_executor', gm.functions.executeFundGasV2(key), sender=DEPLOYER)
    d.reject('GasManager:credit_executor_authorization', gm.functions.executeSponsorFunding(key))
    d.tx('sponsor:treasury_credit_deposit', gm.functions.executeSponsorFunding(key))
    d.check('GasSponsor:separate_credit_ledgers', sponsor.functions.getSponsorFunding(gift.address).call() == [10**15, 10**16])
    d.reject('GasSponsor:credit_not_withdrawable', sponsor.functions.withdrawSponsor(gift.address, DEPLOYER, 10**15 + 1), sender=DEPLOYER)
    d.reject('GasSponsor:unauthorized_admin', sponsor.functions.setPaused(False))
    d.reject('GasSponsor:only_treasury_can_credit', sponsor.functions.depositGasCredit(gift.address), sender=DEPLOYER, value=1)
    d.tx('sponsor:enable_test_relayer', sponsor.functions.setRelayer(DEPLOYER, True))
    calls = [(gift.address, 0, bytes.fromhex(gift.functions.setMarker(7702)._encode_transaction_data()[2:])),
             (cm.address, 0, bytes.fromhex(cm.functions.recordRedemption(d.journal['canary_uids'][2], TESTER)._encode_transaction_data()[2:]))]
    args = signed_operation(d, sponsor, account, gift, 'success', calls)
    d.reject('GasSponsor:paused_rejects_execution', sponsor.functions.executeSponsored(*args), sender=DEPLOYER)
    d.tx('sponsor:unpause_for_bounded_canary', sponsor.functions.setPaused(False))
    d.reject('GasSponsor:wrong_relayer', sponsor.functions.executeSponsored(*args))
    d.reject('GasSponsor:wrong_voucher_signature', sponsor.functions.executeSponsored(args[0], args[1], b''), sender=DEPLOYER)
    d.reject('GasSponsor:changed_payload', sponsor.functions.executeSponsored(args[0], args[1] + b'\x00', args[2]), sender=DEPLOYER)
    before = baseline(d, 'delegation:execution_nonce_before', account.functions.getNonce().call())
    r = d.tx('sponsor:successful_delegated_redemption', sponsor.functions.executeSponsored(*args))
    events = sponsor.events.SponsoredOperation().process_receipt(r, errors=DISCARD)
    reimbursement = sponsor.events.RelayerReimbursed().process_receipt(r, errors=DISCARD)[0]['args']
    d.check('GasSponsor:inner_execution_success', len(events) == 1 and events[0]['args']['success'], events[0]['args'])
    d.check('Delegation:batched_call_identity_and_nonce', gift.functions.marker().call() == 7702 and account.functions.getNonce().call() == before + 1)
    d.check('CodeManager:sponsored_redemption_delivery', cm.functions.getRedemptionDelivery(d.journal['canary_uids'][2]).call() == [TESTER, True, 1] and gift.functions.deliveries().call() == 3)
    refundable, credit = sponsor.functions.getSponsorFunding(gift.address).call()
    d.check('GasSponsor:restricted_credit_spent_first', refundable == 10**15 and credit == 10**16 - reimbursement['reimbursement'] and 0 < reimbursement['reimbursement'] <= args[0][-2], reimbursement)
    d.reject('GasSponsor:operation_replay_rejected', sponsor.functions.executeSponsored(*args), sender=DEPLOYER)
    # Exercise the shared upgrade route with identical reviewed code, then restore.
    replacement = d.deploy('DakotaDelegation', label='DakotaDelegationUpgradeCanary')
    d.reject('Registry:unauthorized_upgrade', registry.functions.upgradeDelegation(replacement.address, d.w3.keccak(d.w3.eth.get_code(replacement.address)) ))
    d.reject('Registry:wrong_code_hash', registry.functions.upgradeDelegation(replacement.address, bytes(32)), sender=DEPLOYER)
    d.tx('registry:upgrade_equivalent_canary', registry.functions.upgradeDelegation(replacement.address, d.w3.keccak(d.w3.eth.get_code(replacement.address))))
    d.check('Registry:upgrade_preserves_account_nonce', account.functions.getNonce().call() == before + 1 and registry.functions.isAccountReady(TESTER).call())
    original = recorded(d, 'DakotaDelegation')
    d.tx('registry:restore_original_logic', registry.functions.upgradeDelegation(original.address, d.w3.keccak(d.w3.eth.get_code(original.address))))
    d.check('Registry:release_history_and_restore', registry.functions.releaseCount().call() == 3 and beacon.functions.implementation().call() == original.address and all(registry.functions.currentSnapshot().call()[13:17]))
    # An accepted voucher with an invalid account-owner signature must not execute calls.
    bad = signed_operation(d, sponsor, account, gift, 'bad-owner-signature', calls, signature=b'')
    r = d.tx('sponsor:invalid_owner_signature_canary', sponsor.functions.executeSponsored(*bad))
    event = sponsor.events.SponsoredOperation().process_receipt(r, errors=DISCARD)[0]['args']
    d.check('Delegation:invalid_owner_cannot_execute', not event['success'] and account.functions.getNonce().call() == before + 1 and gift.functions.deliveries().call() == 3)
    d.check('GasSponsor:failed_submitted_operation_consumed', sponsor.functions.isOperationConsumed(bad[0][0]).call())
    d.tx('sponsor:pause_after_tests', sponsor.functions.setPaused(True))

def cleanup(d):
    sponsor = d.at('GasSponsor'); registry = d.at('DakotaDelegationRegistry')
    cm = d.at('CodeManager'); gm = d.at('GasManager'); gift = recorded(d, 'GenesisCanary')
    d.tx('cleanup:disable_test_relayer', sponsor.functions.setRelayer(DEPLOYER, False))
    d.tx('cleanup:disable_canary_tenant', sponsor.functions.setSponsorAdminEnabled(gift.address, False))
    d.tx('cleanup:withdraw_refundable_deposit', sponsor.functions.withdrawSponsor(gift.address, DEPLOYER, 10**15))
    credit = baseline(d, 'cleanup:remaining_credit', sponsor.functions.getSponsorFunding(gift.address).call()[1])
    d.tx('cleanup:return_unused_credit_to_treasury', sponsor.functions.recoverGasCredit(gift.address, gm.address, credit))
    d.tx('cleanup:remove_canary_gift_scope', cm.functions.voteToSetPrivacyGroupGift(TESTER, gift.address, False))
    d.tx('cleanup:deauthorize_canary_group', cm.functions.voteToDeauthorizePrivacyGroup(TESTER))
    d.tx('cleanup:remove_temporary_treasury_guardian', gm.functions.voteToRemoveGuardian(DEPLOYER))
    for name, c, propose, cancel, accept, current, pending in [
        ('GasSponsor', sponsor, 'proposePlatformAdmin', 'cancelPlatformAdminTransfer', 'acceptPlatformAdmin', 'platformAdmin', 'pendingPlatformAdmin'),
        ('Registry', registry, 'proposeAdmin', 'cancelAdminTransfer', 'acceptAdmin', 'registryAdmin', 'pendingRegistryAdmin')]:
        d.reject(name + ':zero_admin_protected', getattr(c.functions, propose)(ZERO), sender=DEPLOYER)
        d.reject(name + ':self_admin_protected', getattr(c.functions, propose)(c.address), sender=DEPLOYER)
        d.tx('handover:' + name + ':test_proposal', getattr(c.functions, propose)(ADMIN))
        d.check(name + ':proposal_keeps_current_admin', getattr(c.functions, current)().call() == DEPLOYER and getattr(c.functions, pending)().call() == ADMIN)
        d.reject(name + ':unapproved_recipient_cannot_accept', getattr(c.functions, accept)())
        d.tx('handover:' + name + ':cancel_test_proposal', getattr(c.functions, cancel)())
        d.check(name + ':handover_cancellation', getattr(c.functions, pending)().call() == ZERO)
        d.tx('handover:' + name + ':nominate_management_admin', getattr(c.functions, propose)(ADMIN))
    d.check('Cleanup:sponsorship_paused_and_unfunded', sponsor.functions.paused().call() and not sponsor.functions.isRelayer(DEPLOYER).call() and sponsor.functions.getSponsorFunding(gift.address).call() == [0, 0])
    d.check('Cleanup:test_group_and_guardian_removed', not cm.functions.isAuthorizedPrivacyGroup(TESTER).call() and not gm.functions.isGuardian(DEPLOYER).call())
    for name in ['ValidatorSmartContractAllowList', 'GasManager', 'CodeManager']:
        d.check(name + ':final_bootstrap_voter_state', d.at(name).functions.getVoters().call() == [DEPLOYER])
    d.journal['validation_complete'] = True
    d.journal['handover']['pending_admin_acceptance'] = {'GasSponsor': ADMIN, 'DakotaDelegationRegistry': ADMIN}
    d.journal['scope_limits'] = ['Public Besu EIP-7702 proved; private Paladin delegation not tested here.',
        'Canary is a development fixture, not a deployed production gift/account-registration service.',
        'Reserved agent-registry implementation unavailable; reserved slot remains unlinked.',
        'Recipient acceptance, voter/root rotation and removal of remaining bootstrap roles occur after full application acceptance.']
    d.save()

ACTIONS = {'governance': governance, 'proxies': proxies, 'funding': funding, 'codes': codes, 'sponsorship': sponsorship, 'cleanup': cleanup}
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--workspace', required=True)
    parser.add_argument('--stage', choices=list(ACTIONS) + ['all'], default='all'); parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute: raise SystemExit('Live validation requires explicit --execute after branch publication.')
    d = Deployment(args.workspace, execute=True)
    assert d.journal.get('initialization_complete'), 'Complete initialization first'
    for name, action in ACTIONS.items():
        if args.stage in ['all', name]: stage(d, name, action)
