// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title IRedeemable
/// @notice Interface every gift contract implements so CodeManager can deliver redemptions to it.
/// @dev PrivateComboStorage holds the execution-time code state; CodeManager mirrors the public active and redeemed
///      status and routes redemptions; the gift contract owns only the redemption side effects (a flag, a counter,
///      an NFT transfer) and decides whether multi-use redemptions are allowed. CodeManager marks a code Redeemed
///      before it calls the gift. If the gift reverts, CodeManager emits RedemptionFailed, the code stays Redeemed
///      at every layer, and the committed recipient can be retried with `retryRedemptionDelivery`.
/// @custom:version 3.1.0
/// @custom:security-contact security@cryft.cards
interface IRedeemable {
    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Records a redemption of `uniqueId` for `redeemer`; called by CodeManager.
    /// @dev The gift decides what a redemption does (single use, multi use, NFT transfer, conditions). A gift that
    ///      refuses SHOULD revert: CodeManager then emits RedemptionFailed, and the code stays Redeemed.
    /// @param uniqueId The unique identifier being redeemed.
    /// @param redeemer The address performing the redemption.
    function recordRedemption(string memory uniqueId, address redeemer) external;

    /// @notice Returns whether the gift contract considers the unique ID redeemed.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool);
}
