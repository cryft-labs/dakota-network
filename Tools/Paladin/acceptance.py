"""Private code lifecycle acceptance. Never print or publish codes, PINs or private receipts."""
import argparse, ctypes, json, secrets
from ctypes import wintypes
from live import Live, TESTER, ADMIN, DEPLOYER, ZERO, hx

def local_fixture(d,count=4):
    # These are new local acceptance codes, never exported Paladin wallet secrets.
    path=d.out/'acceptance-fixture.dpapi'
    class Blob(ctypes.Structure): _fields_=[('size',wintypes.DWORD),('data',ctypes.POINTER(ctypes.c_ubyte))]
    def transform(raw,encrypt):
        buffer=(ctypes.c_ubyte*len(raw)).from_buffer_copy(raw); source=Blob(len(raw),buffer); dest=Blob()
        library=ctypes.WinDLL('crypt32',use_last_error=True); kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.LocalFree.argtypes=[ctypes.c_void_p]
        if encrypt: ok=library.CryptProtectData(ctypes.byref(source),'Dakota local acceptance fixture',None,None,None,1,ctypes.byref(dest))
        else: ok=library.CryptUnprotectData(ctypes.byref(source),None,None,None,None,1,ctypes.byref(dest))
        assert ok
        try:return ctypes.string_at(dest.data,dest.size)
        finally:kernel.LocalFree(dest.data)
    if not path.exists():
        raw=json.dumps({'codes':[secrets.token_urlsafe(32) for _ in range(4)],'entropies':['0x'+secrets.token_hex(32) for _ in range(4)]}).encode()
        path.write_bytes(transform(raw,True))
    fixture=json.loads(transform(path.read_bytes(),False))
    if len(fixture['codes']) < count:
        missing=count-len(fixture['codes'])
        fixture['codes'].extend(secrets.token_urlsafe(32) for _ in range(missing))
        fixture['entropies'].extend('0x'+secrets.token_hex(32) for _ in range(missing))
        path.write_bytes(transform(json.dumps(fixture).encode(),True))
    fixture['hashes']=[hx(d.w3.keccak(text=code)) for code in fixture['codes']]
    return fixture

def logs(d,receipt,event,types):
    topic=hx(d.w3.keccak(text=event))
    return [d.w3.codec.decode(types,bytes.fromhex(log['data'][2:])) for log in receipt['domainReceipt']['receipt']['logs'] if log['topics'][0].lower()==topic.lower()]

def value(result): return next(iter(result.values())) if isinstance(result,dict) else result[0] if isinstance(result,list) else result

