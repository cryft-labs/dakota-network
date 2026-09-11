"""Prevent proxy/implementation license confusion and wrong-state uploads."""
import hashlib,json,shutil
import pytest
import upload

def test_all_public_creation_requests_use_compilation_target_license():
    manifest=json.loads((upload.ROOT/'manifest.json').read_text())
    for row in manifest['public_creations']['contracts']:
        plan,build=upload.request_plan(row['address'])
        assert plan['license_type']==build['license_type']==row['license_type']
        assert plan['constructor_args']==row['constructor_arguments']
        assert plan['contract_name']==build['contract_name']

def test_genesis_proxy_keeps_mit_while_implementation_is_apache():
    proxy,_=upload.request_plan('0x000000000000000000000000000000000000c0de')
    implementation,_=upload.request_plan('0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424')
    assert (proxy['license_type'],proxy['license_type_id'])==('mit',3)
    assert (implementation['license_type'],implementation['license_type_id'])==('apache_2_0',12)
    assert proxy['genesis_runtime_only'] and proxy['constructor_args']==''

@pytest.mark.parametrize('address',['0x0000000000000000000000000000000000000001','0x7a3eacca11e28712ed6e0dfc464795b2a0c2a342','0x991acc255761dEE0421Ccd3F436788C24425122E'])
def test_non_public_solidity_addresses_are_excluded(address):
    with pytest.raises(ValueError,match='not an audited public Solidity'):upload.request_plan(address)

def test_unknown_license_has_no_default(tmp_path,monkeypatch):
    manifest=json.loads((upload.ROOT/'manifest.json').read_text());row=next(r for r in manifest['public_creations']['contracts'] if r['artifact_alias']=='CodeManagerStrict')
    build=manifest['builds']['CodeManagerStrict'];shutil.copytree(upload.ROOT/'CodeManagerStrict',tmp_path/'CodeManagerStrict')
    path=tmp_path/build['files']['metadata.json']['path'];meta=json.loads(path.read_text());meta['sources'][build['source_path']]['license']='LicenseRef-NeedsReview'
    path.write_text(json.dumps(meta));build['files']['metadata.json']['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
    (tmp_path/'manifest.json').write_text(json.dumps(manifest));monkeypatch.setattr(upload,'ROOT',tmp_path)
    with pytest.raises(ValueError,match='Unsupported license'):upload.request_plan(row['address'])

@pytest.mark.parametrize('field,value',[('license_type','mit'),('name','CodeManagerStrict'),('file_path','wrong.sol'),('compiler_version','0.8.19')])
def test_existing_verification_must_match_all_target_fields(field,value):
    plan,_=upload.request_plan('0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424')
    data={'name':plan['contract_name'],'file_path':plan['source_path'],'compiler_version':plan['compiler_version'],'license_type':plan['license_type']}
    upload.validate_verified_target(data,plan)
    data[field]=value
    with pytest.raises(AssertionError):upload.validate_verified_target(data,plan)
