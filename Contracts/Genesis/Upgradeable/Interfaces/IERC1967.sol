// SPDX-License-Identifier: MIT
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// Derived from OpenZeppelin Contracts v4.9.0 (interfaces/IERC1967.sol), MIT.
pragma solidity 0.8.37;

/**
 * @dev ERC-1967: Proxy Storage Slots. This interface contains the events defined in the ERC.
 *
 * _Available since v4.8.3._
 */
interface IERC1967 {
    /**
     * @dev Emitted when the implementation is upgraded.
     */
    event Upgraded(address indexed implementation);

    /**
     * @dev Emitted when the beacon is changed.
     */
    event BeaconUpgraded(address indexed beacon);
}
