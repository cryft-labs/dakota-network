// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/// @title IDakotaDelegation
/// @notice Minimal native EIP-7702 execution surface used by Dakota widgets.
interface IDakotaDelegation {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    struct SponsoredExecutionRequest {
        bytes32 operationId;
        address executor;
        Call[] calls;
        uint256 nonce;
        uint256 deadline;
        uint256 executionGasLimit;
    }

    event SponsoredExecution(
        bytes32 indexed operationId,
        address indexed executor,
        uint256 indexed nonce,
        bytes32 callsHash,
        uint256 callCount
    );

    event CallExecuted(
        bytes32 indexed operationId,
        uint256 indexed callIndex,
        address indexed target,
        uint256 value,
        bytes32 resultHash
    );

    function executeSponsored(
        SponsoredExecutionRequest calldata execution,
        bytes calldata ownerSignature
    ) external payable returns (bytes[] memory results);

    function getNonce() external view returns (uint256);

    function hashCalls(Call[] calldata calls) external pure returns (bytes32);

    function getExecutionDigest(
        bytes32 operationId,
        address executor,
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view returns (bytes32);

    function domainSeparator() external view returns (bytes32);

    function isValidSignature(
        bytes32 digest,
        bytes calldata signature
    ) external view returns (bytes4);

    function delegationStorageLocation() external pure returns (bytes32);

    function delegationProtocolId() external pure returns (bytes32);

    function implementationVersion() external pure returns (string memory);
}
