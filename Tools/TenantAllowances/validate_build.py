"""Recompile portable release inputs and record runtime immutable references."""
import copy,hashlib,json,re,subprocess
from pathlib import Path
import solcx

REPO=Path(__file__).resolve().parents[2]
RELEASE=REPO/'Releases/TenantAllowances/1.0.0'
BASELINE='3a2a67e4a5b18443c6a4873162e68d4864d997cb'

def baseline(path):
    return subprocess.check_output(['git','-c','safe.directory='+str(REPO),'-C',str(REPO),'show',BASELINE+':Contracts/'+path]).decode('utf-8')

def members(source,name):
    body=re.search(r'struct '+name+r'\s*\{([^}]+)',source).group(1)
    return [re.sub(r'\s+','',line) for line in re.sub(r'//[^\n]*','',body).split(';') if line.strip()]

def main():
    report={'baseline_commit':BASELINE,'contracts':{}}
    for name in ('GasSponsor','TenantAllowancePolicy'):
        path=next(RELEASE.rglob(name+'_artifact.json'));artifact=json.loads(path.read_text(encoding='utf-8'))
        request=copy.deepcopy(artifact['standard_json_input'])
        for unit,value in request['sources'].items():
            assert value['content']==(REPO/'Contracts'/unit.removeprefix('source/')).read_text(encoding='utf-8'),unit+' differs from reviewed source'
        request['settings']['outputSelection']={'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode','storageLayout']}}
        result=solcx.compile_standard(request,solc_version=artifact['compiler_version'])
        unit='source/'+artifact['source_rel_path']
        compiled=result['contracts'][unit][name]
        assert bytes.fromhex(compiled['evm']['bytecode']['object'])==bytes.fromhex(artifact['creation_bytecode'].removeprefix('0x'))
        assert bytes.fromhex(compiled['evm']['deployedBytecode']['object'])==bytes.fromhex(artifact['runtime_bytecode'].removeprefix('0x'))
        assert compiled['abi']==artifact['abi']
        assert artifact['runtime_size_bytes']<=32768 and artifact['evm_version']=='osaka'
        report['contracts'][name]={'artifact_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'runtime_bytes':artifact['runtime_size_bytes'],'immutable_references':compiled['evm']['deployedBytecode']['immutableReferences']}
        if name=='GasSponsor':
            old=baseline('Genesis/7702/GasSponsor.sol');current=request['sources'][unit]['content']
            for struct in ('SponsorState','GasSponsorStorage'):
                before,after=members(old,struct),members(current,struct)
                assert after[:len(before)]==before,struct+' changed existing storage'
                if struct=='SponsorState':assert after==before
            assert re.search(r'_GAS_SPONSOR_STORAGE_LOCATION\s*=\s*(0x[0-9a-f]+)',old).group(1)==re.search(r'_GAS_SPONSOR_STORAGE_LOCATION\s*=\s*(0x[0-9a-f]+)',current).group(1)
            for path in request['sources']:
                if path!='source/Genesis/7702/Interfaces/ITenantAllowancePolicy.sol':request['sources'][path]['content']=baseline(path.removeprefix('source/'))
            legacy=solcx.compile_standard(request,solc_version=artifact['compiler_version'])['contracts'][unit]['GasSponsor']
            (RELEASE/'baseline-gas-sponsor.json').write_text(json.dumps({'abi':legacy['abi'],'creation_bytecode':'0x'+legacy['evm']['bytecode']['object'],
                'runtime_bytecode':'0x'+legacy['evm']['deployedBytecode']['object'],'baseline_commit':BASELINE},indent=2)+'\n',encoding='utf-8')
            report['storage_append_only']=True
    (RELEASE/'validation.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
