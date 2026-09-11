"""Read-only acceptance audit, with an explicit bounded service-restart option.

Reads no remote recovery files. Exports public receipts, code hashes and health only.
"""
import argparse, hashlib, json, sys, time
from datetime import datetime, timezone
from live import Live, REPO, ADDR, TESTER, ZERO, git, hx, serial
from acceptance import value


def audit(d, restart=False):
    sys.path.insert(0,str(d.workspace/'work/production-hardening'))
    sys.path.insert(0,str(REPO/'Tools/SolcCompiler'))
    from hostctl import HOSTS, connect, run
    from ipfs_publish import metadata_cid
    from common import IMPL_SLOT
    assert d.journal['strict_settlement']['accepted']
    pins=json.loads((d.out/'ipfs-verification.json').read_text()); assert pins['passed']
    report={'checked_at':datetime.now(timezone.utc).isoformat(),'source_commit':git('rev-parse','HEAD'),
            'chain_id':d.w3.eth.chain_id,'public_runtimes':{},'private_runtimes':{},'checks':{},
            'secret_policy':'Keep recovery secrets on Paladin-01; no off-server export authorized',
            'full_host_reboot_tested':False,'backup_restore_tested':False,'router_integration_tested':False}
    def check(name,passed):
        assert passed,name
        report['checks'][name]=True; print('PASS '+name,flush=True)
    def private_hash(address):
        # Ephemeral read-only constructor: EXTCODEHASH(address), ABI bytes32 return.
        request={'domain':'pente','group':d.journal['group']['id'],'from':'operator@paladin01','gas':1000000,
                 'bytecode':'0x73'+address[2:]+'3f5f5260205ff3',
                 'function':{'type':'constructor','inputs':[],'outputs':[{'name':'codeHash','type':'bytes32'}]},'input':[]}
        return value(d.rpc('pgroup_call',request))
    public_alias={'PenteFactoryProxy':'ERC1967Proxy','CardProxyAdmin':'ManagedProxyAdmin','CardProxy':'ManagedApplicationProxy'}
    for name,row in d.journal['deployments'].items():
        alias=public_alias.get(name,name); art=d.artifacts[alias]
        actual=bytearray(d.w3.eth.get_code(row['address'])); template=bytes.fromhex(art['runtime_bytecode'][2:])
        assert len(actual)==len(template)
        for ast_id,spans in d.lock[alias]['immutable_references'].items():
            values={int.from_bytes(actual[s['start']:s['start']+s['length']],'big') for s in spans}
            assert values=={int(row['immutable_values'][ast_id],16)}
            for s in spans:actual[s['start']:s['start']+s['length']]=template[s['start']:s['start']+s['length']]
        assert bytes(actual)==template,name
        cid=metadata_cid(hx(d.w3.eth.get_code(row['address'])))
        assert pins['contracts'][alias]['metadata_cid']==cid
        report['public_runtimes'][name]={'address':row['address'],'artifact':alias,'metadata_cid':cid,'runtime_matches':True}
    private_alias={'ComboProxy':'ManagedApplicationProxy','ComboProxyAdmin':'ManagedProxyAdmin','ComboUpgradeCanary':'PrivateComboStorage'}
    for name,row in d.journal['private_deployments'].items():
        alias=private_alias.get(name,name); actual=private_hash(row['address'])
        expected=hx(d.w3.keccak(hexstr=d.artifacts[alias]['runtime_bytecode']))
        assert actual==expected,name
        report['private_runtimes'][name]={'address':row['address'],'artifact':alias,'runtime_keccak256':actual,
                                         'metadata_cid':pins['contracts'][alias]['metadata_cid'],'runtime_matches':True}
    check('compiled_runtime_and_pinned_metadata_match',True)
    cm=d.at('CodeManagerStrict',ADDR['CodeManager'])
    card=d.at('CryftGreetingCards',d.journal['deployments']['CardProxy']['address'])
    proxy=d.journal['private_deployments']['ComboProxy']['address']; admin=d.journal['private_deployments']['ComboProxyAdmin']['address']
    def state():
        group=d.rpc('pgroup_getGroupById','pente',d.journal['group']['id'])
        return {'group_id':group['id'],'group_address':group['contractAddress'],
          'settlement':d.rpc('keymgr_resolveEthAddress','settlement'),'operator':d.rpc('keymgr_resolveEthAddress','operator'),
          'private_admin':value(d.private_call('PrivateComboStorageStrict','ADMIN',proxy)),
          'authorized':value(d.private_call('PrivateComboStorageStrict','AUTHORIZED',proxy)),
          'forwarder':value(d.private_call('PrivateComboStorageStrict','TRUSTED_FORWARDER',proxy)),
          'private_implementation':value(d.private_call('ManagedProxyAdmin','getProxyImplementation',admin,[proxy])),
          'private_proxy_owner':value(d.private_call('ManagedProxyAdmin','owner',admin)),
          'public_implementation':hex(int.from_bytes(d.w3.eth.get_storage_at(cm.address,IMPL_SLOT),'big')),
          'owners':[card.functions.ownerOf(i).call() for i in range(1,6)],
          'deliveries':[cm.functions.getRedemptionDelivery(card.functions.getUniqueIdForToken(i).call()).call() for i in range(1,6)],
          'token_uris':[card.functions.tokenURI(i).call() for i in range(1,6)]}
    before=state()
    check('five_nfts_delivered',before['owners']==[TESTER]*5 and before['deliveries']==[[TESTER,True,2 if i==3 else 1] for i in range(1,6)])
    check('active_implementations',int(before['public_implementation'],16)==int(d.journal['strict_settlement']['public_implementation'],16) and before['private_implementation'].lower()==d.journal['strict_settlement']['private_implementation'].lower())
    check('development_authority_intact',before['private_admin'].lower()==d.journal['operator_address'].lower() and before['authorized'].lower()==before['private_admin'].lower() and before['private_proxy_owner'].lower()==before['private_admin'].lower() and before['forwarder']==ZERO)
    sponsor=d.at('GasSponsor')
    check('sponsor_test_cleanup',sponsor.functions.paused().call() and sponsor.functions.getSponsorFunding(card.address).call()==[0,0])
    check('temporary_public_group_authority_removed',not cm.functions.isAuthorizedPrivacyGroup(TESTER).call())
    for row in d.journal['transactions'].values():
        receipt=d.w3.eth.get_transaction_receipt(row['hash']);assert receipt['status']==row.get('expected_status',1)
    for row in d.journal['private_transactions'].values():
        receipt=d.rpc('ptx_getTransactionReceiptFull',row['id']);assert receipt and receipt['success']
    check('all_journaled_transactions_resolved',True)
    report['journal_counts']={'public':len(d.journal['transactions']),'private':len(d.journal['private_transactions']),
                              'checks':len(d.journal['checks']),'deliberate_public_reverts':sum(r.get('expected_status')==0 for r in d.journal['transactions'].values())}
    ssh=connect(next(h for h in HOSTS if h['name']=='Paladin-01'),True)
    try:
        if restart:
            assert not git('diff','HEAD','--','Tools/Paladin')
            assert git('ls-remote','origin','refs/heads/review/compiler-standard-json').split()[0]==git('rev-parse','HEAD')
            result=run(ssh,'systemctl stop cryft-paladin && systemctl restart cryft-paladin-db && systemctl start cryft-paladin',120)
            assert result['exit']==0,result['stderr']
            for _ in range(35):
                try:
                    after=state()
                    if after==before:break
                except Exception: pass
                time.sleep(1)
            else:raise AssertionError('State did not recover unchanged after service restart')
            check('database_and_paladin_restart_preserves_state',after==before)
        result=run(ssh,'systemctl show cryft-paladin cryft-paladin-db cryft-nginx -p Id -p User -p ActiveState -p UnitFileState -p MemoryMax -p CPUQuotaPerSecUSec; ss -lntup',30)
        assert result['exit']==0
        report['service_inspection']=result['stdout']
        check('services_enabled_and_active',result['stdout'].count('ActiveState=active')==3 and result['stdout'].count('UnitFileState=enabled')==3)
        check('raw_origins_on_loopback',all('127.0.0.1:'+str(port) in result['stdout'] for port in [8548,8549,5433,6100]))
        check('low_privilege_users',result['stdout'].count('User=cryft-paladin')==2 and 'User=cryft-proxy' in result['stdout'])
        with ssh.open_sftp() as s:
            with s.open('/etc/cryft/paladin/installation.json') as f: installed=json.loads(f.read())
        report['installation']=installed
    finally:ssh.close()
    report['state']=before
    report['explorer']={}
    for name in ['first_redemption','sponsored_redemption','strict_settlement']:
        txhash=d.journal[name]['public_transaction_hash']
        url='http://100.111.69.1:8080/api/v2/transactions/'+txhash+'/internal-transactions'
        response=d.http.get(url,timeout=30);response.raise_for_status();body=response.json()
        assert body['items'], 'Explorer internal traces missing: '+name
        report['explorer'][name]={'transaction_hash':txhash,'internal_calls_on_first_page':len(body['items']),'url':'http://100.111.69.1:8080/tx/'+txhash}
    check('explorer_indexes_nested_redemption_calls',True)
    report['ipfs_contracts']=pins['contracts'];report['ipfs_unique_compiler_objects']=len(pins['objects'])
    report['card_metadata']=pins['card_metadata'];report['historical_card_metadata']=pins.get('historical_card_metadata',[])
    report['passed']=True
    (d.out/'acceptance-report.json').write_bytes((json.dumps(serial(report),indent=2)+'\n').encode())
    print('Paladin acceptance audit complete.',flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);p.add_argument('--restart-services',action='store_true');a=p.parse_args();audit(Live(a.workspace),a.restart_services)
