// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.19 <0.9.0;

/// @dev Canonical opaque identifier plus a positive decimal uint256 counter.
/// Invalid input is classified without arithmetic panics or unbounded parsing.
library CanonicalUid {
    uint256 internal constant MAX_IDENTIFIER_BYTES = 128;
    uint256 internal constant MAX_COUNTER_BYTES = 78;

    function validIdentifier(string memory identifier) internal pure returns (bool) {
        bytes memory b = bytes(identifier);
        if (b.length == 0 || b.length > MAX_IDENTIFIER_BYTES) return false;
        for (uint256 i; i < b.length; ++i) if (b[i] == 0x2d) return false;
        return true;
    }

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

    function split(string memory uid) internal pure returns (bool, string memory, uint256) {
        bytes memory b = bytes(uid);
        if (b.length < 3 || b.length > MAX_IDENTIFIER_BYTES + 1 + MAX_COUNTER_BYTES) return (false, "", 0);
        uint256 delimiter;
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
