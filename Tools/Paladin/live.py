"""Journaled operations for the authorized development Pente deployment."""
import argparse, hashlib, json, sys, time
from pathlib import Path
import requests

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'Tools/LiveGenesis'))
from common import Deployment, DEPLOYER, TESTER, ADMIN, ZERO, ADDR, git, hx, serial

class Live(Deployment):
    def __init__(self,workspace,execute=False):
        super().__init__(workspace,execute)
        if execute:
            assert not git('diff','HEAD','--','Tools/Paladin','Contracts')
            assert not git('ls-files','--others','--exclude-standard','--','Tools/Paladin','Contracts')
        self.out=self.workspace/'outputs/paladin-live-20260911'; self.out.mkdir(exist_ok=True)
        self.path=self.out/'transactions.json'
        self.journal=json.loads(self.path.read_text()) if self.path.exists() else {'transactions':{},'deployments':{},'checks':{},'private_transactions':{}}
        newlock=json.loads((Path(__file__).with_name('artifact-lock.json')).read_text())
        for name,record in newlock.items():
            path=self.out/'artifacts'/name/'artifact.json'; assert hashlib.sha256(path.read_bytes()).hexdigest()==record['artifact_sha256'],name
            self.artifacts[name]=json.loads(path.read_text(encoding='utf-8')); self.lock[name]=record
        self.http=requests.Session(); self.http.trust_env=False

    def rpc(self,method,*params):
        response=self.http.post('http://100.111.32.201:8550/',json={'jsonrpc':'2.0','id':1,'method':method,'params':list(params)},timeout=40)
        response.raise_for_status(); data=response.json()
        if data.get('error'): raise RuntimeError(method+': '+json.dumps(data['error']))
        return data['result']

    def wait_private(self,txid):
        for _ in range(25):
            receipt=self.rpc('ptx_getTransactionReceiptFull',txid)
            if receipt:
                assert receipt.get('success'), 'Private transaction failed: '+str(receipt.get('failureMessage'))
                return receipt
            time.sleep(1)
        raise TimeoutError('Private transaction still pending; resume using existing id '+txid)

    def private(self,label,request):
        assert self.execute
        previous=self.journal['private_transactions'].get(label)
        digest=hashlib.sha256(json.dumps(request,sort_keys=True).encode()).hexdigest()
        if previous: assert previous['input_sha256']==digest, 'Journal label reused with a different private request: '+label
        if previous and previous.get('id'): txid=previous['id']
        else:
            key='dakota-live-20260911:'+label
            # Persist a stable idempotency key before RPC; resuming never invents a new request.
            row={'idempotency_key':key,'input_sha256':digest,'source_commit':self.commit}
            self.journal['private_transactions'][label]=row; self.save()
            txid=self.rpc('pgroup_sendTransaction',dict(request,idempotencyKey=key)); row['id']=txid; self.save()
            print('PRIVATE SENT '+label+' '+txid,flush=True)
        receipt=self.wait_private(txid)
        # Domain receipts can expose PINs/codes; persist only non-secret evidence.
        row=self.journal['private_transactions'][label]
        row['success']=True; row['public_receipt']={k:receipt.get(k) for k in ['transactionHash','blockNumber','source']}
        row['contract_address']=receipt.get('domainReceipt',{}).get('receipt',{}).get('contractAddress')
        self.save(); print('PRIVATE PASS '+label,flush=True)
        return receipt

    def private_request(self,name,method,address=None,inputs=None):
        abi=next(x for x in self.artifacts[name]['abi'] if x.get('name')==method) if method else next((x for x in self.artifacts[name]['abi'] if x['type']=='constructor'),{'type':'constructor','inputs':[]})
        request={'domain':'pente','group':self.journal['group']['id'],'from':'operator@paladin01','gas':12000000,'function':abi,'input':inputs or []}
        if address: request['to']=address
        else: request['bytecode']=self.artifacts[name]['creation_bytecode']
        return request

    def private_deploy(self,name,args=None,label=None):
        label=label or name
        receipt=self.private('deploy:'+label,self.private_request(name,None,inputs=args))
        address=receipt['domainReceipt']['receipt']['contractAddress']; assert address
        self.journal.setdefault('private_deployments',{})[label]={'address':address,'artifact':self.lock[name]}; self.save()
        return address

    def private_call(self,name,method,address,inputs=None):
        return self.rpc('pgroup_call',self.private_request(name,method,address,inputs))

    def private_send(self,label,name,method,address,inputs=None):
        return self.private(label,dict(self.private_request(name,method,address,inputs),publicTxOptions={'gas':2000000}))

def infrastructure(d):
    factory=d.deploy('PenteFactory')
    initializer=bytes.fromhex(factory.functions.initialize()._encode_transaction_data()[2:])
    proxy=d.deploy('ERC1967Proxy',factory.address,initializer,label='PenteFactoryProxy')
    d.check('factory:atomic_owner',d.at('PenteFactory',proxy.address).functions.owner().call()==DEPLOYER)
    d.reject('factory:implementation_locked',factory.functions.initialize())
    d.reject('factory:proxy_reinitialization_blocked',d.at('PenteFactory',proxy.address).functions.initialize())
    print(json.dumps({'factory':proxy.address,'from_block':d.journal['transactions']['deploy:PenteFactory']['receipt']['blockNumber']}))

