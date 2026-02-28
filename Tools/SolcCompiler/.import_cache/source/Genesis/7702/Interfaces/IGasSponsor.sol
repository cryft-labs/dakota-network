// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title IGasSponsor
 * @notice Interface for the on-chain gas sponsorship treasury.
 *
 *         Sponsors deposit native tokens and authorise relayer addresses.
 *         Relayers execute transactions on behalf of users (typically via
 *         DakotaDelegation.executeSponsored) and claim gas reimbursement
 *         from the sponsor's balance.
 *
 *         Complements thirdweb's hosted gas sponsorship with
 *         a self-hosted, on-chain alternative for Dakota chain 112311.
 */
interface IGasSponsor {

    // ── Events ─────────────────────────────────────────────

    /// @notice Emitted when a sponsor deposits native tokens.
    event Deposited(address indexed sponsor, uint256 amount);

    /// @notice Emitted when a sponsor withdraws native tokens.
    event Withdrawn(address indexed sponsor, uint256 amount);

    /// @notice Emitted when a relayer is authorised by a sponsor.
    event RelayerAuthorized(
        address indexed sponsor,
        address indexed relayer
    );

    /// @notice Emitted when a relayer is revoked by a sponsor.
    event RelayerRevoked(
        address indexed sponsor,
        address indexed relayer
    );

    /// @notice Emitted when a sponsor updates a configuration parameter.
    event ConfigUpdated(
        address indexed sponsor,
        string param,
        uint256 value
    );

    /// @notice Emitted when a target contract is added to the allowlist.
    event TargetAllowed(
        address indexed sponsor,
        address indexed target
    );

    /// @notice Emitted when a target contract is removed from the allowlist.
    event TargetRemoved(
        address indexed sponsor,
        address indexed target
    );

    /// @notice Emitted when a relayer claims gas reimbursement.
    event Claimed(
        address indexed sponsor,
        address indexed relayer,
        uint256 amount
    );

    /// @notice Emitted when a sponsored call is forwarded and reimbursed.
    event SponsoredCallExecuted(
        address indexed sponsor,
        address indexed relayer,
        address indexed target,
        uint256 totalCost
    );

    /// @notice Emitted when a sponsor tops off from the GasManager.
    event ToppedOff(address indexed sponsor, uint256 amount);

    // ── Sponsor Management ─────────────────────────────────

    /// @notice Deposit native tokens as a sponsor.
    function deposit() external payable;

    /// @notice Withdraw native tokens from the sponsor's balance.
    /// @param amount Amount of native tokens to withdraw.
    function withdraw(uint256 amount) external;

    /// @notice Authorise a relayer address to claim reimbursements.
    /// @param relayer Address of the relayer.
    function authorizeRelayer(address relayer) external;

    /// @notice Revoke a relayer's authorisation.
    /// @param relayer Address of the relayer.
    function revokeRelayer(address relayer) external;

    /// @notice Set the maximum claimable amount per transaction.
    ///         Set to 0 for no limit.
    /// @param amount Max amount in wei.
    function setMaxClaimPerTx(uint256 amount) external;

    /// @notice Set the maximum daily spend across all relayers.
    ///         Set to 0 for no limit.  Resets at midnight UTC.
    /// @param amount Max daily amount in wei.
    function setDailyLimit(uint256 amount) external;

    /// @notice Add a target contract to the sponsor's allowlist.
    ///         Enabling the allowlist restricts sponsored calls to
    ///         only the listed targets.
    /// @param target Contract address.
    function addAllowedTarget(address target) external;

    /// @notice Remove a target from the sponsor's allowlist.
    /// @param target Contract address.
    function removeAllowedTarget(address target) external;

    /// @notice Disable the target allowlist entirely (all targets allowed).
    function disableTargetAllowlist() external;

    // ── Top-Off ────────────────────────────────────────────

    /// @notice Pull voter-approved funds from the GasManager contract
    ///         and credit them to a sponsor's balance.
    ///         Only callable by a GasManager guardian.
    ///         Requires an approved fund in GasManager for this contract
    ///         address and the requested amount.
    /// @param sponsor Address of the sponsor to credit.
    /// @param amount  Amount of native tokens to pull.
    function topOff(address sponsor, uint256 amount) external;

    // ── Reimbursement ──────────────────────────────────────

    /// @notice Claim gas reimbursement from a sponsor.
    ///         The caller must be an authorised relayer.
    /// @param sponsor Address of the sponsor to debit.
    /// @param amount  Amount of native tokens to claim.
    function claim(address sponsor, uint256 amount) external;

    /// @notice Forward a call to a target and automatically reimburse
    ///         the relayer for gas spent.  The caller must be an
    ///         authorised relayer.
    /// @param sponsor Address of the sponsor to debit.
    /// @param target  Address to call.
    /// @param value   Native tokens to send with the call.
    /// @param data    Calldata to forward.
    /// @return result The raw return data from the call.
    function sponsoredCall(
        address sponsor,
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory result);

    // ── Views ──────────────────────────────────────────────

    /// @notice Get a sponsor's current configuration and balances.
    function getSponsorInfo(address sponsor)
        external
        view
        returns (
            uint256 balance,
            uint256 maxClaimPerTx,
            uint256 dailyLimit,
            uint256 dailySpent,
            bool    active,
            bool    useTargetAllowlist
        );

    /// @notice Check whether an address is an authorised relayer for a
    ///         given sponsor.
    function isAuthorizedRelayer(
        address sponsor,
        address relayer
    ) external view returns (bool);

    /// @notice Check whether an address is on a sponsor's target allowlist.
    function isAllowedTarget(
        address sponsor,
        address target
    ) external view returns (bool);
}
