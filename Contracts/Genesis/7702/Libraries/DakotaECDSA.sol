// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/// @notice Minimal ECDSA recovery shared by Dakota's EIP-7702 contracts.
library DakotaECDSA {
    uint256 private constant _MAX_VALID_S =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @dev Returns address(0) for malformed, malleable, or invalid signatures.
    ///      Both 65-byte and EIP-2098 compact 64-byte signatures are accepted.
    function tryRecover(
        bytes32 digest,
        bytes calldata signature
    ) internal pure returns (address recovered) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length == 65) {
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 0x20))
                v := byte(0, calldataload(add(signature.offset, 0x40)))
            }
            if (v < 27) {
                unchecked {
                    v += 27;
                }
            }
        } else if (signature.length == 64) {
            bytes32 vs;
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                vs := calldataload(add(signature.offset, 0x20))
            }
            s = vs & bytes32(
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
            );
            v = uint8((uint256(vs) >> 255) + 27);
        } else {
            return address(0);
        }

        if (uint256(s) > _MAX_VALID_S || (v != 27 && v != 28)) {
            return address(0);
        }
        recovered = ecrecover(digest, v, r, s);
    }
}
