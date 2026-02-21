// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title IRedeemable
 * @notice Standard read-only interface that gift contracts expose so that the
 *         ComboStorage redemption service can check eligibility before recording
 *         a verified redemption.
 *
 *         Gift contracts own their own status (frozen, redeemed) and expose
 *         it through this interface. ComboStorage ONLY reads — never writes —
 *         to gift contract state.
 */
interface IRedeemable {
    /// @notice Returns true if the unique ID is currently frozen by the gift contract.
    function isUniqueIdFrozen(string memory uniqueId) external view returns (bool);

    /// @notice Returns true if the unique ID has already been redeemed.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool);
}
