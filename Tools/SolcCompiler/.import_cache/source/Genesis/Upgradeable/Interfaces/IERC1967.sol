// SPDX-License-Identifier: MIT
//
// Based on OpenZeppelin Contracts (last updated v4.9.0) (interfaces/IERC1967.sol).
// Modified for the Dakota Network by Cryft Labs.
//
// WARNING: This is a modified version of the original OpenZeppelin contract.
// Do not assume it is stock or unmodified — review all changes before use.

pragma solidity >=0.8.2 <0.9.0;

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
     * @dev Emitted when the admin account has changed.
     */
    event AdminChanged(address previousAdmin, address newAdmin);

    /**
     * @dev Emitted when the beacon is changed.
     */
    event BeaconUpgraded(address indexed beacon);
}
