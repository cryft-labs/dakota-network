"""Export exact deployed builds and audit genesis/live coverage without signing.

Never fabricates Solidity artifacts for native precompiles or EIP-7702 designators.
Does not upload to Blockscout or expose private transaction inputs/receipts.
"""
import argparse,csv,hashlib,json,re,sys
from collections import Counter
from datetime import datetime,timezone
from pathlib import Path
import solcx

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'Tools/Paladin'))
sys.path.insert(0,str(REPO/'Tools/SolcCompiler'))
from live import Live,hx,ADDR
from ipfs_publish import metadata_cid
LICENSES={'MIT':('mit',3),'Apache-2.0':('apache_2_0',12)}

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(8*1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes((json.dumps(value,indent=2)+'\n').encode())

def genesis_records(path):
    """Stream the checksum-verified canonical genesis, avoiding a 1.25 GB DOM."""
    with path.open(encoding='utf-8') as f:
        header=[]
        for line in f:
            if line.strip()=='"alloc": {':break
            header.append(line)
        else:raise ValueError('Missing allocation object')
        yield None,json.loads(''.join(header).rstrip().rstrip(',')+'\n}')
        address=None;seen=set();block=[]
        for line in f:
            if address is None:
                if line.strip()=='}':
                    assert f.read().strip()=='}';return
                m=re.fullmatch(r'      "(0x[0-9a-fA-F]{40})": \{\s*',line);assert m
                address=m[1];assert int(address,16) not in seen
                seen.add(int(address,16));block=['{\n']
            elif re.fullmatch(r'      \},?\s*',line):
                yield address,json.loads(''.join(block)+'}');address=None
            else:block.append(line)
        raise ValueError('Incomplete genesis')

def main():
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);p.add_argument('--stage',choices=['build','genesis','chain','all'],default='all');a=p.parse_args()
    root=Path(a.workspace).resolve();d=Live(root)
    # Historical canary artifacts omit the hex prefix; normalize only in memory.
    for art in d.artifacts.values():
        for key in ['runtime_bytecode','creation_bytecode']:
            art[key]='0x'+art[key].removeprefix('0x')
    target=REPO/'Contracts/Verification/20260911';target.mkdir(parents=True,exist_ok=True)
    path=target/'manifest.json';report=json.loads(path.read_text()) if path.exists() else {'builds':{}}
    report.update({'checked_at':datetime.now(timezone.utc).isoformat(),'source_commit':d.commit,'chain_id':112311,'genesis_block_hash':hx(d.w3.eth.get_block(0)['hash']),'blockscout_uploads_performed':False})
    def save():write(path,report)
    if a.stage in ['build','all']:
        compiled_cache={}
        for name,art in d.artifacts.items():
            standard=art['standard_json_input'];digest=hashlib.sha256(json.dumps(standard,sort_keys=True).encode()).hexdigest()
            version=d.lock[name]['compiler']
            if digest not in compiled_cache:compiled_cache[digest]=solcx.compile_standard(standard,solc_version=version)
            result=compiled_cache[digest]
            raw=art['metadata'];metadata=json.loads(raw) if isinstance(raw,str) else raw
            source,contract=next(iter(metadata['settings']['compilationTarget'].items()))
            output=result['contracts'][source][contract]
            assert json.loads(output['metadata'])==metadata,name+': metadata changed'
            assert '0x'+output['evm']['deployedBytecode']['object']==art['runtime_bytecode'],name+': runtime replay mismatch'
            assert '0x'+output['evm']['bytecode']['object']==art['creation_bytecode'],name+': creation replay mismatch'
            if isinstance(raw,str):assert output['metadata']==raw
            target_license=metadata['sources'][source].get('license')
            assert target_license in LICENSES,(name,target_license)
            for unit,record in metadata['sources'].items():
                content=standard['sources'][unit]['content'];assert hx(d.w3.keccak(text=content))==record['keccak256']
                declared=re.findall(r'SPDX-License-Identifier:\s*([^\r\n*]+)',content)
                if record.get('license'):assert declared and declared[0].strip()==record['license'],unit
            folder=target/name;folder.mkdir(exist_ok=True)
            write(folder/'standard-input.json',standard)
            write(folder/'standard-output.json',result)
            (folder/'metadata.json').write_bytes(output['metadata'].encode())
            write(folder/'abi.json',output['abi'])
            for f,k in [('creation-bytecode.txt','creation_bytecode'),('runtime-bytecode.txt','runtime_bytecode')]:
                (folder/f).write_bytes((art[k]+'\n').encode())
            info={'artifact_alias':name,'contract_name':contract,'source_path':source,'qualified_contract_name':source+':'+contract,
                  'compiler_version':'v'+metadata['compiler']['version'],'evm_version':standard['settings']['evmVersion'],
                  'spdx_license':target_license,'license_type':LICENSES[target_license][0],'license_type_id':LICENSES[target_license][1],
                  'source_licenses':{unit:rec.get('license') for unit,rec in metadata['sources'].items()},
                  'metadata_cid':metadata_cid(art['runtime_bytecode']),'runtime_bytes':len(art['runtime_bytecode'][2:])//2,
                  'immutable_references':output['evm']['deployedBytecode'].get('immutableReferences',{}),
                  'files':{f:{'path':name+'/'+f,'sha256':sha(folder/f)} for f in ['standard-input.json','standard-output.json','metadata.json','abi.json','creation-bytecode.txt','runtime-bytecode.txt']},
                  'original_artifact_sha256':d.lock[name]['artifact_sha256'],'compiler_replay_passed':True}
            report['builds'][name]=info;save();print('BUILD '+name+' '+target_license,flush=True)
        with (target/'licenses.csv').open('w',newline='',encoding='utf-8') as f:
            w=csv.writer(f,lineterminator='\n');w.writerow(['artifact_alias','contract_name','spdx','license_type','license_type_id','compiler_version','evm'])
            for name,b in report['builds'].items():w.writerow([name,b['contract_name'],b['spdx_license'],b['license_type'],b['license_type_id'],b['compiler_version'],b['evm_version']])
        report['build_count']=len(report['builds']);report['all_builds_replayed']=True;save()
    if a.stage in ['genesis','all']:
        release=json.loads((REPO/'Contracts/Genesis/development-release.json').read_text())
        archive=REPO/'Contracts/Genesis/besuGenesis.7z';genesis=root/'work/genesis/BesuGenesis.json'
        assert sha(archive)==release['archive_sha256'];assert sha(genesis)==release['genesis_sha256']
        by_code={d.artifacts[n]['runtime_bytecode']:n for n in ['ValidatorSmartContractAllowList','ProxyAdmin','TransparentUpgradeableProxy']}
        counts=Counter();coins=[];precompile_collision=[];names={}
        with (target/'genesis-addresses.csv').open('w',newline='',encoding='utf-8') as f:
            w=csv.writer(f,lineterminator='\n');w.writerow(['address','artifact_alias','license_type','metadata_cid'])
            for address,account in genesis_records(genesis):
                if address is None:assert account['config']['chainId']==112311;continue
                counts['allocations']+=1
                if not account.get('code'):coins.append(address);continue
                alias=by_code[account['code']];b=report['builds'][alias];counts[alias]+=1
                if int(address,16) in list(range(1,18))+[256]:precompile_collision.append(address)
                names.setdefault(alias,address)
                w.writerow([address,alias,b['license_type'],b['metadata_cid']])
        assert dict(counts)==release['counts'] and not precompile_collision
        samples={**names,**ADDR}
        for key,address in samples.items():
            actual=hx(d.w3.eth.get_code(d.w3.to_checksum_address(address),0))
            alias=by_code[actual];assert alias in report['builds']
        report['genesis']={'archive_sha256':release['archive_sha256'],'json_sha256':release['genesis_sha256'],
                          'counts':dict(counts),'all_genesis_bytecodes_match_replayed_builds':True,
                          'address_inventory':'genesis-addresses.csv','inventory_sha256':sha(target/'genesis-addresses.csv'),
                          'non_contract_allocations':coins,'native_precompile_collisions':[],'live_block_zero_sample_addresses':list(set(samples.values())),
                          'coverage':'All allocations checked locally against the live-chain genesis checksum; representative block-zero RPC code reads, not 32433 individual RPC reads.'}
        save();print('GENESIS '+json.dumps(dict(counts)),flush=True)
    if a.stage in ['chain','all']:
        head=d.w3.eth.block_number;endhash=hx(d.w3.eth.get_block(head)['hash']);offset=0;creates={};trace_count=0
        while True:
            r=d.w3.provider.make_request('trace_filter',[{'fromBlock':'0x0','toBlock':hex(head),'after':offset,'count':500}])
            assert 'error' not in r,r.get('error');page=r['result'];trace_count+=len(page)
            for t in page:
                if t['type']=='create' and not t.get('error') and t.get('result',{}).get('address'):
                    address=d.w3.to_checksum_address(t['result']['address']);assert address not in creates
                    creates[address]=t
            print('TRACE PAGE '+str(offset)+' entries='+str(len(page)),flush=True)
            if len(page)<500:break
            offset+=500;assert offset<100000,'Unexpected network growth: bound a new audit interval'
        public=[];unknown=[]
        for address,t in creates.items():
            runtime=hx(d.w3.eth.get_code(address,head))
            try:cid=metadata_cid(runtime)
            except Exception:unknown.append({'address':address,'reason':'no Solidity trailer'});continue
            candidates=[n for n,b in report['builds'].items() if b['metadata_cid']==cid]
            matched=[]
            for alias in candidates:
                art=d.artifacts[alias];actual=bytearray.fromhex(runtime[2:]);template=bytes.fromhex(art['runtime_bytecode'][2:])
                if len(actual)!=len(template):continue
                imm={}
                for ast_id,spans in report['builds'][alias]['immutable_references'].items():
                    values={hx(actual[s['start']:s['start']+s['length']]) for s in spans}
                    assert len(values)==1;imm[ast_id]=next(iter(values))
                    for s in spans:actual[s['start']:s['start']+s['length']]=template[s['start']:s['start']+s['length']]
                if bytes(actual)==template:matched.append((alias,imm))
            if len(matched)!=1:unknown.append({'address':address,'metadata_cid':cid,'matches':[x[0] for x in matched]});continue
            alias,imm=matched[0];b=report['builds'][alias];init=t['action']['init']
            assert init.startswith(d.artifacts[alias]['creation_bytecode']),address+': constructor prefix mismatch'
            args=init[len(d.artifacts[alias]['creation_bytecode']):]
            api=d.http.get('http://100.111.69.1:8080/api/v2/smart-contracts/'+address,timeout=25)
            data=api.json();observed={k:data.get(k) for k in ['is_verified','is_partially_verified','license_type','compiler_version','name','file_path']}
            public.append({'address':address,'artifact_alias':alias,'license_type':b['license_type'],'license_type_id':b['license_type_id'],
                           'metadata_cid':cid,'runtime_keccak256':hx(d.w3.keccak(hexstr=runtime)),'immutable_values':imm,
                           'creation_transaction_hash':t['transactionHash'],'creation_block':t['blockNumber'],
                           'trace_address':t['traceAddress'],'constructor_arguments':args,'constructor_arguments_source':'actual public creation trace suffix',
                           'blockscout_before':{'http_status':api.status_code,**observed},
                           'license_mismatch':bool(observed['is_verified'] and observed['license_type']!=b['license_type'])})
        report['public_creations']={'through_block':head,'block_hash':endhash,'trace_count':trace_count,'successful_creation_count':len(creates),'contracts':public,'unmatched':unknown}
        names=['ECREC','SHA256','RIPEMD160','IDENTITY','MODEXP','ALTBN128_ADD','ALTBN128_MUL','ALTBN128_PAIRING','BLAKE2B_F','KZG_POINT_EVAL','BLS12_G1ADD','BLS12_G1MULTIEXP','BLS12_G2ADD','BLS12_G2MULTIEXP','BLS12_PAIRING','BLS12_MAP_FP_TO_G1','BLS12_MAP_FP2_TO_G2','P256_VERIFY']
        native=[]
        for number,name in zip(list(range(1,18))+[256],names):
            address=d.w3.to_checksum_address('0x'+hex(number)[2:].zfill(40));assert hx(d.w3.eth.get_code(address,head))=='0x'
            native.append({'address':address,'name':name,'type':'besu_native_precompile','standard_json':'not_applicable_native_client_implementation',
                           'solidity_metadata':'not_applicable','blockscout_solidity_upload':False,'client_source_spdx':'Apache-2.0'})
        write(target/'native-precompiles.json',{'besu':'26.8.1','fork':'osaka','source':'https://github.com/besu-eth/besu/blob/26.8.1/evm/src/main/java/org/hyperledger/besu/evm/precompile/MainnetPrecompiledContracts.java','precompiles':native})
        report['native_precompile_count']=len(native)
        private=[]
        mapping={'ComboProxy':'ManagedApplicationProxy','ComboProxyAdmin':'ManagedProxyAdmin','ComboUpgradeCanary':'PrivateComboStorage'}
        for name,row in d.journal['private_deployments'].items():
            address=row['address'];alias=mapping.get(name,name)
            request={'domain':'pente','group':d.journal['group']['id'],'from':'operator@paladin01','gas':1000000,
                     'bytecode':'0x73'+address[2:]+'3f5f5260205ff3','function':{'type':'constructor','inputs':[],'outputs':[{'name':'codeHash','type':'bytes32'}]},'input':[]}
            result=d.rpc('pgroup_call',request);assert result['codeHash']==hx(d.w3.keccak(hexstr=d.artifacts[alias]['runtime_bytecode']))
            private.append({'address':address,'artifact_alias':alias,'group':d.journal['group']['id'],'runtime_keccak256':result['codeHash'],'license_type':report['builds'][alias]['license_type'],'public_blockscout_upload':False,'reason':'Private Pente state is not public Besu contract code'})
        report['private_contracts']=private
        from live import TESTER
        code=hx(d.w3.eth.get_code(TESTER,head));assert code.startswith('0xef0100') and len(code)==48
        report['delegated_accounts']=[{'address':TESTER,'designator':code,'delegate_target':'0x'+code[8:],'solidity_upload':False,'reason':'EIP-7702 authorization designator; verify its target separately'}]
        config=d.http.get('http://100.111.69.1:8080/api/v2/smart-contracts/verification/config',timeout=40).json()
        assert config['license_types']['mit']==3 and config['license_types']['apache_2_0']==12
        versions={b['compiler_version'] for b in report['builds'].values()};assert versions.issubset(set(config['solidity_compiler_versions']))
        report['blockscout_config']={k:config[k] for k in ['license_types','verification_options','is_rust_verifier_microservice_enabled']}
        report['blockscout_config']['required_compilers_available']=sorted(versions)
        report['coverage_passed']=not unknown;save();assert not unknown,'Unmatched public creations: '+json.dumps(unknown)
        print('COVERAGE public='+str(len(public))+' private='+str(len(private))+' native='+str(len(native)),flush=True)

if __name__=='__main__':main()
