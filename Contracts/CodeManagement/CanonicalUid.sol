// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title CanonicalUid
/// @notice Parses unique code identifiers of the form `<identifier>-<counter>`.
/// @dev The identifier is opaque (1 to 128 bytes, no '-'); the counter is a positive decimal uint256 without a
///      leading zero. Invalid input is classified without arithmetic panics, and every loop is bounded by
///      MAX_IDENTIFIER_BYTES or MAX_COUNTER_BYTES, checked before it runs.
/// @custom:version 3.1.0
/// @custom:security-contact security@cryft.cards
library CanonicalUid {
    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @dev Longest identifier part.
    uint256 internal constant MAX_IDENTIFIER_BYTES = 128;
    /// @dev Longest counter part (the digits of type(uint256).max).
    uint256 internal constant MAX_COUNTER_BYTES = 78;

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @dev Whether `identifier` is a valid identifier part.
    function validIdentifier(string memory identifier) internal pure returns (bool) {
        bytes memory b = bytes(identifier);
        if (b.length == 0 || b.length > MAX_IDENTIFIER_BYTES) return false;
        for (uint256 i; i < b.length; ++i) if (b[i] == 0x2d) return false;
        return true;
    }

    /// @dev Parses a positive decimal counter; returns (false, 0) for anything else.
    function parseCounter(string memory value) internal pure returns (bool, uint256) {
        bytes memory b = bytes(value);
        if (b.length == 0 || b.length > MAX_COUNTER_BYTES || b[0] == 0x30) return (false, 0);
        uint256 result;
        for (uint256 i; i < b.length; ++i) {
            uint256 c = uint8(b[i]);
            if (c < 48 || c > 57) return (false, 0);
            uint256 digit = c - 48;
            if (result > (type(uint256).max - digit) / 10) return (false, 0);
            result = result * 10 + digit;
        }
        return (true, result);
    }

    /// @dev Splits a code at its first '-' into (ok, identifier, counter).
    function split(string memory uid) internal pure returns (bool, string memory, uint256) {
        bytes memory b = bytes(uid);
        if (b.length < 3 || b.length > MAX_IDENTIFIER_BYTES + 1 + MAX_COUNTER_BYTES) return (false, "", 0);
        uint256 delimiter;
        // Bounded by b.length, at most MAX_IDENTIFIER_BYTES + 1 + MAX_COUNTER_BYTES.
        while (delimiter < b.length && b[delimiter] != 0x2d) ++delimiter;
        if (delimiter == 0 || delimiter > MAX_IDENTIFIER_BYTES || delimiter + 1 >= b.length) return (false, "", 0);
        bytes memory identifier = new bytes(delimiter);
        bytes memory suffix = new bytes(b.length - delimiter - 1);
        for (uint256 i; i < delimiter; ++i) identifier[i] = b[i];
        for (uint256 i; i < suffix.length; ++i) suffix[i] = b[delimiter + 1 + i];
        (bool ok, uint256 counter) = parseCounter(string(suffix));
        if (!ok) return (false, "", 0);
        return (true, string(identifier), counter);
    }
}