def group(d):
    assert d.execute
    address=d.w3.to_checksum_address(d.rpc('keymgr_resolveEthAddress','settlement'))
    d.journal['settlement_address']=address; d.save()
    d.tx('fund:paladin-settlement',transaction={'to':address,'value':3*10**16,'gas':21000,'gasPrice':10**9})
    if not d.journal.get('group'):
        existing=d.rpc('pgroup_queryGroups',{'eq':[{'field':'name','value':'moment-cards-development'}],'limit':10})
        assert len(existing)<=1,'Ambiguous existing groups'
        request={'domain':'pente','name':'moment-cards-development','members':['operator@paladin01'],
                 'configuration':{'evmVersion':'shanghai','endorsementType':'group_scoped_identities','externalCallsEnabled':'true'},
                 'transactionOptions':{'idempotencyKey':'dakota-live-20260911:group','gas':6000000}}
        d.journal['group']=existing[0] if existing else d.rpc('pgroup_createGroup',request); d.save()
    g=d.journal['group']; receipt=d.wait_private(g['genesisTransaction'])
    g=d.rpc('pgroup_getGroupById','pente',g['id']); assert g['contractAddress']; d.journal['group']=g; d.save()
    d.check('pente:group_on_chain',len(d.w3.eth.get_code(d.w3.to_checksum_address(g['contractAddress'])))>0)
    print(json.dumps({'group':g,'settlement':address}))

def application(d):
    metadata=json.loads((d.out/'ipfs-verification.json').read_text()); assert metadata['passed']
    base=metadata['card_metadata']['base_uri']
    logic=d.deploy('CryftGreetingCards')
    admin=d.deploy('ManagedProxyAdmin',DEPLOYER,label='CardProxyAdmin')
    init=bytes.fromhex(logic.functions.initializeWithOwner('moment.cards Development','MOMENTDEV',base,ADDR['CodeManager'],'112311',DEPLOYER)._encode_transaction_data()[2:])
    shell=d.deploy('ManagedApplicationProxy',logic.address,admin.address,init,label='CardProxy')
    card=d.at('CryftGreetingCards',shell.address)
    d.check('cards:atomic_owner',card.functions.owner().call()==DEPLOYER)
    d.reject('cards:reinitialization_blocked',card.functions.initialize('x','x',base,ADDR['CodeManager'],'112311'))
    cm=d.at('CodeManager')
    d.tx('cards:register_four_uids',card.functions.setMaxSaleSupply(4),value=cm.functions.registrationFee().call()*4)
    d.tx('cards:buy_four_into_vault',card.functions.buy(TESTER,4,base))
    d.tx('codes:scope_group_to_card',cm.functions.voteToSetPrivacyGroupGift(d.w3.to_checksum_address(d.journal['group']['contractAddress']),card.address,True))
    d.check('codes:tenant_scoped',cm.functions.isScopedPrivacyGroup(d.w3.to_checksum_address(d.journal['group']['contractAddress'])).call())
    operator=d.w3.to_checksum_address(d.rpc('keymgr_resolveEthAddress','operator'))
    d.journal['operator_address']=operator; d.save()
    private_logic=d.private_deploy('PrivateComboStorage')
    private_admin=d.private_deploy('ManagedProxyAdmin',[operator],label='ComboProxyAdmin')
    private_init=bytes.fromhex(d.at('PrivateComboStorage',d.w3.to_checksum_address(private_logic)).functions.initialize(operator,operator,ZERO)._encode_transaction_data()[2:])
    private_proxy=d.private_deploy('ManagedApplicationProxy',[private_logic,private_admin,hx(private_init)],label='ComboProxy')
    d.check('private:atomic_admin',str(d.private_call('PrivateComboStorage','ADMIN',private_proxy)).lower().find(operator.lower())>=0)
    identifier,counter=cm.functions.getIdentifierCounter(card.address,'112311').call()
    d.private_send('private:whitelist_card','PrivateComboStorage','setContractIdentifierWhitelist',private_proxy,[[identifier],[True]])
    d.private_send('private:sync_registered_count','PrivateComboStorage','syncRegisteredCodeCountBatch',private_proxy,[[identifier],[counter]])
    d.check('cards:vault_holds_unredeemed',card.functions.ownerOf(1).call()==card.address)
    print(json.dumps({'card':card.address,'private_combo':private_proxy,'operator':operator,'registered':counter}))

def main():
    p=argparse.ArgumentParser(); p.add_argument('--workspace',required=True); p.add_argument('--execute',action='store_true'); p.add_argument('stage',choices=['infrastructure','group','application','inspect']); a=p.parse_args()
    d=Live(a.workspace,a.execute)
    if a.stage=='infrastructure': infrastructure(d)
    elif a.stage=='group': group(d)
    elif a.stage=='application': application(d)
    else: print(json.dumps({'head':d.w3.eth.block_number,'wallets':d.rpc('keymgr_wallets'),'domains':d.rpc('domain_listDomains')}))

if __name__=='__main__': main()
