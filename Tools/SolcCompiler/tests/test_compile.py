"""Replay exported verification inputs with real solc, without network imports."""
import importlib.util
import json
from pathlib import Path

import pytest
import solcx

SCRIPT = Path(__file__).resolve().parents[1] / "compile.py"
spec = importlib.util.spec_from_file_location("dakota_compiler", SCRIPT)
compiler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compiler)


@pytest.fixture
def build(tmp_path, monkeypatch):
    installed = {str(item) for item in solcx.get_installed_solc_versions()}
    if not {compiler.VALIDATOR_SOLC_VERSION, compiler.DEFAULT_SOLC_VERSION}.issubset(installed):
        pytest.skip("Install the pinned validator and current compilers, or set SOLCX_BINARY_PATH to their directory")
    monkeypatch.setattr(compiler, "IMPORT_CACHE_DIR", tmp_path / "cache")
    return compiler


@pytest.mark.parametrize("relative,name,evm,private", [
    ("Genesis/validatorContracts/ValidatorSmartContractAllowList.sol", "ValidatorSmartContractAllowList", "london", False),
    ("Genesis/7702/GasSponsor.sol", "GasSponsor", "osaka", False),
    ("CodeManagement/PrivateComboStorage.sol", "PrivateComboStorage", "shanghai", False),
    ("CodeManagement/PrivateMetaTxRelay.sol", "PrivateMetaTxRelay", "shanghai", False),
    ("Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol", "TransparentUpgradeableProxy", "shanghai", True),
])
def test_export_reproduces_all_bytecode_without_source_callbacks(build, tmp_path, relative, name, evm, private):
    results = build.compile_contract(str(build.CONTRACTS_DIR / relative), private=private)
    assert results[name]["evm_version"] == evm
    for contract, artifact in results.items():
        output = build.get_contract_output_dir(tmp_path / "output", artifact["source_rel_path"], contract, evm)
        build.save_results({contract: artifact}, str(output), quiet=True)
        standard = json.loads((output / f"{contract}_standard_input.json").read_text(encoding="utf-8"))
        assert all("content" in source and "urls" not in source for source in standard["sources"].values())
        assert all(not Path(key).is_absolute() and "\\" not in key for key in standard["sources"])
        for key, entry in standard["sources"].items():
            assert entry["content"].encode("utf-8") == (build.IMPORT_CACHE_DIR / key).read_bytes()
        assert (output / f"{contract}_metadata.json").read_bytes() == artifact["metadata"].encode("utf-8")
        result = solcx.compile_standard(standard, solc_version=artifact["compiler_version"])
        source, target = artifact["fully_qualified_name"].rsplit(":", 1)
        actual = result["contracts"][source][target]
        assert actual["evm"]["bytecode"]["object"] == artifact["creation_bytecode"].removeprefix("0x")
        assert actual["evm"]["deployedBytecode"]["object"] == artifact["runtime_bytecode"].removeprefix("0x")
        assert actual["abi"] == artifact["abi"]
        assert actual["metadata"] == artifact["metadata"]


def test_validator_settings_are_preserved_under_global_overrides():
    validator = compiler.CONTRACTS_DIR / "Genesis/validatorContracts/ValidatorSmartContractAllowList.sol"
    assert compiler.contract_compile_settings(validator, "0.8.34", "osaka", "shanghai", True) == ("0.8.19", "london")


def test_unsupported_private_runtime_target_is_rejected():
    private = compiler.CONTRACTS_DIR / "CodeManagement/PrivateComboStorage.sol"
    with pytest.raises(ValueError, match="Pente"):
        compiler.contract_compile_settings(private, "0.8.34", "osaka", "osaka")


def test_public_and_private_proxy_exports_have_separate_directories(tmp_path):
    source = "Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol"
    assert compiler.get_contract_output_dir(tmp_path, source, "Proxy", "osaka") != compiler.get_contract_output_dir(tmp_path, source, "Proxy", "shanghai")


def test_deep_dependency_verification_files_can_be_exported(tmp_path):
    source = "External/OpenZeppelin/openzeppelin-contracts/v5.2.0/contracts/proxy/transparent/TransparentUpgradeableProxy.sol"
    name = "ITransparentUpgradeableProxy"
    output = compiler.get_contract_output_dir(tmp_path / ("review-" + "x" * 80), source, name)
    artifact = {"runtime_bytecode": "", "creation_bytecode": "", "abi": [],
                "standard_json_input": {"language": "Solidity", "sources": {}, "settings": {}}}
    compiler.save_results({name: artifact}, str(output), quiet=True)
    assert json.loads((output / f"{name}_standard_input.json").read_text()) == artifact["standard_json_input"]
