// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title IComboStorage (Pente Private Contract Interface)
 * @notice Interface for the private combo storage contract deployed inside
 *         a Paladin Pente privacy group. All state is private to privacy
 *         group members.
 *
 *         The private contract stores hash+salt pairs (secret representations
 *         of redeemable codes), verifies submitted codes via hash comparison,
 *         and manages per-UID state (frozen, redeemed, content) privately.
 *
 *         On redemption, the private contract emits a PenteExternalCall event
 *         that atomically routes through CodeManager to the gift contract on
 *         the public chain. The gift contract is the sole authority on
 *         redemption behavior; the private state is for internal tracking.
 *
 *         Patent Reference: Claims 1–5, 13
 */
interface IComboStorage {
    /// @notice Returns true if a verified redemption exists for this unique ID.
    function isRedemptionVerified(string memory uniqueId) external view returns (bool);

    /// @notice Returns the address that redeemed the code for this unique ID.
    ///         Returns address(0) if no verified redemption exists.
    function redemptionRedeemer(string memory uniqueId) external view returns (address);

    /// @notice Returns whether a UID is frozen (private state).
    function isFrozen(string memory uniqueId) external view returns (bool);

    /// @notice Returns whether a UID has been redeemed (private tracking).
    function isRedeemed(string memory uniqueId) external view returns (bool);

    /// @notice Returns the content identifier for a UID (private state).
    function getContentId(string memory uniqueId) external view returns (string memory);
}
