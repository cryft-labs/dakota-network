"""Build pinned Pente infrastructure and reviewed application contracts; maintain artifact-lock.json.

Writes self-contained Standard JSON, metadata and an artifact for every deployment target under --out.
Upstream Pente sources come from the Paladin v1.0.0 checkout pinned at commit 6d4b9134 (--upstream).

    python Tools/Paladin/build.py --upstream ~/Cryft/tools/paladin-v1.0.0 --out ~/Cryft/codex-outputs/paladin-113211
    python Tools/Paladin/build.py --repo-only --out ...   # only the contracts whose source is in this repo
"""
import argparse, hashlib, importlib.util, json, posixpath, re, subprocess
from pathlib import Path
import solcx, requests

REPO = Path(__file__).resolve().parents[2]

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--upstream', default=str(Path.home()/'Cryft/tools/paladin-v1.0.0'))
    p.add_argument('--out', default=str(Path.home()/'Cryft/codex-outputs/paladin-113211'))
    # --repo-only (fresh chain 113211): rebuild only the contracts whose source is in this repo, without the
    # upstream Paladin checkout, and REPLACE their lock entries (nothing of the old chain is deployed any more).
    # The upstream Pente entries (PenteFactory, PentePrivacyGroup, ERC1967Proxy) keep their lock entries.
    p.add_argument('--repo-only', action='store_true'); p.add_argument('--only', nargs='*', default=None)
    a = p.parse_args()
    root = Path(a.out).resolve(); checkout = Path(a.upstream).resolve(); upstream = checkout/'solidity'
    def git(*args): return subprocess.check_output(['git','-c','safe.directory='+checkout.as_posix(),'-C',str(checkout),*args],text=True).strip()
    if not a.repo_only:
        assert git('rev-parse','HEAD')=='6d4b91343426d17d713a0d61dfbcb2e262cb346d'
        assert not git('status','--porcelain'), 'Upstream sources must be pristine'
    out = root/'artifacts'; out.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('compiler', REPO/'Tools/SolcCompiler/compile.py')
    compiler = importlib.util.module_from_spec(spec); spec.loader.exec_module(compiler)
    inputs = {}
    for file, evm, names in [
        ('CodeManagement/PrivateComboStorage.sol', 'shanghai', ['PrivateComboStorage']),
        ('Tokens/GreetingCards.sol', 'osaka', ['CryftGreetingCards']),
        ('Paladin/DeliveryFailureProbe.sol', 'osaka', ['DeliveryFailureProbe']),
        ('Paladin/ManagedProxyAdmin.sol', 'shanghai', ['ManagedProxyAdmin','ManagedApplicationProxy']),
    ]:
        if a.only is not None and not set(names) & set(a.only): continue
        result = compiler.compile_contract(REPO/'Contracts'/file, solc_version='0.8.37', evm_version=evm)
        for name in names:
            assert name in result, (name, list(result))
            inputs[name] = result[name]['standard_json_input']
    sources = {}
    def resolve(name):
        if name in sources: return
        if name.startswith('@openzeppelin/'):
            package, tail = name[len('@openzeppelin/'):].split('/', 1)
            url = 'https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-'+package+'/v5.4.0/contracts/'+tail
            cache=root/'pente-dependencies'/package/tail
            if not cache.exists():
                response=requests.get(url,timeout=30); response.raise_for_status()
                cache.parent.mkdir(parents=True,exist_ok=True); cache.write_bytes(response.content)
            source=cache.read_text(encoding='utf-8')
        else:
            path = (upstream/name).resolve(); assert path.is_relative_to(upstream.resolve())
            source = path.read_text(encoding='utf-8')
        sources[name] = {'content': source}
        for dependency in re.findall(r'import\s+(?:[^;]*?from\s+)?["\']([^"\']+)["\']\s*;', source):
            resolve(posixpath.normpath(posixpath.join(posixpath.dirname(name), dependency)) if dependency.startswith('.') else dependency)
    if not a.repo_only: resolve('contracts/domains/pente/PenteFactory.sol')
    upstream_input = {'language':'Solidity','sources':sources,'settings':{'optimizer':{'enabled':True,'runs':200},'viaIR':True,'evmVersion':'osaka','metadata':{'bytecodeHash':'ipfs'}}}
    if not a.repo_only:
        for name in ['PenteFactory','PentePrivacyGroup','ERC1967Proxy']: inputs[name] = upstream_input
    lockpath = Path(__file__).with_name('artifact-lock.json')
    lock = json.loads(lockpath.read_text()) if lockpath.exists() else {}
    # Old-chain upgrade aliases; CodeManager 3.1 at 0x…c0DE already carries recordRedemptionStrict.
    for retired in ('CodeManagerStrict', 'PrivateComboStorageStrict'): lock.pop(retired, None)
    for name, standard in inputs.items():
        standard = json.loads(json.dumps(standard))
        standard['settings']['outputSelection'] = {'*':{'*':['abi','metadata','storageLayout','evm.bytecode','evm.deployedBytecode']}}
        result = solcx.compile_standard(standard, solc_version='0.8.37')
        matches = [(unit, contracts[name]) for unit, contracts in result['contracts'].items() if name in contracts]
        assert len(matches)==1, name
        unit, compiled = matches[0]; evm = compiled['evm']; runtime = evm['deployedBytecode']['object']
        assert len(runtime)//2 <= (24576 if standard['settings']['evmVersion']=='shanghai' else 32768), name
        artifact = {'abi':compiled['abi'],'creation_bytecode':'0x'+evm['bytecode']['object'],'runtime_bytecode':'0x'+runtime,
                    'metadata':compiled['metadata'],'standard_json_input':standard,'source':unit,'compiler':'0.8.37','evm':standard['settings']['evmVersion'],
                    'storage_layout':compiled['storageLayout']}
        target=out/name; target.mkdir(exist_ok=True)
        blob=(json.dumps(artifact,indent=2)+'\n').encode()
        if name in lock and not a.repo_only:
            assert hashlib.sha256(blob).hexdigest()==lock[name]['artifact_sha256'], 'Preserve historical artifact aliases; use build-strict.py or the recorded original source commit: '+name
        if (target/'artifact.json').exists() and not a.repo_only:
            assert (target/'artifact.json').read_bytes()==blob, 'Use a versioned artifact alias for changed deployed contracts: '+name
        (target/'artifact.json').write_bytes(blob)
        (target/'standard-input.json').write_text(json.dumps(standard,indent=2)+'\n',encoding='utf-8')
        (target/'standard-output.json').write_text(json.dumps(result)+'\n',encoding='utf-8')
        (target/'metadata.json').write_text(compiled['metadata'],encoding='utf-8')
        lock[name]={'artifact_sha256':hashlib.sha256(blob).hexdigest(),'runtime_bytes':len(runtime)//2,
                    'immutable_references':evm['deployedBytecode'].get('immutableReferences',{}),'evm':artifact['evm'],'compiler':artifact['compiler']}
        print(name, len(runtime)//2, artifact['evm'], flush=True)
    lockpath.write_bytes((json.dumps(lock,indent=2)+'\n').encode())

if __name__=='__main__': main()
