"""Read-only wallet funding and Pente factory/group deployment inspection."""
import argparse,json,sys
from datetime import datetime,timezone
from live import Live,REPO,ADMIN,DEPLOYER,TESTER,ADDR,hx
from common import IMPL_SLOT

def inspect(d):
    sys.path.insert(0,str(REPO/'Tools/SolcCompiler'))
    from ipfs_publish import metadata_cid
    addresses={'paladin_public_settlement':d.journal['settlement_address'],
               'deployer_and_test_relayer':DEPLOYER,'delegated_test_recipient':TESTER,
               'final_management':ADMIN,'private_operator_no_gas_needed':d.journal['operator_address']}
    block=d.w3.eth.block_number
    report={'checked_at':datetime.now(timezone.utc).isoformat(),'block':block,'chain_id':d.w3.eth.chain_id,
            'symbol':'KOTA','decimals':18,'wallets':{},'transactions_sent':0}
    for role,address in addresses.items():
        address=d.w3.to_checksum_address(address); balance=d.w3.eth.get_balance(address,block)
        report['wallets'][role]={'address':address,'balance_wei':str(balance),'balance_kota':str(d.w3.from_wei(balance,'ether'))}
    card=d.journal['deployments']['CardProxy']['address'];sponsor=d.at('GasSponsor')
    report['sponsor']={'address':sponsor.address,'tenant':card,'paused':sponsor.functions.paused().call(),
                       'funding_wei':[str(x) for x in sponsor.functions.getSponsorFunding(card).call()]}
    report['registration_fee_wei']=str(d.at('CodeManager').functions.registrationFee().call())
    original=json.loads((d.workspace/'outputs/live-genesis-20260911/transactions.json').read_text())
    report['current_core_implementations']={}
    for name in ['GasManager','CodeManager','GasSponsor','DakotaDelegationRegistry']:
        expected=d.journal['deployments']['CodeManagerStrict'] if name=='CodeManager' else original['deployments'][name]
        current=d.at('ProxyAdmin').functions.getProxyImplementation(ADDR[name]).call()
        assert current==expected['address']
        assert hx(d.w3.keccak(d.w3.eth.get_code(current)))==expected['runtime_keccak256']
        report['current_core_implementations'][name]={'proxy':ADDR[name],'implementation':current,'runtime_keccak256':expected['runtime_keccak256']}
    group=d.w3.to_checksum_address(d.journal['group']['contractAddress'])
    factory=d.journal['deployments']['PenteFactoryProxy']['address']
    implementation=d.w3.to_checksum_address('0x'+d.w3.eth.get_storage_at(group,IMPL_SLOT)[-20:].hex())
    assert int.from_bytes(d.w3.eth.get_storage_at(factory,0),'big')==int(implementation,16)
    shell=hx(d.w3.eth.get_code(group)); assert shell==d.artifacts['ERC1967Proxy']['runtime_bytecode']
    actual=bytearray(d.w3.eth.get_code(implementation));template=bytes.fromhex(d.artifacts['PentePrivacyGroup']['runtime_bytecode'][2:])
    assert len(actual)==len(template)
    for spans in d.lock['PentePrivacyGroup']['immutable_references'].values():
        assert {int.from_bytes(actual[s['start']:s['start']+s['length']],'big') for s in spans}=={int(implementation,16)}
        for s in spans:actual[s['start']:s['start']+s['length']]=template[s['start']:s['start']+s['length']]
    assert bytes(actual)==template
    report['pente_group']={'proxy':group,'implementation':implementation,'factory':factory,
          'runtime_matches':True,'metadata_cid':metadata_cid(hx(d.w3.eth.get_code(implementation)))}
    (d.out/'funding-status.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);a=p.parse_args();inspect(Live(a.workspace))
