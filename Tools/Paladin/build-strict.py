"""Versioned artifacts for strict settlement; retain the original deployed builds."""
import argparse,hashlib,importlib.util,json,re
from pathlib import Path
import solcx

def shape(layout):
    def normalized(t):
        record=layout['types'][t]
        result={k:record[k] for k in ['label','encoding','numberOfBytes']}
        for k in ['base','key','value']:
            if k in record:result[k]=normalized(record[k])
        if 'members' in record:result['members']=[(m['label'],m['slot'],m['offset'],normalized(m['type'])) for m in record['members']]
        return result
    return [(x['label'],x['slot'],x['offset'],normalized(x['type'])) for x in layout['storage']]

def main():
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);a=p.parse_args();root=Path(a.workspace).resolve()
    repo=Path(__file__).resolve().parents[2];out=root/'outputs/paladin-live-20260911/artifacts'
    spec=importlib.util.spec_from_file_location('compiler',repo/'Tools/SolcCompiler/compile.py');compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(compiler)
    lockpath=Path(__file__).with_name('artifact-lock.json');lock=json.loads(lockpath.read_text())
    for name,alias,path,evm in [('CodeManager','CodeManagerStrict','CodeManagement/CodeManager.sol','osaka'),('PrivateComboStorage','PrivateComboStorageStrict','CodeManagement/PrivateComboStorage.sol','shanghai')]:
        build=compiler.compile_contract(repo/'Contracts'/path,solc_version='0.8.37',evm_version=evm)[name]
        standard=build['standard_json_input'];standard['settings']['outputSelection']={'*':{'*':['abi','metadata','storageLayout','evm.bytecode','evm.deployedBytecode']}}
        result=solcx.compile_standard(standard,solc_version='0.8.37');unit=build['fully_qualified_name'].rsplit(':',1)[0];compiled=result['contracts'][unit][name]
        if name=='CodeManager':
            old=json.loads((root/'outputs/live-genesis-20260911/CodeManager/artifact.json').read_text())['standard_json_input']
            old['settings']['outputSelection']={'*':{'*':['storageLayout']}}
            oldresult=solcx.compile_standard(old,solc_version='0.8.37');oldlayout=next(cs[name]['storageLayout'] for cs in oldresult['contracts'].values() if name in cs)
        else:oldlayout=json.loads((out/name/'artifact.json').read_text())['storage_layout']
        assert shape(oldlayout)==shape(compiled['storageLayout']),alias+': incompatible storage layout'
        runtime=compiled['evm']['deployedBytecode'];assert len(runtime['object'])//2 < (24576 if evm=='shanghai' else 32768)
        artifact={'abi':compiled['abi'],'creation_bytecode':'0x'+compiled['evm']['bytecode']['object'],'runtime_bytecode':'0x'+runtime['object'],
                  'metadata':compiled['metadata'],'standard_json_input':standard,'source':unit,'compiler':'0.8.37','evm':evm,'storage_layout':compiled['storageLayout']}
        target=out/alias;target.mkdir(exist_ok=True);blob=(json.dumps(artifact,indent=2)+'\n').encode();(target/'artifact.json').write_bytes(blob)
        for filename,body in [('standard-input.json',json.dumps(standard,indent=2)+'\n'),('standard-output.json',json.dumps(result)+'\n'),('metadata.json',compiled['metadata'])]:
            (target/filename).write_bytes(body.encode())
        lock[alias]={'artifact_sha256':hashlib.sha256(blob).hexdigest(),'runtime_bytes':len(runtime['object'])//2,'immutable_references':runtime.get('immutableReferences',{}),'evm':evm,'compiler':'0.8.37','storage_compatible_with':name}
        print(alias,'storage layout unchanged; bytes',lock[alias]['runtime_bytes'],flush=True)
    lockpath.write_bytes((json.dumps(lock,indent=2)+'\n').encode())

if __name__=='__main__':main()
