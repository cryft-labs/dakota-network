// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title ITenantAllowancePolicy
/// @notice Optional, tenant-scoped accounting asked by the gas sponsor. A policy never receives native coin.
/// @custom:version 1.5.2
/// @custom:security-contact security@cryft.cards
interface ITenantAllowancePolicy {
    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Reserves up to `maximumCost` for `wallet`'s operation; returns this function's selector to accept.
    function reserve(bytes32 operationId, address wallet, uint256 maximumCost) external returns (bytes4);

    /// @notice Settles a reserved operation at `chargedCost`; returns this function's selector to accept.
    function settle(bytes32 operationId, uint256 chargedCost) external returns (bytes4);

    /// @notice The gas sponsor this policy serves.
    function gasSponsor() external view returns (address);

    /// @notice The sponsor account this policy serves.
    function sponsor() external view returns (address);
}
