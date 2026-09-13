"""Local ERC-6551 registry and MomentCardAccount tests. No live RPC or keys."""
from pathlib import Path
import importlib.util
import json

import pytest
from eth_abi import encode
from eth_account import Account
from eth_tester import EthereumTester, PyEVMBackend
from eth_tester.exceptions import TransactionFailed
from web3 import Web3, EthereumTesterProvider
import solcx

REPO = Path(__file__).resolve().parents[2]
APP_SALT_PREIMAGE = "moment.cards:tba:v1"
ERC1167_HEADER = bytes.fromhex("3d60ad80600a3d3981f3363d3d373d3d3d363d73")
ERC1167_FOOTER = bytes.fromhex("5af43d82803e903d91602b57fd5bf3")
MOCK_SOURCE = r'''
pragma solidity ^0.8.20;

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}
interface IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external returns (bytes4);
}

contract MockCard {
    mapping(uint256 => address) private _owners;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        require(to != address(0) && _owners[id] == address(0));
        _owners[id] = to;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address current = _owners[id];
        require(current != address(0), "nonexistent");
        return current;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(_owners[id] == from, "owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "auth");
        require(to != address(0), "to");
        _owners[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, data) == 0x150b7a02,
                "receiver"
            );
        }
    }

    function burn(uint256 id) external {
        require(_owners[id] == msg.sender, "owner");
        delete _owners[id];
    }
}

contract MockTrait {
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[id][to] += amount;
        if (to.code.length > 0) {
            require(
                IERC1155Receiver(to).onERC1155Received(msg.sender, address(0), id, amount, "") == 0xf23a6e61,
                "receiver"
            );
        }
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts) external {
        for (uint256 i; i < ids.length; ++i) {
            balanceOf[ids[i]][to] += amounts[i];
        }
        if (to.code.length > 0) {
            require(
                IERC1155Receiver(to).onERC1155BatchReceived(msg.sender, address(0), ids, amounts, "") == 0xbc197c81,
                "receiver"
            );
        }
    }
}

contract Sink {
    uint256 public value;
    function set(uint256 next) external payable {
        value = next;
    }
    function fail() external pure {
        revert("sink");
    }
}

contract OtherNft {
    mapping(uint256 => address) public ownerOf;
    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from);
        ownerOf[id] = to;
        if (to.code.length > 0) {
            require(IERC721Receiver(to).onERC721Received(msg.sender, from, id, "") == 0x150b7a02);
        }
    }
}
'''


@pytest.fixture(scope="session")
def builds(tmp_path_factory):
    spec = importlib.util.spec_from_file_location(
        "tba_compiler", REPO / "Tools/SolcCompiler/compile.py"
    )
    compiler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compiler)
    installed = {str(item) for item in solcx.get_installed_solc_versions()}
    if compiler.DEFAULT_SOLC_VERSION not in installed:
        pytest.skip(
            "Install solc 0.8.37 or set SOLCX_BINARY_PATH to its directory"
        )
    output = {}
    for relative, name in (
        ("Accounts/ERC6551Registry.sol", "ERC6551Registry"),
        ("Accounts/MomentCardAccount.sol", "MomentCardAccount"),
    ):
        contracts = compiler.compile_contract(
            REPO / "Contracts" / relative,
            solc_version=compiler.DEFAULT_SOLC_VERSION,
            evm_version="osaka",
        )
        output[name] = next(
            value for key, value in contracts.items() if key.rsplit(":", 1)[-1] == name
        )
        output[name]["runtime_keccak256"] = "0x" + Web3.keccak(
            hexstr=output[name]["runtime_bytecode"]
        ).hex().removeprefix("0x")
    compiled = solcx.compile_source(
        MOCK_SOURCE,
        solc_version=compiler.DEFAULT_SOLC_VERSION,
        evm_version="osaka",
        output_values=["abi", "bin", "bin-runtime"],
    )
    for key, artifact in compiled.items():
        output[key.split(":")[-1]] = {
            "abi": artifact["abi"],
            "creation_bytecode": "0x" + artifact["bin"],
            "runtime_bytecode": "0x" + artifact["bin-runtime"],
        }
    evidence = tmp_path_factory.getbasetemp() / "tba-runtime.json"
    evidence.write_text(
        json.dumps(
            {
                name: {
                    "runtime_bytes": len(
                        bytes.fromhex(a["runtime_bytecode"].removeprefix("0x"))
                    ),
                    "runtime_keccak256": "0x"
                    + Web3.keccak(hexstr=a["runtime_bytecode"]).hex().removeprefix("0x"),
                }
                for name, a in output.items()
                if a.get("runtime_bytecode")
            },
            indent=2,
        )
    )
    return output


