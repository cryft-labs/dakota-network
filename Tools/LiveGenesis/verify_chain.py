"""Read-only final receipt, bytecode, authority and explorer-trace acceptance."""
import argparse
from datetime import datetime, timezone
import json
import urllib.request
from common import Deployment, ADDR, ADMIN, DEPLOYER, TESTER, REPO, hx, serial

def verify(workspace):
    d = Deployment(workspace)
    assert d.journal.get('initialization_complete') and d.journal.get('validation_complete')
    report = {'checked_at': datetime.now(timezone.utc).isoformat(), 'chain_id': 112311,
              'genesis_hash': d.journal['genesis_hash'], 'head': d.w3.eth.block_number,
              'checks_recorded': len(d.journal['checks']), 'receipts': {}, 'deployments': {}, 'traces': {}}
    for label, row in d.journal['transactions'].items():
        receipt = d.w3.eth.get_transaction_receipt(row['hash'])
        transaction = d.w3.eth.get_transaction(row['hash'])
        assert receipt['status'] == 1 and hx(receipt['blockHash']) == row['receipt']['blockHash']
        assert transaction['nonce'] == row['nonce'] and transaction['from'] == row['from']
        report['receipts'][label] = {'hash': row['hash'], 'block': receipt['blockNumber'], 'status': 1,
            'gas_used': receipt['gasUsed'], 'fee_wei': receipt['gasUsed'] * receipt['effectiveGasPrice']}
    for name, row in d.journal['deployments'].items():
        actual = hx(d.w3.keccak(d.w3.eth.get_code(row['address'])))
        assert actual == row['runtime_keccak256']
        report['deployments'][name] = {'address': row['address'], 'runtime_keccak256': actual, 'matches_reviewed_deployment': True}
    expected = json.loads((REPO / 'Contracts/Genesis/development-release.json').read_text())
    for name in ['ValidatorSmartContractAllowList', 'ProxyAdmin']:
        assert hx(d.w3.keccak(d.w3.eth.get_code(ADDR[name]))) == expected['runtimes'][name]['runtime_keccak256']
    facade = d.at('ProxyAdmin')
    for name in ['GasManager', 'CodeManager', 'GasSponsor', 'DakotaDelegationRegistry']:
        proxy = d.at('TransparentUpgradeableProxy', ADDR[name])
        assert hx(d.w3.keccak(d.w3.eth.get_code(ADDR[name]))) == expected['runtimes']['TransparentUpgradeableProxy']['runtime_keccak256']
        assert facade.functions.getProxyImplementation(ADDR[name]).call() == d.journal['deployments'][name]['address']
        assert proxy.functions.proxy_getIsInit().call()
        assert proxy.functions.proxy_isGuardian(ADMIN).call() and not proxy.functions.proxy_isGuardian(TESTER).call()
        assert not proxy.functions.proxy_isOverlord(TESTER).call() and not proxy.functions.proxy_isVotingSessionActive().call()
    validator = d.at('ValidatorSmartContractAllowList')
    assert sorted(validator.functions.getValidators().call()) == sorted(expected['validators'])
    assert set(validator.functions.getRootOverlords().call()) == {ADMIN, DEPLOYER}
    for name in ['ValidatorSmartContractAllowList', 'GasManager', 'CodeManager']:
        assert d.at(name).functions.getVoters().call() == [DEPLOYER]
        assert d.at(name).functions.activeVoteCount().call() == 0
    sponsor = d.at('GasSponsor'); registry = d.at('DakotaDelegationRegistry')
    gift = d.journal['deployments']['GenesisCanary']['address']
    assert sponsor.functions.paused().call() and not sponsor.functions.isRelayer(DEPLOYER).call()
    assert sponsor.functions.getSponsorFunding(gift).call() == [0, 0]
    assert sponsor.functions.platformAdmin().call() == registry.functions.registryAdmin().call() == DEPLOYER
    assert sponsor.functions.pendingPlatformAdmin().call() == registry.functions.pendingRegistryAdmin().call() == ADMIN
    assert all(registry.functions.currentSnapshot().call()[13:17])
    assert not d.at('CodeManager').functions.isAuthorizedPrivacyGroup(TESTER).call()
    assert not d.at('GasManager').functions.isGuardian(DEPLOYER).call()
    report['final_authority'] = {'roots': validator.functions.getRootOverlords().call(), 'temporary_voter': DEPLOYER,
        'platform_and_registry_admin': DEPLOYER, 'pending_platform_and_registry_admin': ADMIN,
        'beacon_owner': ADDR['DakotaDelegationRegistry'], 'temporary_validation_roles_removed': True,
        'sponsorship_paused': True, 'test_tenant_funding_zero': True, 'handover_complete': False}
    report['accounts'] = {}
    for account in [DEPLOYER, TESTER]:
        latest, pending = d.w3.eth.get_transaction_count(account), d.w3.eth.get_transaction_count(account, 'pending')
        assert latest == pending
        report['accounts'][account] = {'nonce': latest, 'pending_nonce': pending, 'balance_wei': d.w3.eth.get_balance(account)}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for label in ['codes:register_three', 'sponsor:successful_delegated_redemption', 'sponsor:invalid_owner_signature_canary']:
        tx_hash = d.journal['transactions'][label]['hash']
        result = d.w3.provider.make_request('trace_transaction', [tx_hash])
        assert 'error' not in result and result['result']
        traces = result['result']
        url = 'http://100.111.69.1:8080/api/v2/transactions/' + tx_hash + '/internal-transactions'
        with opener.open(url, timeout=20) as response: explorer = json.load(response)
        assert explorer['items'] and explorer['next_page_params'] is None
        if label == 'codes:register_three':
            fee = d.journal['registration_fee_check']['amount_wei']
            assert any(t.get('action', {}).get('to', '').lower() == ADDR['GasManager'].lower() and int(t['action'].get('value', '0x0'), 16) == fee for t in traces)
        if label == 'sponsor:successful_delegated_redemption':
            for target in [gift, ADDR['CodeManager']]:
                assert any(t.get('action', {}).get('to', '').lower() == target.lower() and not t.get('error') for t in traces)
                assert any((t.get('to') or {}).get('hash', '').lower() == target.lower() and t['success'] for t in explorer['items'])
        report['traces'][label] = {'hash': tx_hash, 'explorer_url': 'http://100.111.69.1:8080/tx/' + tx_hash,
                                  'archive_trace': traces, 'explorer_internal_calls': explorer['items']}
    report['receipt_count'] = len(report['receipts'])
    report['total_gas_used'] = sum(x['gas_used'] for x in report['receipts'].values())
    report['total_transaction_fee_wei'] = sum(x['fee_wei'] for x in report['receipts'].values())
    report['all_receipts_reconfirmed'] = True; report['passed'] = True
    report['explorer_source_verification_complete'] = False
    (d.out / 'chain-verification.json').write_text(json.dumps(serial(report), indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: report[k] for k in ['passed', 'head', 'receipt_count', 'checks_recorded', 'total_gas_used', 'total_transaction_fee_wei', 'final_authority']}, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--workspace', required=True)
    verify(parser.parse_args().workspace)
