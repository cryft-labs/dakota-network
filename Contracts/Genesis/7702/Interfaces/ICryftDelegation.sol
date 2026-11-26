// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title ICryftDelegation
/// @notice Native EIP-7702 execution surface of a Cryft account, used by Cryft widgets.
/// @custom:version 1.2.0
/// @custom:security-contact security@cryft.cards
interface ICryftDelegation {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @notice One call of an operation.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice A sponsored operation, signed by the account's owner key.
    struct SponsoredExecutionRequest {
        bytes32 operationId;
        address executor;
        Call[] calls;
        uint256 nonce;
        uint256 deadline;
        uint256 executionGasLimit;
    }

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A sponsored operation ran to completion.
    event SponsoredExecution(
        bytes32 indexed operationId,
        address indexed executor,
        uint256 indexed nonce,
        bytes32 callsHash,
        uint256 callCount
    );

    /// @notice One call of a sponsored operation succeeded.
    event CallExecuted(
        bytes32 indexed operationId,
        uint256 indexed callIndex,
        address indexed target,
        uint256 value,
        bytes32 resultHash
    );

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Runs a signed operation for its named executor and returns each call's return data.
    function executeSponsored(
        SponsoredExecutionRequest calldata execution,
        bytes calldata ownerSignature
    ) external payable returns (bytes[] memory results);

    /// @notice The account's next operation nonce.
    function getNonce() external view returns (uint256);

    /// @notice The EIP-712 digest the owner signs for an operation.
    function getExecutionDigest(
        bytes32 operationId,
        address executor,
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view returns (bytes32);

    /// @notice The account's EIP-712 domain separator (domain "CryftDelegation", version "1").
    function domainSeparator() external view returns (bytes32);

    /// @notice EIP-1271: returns the magic value when the account's own key signed `digest`.
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4);

    /// @notice The EIP-712 hash of a call list.
    function hashCalls(Call[] calldata calls) external pure returns (bytes32);

    /// @notice The ERC-7201 slot of the account's delegation storage.
    function delegationStorageLocation() external pure returns (bytes32);

    /// @notice The delegation protocol id this logic implements.
    function delegationProtocolId() external pure returns (bytes32);

    /// @notice Capability bitmap implemented by the current account logic.
    /// @dev Bits are stable within a protocol generation: 0 sponsored execution, 1 batched calls, 2 EIP-1271,
    ///      3 native-coin receive, 4 ERC-721 receive, 5 ERC-1155 receive, 6 typed-data digest helpers,
    ///      7 replay-protected account nonce.
    function delegationCapabilities() external pure returns (uint256);

    /// @notice The account logic's version.
    function implementationVersion() external pure returns (string memory);

    /// @notice ERC-165 introspection for the account and receiver surfaces.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
