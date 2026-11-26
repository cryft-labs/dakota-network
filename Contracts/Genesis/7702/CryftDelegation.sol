// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {ICryftDelegation} from "./Interfaces/ICryftDelegation.sol";
import {DelegationGas} from "./DelegationGas.sol";
import {CryftDelegationCapabilities} from "./Libraries/CryftDelegationCapabilities.sol";
import {CryftECDSA} from "./Libraries/CryftECDSA.sol";

/// @title CryftDelegation
/// @notice Shared account logic for relayed, sponsored EIP-7702 execution.
/// @dev Route: user EOA -> immutable dispatcher -> shared beacon -> this implementation; the registry
///      0x…de1E6A7E controls the beacon. The EIP-712 domain binds every signature to the account itself: the
///      owner signature must recover to address(this), and executor, operation id, nonce, deadline, calls and
///      the execution gas limit are all signed. 1-32 calls per operation, 5,000,000 execution gas at most.
///      Direct calls to the implementation are refused; signatures are strict low-s (65-byte and EIP-2098);
///      the reentrancy lock is transient (EIP-1153). Only the nonce lives in the account's storage
///      (ERC-7201 namespace cryft.storage.CryftDelegation). Upgrades change the shared beacon implementation.
/// @custom:version 1.2.0
/// @custom:security-contact security@cryft.cards
contract CryftDelegation is ICryftDelegation {
    using CryftECDSA for bytes32;

    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @custom:storage-location erc7201:cryft.storage.CryftDelegation
    struct DelegationStorage {
        uint256 nonce;
    }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    uint256 private constant _MAX_CALLS = 32;
    uint256 private constant _MAX_EXECUTION_GAS_LIMIT = 5_000_000;
    uint256 private constant _MAX_RETURN_BYTES_PER_CALL = 4096;
    uint256 private constant _MAX_RETURN_BYTES_TOTAL = 16_384;

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;
    bytes4 private constant _ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;
    bytes4 private constant _ERC1155_RECEIVED = 0xf23a6e61;
    bytes4 private constant _ERC1155_BATCH_RECEIVED = 0xbc197c81;
    bytes4 private constant _ERC1155_RECEIVER_INTERFACE_ID = 0x4e2312e0;

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256("CryftDelegation");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant _EXECUTION_TYPEHASH = keccak256(
        "ExecuteSponsored(bytes32 operationId,address executor,bytes32 callsHash,uint256 nonce,uint256 deadline,uint256 executionGasLimit)"
    );

    bytes32 private constant _DELEGATION_STORAGE_LOCATION =
        0x2d5df833376e6c9531b3cb92f5745ecf8ad8197730684ec3db99cc12d4e93d00;
    /// @dev Transient (EIP-1153) reentrancy slot, keccak256("cryft.transient.CryftDelegation.reentrancy") - 1.
    ///      Transient storage clears at the end of every transaction, so no earlier or foreign 7702 delegate can
    ///      leave a value behind that blocks executeSponsored.
    bytes32 private constant _REENTRANCY_TSLOT =
        bytes32(uint256(keccak256("cryft.transient.CryftDelegation.reentrancy")) - 1);
    bytes32 private constant _DELEGATION_PROTOCOL_ID =
        keccak256("cryft.delegation.sponsored-execution.v1");

    address private immutable _IMPLEMENTATION;

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The implementation was called directly instead of through a delegated account.
    error DirectImplementationCall();

    /// @notice The operation id is zero.
    error EmptyOperationId();

    /// @notice The caller is not the signed executor, or the executor is zero.
    error InvalidExecutor();

    /// @notice The signed nonce is not the account's next nonce.
    error InvalidNonce(uint256 expected, uint256 supplied);

    /// @notice The signed deadline has passed.
    error Expired();

    /// @notice The owner signature does not recover to the account.
    error InvalidSignature();

    /// @notice The operation has no calls or more than the maximum.
    error InvalidCallCount();

    /// @notice A call targets address(0) or the account itself.
    error InvalidTarget(uint256 callIndex);

    /// @notice executeSponsored was entered again within the same transaction.
    error ReentrantExecution();

    /// @notice Too little gas is left to honour the signed execution gas limit, or that limit is out of range.
    error InsufficientExecutionGas(uint256 available, uint256 required);

    /// @notice The calls used more gas than the signed execution gas limit.
    error ExecutionGasBudgetExceeded(uint256 consumed, uint256 limit);

    /// @notice A call reverted without return data.
    error CallReverted(uint256 callIndex);

    /// @notice A call returned more data than allowed.
    error ReturnDataTooLarge(uint256 callIndex, uint256 size);

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    modifier onlyDelegated() {
        if (address(this) == _IMPLEMENTATION) revert DirectImplementationCall();
        _;
    }

    modifier nonReentrant() {
        bytes32 slot = _REENTRANCY_TSLOT;
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked != 0) revert ReentrantExecution();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor() {
        _IMPLEMENTATION = address(this);
    }

    // ─── receive / fallback ──────────────────────────────────────────────────────────────────────

    /// @notice Accepts native coin sent to a delegated account.
    receive() external payable {
        if (address(this) == _IMPLEMENTATION) revert DirectImplementationCall();
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc ICryftDelegation
    function executeSponsored(
        SponsoredExecutionRequest calldata execution,
        bytes calldata ownerSignature
    )
        external
        payable
        override
        onlyDelegated
        nonReentrant
        returns (bytes[] memory results)
    {
        if (execution.operationId == bytes32(0)) revert EmptyOperationId();
        if (execution.executor == address(0) || msg.sender != execution.executor) revert InvalidExecutor();
        if (block.timestamp > execution.deadline) revert Expired();

        uint256 callCount = execution.calls.length;
        if (callCount == 0 || callCount > _MAX_CALLS) revert InvalidCallCount();

        DelegationStorage storage state = _delegationStorage();
        if (execution.nonce != state.nonce) revert InvalidNonce(state.nonce, execution.nonce);

        bytes32 callsHash = _hashCalls(execution.calls);
        bytes32 digest = _executionDigest(
            execution.operationId,
            execution.executor,
            callsHash,
            execution.nonce,
            execution.deadline,
            execution.executionGasLimit
        );
        if (digest.tryRecover(ownerSignature) != address(this)) revert InvalidSignature();

        unchecked {
            state.nonce = execution.nonce + 1;
        }

        uint256 availableGas = gasleft();
        uint256 requiredGas = DelegationGas.executionReserve(execution.executionGasLimit);
        if (
            execution.executionGasLimit == 0 ||
            execution.executionGasLimit > _MAX_EXECUTION_GAS_LIMIT ||
            availableGas < requiredGas
        ) {
            revert InsufficientExecutionGas(availableGas, requiredGas);
        }

        results = _executeCalls(execution.operationId, execution.calls, execution.executionGasLimit);

        emit SponsoredExecution(execution.operationId, execution.executor, execution.nonce, callsHash, callCount);
    }

    /// @inheritdoc ICryftDelegation
    function getNonce() external view override returns (uint256) {
        return _delegationStorage().nonce;
    }

    /// @inheritdoc ICryftDelegation
    function getExecutionDigest(
        bytes32 operationId,
        address executor,
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view override returns (bytes32) {
        return _executionDigest(operationId, executor, _hashCalls(calls), nonce, deadline, executionGasLimit);
    }

    /// @inheritdoc ICryftDelegation
    function domainSeparator() external view override returns (bytes32) {
        return _domainSeparator();
    }

    /// @inheritdoc ICryftDelegation
    function isValidSignature(bytes32 digest, bytes calldata signature) external view override returns (bytes4) {
        return digest.tryRecover(signature) == address(this) ? _EIP1271_MAGIC : bytes4(0xffffffff);
    }

    /// @inheritdoc ICryftDelegation
    function hashCalls(Call[] calldata calls) external pure override returns (bytes32) {
        return _hashCalls(calls);
    }

    /// @inheritdoc ICryftDelegation
    function delegationStorageLocation() external pure override returns (bytes32) {
        return _DELEGATION_STORAGE_LOCATION;
    }

    /// @inheritdoc ICryftDelegation
    function delegationProtocolId() external pure override returns (bytes32) {
        return _DELEGATION_PROTOCOL_ID;
    }

    /// @inheritdoc ICryftDelegation
    function delegationCapabilities() external pure override returns (uint256) {
        return CryftDelegationCapabilities.ALL_V1;
    }

    /// @inheritdoc ICryftDelegation
    function implementationVersion() external pure override returns (string memory) {
        return "1.2.0";
    }

    /// @inheritdoc ICryftDelegation
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == _ERC165_INTERFACE_ID ||
            interfaceId == type(ICryftDelegation).interfaceId ||
            interfaceId == _EIP1271_MAGIC ||
            interfaceId == _ERC721_RECEIVED ||
            interfaceId == _ERC1155_RECEIVER_INTERFACE_ID;
    }

    /// @notice Accepts every ERC-721 token sent to the account.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return _ERC721_RECEIVED;
    }

    /// @notice Accepts every ERC-1155 token sent to the account.
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return _ERC1155_RECEIVED;
    }

    /// @notice Accepts every ERC-1155 batch sent to the account.
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return _ERC1155_BATCH_RECEIVED;
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    /// @dev Runs every call with the gas left in the signed budget. Bounded by _MAX_CALLS (checked by the caller).
    function _executeCalls(
        bytes32 operationId,
        Call[] calldata calls,
        uint256 executionGasLimit
    ) private returns (bytes[] memory results) {
        uint256 callCount = calls.length;
        uint256 executionStartGas = gasleft();
        results = new bytes[](callCount);
        uint256 totalReturnBytes;
        for (uint256 i; i < callCount; ++i) {
            Call calldata callItem = calls[i];
            if (callItem.target == address(0) || callItem.target == address(this)) revert InvalidTarget(i);

            uint256 consumedGas = executionStartGas - gasleft();
            if (consumedGas >= executionGasLimit) {
                revert ExecutionGasBudgetExceeded(consumedGas, executionGasLimit);
            }
            uint256 remainingGas = executionGasLimit - consumedGas;
            bytes memory result = _boundedTargetCall(
                callItem,
                remainingGas,
                i,
                _MAX_RETURN_BYTES_TOTAL - totalReturnBytes
            );
            totalReturnBytes += result.length;

            results[i] = result;
            emit CallExecuted(operationId, i, callItem.target, callItem.value, keccak256(result));
        }
        uint256 totalExecutionGas = executionStartGas - gasleft();
        if (totalExecutionGas > executionGasLimit) {
            revert ExecutionGasBudgetExceeded(totalExecutionGas, executionGasLimit);
        }
    }

    /// @dev One call with exactly `budget` gas; its return data is bounded per call and in total.
    function _boundedTargetCall(
        Call calldata item,
        uint256 budget,
        uint256 index,
        uint256 remainingReturnBytes
    ) private returns (bytes memory result) {
        bytes memory input = item.data;
        address target = item.target;
        uint256 value = item.value;
        bool success;
        uint256 size;
        assembly ("memory-safe") {
            success := call(budget, target, value, add(input, 32), mload(input), 0, 0)
            size := returndatasize()
        }
        if (size > _MAX_RETURN_BYTES_PER_CALL || size > remainingReturnBytes) {
            revert ReturnDataTooLarge(index, size);
        }
        result = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(result, 32), 0, size)
        }
        if (!success) _bubbleRevert(result, index);
    }

    function _executionDigest(
        bytes32 operationId,
        address executor,
        bytes32 callsHash,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(_EXECUTION_TYPEHASH, operationId, executor, callsHash, nonce, deadline, executionGasLimit)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    /// @dev Bounded by the call count (at most _MAX_CALLS on execution; views hash what they are given).
    function _hashCalls(Call[] calldata calls) private pure returns (bytes32) {
        uint256 callCount = calls.length;
        bytes32[] memory callHashes = new bytes32[](callCount);
        for (uint256 i; i < callCount; ++i) {
            callHashes[i] = keccak256(
                abi.encode(_CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data))
            );
        }
        return keccak256(abi.encode(callHashes));
    }

    function _delegationStorage() private pure returns (DelegationStorage storage state) {
        bytes32 location = _DELEGATION_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }

    function _bubbleRevert(bytes memory returnData, uint256 callIndex) private pure {
        if (returnData.length != 0) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        revert CallReverted(callIndex);
    }
}
