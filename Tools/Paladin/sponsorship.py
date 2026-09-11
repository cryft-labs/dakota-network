"""Prepare a private redemption and settle it through public EIP-7702/GasSponsor.

Private execution remains fee-free. No MetaTx relay or private authorization bypass.
"""
import argparse,copy,json,time
from web3.logs import DISCARD
from acceptance import local_fixture,logs
from live import Live,DEPLOYER,TESTER,hx

TENANT='moment-cards-pente-development-20260911'

def run(d):
    assert d.journal['acceptance']['redemption']
    card=d.at('CryftGreetingCards',d.journal['deployments']['CardProxy']['address']); cm=d.at('CodeManager')
    sponsor=d.at('GasSponsor'); account=d.at('DakotaDelegation',TESTER)
    group=d.w3.to_checksum_address(d.journal['group']['contractAddress']); pente=d.at('PentePrivacyGroup',group)
    uid=card.functions.getUniqueIdForToken(2).call()
    fixture=local_fixture(d)
    stored=d.rpc('ptx_getTransactionReceiptFull',d.journal['private_transactions']['codes:store_four']['id'])
    pins=[x[1] for x in logs(d,stored,'DataStoredStatus(string,string)',['string','string'])]
    key='dakota-live-20260911:prepare-sponsored-card-two'
    prepared_record=d.journal.setdefault('prepared_redemption',{'idempotency_key':key});d.save()
    if not prepared_record.get('id'):
        existing=d.rpc('ptx_getTransactionByIdempotencyKey',key)
        if existing:txid=existing['id']
        else:
            previous=d.rpc('ptx_getTransaction',d.journal['private_transactions']['codes:first_card_redemption']['id'])
            request={k:copy.deepcopy(previous[k]) for k in ['type','domain','function','abiReference','from','to','data']}
            request['idempotencyKey']=key
            request['data']['inputs']={'pins':[pins[1]],'codeHashes':[fixture['hashes'][1]],'redeemers':[TESTER]}
            txid=d.rpc('ptx_prepareTransaction',request)
        prepared_record['id']=txid;d.save()
    for _ in range(30):
        prepared=d.rpc('ptx_getPreparedTransaction',prepared_record['id'])
        if prepared:break
        time.sleep(1)
    else:raise TimeoutError('Preparation still pending; resume the recorded id')
    public=prepared['transaction']
    assert public['type']=='public' and public['to'].lower()==group.lower()
    method=public['function'].split('(')[0]
    assert method=='transition', 'Review unexpected prepared settlement method: '+method
    definition=next(x for x in d.artifacts['PentePrivacyGroup']['abi'] if x.get('name')==method)
    def convert(abi,value):
        if abi['type']=='tuple':return tuple(convert(component,value[component['name']]) for component in abi['components'])
        if abi['type']=='tuple[]':return [convert(dict(abi,type='tuple'),item) for item in value]
        if abi['type']=='address':return d.w3.to_checksum_address(value)
        return value
    arguments=[convert(item,public['data'][item['name']]) for item in definition['inputs']]
    settlement=getattr(pente.functions,method)(*arguments)
    # All public settlement calldata is inspected before sending; never export prepared private states.
    payload=bytes.fromhex(settlement._encode_transaction_data()[2:])
    prepared_record['public_calldata_keccak256']=hx(d.w3.keccak(payload));d.save()
    d.tx('pente-sponsor:configure',sponsor.functions.configureSponsor(card.address,d.w3.keccak(text=TENANT),DEPLOYER,5*10**15,2*10**16,True))
    d.tx('pente-sponsor:deposit',sponsor.functions.depositFor(card.address),value=10**16)
    d.tx('pente-sponsor:enable_relayer',sponsor.functions.setRelayer(DEPLOYER,True))
    d.tx('pente-sponsor:unpause',sponsor.functions.setPaused(False))
    if 'pente-sponsor:settle_redemption' not in d.journal['transactions']:
        d.check('sponsored:private_code_not_committed_before_settlement',card.functions.ownerOf(2).call()==card.address)
        d.check('sponsored:public_account_delegated',sponsor.functions.isDelegationReady(TESTER).call())
        d.journal['sponsor_balance_before']=d.w3.eth.get_balance(TESTER);d.save()
    operation=d.w3.keccak(text=TENANT+':card-two'); deadline=d.w3.eth.get_block('latest')['timestamp']+3600
    calls=[(group,0,payload)]
    request=(operation,sponsor.address,calls,account.functions.getNonce().call(),deadline,3000000)
    owner_sig=d.accounts[TESTER].unsafe_sign_hash(account.functions.getExecutionDigest(*request).call()).signature
    execution=bytes.fromhex(account.functions.executeSponsored(request,owner_sig)._encode_transaction_data()[2:])
    callgas=sponsor.functions.minimumCallGas(request[-1],len(execution)).call()
    voucher=(operation,d.w3.keccak(text=TENANT),d.w3.keccak(text='pente-redemption'),card.address,TESTER,DEPLOYER,
             sponsor.functions.approvedDelegate().call(),d.w3.keccak(execution),callgas,10**9,(callgas+100000)*10**9,deadline)
    signature=d.accounts[DEPLOYER].unsafe_sign_hash(sponsor.functions.voucherDigest(voucher).call()).signature
    receipt=d.tx('pente-sponsor:settle_redemption',sponsor.functions.executeSponsored(voucher,execution,signature))
    events=sponsor.events.SponsoredOperation().process_receipt(receipt,errors=DISCARD)
    assert len(events)==1 and events[0]['args']['success'], 'Public wrapper succeeded but inner settlement failed'
    private_receipt=d.wait_private(prepared_record['id'])
    assert private_receipt['transactionHash'].lower()==hx(receipt['transactionHash']).lower()
    d.check('sponsored:nft_delivered',card.functions.ownerOf(2).call()==TESTER and cm.functions.getRedemptionDelivery(uid).call()==[TESTER,True,1])
    d.check('sponsored:recipient_paid_no_public_gas',d.w3.eth.get_balance(TESTER)==d.journal['sponsor_balance_before'])
    refund=sponsor.events.RelayerReimbursed().process_receipt(receipt,errors=DISCARD)[0]['args']
    d.check('sponsored:relayer_reimbursed',refund['reimbursement']>0,dict(refund))
    d.reject('sponsored:transition_replay_blocked',settlement,sender=DEPLOYER)
    d.journal['sponsored_redemption']={'uid':uid,'token_id':2,'nft':card.address,'recipient':TESTER,'public_transaction_hash':hx(receipt['transactionHash']),
          'block_number':receipt['blockNumber'],'private_transaction_id':prepared_record['id'],'public_sender':DEPLOYER,'metatx_used':False,
          'private_evm':'shanghai','public_evm':'osaka','reimbursement_wei':refund['reimbursement']};d.save()
    d.tx('pente-sponsor:pause_after_acceptance',sponsor.functions.setPaused(True))
    d.tx('pente-sponsor:disable_relayer',sponsor.functions.setRelayer(DEPLOYER,False))
    d.tx('pente-sponsor:disable_tenant',sponsor.functions.setSponsorAdminEnabled(card.address,False))
    remaining=sponsor.functions.getSponsorFunding(card.address).call()[0]
    if remaining:d.tx('pente-sponsor:return_unspent_test_deposit',sponsor.functions.withdrawSponsor(card.address,DEPLOYER,remaining))
    d.check('sponsored:cleanup',sponsor.functions.paused().call() and sponsor.functions.getSponsorFunding(card.address).call()==[0,0])
    print(json.dumps(d.journal['sponsored_redemption']),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);a=p.parse_args();run(Live(a.workspace,True))