def tx(chain, function, sender=None, value=0):
    w3 = chain["w3"]
    receipt = w3.eth.wait_for_transaction_receipt(
        function.transact(
            {"from": sender or chain["accounts"][0], "gas": 8_000_000, "value": value}
        )
    )
    assert receipt.status == 1, "Transaction reverted"
    return receipt


def fails(chain, function, sender=None, value=0):
    with pytest.raises((TransactionFailed, ValueError)):
        function.call(
            {"from": sender or chain["accounts"][0], "gas": 8_000_000, "value": value}
        )


def deploy(chain, name, *args):
    artifact = chain["builds"][name]
    factory = chain["w3"].eth.contract(
        abi=artifact["abi"], bytecode=artifact["creation_bytecode"]
    )
    receipt = tx(chain, factory.constructor(*args))
    return chain["w3"].eth.contract(address=receipt.contractAddress, abi=artifact["abi"])


def pad_address(address):
    return bytes.fromhex(address.removeprefix("0x").zfill(40)).rjust(32, b"\x00")


def account_init_code(implementation, salt, chain_id, token_contract, token_id):
    init = (
        ERC1167_HEADER
        + bytes.fromhex(implementation.removeprefix("0x").zfill(40))
        + ERC1167_FOOTER
        + salt
        + chain_id.to_bytes(32, "big")
        + pad_address(token_contract)
        + token_id.to_bytes(32, "big")
    )
    assert len(init) == 0xB7
    return init


def derive_account(registry, implementation, salt, chain_id, token_contract, token_id):
    init = account_init_code(implementation, salt, chain_id, token_contract, token_id)
    digest = Web3.keccak(
        b"\xff"
        + bytes.fromhex(registry.removeprefix("0x").zfill(40))
        + salt
        + Web3.keccak(init)
    )
    return Web3.to_checksum_address(digest[-20:])


def private_key_for(chain, address):
    target = Web3.to_checksum_address(address)
    for key in chain["tester"].backend.account_keys:
        if Web3.to_checksum_address(key.public_key.to_checksum_address()) == target:
            return key.to_bytes()
    raise AssertionError(f"no private key for {address}")


def sign_execute(chain, account, owner, to, value, data, operation, nonce, deadline):
    domain_typehash = Web3.keccak(
        text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    )
    name_hash = Web3.keccak(text="MomentCardAccount")
    version_hash = Web3.keccak(text="1")
    execute_typehash = Web3.keccak(
        text="Execute(address to,uint256 value,bytes data,uint8 operation,uint256 nonce,uint256 deadline)"
    )
    domain = Web3.keccak(
        encode(
            ["bytes32", "bytes32", "bytes32", "uint256", "address"],
            [
                domain_typehash,
                name_hash,
                version_hash,
                chain["w3"].eth.chain_id,
                account.address,
            ],
        )
    )
    struct_hash = Web3.keccak(
        encode(
            ["bytes32", "address", "uint256", "bytes32", "uint8", "uint256", "uint256"],
            [execute_typehash, to, value, Web3.keccak(data), operation, nonce, deadline],
        )
    )
    digest = Web3.keccak(b"\x19\x01" + domain + struct_hash)
    on_chain = account.functions.getExecuteDigest(
        to, value, data, operation, nonce, deadline
    ).call()
    assert digest == on_chain
    signed = Account.unsafe_sign_hash(digest, private_key_for(chain, owner))
    return signed.signature


@pytest.fixture
def chain(builds):
    tester = EthereumTester(
        backend=PyEVMBackend(genesis_parameters={"gas_limit": 64_000_000})
    )
    w3 = Web3(EthereumTesterProvider(tester))
    return {"w3": w3, "tester": tester, "accounts": w3.eth.accounts, "builds": builds}


@pytest.fixture
def world(chain):
    registry = deploy(chain, "ERC6551Registry")
    implementation = deploy(chain, "MomentCardAccount")
    cards = deploy(chain, "MockCard")
    traits = deploy(chain, "MockTrait")
    other = deploy(chain, "OtherNft")
    sink = deploy(chain, "Sink")
    salt = Web3.keccak(text=APP_SALT_PREIMAGE)
    owner = chain["accounts"][0]
    other_owner = chain["accounts"][1]
    token_id = 6
    tx(chain, cards.functions.mint(owner, token_id))
    predicted = derive_account(
        registry.address,
        implementation.address,
        salt,
        chain["w3"].eth.chain_id,
        cards.address,
        token_id,
    )
    return {
        "registry": registry,
        "implementation": implementation,
        "cards": cards,
        "traits": traits,
        "other": other,
        "sink": sink,
        "salt": salt,
        "owner": owner,
        "other_owner": other_owner,
        "token_id": token_id,
        "predicted": predicted,
    }


