// SPDX-License-Identifier: MIT
//
// Based on OpenZeppelin Contracts v4.4.1 (proxy/beacon/IBeacon.sol).
// Modified for the Dakota Network by Cryft Labs.
//
// WARNING: This is a modified version of the original OpenZeppelin contract.
// Do not assume it is stock or unmodified — review all changes before use.

pragma solidity >=0.8.2 <0.9.0;

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