def run(d):
    fixture=local_fixture(d); hashes=fixture['hashes']; proxy=d.journal['private_deployments']['ComboProxy']['address']
    card=d.at('CryftGreetingCards',d.journal['deployments']['CardProxy']['address']); cm=d.at('CodeManager')
    identifier,count=cm.functions.getIdentifierCounter(card.address,'112311').call(); uids=[identifier+'-'+str(i) for i in range(1,5)]
    def call(method,inputs=None):return d.private_call('PrivateComboStorage',method,proxy,inputs)
    def send(label,method,inputs):return d.private_send(label,'PrivateComboStorage',method,proxy,inputs)
    def stage(label,action):
        if d.journal.setdefault('acceptance',{}).get(label): print('RECORDED '+label,flush=True); return
        action(); d.journal['acceptance'][label]=True; d.save()
    stored=send('codes:store_four','storeDataBatch',[[identifier,[1,2,3,4],hashes,8,False,fixture['entropies'],[ZERO]*4,[True]*4]])
    assignments=logs(d,stored,'DataStoredStatus(string,string)',['string','string'])
    assert len(assignments)==4 and [x[0] for x in assignments]==uids
    pins=[x[1] for x in assignments]
    def exists(index):
        result=call('pinToHash',[pins[index],hashes[index]])
        return result['exists'] if isinstance(result,dict) else result[2]
    def rejected_call(label,request):
        try:d.rpc('pgroup_call',request)
        except RuntimeError as e:
            assert 'revert' in str(e).lower(),str(e)
            d.check(label,True,{'read_only_revert':True})
        else:raise AssertionError('Expected rejection: '+label)
    def invalid():
        r=send('codes:wrong_pin','redeemCodeBatch',[['incorrect-pin'],[hashes[0]],[TESTER]])
        assert len(logs(d,r,'RedeemFailed(uint256,string)',['uint256','string']))==1
        d.check('private:wrong_pin_preserves_code',exists(0) and card.functions.ownerOf(1).call()==card.address)
        r=send('codes:wrong_code','redeemCodeBatch',[[pins[0]],[hx(d.w3.keccak(text='not-a-valid-acceptance-code'))],[TESTER]])
        assert len(logs(d,r,'RedeemFailed(uint256,string)',['uint256','string']))==1
        d.check('private:wrong_code_preserves_code',exists(0))
        request=d.private_request('PrivateComboStorage','redeemCodeBatch',proxy,[[pins[0]],[hashes[0]],[TESTER]])
        request['from']='outsider@paladin01'; rejected_call('private:unauthorized_redemption',request)
        rejected_call('private:implementation_initializer_locked',d.private_request('PrivateComboStorage','initialize',d.journal['private_deployments']['PrivateComboStorage']['address'],[d.journal['operator_address'],ZERO,ZERO]))
        rejected_call('private:proxy_reinitialization_blocked',d.private_request('PrivateComboStorage','initialize',proxy,[d.journal['operator_address'],ZERO,ZERO]))
    stage('invalid_inputs',invalid)
    def upgrade():
        replacement=d.private_deploy('PrivateComboStorage',label='ComboUpgradeCanary')
        admin=d.journal['private_deployments']['ComboProxyAdmin']['address']
        request=d.private_request('ManagedProxyAdmin','upgrade',admin,[proxy,replacement]); request['from']='outsider@paladin01'
        rejected_call('private:unauthorized_upgrade',request)
        d.private_send('private:upgrade_with_stored_codes','ManagedProxyAdmin','upgrade',admin,[proxy,replacement])
        d.check('private:upgrade_preserves_codes',all(exists(i) for i in range(4)))
        d.check('private:upgrade_preserves_roles',str(value(call('ADMIN'))).lower()==d.journal['operator_address'].lower())
        d.private_send('private:restore_original_logic','ManagedProxyAdmin','upgrade',admin,[proxy,d.journal['private_deployments']['PrivateComboStorage']['address']])
    stage('upgrade',upgrade)
    def freeze():
        send('codes:freeze_second','setUniqueIdActiveBatch',[[uids[1]],[False]])
        d.check('private:freeze_mirrored_publicly',not cm.functions.isUniqueIdActive(uids[1]).call())
        r=send('codes:reject_frozen','redeemCodeBatch',[[pins[1]],[hashes[1]],[TESTER]])
        assert len(logs(d,r,'RedeemFailed(uint256,string)',['uint256','string']))==1
        d.check('private:freeze_preserves_code',exists(1) and card.functions.ownerOf(2).call()==card.address)
        send('codes:unfreeze_second','setUniqueIdActiveBatch',[[uids[1]],[True]])
        d.check('private:unfreeze_mirrored_publicly',cm.functions.isUniqueIdActive(uids[1]).call())
    stage('freeze',freeze)
    def redeem():
        r=send('codes:first_card_redemption','redeemCodeBatch',[[pins[0]],[hashes[0]],[TESTER]])
        assert len(logs(d,r,'RedeemStatus(string,address)',['string','address']))==1
        d.check('private:redemption_consumes_code',not exists(0))
        d.check('public:redemption_delivers_nft',card.functions.ownerOf(1).call()==TESTER and cm.functions.getRedemptionDelivery(uids[0]).call()==[TESTER,True,1])
        d.journal['first_redemption']={'uid':uids[0],'token_id':1,'nft':card.address,'recipient':TESTER,'public_transaction_hash':r['transactionHash'],'block_number':r['blockNumber']};d.save()
        r=send('codes:first_card_replay','redeemCodeBatch',[[pins[0]],[hashes[0]],[DEPLOYER]])
        assert len(logs(d,r,'RedeemFailed(uint256,string)',['uint256','string']))==1
        d.check('private:replay_cannot_redirect_nft',card.functions.ownerOf(1).call()==TESTER and cm.functions.getRedemptionDelivery(uids[0]).call()==[TESTER,True,1])
    stage('redemption',redeem)
    print(json.dumps(d.journal['first_redemption']),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);a=p.parse_args();run(Live(a.workspace,True))
