// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title IRedeemable
 * @notice Interface that gift contracts MUST implement. In the current
 *         private-source/public-mirror flow, PrivateComboStorage is the
 *         execution-time source of UID state, CodeManager mirrors the public
 *         active/redeemed status and routes redemptions, and the gift contract
 *         owns only the redemption side effects for the unique IDs it manages.
 *
 *         When the Pente privacy group emits an external call, CodeManager
 *         resolves the UID to its gift contract and forwards the redemption
 *         here after validating the mirrored public state.
 *
 *         The gift contract decides:
 *           - What redemption does (boolean flip, counter, NFT transfer, etc.)
 *           - Whether multi-use redemptions are allowed
 *
 *         If the gift contract reverts on redemption, the entire
 *         Pente transition rolls back atomically.
 *
 */
interface IRedeemable {
    // ── Read Functions ──────────────────────────────────────────

    /// @notice Returns true if the gift contract considers the UID redeemed.
    ///         This is retained for compatibility and external consumers.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool);

    // ── Management Functions (called by CodeManager router) ─

    /// @notice Record a redemption for a unique ID.
    function recordRedemption(string memory uniqueId, address redeemer) external;
}