def create_tba(chain, world):
    receipt = tx(
        chain,
        world["registry"].functions.createAccount(
            world["implementation"].address,
            world["salt"],
            chain["w3"].eth.chain_id,
            world["cards"].address,
            world["token_id"],
        ),
    )
    account = chain["w3"].eth.contract(
        address=world["predicted"], abi=chain["builds"]["MomentCardAccount"]["abi"]
    )
    return account, receipt


def test_application_salt_is_documented_constant(chain, world):
    salt = world["implementation"].functions.APPLICATION_SALT().call()
    assert salt == Web3.keccak(text=APP_SALT_PREIMAGE)
    assert salt == world["salt"]


def test_account_address_matches_create2_derivation(chain, world):
    on_chain = world["registry"].functions.account(
        world["implementation"].address,
        world["salt"],
        chain["w3"].eth.chain_id,
        world["cards"].address,
        world["token_id"],
    ).call()
    assert on_chain == world["predicted"]
    account, receipt = create_tba(chain, world)
    assert account.address == world["predicted"]
    created = next(
        log
        for log in world["registry"].events.ERC6551AccountCreated().process_receipt(receipt)
    )
    assert created["args"]["account"] == world["predicted"]
    assert created["args"]["implementation"] == world["implementation"].address
    assert created["args"]["salt"] == world["salt"]
    assert created["args"]["tokenContract"] == world["cards"].address
    assert created["args"]["tokenId"] == world["token_id"]


def test_create_account_is_idempotent(chain, world):
    first, _ = create_tba(chain, world)
    second = world["registry"].functions.createAccount(
        world["implementation"].address,
        world["salt"],
        chain["w3"].eth.chain_id,
        world["cards"].address,
        world["token_id"],
    ).call()
    assert second == first.address
    tx(
        chain,
        world["registry"].functions.createAccount(
            world["implementation"].address,
            world["salt"],
            chain["w3"].eth.chain_id,
            world["cards"].address,
            world["token_id"],
        ),
    )


def test_different_implementation_derives_a_different_account(chain, world):
    other_impl = deploy(chain, "MomentCardAccount")
    other = world["registry"].functions.account(
        other_impl.address,
        world["salt"],
        chain["w3"].eth.chain_id,
        world["cards"].address,
        world["token_id"],
    ).call()
    assert other != world["predicted"]


def test_token_and_owner_follow_parent_nft(chain, world):
    account, _ = create_tba(chain, world)
    chain_id, token_contract, token_id = account.functions.token().call()
    assert chain_id == chain["w3"].eth.chain_id
    assert token_contract == world["cards"].address
    assert token_id == world["token_id"]
    assert account.functions.owner().call() == world["owner"]
    tx(
        chain,
        world["cards"].functions.transferFrom(
            world["owner"], world["other_owner"], world["token_id"]
        ),
        world["owner"],
    )
    assert account.functions.owner().call() == world["other_owner"]


def test_previous_owner_cannot_execute_after_transfer(chain, world):
    account, _ = create_tba(chain, world)
    data = bytes.fromhex(world["sink"].functions.set(7)._encode_transaction_data()[2:])
    tx(
        chain,
        account.functions.execute(world["sink"].address, 0, data, 0),
        world["owner"],
    )
    assert world["sink"].functions.value().call() == 7
    tx(
        chain,
        world["cards"].functions.transferFrom(
            world["owner"], world["other_owner"], world["token_id"]
        ),
        world["owner"],
    )
    fails(
        chain,
        account.functions.execute(world["sink"].address, 0, data, 0),
        world["owner"],
    )
    tx(
        chain,
        account.functions.execute(world["sink"].address, 0, data, 0),
        world["other_owner"],
    )
    assert account.functions.state().call() == 2


def test_execute_is_replay_protected_and_rejects_delegatecall(chain, world):
    account, _ = create_tba(chain, world)
    data = bytes.fromhex(world["sink"].functions.set(1)._encode_transaction_data()[2:])
    fails(chain, account.functions.execute(world["sink"].address, 0, data, 1), world["owner"])
    tx(chain, account.functions.execute(world["sink"].address, 0, data, 0), world["owner"])
    assert account.functions.state().call() == 1


