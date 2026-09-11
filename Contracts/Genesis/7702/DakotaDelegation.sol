// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/*
  ___       _        _          ___      _                 _   _
 |   \ __ _| | _____| |_ __ _  |   \ ___| |___ __ _ __ _| |_(_)___ _ _
 | |) / _` | |/ / _ \  _/ _` | | |) / -_) / -_) _` / _` |  _| / _ \ ' \
 |___/\__,_|_|\_\___/\__\__,_| |___/\___|_\___\__, \__,_|\__|_\___/_||_|
                                               |___/ By: CryftCreator

  Version 1.1.0 — Production Dakota Delegation  [BEACON-UPGRADEABLE]

  ┌──────────────── Contract Architecture ─────────────────────────────┐
  │                                                                    │
  │  NATIVE EIP-7702 SPONSORED EXECUTION                               │
  │                                                                    │
  │  Registry control plane: 0x0000...de1E6A7E                         │
  │  Per-account route:                                                │
  │    user EOA → immutable dispatcher                  │
  │    → shared beacon → this implementation                           │
  │                                                                    │
  │  Signed execution contract:                                        │
  │    • EIP-712 domain is bound to each delegated user account        │
  │    • owner signature must recover to address(this)                 │
  │    • executor, operation ID, nonce, deadline, calls, and           │
  │      execution gas limit are all signature-bound                   │
  │    • 1-32 calls per operation; 5,000,000 execution-gas ceiling     │
  │                                                                    │
  │  Security rails:                                                   │
  │    • direct implementation execution is rejected                   │
  │    • strict low-s ECDSA with 65-byte and EIP-2098 signatures       │
  │    • per-account nonce, reentrancy guard, and post-call reserve    │
  │    • zero targets are rejected and target reverts are preserved    │
  │                                                                    │
  │  Compatibility:                                                    │
  │    • EIP-1271 signature validation                                 │
  │    • native token, ERC-721, and ERC-1155 receiving                 │
  │                                                                    │
  │  Storage and upgrades:                                             │
  │    • ERC-7201 namespace: dakota.storage.DakotaDelegation           │
  │    • only nonce and reentrancy state live in the user account      │
  │    • normal upgrades change the shared beacon implementation       │
  │    • protocol ID: dakota.delegation.sponsored-execution.v1         │
  └────────────────────────────────────────────────────────────────────┘
*/

import "./DelegationGas.sol";
import "./Interfaces/IDakotaDelegation.sol";
import "./Libraries/DakotaDelegationCapabilities.sol";
import "./Libraries/DakotaECDSA.sol";

