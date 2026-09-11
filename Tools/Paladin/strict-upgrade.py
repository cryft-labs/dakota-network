"""Upgrade the private/public boundary and prove rejection rolls back private spend.

Development chain only. Uses existing identities, proxies and durable journals.
No recovery credentials, codes, PINs or prepared private states are exported.
"""
import argparse, copy, hashlib, json, time
from acceptance import local_fixture, logs, value
from live import Live, DEPLOYER, TESTER, ZERO, ADDR, hx, serial


def expected_revert(d, label, function):
    """One bounded negative transaction; record its hash before a single broadcast."""
    prior = d.journal['transactions'].get(label)
    if prior:
        receipt = d.w3.eth.get_transaction_receipt(prior['hash'])
    else:
        d.reject(label + ':simulation', function, sender=DEPLOYER)
        nonce = d.w3.eth.get_transaction_count(DEPLOYER)
        assert nonce == d.w3.eth.get_transaction_count(DEPLOYER, 'pending')
        tx = function.build_transaction({'from': DEPLOYER, 'nonce': nonce, 'chainId': 112311,
                                         'gas': 2000000, 'gasPrice': 10**9, 'value': 0})
        assert d.w3.eth.get_balance(DEPLOYER) > tx['gas'] * tx['gasPrice']
        signed = d.accounts[DEPLOYER].sign_transaction(tx)
        prior = {'hash': hx(signed.hash), 'from': DEPLOYER, 'nonce': nonce, 'to': tx['to'],
                 'source_commit': d.commit, 'expected_status': 0, 'state': 'prepared',
                 'gas_limit': tx['gas'], 'input_sha256': hashlib.sha256(bytes.fromhex(tx['data'][2:])).hexdigest()}
        d.journal['transactions'][label] = prior; d.save()
        assert hx(d.w3.eth.send_raw_transaction(signed.raw_transaction)) == prior['hash']
        prior['state'] = 'submitted'; d.save()
        receipt = d.w3.eth.wait_for_transaction_receipt(prior['hash'], timeout=50, poll_latency=1)
    assert receipt['status'] == 0, 'Negative settlement unexpectedly succeeded'
    assert receipt['gasUsed'] < 1900000, 'Out of gas is not evidence of the intended rejection'
    prior['receipt'] = serial(receipt); prior['state'] = 'expected_revert'; d.save()
    return receipt


