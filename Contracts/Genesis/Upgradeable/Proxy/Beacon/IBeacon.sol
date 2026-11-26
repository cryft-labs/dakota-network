// SPDX-License-Identifier: MIT
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// Derived from OpenZeppelin Contracts v4.4.1 (proxy/beacon/IBeacon.sol), MIT.
pragma solidity 0.8.37;

/**
 * @dev This is the interface that {BeaconProxy} expects of its beacon.
 */
interface IBeacon {
    /**
     * @dev Must return an address that can be used as a delegate call target.
     *
     * {BeaconProxy} will check that this address is a contract.
     */
    function implementation() external view returns (address);
}
