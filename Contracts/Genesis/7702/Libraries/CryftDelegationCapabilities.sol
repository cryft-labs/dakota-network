// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title CryftDelegationCapabilities
/// @notice Stable capability bits of delegation protocol v1.
/// @custom:version 1.2.0
/// @custom:security-contact security@cryft.cards
library CryftDelegationCapabilities {
    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    uint256 internal constant SPONSORED_EXECUTION = 1 << 0;
    uint256 internal constant BATCHED_CALLS = 1 << 1;
    uint256 internal constant EIP1271 = 1 << 2;
    uint256 internal constant NATIVE_RECEIVE = 1 << 3;
    uint256 internal constant ERC721_RECEIVE = 1 << 4;
    uint256 internal constant ERC1155_RECEIVE = 1 << 5;
    uint256 internal constant TYPED_DATA_HELPERS = 1 << 6;
    uint256 internal constant REPLAY_PROTECTION = 1 << 7;

    /// @notice Bits every v1 account logic must implement.
    uint256 internal constant REQUIRED_V1 =
        SPONSORED_EXECUTION | BATCHED_CALLS | EIP1271 | TYPED_DATA_HELPERS | REPLAY_PROTECTION;

    /// @notice Every v1 bit.
    uint256 internal constant ALL_V1 = REQUIRED_V1 | NATIVE_RECEIVE | ERC721_RECEIVE | ERC1155_RECEIVE;
}