def test_signed_execute_enforces_expiry_and_nonce(chain, world):
    account, _ = create_tba(chain, world)
    relayer = chain["accounts"][2]
    data = bytes.fromhex(world["sink"].functions.set(99)._encode_transaction_data()[2:])
    now = chain["w3"].eth.get_block("latest")["timestamp"]
    deadline = now + 3600
    signature = sign_execute(
        chain, account, world["owner"], world["sink"].address, 0, data, 0, 0, deadline
    )
    tx(
        chain,
        account.functions.executeSigned(
            world["sink"].address, 0, data, 0, 0, deadline, signature
        ),
        relayer,
    )
    assert world["sink"].functions.value().call() == 99
    fails(
        chain,
        account.functions.executeSigned(
            world["sink"].address, 0, data, 0, 0, deadline, signature
        ),
        relayer,
    )
    expired_sig = sign_execute(
        chain, account, world["owner"], world["sink"].address, 0, data, 0, 1, now - 1
    )
    fails(
        chain,
        account.functions.executeSigned(
            world["sink"].address, 0, data, 0, 1, now - 1, expired_sig
        ),
        relayer,
    )


def test_previous_owner_signature_cannot_execute(chain, world):
    account, _ = create_tba(chain, world)
    data = bytes.fromhex(world["sink"].functions.set(3)._encode_transaction_data()[2:])
    now = chain["w3"].eth.get_block("latest")["timestamp"]
    deadline = now + 3600
    signature = sign_execute(
        chain, account, world["owner"], world["sink"].address, 0, data, 0, 0, deadline
    )
    tx(
        chain,
        world["cards"].functions.transferFrom(
            world["owner"], world["other_owner"], world["token_id"]
        ),
        world["owner"],
    )
    fails(
        chain,
        account.functions.executeSigned(
            world["sink"].address, 0, data, 0, 0, deadline, signature
        ),
        chain["accounts"][2],
    )


def test_receives_erc721_from_other_collection_and_erc1155_traits(chain, world):
    account, _ = create_tba(chain, world)
    tx(chain, world["other"].functions.mint(world["owner"], 1))
    tx(
        chain,
        world["other"].functions.safeTransferFrom(world["owner"], account.address, 1),
        world["owner"],
    )
    assert world["other"].functions.ownerOf(1).call() == account.address
    tx(chain, world["traits"].functions.mint(account.address, 7, 2))
    assert world["traits"].functions.balanceOf(7, account.address).call() == 2
    tx(
        chain,
        world["traits"].functions.mintBatch(account.address, [8, 9], [1, 3]),
    )
    assert world["traits"].functions.balanceOf(8, account.address).call() == 1
    assert world["traits"].functions.balanceOf(9, account.address).call() == 3


def test_nested_card_nft_is_rejected(chain, world):
    account, _ = create_tba(chain, world)
    sibling = 7
    tx(chain, world["cards"].functions.mint(world["owner"], sibling))
    fails(
        chain,
        world["cards"].functions.safeTransferFrom(
            world["owner"], account.address, sibling
        ),
        world["owner"],
    )
    tx(
        chain,
        world["cards"].functions.setApprovalForAll(account.address, True),
        world["owner"],
    )
    data = bytes.fromhex(
        world["cards"]
        .functions.transferFrom(world["owner"], account.address, world["token_id"])
        ._encode_transaction_data()[2:]
    )
    fails(
        chain,
        account.functions.execute(world["cards"].address, 0, data, 0),
        world["owner"],
    )
    assert world["cards"].functions.ownerOf(world["token_id"]).call() == world["owner"]


def test_burned_parent_locks_execute(chain, world):
    account, _ = create_tba(chain, world)
    tx(chain, world["cards"].functions.burn(world["token_id"]), world["owner"])
    data = bytes.fromhex(world["sink"].functions.set(1)._encode_transaction_data()[2:])
    fails(
        chain,
        account.functions.execute(world["sink"].address, 0, data, 0),
        world["owner"],
    )


def test_direct_implementation_calls_are_rejected(chain, world):
    impl = world["implementation"]
    fails(chain, impl.functions.token())
    fails(chain, impl.functions.owner())
    data = b""
    fails(chain, impl.functions.execute(world["sink"].address, 0, data, 0), world["owner"])


def test_supports_required_interfaces(chain, world):
    account, _ = create_tba(chain, world)
    assert account.functions.supportsInterface("0x01ffc9a7").call()
    assert account.functions.supportsInterface("0x6faff5f1").call()
    assert account.functions.supportsInterface("0x51945447").call()
    assert account.functions.supportsInterface("0x1626ba7e").call()
    assert account.functions.supportsInterface("0x150b7a02").call()
    assert account.functions.supportsInterface("0x4e2312e0").call()
    assert not account.functions.supportsInterface("0xffffffff").call()
