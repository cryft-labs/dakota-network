// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.8.20;

/**
 * @title IComboStorage
 * @notice Read-only interface that gift contracts use to verify redemption
 *         results recorded by the ComboStorage service.
 *
 *         ComboStorage validates redemption codes and records the result
 *         (uniqueId → redeemer) in its own state. Gift contracts then
 *         read this state to safely finalize the redemption on their side.
 */
interface IComboStorage {
    /// @notice Returns true if ComboStorage has verified a successful code
    ///         match for this unique ID.
    function isRedemptionVerified(string memory uniqueId) external view returns (bool);

    /// @notice Returns the address that redeemed the code for this unique ID.
    ///         Returns address(0) if no verified redemption exists.
    function redemptionRedeemer(string memory uniqueId) external view returns (address);
}