def run(d):
    report = json.loads((d.out/'ipfs-verification.json').read_text())
    assert report['passed'] and all(n in report['contracts'] for n in ['CodeManagerStrict', 'PrivateComboStorageStrict'])
    card = d.at('CryftGreetingCards', d.journal['deployments']['CardProxy']['address'])
    cm = d.at('CodeManagerStrict', ADDR['CodeManager'])
    proxy = d.journal['private_deployments']['ComboProxy']['address']
    admin = d.journal['private_deployments']['ComboProxyAdmin']['address']
    row = d.journal.setdefault('strict_settlement', {}); d.save()
    def call(method, inputs=None): return d.private_call('PrivateComboStorageStrict', method, proxy, inputs)
    def stage(name, action):
        if row.get(name): print('RECORDED strict:' + name, flush=True); return
        action(); row[name] = True; d.save()
    def snapshot():
        identifier, counter = cm.functions.getIdentifierCounter(card.address, '112311').call()
        return {'voters': cm.functions.getVoters().call(), 'fee': cm.functions.registrationFee().call(),
                'identifier': identifier, 'counter': counter,
                'deliveries': [cm.functions.getRedemptionDelivery(identifier+'-'+str(i)).call() for i in range(1,5)],
                'owners': [card.functions.ownerOf(i).call() for i in range(1,5)],
                'private_admin': value(call('ADMIN')), 'authorized': value(call('AUTHORIZED')),
                'forwarder': value(call('TRUSTED_FORWARDER')),
                'private_counter': value(call('registeredCodeCount', [hx(d.w3.keccak(text=identifier))])),
                'proxy_owner': value(d.private_call('ManagedProxyAdmin', 'owner', admin))}
    def upgrade():
        if 'before' not in row: row['before'] = snapshot(); d.save()
        logic = d.deploy('CodeManagerStrict')
        d.tx('strict:upgrade_public_router', d.at('ProxyAdmin').functions.upgrade(cm.address, logic.address))
        from common import IMPL_SLOT
        d.check('strict:public_implementation', int.from_bytes(d.w3.eth.get_storage_at(cm.address, IMPL_SLOT), 'big') == int(logic.address,16))
        private_logic = d.private_deploy('PrivateComboStorageStrict')
        d.private_send('strict:upgrade_private_combo', 'ManagedProxyAdmin', 'upgrade', admin, [proxy, private_logic])
        actual = value(d.private_call('ManagedProxyAdmin', 'getProxyImplementation', admin, [proxy]))
        d.check('strict:private_implementation', actual.lower() == private_logic.lower())
        d.check('strict:live_state_preserved', snapshot() == row['before'])
        row['public_implementation'] = logic.address; row['private_implementation'] = private_logic; d.save()
    stage('upgraded', upgrade)

    fixture = local_fixture(d, 5)
    identifier, _ = cm.functions.getIdentifierCounter(card.address, '112311').call()
    uid = identifier + '-5'
    def issue():
        d.tx('strict:register_fifth_uid', card.functions.setMaxSaleSupply(5), value=cm.functions.registrationFee().call())
        d.tx('strict:buy_fifth_into_vault', card.functions.buy(TESTER, 1, report['card_metadata']['base_uri']))
        d.private_send('strict:sync_fifth_uid', 'PrivateComboStorageStrict', 'syncRegisteredCodeCountBatch', proxy, [[identifier], [5]])
        d.private_send('strict:store_fifth_code', 'PrivateComboStorageStrict', 'storeDataBatch', proxy,
                       [[identifier, [5], [fixture['hashes'][4]], 8, False, [fixture['entropies'][4]], [ZERO], [True]]])
    stage('issued', issue)
    stored = d.rpc('ptx_getTransactionReceiptFull', d.journal['private_transactions']['strict:store_fifth_code']['id'])
    assigned = logs(d, stored, 'DataStoredStatus(string,string)', ['string', 'string'])
    assert len(assigned) == 1 and assigned[0][0] == uid
    pin = assigned[0][1]
    def exists():
        result = call('pinToHash', [pin, fixture['hashes'][4]])
        return result['exists'] if isinstance(result,dict) else result[2]
    def prepare():
        key = 'dakota-live-20260911:strict-fifth-prepared'
        row['idempotency_key'] = key; d.save()
        existing = d.rpc('ptx_getTransactionByIdempotencyKey', key)
        if existing: row['private_transaction_id'] = existing['id']
        else:
            original = d.rpc('ptx_getTransaction', d.journal['private_transactions']['codes:first_card_redemption']['id'])
            request = {k:copy.deepcopy(original[k]) for k in ['type','domain','function','abiReference','from','to','data']}
            request['idempotencyKey'] = key
            request['data']['inputs'] = {'pins':[pin], 'codeHashes':[fixture['hashes'][4]], 'redeemers':[TESTER]}
            row['private_transaction_id'] = d.rpc('ptx_prepareTransaction', request)
        d.save()
    stage('prepared', prepare)
    for _ in range(30):
        prepared = d.rpc('ptx_getPreparedTransaction', row['private_transaction_id'])
        if prepared: break
        time.sleep(1)
    else: raise TimeoutError('Resume existing prepared transaction')
    public = prepared['transaction']; group = d.w3.to_checksum_address(d.journal['group']['contractAddress'])
    assert public['type'] == 'public' and public['to'].lower() == group.lower() and public['function'].startswith('transition(')
    definition = next(x for x in d.artifacts['PentePrivacyGroup']['abi'] if x.get('name') == 'transition')
    def convert(abi, data):
        if abi['type'] == 'tuple': return tuple(convert(c, data[c['name']]) for c in abi['components'])
        if abi['type'] == 'tuple[]': return [convert(dict(abi,type='tuple'), x) for x in data]
        if abi['type'] == 'address': return d.w3.to_checksum_address(data)
        return data
    settlement = d.at('PentePrivacyGroup', group).functions.transition(*[convert(a, public['data'][a['name']]) for a in definition['inputs']])
    expected_selector = hx(d.w3.keccak(text='recordRedemptionStrict(string,address)')[:4])
    external = public['data']['externalCalls']
    assert len(external) == 1 and external[0]['contractAddress'].lower() == cm.address.lower()
    assert external[0]['encodedCall'].startswith(expected_selector), 'Private execution emitted the wrong settlement entry point'
    row['public_calldata_keccak256'] = hx(d.w3.keccak(hexstr=settlement._encode_transaction_data())); d.save()
    def reject_then_restore():
        if 'temporary_scope_before' not in row:
            assert not cm.functions.isAuthorizedPrivacyGroup(TESTER).call(), 'Test account unexpectedly already has public group authority'
            row['temporary_scope_before'] = {'authorized':False}; d.save()
        d.tx('strict:grant_temporary_freeze_scope', cm.functions.voteToSetPrivacyGroupGift(TESTER, card.address, True))
        try:
            d.tx('strict:public_only_freeze', cm.functions.setUniqueIdActiveBatch([uid], [False]), sender=TESTER)
            reverted = expected_revert(d, 'strict:reject_public_precondition', settlement)
            d.check('strict:rejection_preserves_private_code', exists())
            d.check('strict:rejection_preserves_public_vault', card.functions.ownerOf(5).call() == card.address and cm.functions.getRedemptionDelivery(uid).call() == [ZERO,False,0])
            row['rejected_public_transaction'] = hx(reverted['transactionHash']); d.save()
        finally:
            d.tx('strict:restore_public_active', cm.functions.setUniqueIdActiveBatch([uid], [True]), sender=TESTER)
            d.tx('strict:remove_temporary_gift_scope', cm.functions.voteToSetPrivacyGroupGift(TESTER, card.address, False))
            d.tx('strict:remove_temporary_authority', cm.functions.voteToDeauthorizePrivacyGroup(TESTER))
    stage('rejection_verified', reject_then_restore)
    def settle():
        receipt = d.tx('strict:retry_same_prepared_transition', settlement)
        private_receipt = d.wait_private(row['private_transaction_id'])
        assert private_receipt['transactionHash'].lower() == hx(receipt['transactionHash']).lower()
        d.check('strict:retry_consumes_code', not exists())
        d.check('strict:retry_delivers_once', card.functions.ownerOf(5).call() == TESTER and cm.functions.getRedemptionDelivery(uid).call() == [TESTER,True,1])
        d.reject('strict:successful_transition_replay_blocked', settlement, sender=DEPLOYER)
        d.check('strict:temporary_authority_removed', not cm.functions.isAuthorizedPrivacyGroup(TESTER).call() and not cm.functions.canPrivacyGroupAccessGift(TESTER,card.address).call())
        row.update({'public_transaction_hash':hx(receipt['transactionHash']), 'token_id':5, 'recipient':TESTER, 'nft':card.address})
        d.save()
    stage('accepted', settle)
    print(json.dumps({k:row[k] for k in ['public_implementation','private_implementation','rejected_public_transaction','public_transaction_hash','accepted']}), flush=True)


if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('--workspace',required=True); a=p.parse_args(); run(Live(a.workspace,True))
