// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title IRedeemable
 * @notice Interface that gift contracts MUST implement. The gift contract is
 *         the SOLE AUTHORITY on frozen status and redemption behavior for
 *         the unique IDs it manages.
 *
 *         CodeManager delegates all per-UID state management to the gift
 *         contract via this interface. When the Pente privacy group emits
 *         an externalCall, CodeManager resolves the UID to its gift contract
 *         and forwards the call here.
 *
 *         The gift contract decides:
 *           - Whether a code can be redeemed (frozen? already used?)
 *           - How redemption is recorded (boolean, counter, NFT mint, etc.)
 *           - Whether multi-use redemptions are allowed
 *
 *         If the gift contract reverts on any management call, the entire
 *         Pente transition rolls back atomically.
 *
 *         DESIGN REQUIREMENT — DEFAULT FROZEN STATE:
 *         The gift contract SHOULD return frozen=true from isUniqueIdFrozen()
 *         for any UID that has not been explicitly unfrozen. This ensures
 *         UIDs have a default frozen state upon initial registration
 */
interface IRedeemable {
    // ── Read Functions ──────────────────────────────────────────

    /// @notice Returns true if the unique ID is currently frozen.
    function isUniqueIdFrozen(string memory uniqueId) external view returns (bool);

    /// @notice Returns true if the unique ID has already been redeemed.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool);

    // ── Management Functions (called by CodeManager router) ─

    /// @notice Set frozen status for a unique ID.
    function setFrozen(string memory uniqueId, bool frozen) external;

    /// @notice Record a redemption for a unique ID.
    function recordRedemption(string memory uniqueId, address redeemer) external;
}
