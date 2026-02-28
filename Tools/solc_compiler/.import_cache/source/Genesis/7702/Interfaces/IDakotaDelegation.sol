// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title IDakotaDelegation
 * @notice Interface for the EIP-7702 delegation target contract.
 *
 *         EOAs delegate to this contract via type 0x04 transactions.
 *         Once delegated, the EOA gains smart-account capabilities:
 *         batch execution, gas-sponsored execution, session keys,
 *         and EIP-1271 signature validation.
 */
interface IDakotaDelegation {

    // ── Structs ────────────────────────────────────────────

    /// @notice A single call to execute via the delegation contract.
    struct Call {
        address target;
        uint256 value;
        bytes   data;
    }

    // ── Events ─────────────────────────────────────────────

    /// @notice Emitted when a single call is executed.
    event Executed(address indexed target, uint256 value, bytes data);

    /// @notice Emitted when a batch of calls is executed.
    event BatchExecuted(uint256 callCount);

    /// @notice Emitted when a sponsor-relayed execution completes.
    event SponsoredExecution(
        address indexed relayer,
        uint256 nonce,
        uint256 callCount
    );

    /// @notice Emitted when a session key is added.
    event SessionKeyAdded(address indexed key, uint256 expiry);

    /// @notice Emitted when a session key is removed.
    event SessionKeyRemoved(address indexed key);

    // ── Execution ──────────────────────────────────────────

    /// @notice Execute a single call.  Caller must be the account owner
    ///         (i.e. the delegating EOA) or a valid session key.
    /// @param target  Destination address.
    /// @param value   Native tokens to forward.
    /// @param data    Calldata to send.
    /// @return result The raw return data from the call.
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory result);

    /// @notice Execute a batch of calls atomically.
    /// @param calls   Array of Call structs.
    /// @return results Array of raw return data, one per call.
    function executeBatch(Call[] calldata calls)
        external
        payable
        returns (bytes[] memory results);

    /// @notice Execute a batch of calls on behalf of the account owner.
    ///         Anyone may call this (typically a relayer / GasSponsor);
    ///         authorisation is proven by the owner's EIP-712 signature.
    /// @param calls          Array of Call structs the owner authorised.
    /// @param nonce          Sequential nonce (prevents replay).
    /// @param deadline       Unix timestamp after which the signature is invalid.
    /// @param ownerSignature 65-byte ECDSA signature (r ‖ s ‖ v).
    /// @return results       Array of raw return data, one per call.
    function executeSponsored(
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        bytes calldata ownerSignature
    ) external payable returns (bytes[] memory results);

    // ── Session Keys ───────────────────────────────────────

    /// @notice Authorise a session key for limited-time autonomous execution.
    ///         Only the account owner may call this.
    /// @param key    Address of the session key.
    /// @param expiry Unix timestamp when the key expires.
    function addSessionKey(address key, uint256 expiry) external;

    /// @notice Revoke a session key immediately.
    /// @param key Address of the session key to remove.
    function removeSessionKey(address key) external;

    // ── EIP-1271 ───────────────────────────────────────────

    /// @notice Validate a signature on behalf of the delegated account.
    ///         Returns 0x1626ba7e if the signer is the account owner.
    /// @param hash      The hash that was signed.
    /// @param signature 65-byte ECDSA signature (r ‖ s ‖ v).
    /// @return magicValue 0x1626ba7e on success, 0xffffffff on failure.
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4 magicValue);

    // ── Views ──────────────────────────────────────────────

    /// @notice Current nonce for sponsored execution replay protection.
    function getNonce() external view returns (uint256);

    /// @notice Check whether an address is a valid (non-expired) session key.
    function isValidSessionKey(address key) external view returns (bool);
}
