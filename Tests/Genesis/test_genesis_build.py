"""The committed genesis is reproducible and decodes back to its inputs (audit X-7)."""
import json
import subprocess
import sys
from pathlib import Path

import pytest
from eth_tester import EthereumTester, PyEVMBackend
from web3 import EthereumTesterProvider, Web3

REPO = Path(__file__).resolve().parents[2]
GENESIS = json.loads((REPO / "Contracts/Genesis/CryftGenesis.json").read_text())
MANIFEST = json.loads((REPO / "Contracts/Genesis/genesis-release.json").read_text())
INPUTS = json.loads((REPO / "Tools/Genesis/inputs.json").read_text())
VALIDATORS = [v["address"] for v in json.loads((REPO / "Tools/Genesis/validators.json").read_text())["validators"]]
REGISTRY = Web3.to_checksum_address("0x" + "0" * 36 + "1111")


def test_build_is_reproducible():
    out = subprocess.run([sys.executable, str(REPO / "Tools/Genesis/build.py"), "--check"], capture_output=True, text=True)
    assert out.returncode == 0, out.stdout + out.stderr


def test_chain_config():
    c = GENESIS["config"]
    assert c["chainId"] == 113211 == MANIFEST["chainId"] and MANIFEST["chainIdHex"] == "0x1ba3b"
    assert c["contractSizeLimit"] == 32768
    assert GENESIS["gasLimit"] == "0x3D09000"  # 64,000,000
    q = c["qbft"]
    assert (q["blockPeriodSeconds"], q["emptyBlockPeriodSeconds"], q["requestTimeoutSeconds"], q["epochLength"]) == (1, 64, 86, 86000)
    assert q["validatorContractAddress"].lower() == REGISTRY.lower()
    assert all(c[f] == 0 for f in INPUTS["forks"] + INPUTS["timeForks"])


def test_alloc_is_minimal():
    alloc = {k.lower(): v for k, v in GENESIS["alloc"].items()}
    eoas = [a for a, v in alloc.items() if "code" not in v]
    assert sorted(eoas) == sorted(a.lower() for a in INPUTS["balances"])
    assert "0x991acc255761dee0421ccd3f436788c24425122e" not in alloc  # the old test account
    proxies = [a for a, v in alloc.items() if v.get("comment", "").startswith("Cryft genesis proxy")]
    assert len(proxies) == 5 and len({alloc[a]["code"] for a in proxies}) == 1
    assert "0x0000f90827f1c53a10cb7a02335b175320002935" in alloc  # EIP-2935


def chain():
    state = PyEVMBackend.generate_genesis_state(num_accounts=1)
    for address, entry in GENESIS["alloc"].items():
        state[bytes.fromhex(address[2:])] = {
            "balance": int(entry["balance"], 16), "nonce": int(entry.get("nonce", "0x0"), 16),
            "code": bytes.fromhex(entry.get("code", "0x")[2:]),
            "storage": {int(k, 16): int(v, 16) for k, v in entry.get("storage", {}).items()}}
    w3 = Web3(EthereumTesterProvider(EthereumTester(backend=PyEVMBackend(genesis_state=state))))
    abi = json.loads(subprocess.run([sys.executable, "-c", (
        "import sys,json;sys.path.insert(0,'Tools/Genesis');import build;"
        "u=build.compile_unit(build.VALIDATOR_SRC,'ValidatorSmartContractAllowList',"
        "{'version':'0.8.19','evm':'london','runs':200});print(json.dumps(u['abi']))")],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.splitlines()[-1])
    return w3.eth.contract(REGISTRY, abi=abi)


@pytest.fixture(scope="module")
def registry():
    return chain()


def test_decode_back(registry):
    g = INPUTS["governance"]
    assert registry.functions.getValidators().call() == VALIDATORS == MANIFEST["validators"]
    assert registry.functions.getVoters().call() == g["voters"]
    assert registry.functions.getRootOverlords().call() == g["roots"]
    assert registry.functions.maxValidators().call() == g["maxValidators"]
    assert registry.functions.voteTallyBlockThreshold().call() == g["voteWindowSeconds"]
    assert registry.functions.getUpgradeDelay().call() == g["upgradeDelaySeconds"]
    assert "initialize" not in [f.get("name") for f in registry.abi]
