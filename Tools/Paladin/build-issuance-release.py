"""Reproducible issuance/gas release with append-only storage validation."""
import copy, hashlib, importlib.util, json, subprocess, re
from pathlib import Path
import solcx

REPO=Path(__file__).resolve().parents[2]
BASELINE='b943573873cb283574debfe268e422156cb9c152'
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
compiler=module('issuance_compiler',REPO/'Tools/SolcCompiler/compile.py')
shape=module('issuance_layout',REPO/'Tools/Paladin/storage_layout.py').shape

def main():
    report={}
    tracked=subprocess.check_output(['git','-c','safe.directory='+REPO.as_posix(),'-C',str(REPO),'ls-files']).decode().splitlines()
    tracked={p.lower():p for p in tracked}
    for name,relative,evm in (
        ('PrivateComboStorage','CodeManagement/PrivateComboStorage.sol','shanghai'),
        ('CryftGreetingCards','Tokens/GreetingCards.sol','osaka'),
        ('WorkerGasSponsor','Genesis/7702/WorkerGasSponsor.sol','osaka'),
        ('TenantAllowancePolicy','Templates/TenantAllowancePolicy.sol','osaka')):
        build=compiler.compile_contract(REPO/'Contracts'/relative,solc_version='0.8.37',evm_version=evm)[name]
        request=build['standard_json_input']
        request['settings']['outputSelection']={'*':{'*':['abi','metadata','storageLayout','evm.bytecode','evm.deployedBytecode']}}
        result=solcx.compile_standard(request,solc_version='0.8.37')
        unit=build['fully_qualified_name'].rsplit(':',1)[0];contract=result['contracts'][unit][name]
        runtime=contract['evm']['deployedBytecode']['object']
        assert len(runtime)//2 <= (24576 if evm=='shanghai' else 32768)
        old=copy.deepcopy(request)
        for path,source in old['sources'].items():
            relative_path='Contracts/'+path.removeprefix('source/')
            if relative_path.endswith('/WorkerGasSponsor.sol'):continue
            if relative_path.lower() not in tracked:continue  # Pinned vendored dependency unit.
            relative_path=tracked[relative_path.lower()]
            previous=subprocess.check_output(['git','-c','safe.directory='+REPO.as_posix(),'-C',str(REPO),'show',BASELINE+':'+relative_path]).decode()
            imports=lambda content:re.findall(r'import\s+(?:\{[^}]*\}\s+from\s+)?[\"\x27]([^\"\x27]+)[\"\x27];',content)
            raw_imports=imports((REPO/relative_path).read_text(encoding='utf-8'))
            portable_imports=imports(source['content'])
            assert len(raw_imports)==len(portable_imports)
            for raw,portable in zip(raw_imports,portable_imports):previous=previous.replace(raw,portable)
            source['content']=previous
        prior_name=name
        if name=='WorkerGasSponsor':
            del old['sources'][unit];prior_name='GasSponsor';oldunit='source/Genesis/7702/GasSponsor.sol'
        else:oldunit=unit
        baseline=solcx.compile_standard(old,solc_version='0.8.37')['contracts'][oldunit][prior_name]
        before,after=shape(baseline['storageLayout']),shape(contract['storageLayout'])
        assert after[:len(before)]==before, name+' moved existing storage'
        if name=='WorkerGasSponsor':
            # ERC-7201 members are not in the ordinary storageLayout array.
            current=request['sources']['source/Genesis/7702/GasSponsor.sol']['content']
            previous=old['sources']['source/Genesis/7702/GasSponsor.sol']['content']
            for struct in ('SponsorState','GasSponsorStorage'):
                extract=lambda text:re.sub(r'\s+','',re.sub(r'//[^\n]*','',re.search(r'struct '+struct+r'\s*\{([^}]+)',text).group(1)))
                assert extract(current)==extract(previous)
        folder=REPO/'Contracts/Verification/20260915'/name;folder.mkdir(parents=True,exist_ok=True)
        artifact={'abi':contract['abi'],'creation_bytecode':'0x'+contract['evm']['bytecode']['object'],
            'runtime_bytecode':'0x'+runtime,'metadata':contract['metadata'],'storage_layout':contract['storageLayout'],
            'standard_json_input':request,'compiler':'0.8.37','evm':evm,'source':unit}
        for filename,data in [('artifact.json',artifact),('standard-input.json',request),('standard-output.json',result),
                              ('abi.json',contract['abi']),('storage-layout.json',contract['storageLayout']),
                              ('baseline.json',{'abi':baseline['abi'],'creation_bytecode':'0x'+baseline['evm']['bytecode']['object']})]:
            (folder/filename).write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8',newline='\n')
        (folder/'metadata.json').write_text(contract['metadata'],encoding='utf-8',newline='\n')
        report[name]={'evm':evm,'append_only_layout':True,'runtime_bytes':len(runtime)//2,
            'runtime_sha256':hashlib.sha256(bytes.fromhex(runtime)).hexdigest()}
    target=REPO/'Contracts/Verification/20260915/issuance-build.json'
    target.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report))
if __name__=='__main__':main()