/// @title DakotaDelegation
/// @notice Shared account logic for widget-driven, relayed EIP-7702 execution.
/// @dev User EOAs designate the immutable dispatcher directly. It resolves this
///      implementation through the shared beacon without per-account proxy slots.
contract DakotaDelegation is IDakotaDelegation {
    using DakotaECDSA for bytes32;

    error DirectImplementationCall();
    error EmptyOperationId();
    error InvalidExecutor();
    error InvalidNonce(uint256 expected, uint256 supplied);
    error Expired();
    error InvalidSignature();
    error InvalidCallCount();
    error InvalidTarget(uint256 callIndex);
    error ReentrantExecution();
    error InsufficientExecutionGas(uint256 available, uint256 required);
    error ExecutionGasBudgetExceeded(uint256 consumed, uint256 limit);
    error CallReverted(uint256 callIndex);
    error ReturnDataTooLarge(uint256 callIndex, uint256 size);

    uint256 private constant _MAX_CALLS = 32;
    uint256 private constant _MAX_EXECUTION_GAS_LIMIT = 5_000_000;
    uint256 private constant _POST_EXECUTION_GAS_RESERVE = 30_000;
    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256("DakotaDelegation");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _CALL_TYPEHASH = keccak256(
        "Call(address target,uint256 value,bytes data)"
    );
    bytes32 private constant _EXECUTION_TYPEHASH = keccak256(
        "ExecuteSponsored(bytes32 operationId,address executor,bytes32 callsHash,uint256 nonce,uint256 deadline,uint256 executionGasLimit)"
    );

    /// @custom:storage-location erc7201:dakota.storage.DakotaDelegation
    struct DelegationStorage {
        uint256 nonce;
        uint256 reentrancyStatus;
    }

    bytes32 private constant _DELEGATION_STORAGE_LOCATION =
        0x2d5df833376e6c9531b3cb92f5745ecf8ad8197730684ec3db99cc12d4e93d00;
    bytes32 private constant _DELEGATION_PROTOCOL_ID =
        keccak256("dakota.delegation.sponsored-execution.v1");

    address private immutable _implementationAddress;

    constructor() {
        _implementationAddress = address(this);
    }

    modifier onlyDelegated() {
        if (address(this) == _implementationAddress) {
            revert DirectImplementationCall();
        }
        _;
    }

    modifier nonReentrant() {
        DelegationStorage storage state = _delegationStorage();
        if (state.reentrancyStatus == 1) {
            revert ReentrantExecution();
        }
        state.reentrancyStatus = 1;
        _;
        state.reentrancyStatus = 0;
    }

    /// @inheritdoc IDakotaDelegation
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
        if (execution.operationId == bytes32(0)) {
            revert EmptyOperationId();
        }
        if (
            execution.executor == address(0) ||
            msg.sender != execution.executor
        ) {
            revert InvalidExecutor();
        }
        if (block.timestamp > execution.deadline) revert Expired();

        uint256 callCount = execution.calls.length;
        if (callCount == 0 || callCount > _MAX_CALLS) {
            revert InvalidCallCount();
        }

        DelegationStorage storage state = _delegationStorage();
        if (execution.nonce != state.nonce) {
            revert InvalidNonce(state.nonce, execution.nonce);
        }

        bytes32 callsHash = _hashCalls(execution.calls);
        bytes32 digest = _executionDigest(
            execution.operationId,
            execution.executor,
            callsHash,
            execution.nonce,
            execution.deadline,
            execution.executionGasLimit
        );
        if (digest.tryRecover(ownerSignature) != address(this)) {
            revert InvalidSignature();
        }

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
            revert InsufficientExecutionGas(
                availableGas,
                requiredGas
            );
        }

        results = _executeCalls(
            execution.operationId,
            execution.calls,
            execution.executionGasLimit
        );

        emit SponsoredExecution(
            execution.operationId,
            execution.executor,
            execution.nonce,
            callsHash,
            callCount
        );
    }

    /// @inheritdoc IDakotaDelegation
    function getNonce() external view override returns (uint256) {
        return _delegationStorage().nonce;
    }

    /// @inheritdoc IDakotaDelegation
    function hashCalls(
        Call[] calldata calls
    ) external pure override returns (bytes32) {
        return _hashCalls(calls);
    }

    /// @inheritdoc IDakotaDelegation
    function getExecutionDigest(
        bytes32 operationId,
        address executor,
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view override returns (bytes32) {
        return _executionDigest(
            operationId,
            executor,
            _hashCalls(calls),
            nonce,
            deadline,
            executionGasLimit
        );
    }

    /// @inheritdoc IDakotaDelegation
    function domainSeparator() external view override returns (bytes32) {
        return _domainSeparator();
    }

    /// @inheritdoc IDakotaDelegation
    function isValidSignature(
        bytes32 digest,
        bytes calldata signature
    ) external view override returns (bytes4) {
        return digest.tryRecover(signature) == address(this)
            ? _EIP1271_MAGIC
            : bytes4(0xffffffff);
    }

    /// @inheritdoc IDakotaDelegation
    function delegationStorageLocation()
        external
        pure
        override
        returns (bytes32)
    {
        return _DELEGATION_STORAGE_LOCATION;
    }

    /// @inheritdoc IDakotaDelegation
    function delegationProtocolId()
        external
        pure
        override
        returns (bytes32)
    {
        return _DELEGATION_PROTOCOL_ID;
    }

    /// @inheritdoc IDakotaDelegation
    function delegationCapabilities()
        external
        pure
        override
        returns (uint256)
    {
        return DakotaDelegationCapabilities.ALL_V1;
    }

    /// @inheritdoc IDakotaDelegation
    function implementationVersion()
        external
        pure
        override
        returns (string memory)
    {
        return "1.1.0";
    }

    /// @inheritdoc IDakotaDelegation
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return
            interfaceId == 0x01ffc9a7 ||
            interfaceId == type(IDakotaDelegation).interfaceId ||
            interfaceId == _EIP1271_MAGIC ||
            interfaceId == 0x150b7a02 ||
            interfaceId == 0x4e2312e0;
    }

    receive() external payable {
        if (address(this) == _implementationAddress) {
            revert DirectImplementationCall();
        }
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xbc197c81;
    }

    function _hashCalls(
        Call[] calldata calls
    ) private pure returns (bytes32) {
        uint256 callCount = calls.length;
        bytes32[] memory callHashes = new bytes32[](callCount);
        for (uint256 i; i < callCount; ) {
            callHashes[i] = keccak256(
                abi.encode(
                    _CALL_TYPEHASH,
                    calls[i].target,
                    calls[i].value,
                    keccak256(calls[i].data)
                )
            );
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encode(callHashes));
    }

    function _boundedTargetCall(Call calldata item, uint256 budget, uint256 index, uint256 remainingReturnBytes)
        private returns (bytes memory result)
    {
        bytes memory input = item.data;
        address target = item.target;
        uint256 value = item.value;
        bool success;
        uint256 size;
        assembly ("memory-safe") {
            success := call(budget, target, value, add(input, 32), mload(input), 0, 0)
            size := returndatasize()
        }
        if (size > 4096 || size > remainingReturnBytes) revert ReturnDataTooLarge(index, size);
        result = new bytes(size);
        assembly ("memory-safe") { returndatacopy(add(result, 32), 0, size) }
        if (!success) _bubbleRevert(result, index);
    }

    function _executeCalls(
        bytes32 operationId,
        Call[] calldata calls,
        uint256 executionGasLimit
    ) private returns (bytes[] memory results) {
        uint256 callCount = calls.length;
        uint256 executionStartGas = gasleft();
        results = new bytes[](callCount);
        uint256 totalReturnBytes;
        for (uint256 i; i < callCount; ) {
            Call calldata callItem = calls[i];
            if (
                callItem.target == address(0) ||
                callItem.target == address(this)
            ) {
                revert InvalidTarget(i);
            }

            uint256 consumedGas = executionStartGas - gasleft();
            if (consumedGas >= executionGasLimit) {
                revert ExecutionGasBudgetExceeded(
                    consumedGas,
                    executionGasLimit
                );
            }
            uint256 remainingGas = executionGasLimit - consumedGas;
            bytes memory result = _boundedTargetCall(callItem, remainingGas, i, 16384 - totalReturnBytes);
            totalReturnBytes += result.length;

            results[i] = result;
            emit CallExecuted(
                operationId,
                i,
                callItem.target,
                callItem.value,
                keccak256(result)
            );
            unchecked {
                ++i;
            }
        }
        uint256 totalExecutionGas = executionStartGas - gasleft();
        if (totalExecutionGas > executionGasLimit) {
            revert ExecutionGasBudgetExceeded(
                totalExecutionGas,
                executionGasLimit
            );
        }
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
            abi.encode(
                _EXECUTION_TYPEHASH,
                operationId,
                executor,
                callsHash,
                nonce,
                deadline,
                executionGasLimit
            )
        );
        return keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                _NAME_HASH,
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    function _delegationStorage()
        private
        pure
        returns (DelegationStorage storage state)
    {
        bytes32 location = _DELEGATION_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }

    function _bubbleRevert(
        bytes memory returnData,
        uint256 callIndex
    ) private pure {
        if (returnData.length != 0) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        revert CallReverted(callIndex);
    }
}
