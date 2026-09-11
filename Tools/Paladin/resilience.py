"""Bounded live delivery recovery, concurrent redemption, and private handover checks."""
import argparse,copy,json
from acceptance import local_fixture,logs,value
from live import Live,DEPLOYER,TESTER,ZERO

def run(d):
    card=d.at('CryftGreetingCards',d.journal['deployments']['CardProxy']['address']);cm=d.at('CodeManager')
    proxy=d.journal['private_deployments']['ComboProxy']['address']; fixture=local_fixture(d)
    stored=d.rpc('ptx_getTransactionReceiptFull',d.journal['private_transactions']['codes:store_four']['id'])
    pins=[x[1] for x in logs(d,stored,'DataStoredStatus(string,string)',['string','string'])]
    def stage(name,action):
        if d.journal.setdefault('resilience',{}).get(name):print('RECORDED '+name,flush=True);return
        action();d.journal['resilience'][name]=True;d.save()
    def recovery():
        assert json.loads((d.out/'ipfs-verification.json').read_text())['contracts']['DeliveryFailureProbe']
        failure=d.deploy('DeliveryFailureProbe');admin=d.at('ManagedProxyAdmin',d.journal['deployments']['CardProxyAdmin']['address'])
        original=d.journal['deployments']['CryftGreetingCards']['address'];uid=card.functions.getUniqueIdForToken(3).call()
        try:
            d.tx('recovery:temporarily_reject_delivery',admin.functions.upgrade(card.address,failure.address))
            d.private_send('codes:third_card_pending_delivery','PrivateComboStorage','redeemCodeBatch',proxy,[[pins[2]],[fixture['hashes'][2]],[TESTER]])
            d.check('recovery:recipient_committed_despite_delivery_failure',cm.functions.getRedemptionDelivery(uid).call()==[TESTER,False,1])
        finally:
            d.tx('recovery:restore_card_implementation',admin.functions.upgrade(card.address,original))
        d.check('recovery:nft_remains_in_vault',card.functions.ownerOf(3).call()==card.address)
        d.reject('recovery:owner_cannot_redirect_committed_recipient',card.functions.syncRedemption(uid,DEPLOYER),sender=DEPLOYER)
        d.tx('recovery:retry_committed_delivery',cm.functions.retryRedemptionDelivery(uid))
        d.check('recovery:retry_delivers_to_committed_recipient',card.functions.ownerOf(3).call()==TESTER and cm.functions.getRedemptionDelivery(uid).call()==[TESTER,True,2])
        d.tx('recovery:repeat_retry_is_safe',cm.functions.retryRedemptionDelivery(uid))
        d.check('recovery:repeat_retry_does_not_redeliver',cm.functions.getRedemptionDelivery(uid).call()==[TESTER,True,2])
    stage('delivery_recovery',recovery)
    def concurrent():
        record=d.journal.setdefault('concurrent_redemptions',{});d.save()
        if not record.get('ids'):
            original=d.rpc('ptx_getTransaction',d.journal['private_transactions']['codes:first_card_redemption']['id'])
            requests=[];found=[]
            for i in range(2):
                request={k:copy.deepcopy(original[k]) for k in ['type','domain','function','abiReference','from','to','data']}
                request['idempotencyKey']='dakota-live-20260911:concurrent-fourth:'+str(i)
                request['data']['inputs']={'pins':[pins[3]],'codeHashes':[fixture['hashes'][3]],'redeemers':[TESTER]}
                request['gas']=2000000;requests.append(request)
                found.append(d.rpc('ptx_getTransactionByIdempotencyKey',request['idempotencyKey']))
            assert all(found) or not any(found),'Reconcile partial batch acceptance'
            record['ids']=[t['id'] for t in found] if all(found) else d.rpc('ptx_sendTransactions',requests);d.save()
        receipts=[d.wait_private(txid) for txid in record['ids']]
        successes=sum(len(logs(d,r,'RedeemStatus(string,address)',['string','address'])) for r in receipts)
        failures=sum(len(logs(d,r,'RedeemFailed(uint256,string)',['uint256','string'])) for r in receipts)
        uid=card.functions.getUniqueIdForToken(4).call()
        d.check('concurrency:one_redemption_wins',successes==1 and failures==1)
        d.check('concurrency:one_nft_delivery',card.functions.ownerOf(4).call()==TESTER and cm.functions.getRedemptionDelivery(uid).call()==[TESTER,True,1])
        record['public_transactions']=[r['transactionHash'] for r in receipts];d.save()
    stage('concurrent_redemption',concurrent)
    def handover():
        previous=d.journal['operator_address'];successor=d.w3.to_checksum_address(d.rpc('keymgr_resolveEthAddress','maintenance'))
        admin=d.journal['private_deployments']['ComboProxyAdmin']['address']
        def send(label,name,method,target,inputs=None,sender='operator@paladin01'):
            request=d.private_request(name,method,target,inputs);request['from']=sender
            return d.private(label,dict(request,publicTxOptions={'gas':2000000}))
        send('handover:propose_private_admin','PrivateComboStorage','transferAdmin',proxy,[successor])
        d.check('handover:proposal_keeps_current_authority',str(value(d.private_call('PrivateComboStorage','ADMIN',proxy))).lower()==previous.lower())
        send('handover:accept_private_admin','PrivateComboStorage','acceptAdmin',proxy,sender='maintenance@paladin01')
        d.check('handover:former_service_revoked',str(value(d.private_call('PrivateComboStorage','AUTHORIZED',proxy))).lower()==ZERO.lower())
        request=d.private_request('PrivateComboStorage','setAuthorized',proxy,[previous])
        try:d.rpc('pgroup_call',request)
        except RuntimeError as e:assert 'revert' in str(e).lower()
        else:raise AssertionError('Former administrator retained control')
        send('handover:propose_proxy_admin','ManagedProxyAdmin','transferOwnership',admin,[successor])
        send('handover:accept_proxy_admin','ManagedProxyAdmin','acceptOwnership',admin,sender='maintenance@paladin01')
        d.check('handover:proxy_owner_rotated',str(value(d.private_call('ManagedProxyAdmin','owner',admin))).lower()==successor.lower())
        send('handover:propose_restore_private_admin','PrivateComboStorage','transferAdmin',proxy,[previous],sender='maintenance@paladin01')
        send('handover:accept_restore_private_admin','PrivateComboStorage','acceptAdmin',proxy)
        send('handover:propose_restore_proxy_admin','ManagedProxyAdmin','transferOwnership',admin,[previous],sender='maintenance@paladin01')
        send('handover:accept_restore_proxy_admin','ManagedProxyAdmin','acceptOwnership',admin)
        send('handover:restore_development_service','PrivateComboStorage','setAuthorized',proxy,[previous])
        d.check('handover:development_authorities_restored',str(value(d.private_call('PrivateComboStorage','ADMIN',proxy))).lower()==previous.lower() and str(value(d.private_call('ManagedProxyAdmin','owner',admin))).lower()==previous.lower())
        d.check('handover:nfts_unchanged',all(card.functions.ownerOf(i).call()==TESTER for i in range(1,5)))
        d.journal['private_handover_test']={'successor':successor,'restored_to':previous,'external_management_handover_complete':False};d.save()
    stage('private_handover',handover)
    print('Recovery, concurrency and private authority handover verified.',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);a=p.parse_args();run(Live(a.workspace,True))
