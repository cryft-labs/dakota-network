// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/// @title IPrivateMetaTxRelay
/// @notice Interface for the private meta-transaction relay deployed
///         inside a Paladin Pente privacy group. Enables gas-covered
///         operations where the Paladin signer submits EIP-712 signed
///         requests on behalf of end users.
interface IPrivateMetaTxRelay {

    /// @notice A signed request from a user to execute a call on
    ///         PrivateComboStorage via the Paladin signer.
    struct ForwardRequest {
        address from;       // The original signer (recovered and verified)
        bytes   data;       // ABI-encoded function call to PrivateComboStorage
        uint256 nonce;      // Per-signer replay-protection nonce
        uint256 deadline;   // block.timestamp expiry
    }

    // ── Events ────────────────────────────────────────────

    /// @notice Emitted when a meta-transaction is successfully forwarded.
    event MetaTxExecuted(
        address indexed from,
        uint256 nonce,
        bytes returnData
    );

    /// @notice Emitted when a meta-transaction fails during batch execution.
    event MetaTxFailed(
        uint256 indexed index,
        address indexed from,
        string reason
    );

    // ── Functions ─────────────────────────────────────────

    /// @notice Forward a single signed request to PrivateComboStorage.
    ///         Reverts if the signature is invalid or the forwarded call fails.
    /// @param request  The signed forward request.
    /// @param signature 65-byte ECDSA signature (r || s || v) over the
    ///                  EIP-712 typed data hash of the request.
    /// @return returnData ABI-encoded return value from PrivateComboStorage.
    function execute(
        ForwardRequest calldata request,
        bytes calldata signature
    ) external returns (bytes memory returnData);

    /// @notice Forward multiple independent signed requests in one transaction.
    ///         Invalid entries are skipped with MetaTxFailed events.
    ///         Entries from the same signer must be ordered by ascending nonce.
    /// @param requests  Array of signed forward requests.
    /// @param signatures Array of corresponding 65-byte ECDSA signatures.
    /// @return successes Per-index success flags.
    /// @return results   Per-index ABI-encoded return data (or revert data on failure).
    function executeBatch(
        ForwardRequest[] calldata requests,
        bytes[] calldata signatures
    ) external returns (bool[] memory successes, bytes[] memory results);

    /// @notice Returns the current nonce for a given signer.
    /// @param from The signer address.
    function getNonce(address from) external view returns (uint256);

    /// @notice Check whether a request and signature pair would pass
    ///         verification at the current block.
    /// @param request  The forward request to verify.
    /// @param signature The ECDSA signature to verify.
    function verify(
        ForwardRequest calldata request,
        bytes calldata signature
    ) external view returns (bool);

    /// @notice Returns the EIP-712 domain separator for this relay instance.
    function domainSeparator() external view returns (bytes32);
}
