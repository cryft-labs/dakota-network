"""Reproduce the explicitly development-only live canary artifact."""
import argparse
import hashlib
import json
from pathlib import Path
import solcx

def write(path, value):
    path.write_bytes((json.dumps(value, indent=2, sort_keys=True) + '\n').encode())

def prepare(workspace):
    folder = Path(__file__).resolve().parent
    source = (folder / 'GenesisCanary.sol').read_text()
    inp = {'language': 'Solidity', 'sources': {'GenesisCanary.sol': {'content': source}}, 'settings': {
        'evmVersion': 'osaka', 'optimizer': {'enabled': True, 'runs': 200},
        'metadata': {'bytecodeHash': 'ipfs', 'useLiteralContent': True},
        'outputSelection': {'*': {'*': ['abi', 'metadata', 'storageLayout', 'evm.bytecode', 'evm.deployedBytecode']}}}}
    result = solcx.compile_standard(inp, solc_version='0.8.37')
    contract = result['contracts']['GenesisCanary.sol']['GenesisCanary']
    artifact = {'abi': contract['abi'], 'creation_bytecode': contract['evm']['bytecode']['object'],
                'runtime_bytecode': contract['evm']['deployedBytecode']['object'], 'standard_json_input': inp,
                'metadata': json.loads(contract['metadata']), 'storage_layout': contract['storageLayout']}
    out = Path(workspace).resolve() / 'outputs/live-genesis-20260911/GenesisCanary'
    out.mkdir(exist_ok=True)
    write(out / 'artifact.json', artifact); write(out / 'standard-output.json', result)
    write(out / 'standard-input.json', inp)
    (out / 'metadata.json').write_bytes(contract['metadata'].encode())
    (out / 'GenesisCanary.sol').write_bytes(source.encode())
    lockfile = folder / 'artifact-lock.json'
    lock = json.loads(lockfile.read_text())
    lock['GenesisCanary'] = {'source': 'Tools/LiveGenesis/GenesisCanary.sol', 'development_only': True,
        'artifact_sha256': hashlib.sha256((out / 'artifact.json').read_bytes()).hexdigest(),
        'standard_input_sha256': hashlib.sha256((out / 'standard-input.json').read_bytes()).hexdigest(),
        'compiler': '0.8.37', 'evm': 'osaka', 'runtime_bytes': len(artifact['runtime_bytecode']) // 2,
        'immutable_references': contract['evm']['deployedBytecode']['immutableReferences'], 'reproduced_current_source': True}
    write(lockfile, lock)
    print('Prepared development canary: ' + str(lock['GenesisCanary']['runtime_bytes']) + ' runtime bytes')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--workspace', required=True)
    prepare(parser.parse_args().workspace)
