// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Development-only target for verifying committed-recipient delivery recovery.
/// @dev Never leave this implementation linked after the bounded acceptance test.
contract DeliveryFailureProbe {
    fallback() external { revert("Development delivery failure"); }
}
