// SPDX-License-Identifier: MIT
//
// Based on OpenZeppelin Contracts (last updated v4.5.0) (interfaces/draft-IERC1822.sol).
// Modified for the Dakota Network by Cryft Labs.
//
// WARNING: This is a modified version of the original OpenZeppelin contract.
// Do not assume it is stock or unmodified — review all changes before use.

pragma solidity >=0.8.2 <0.9.0;

/**
 * @dev ERC1822: Universal Upgradeable Proxy Standard (UUPS) documents a method for upgradeability through a simplified
 * proxy whose upgrades are fully controlled by the current implementation.
 */
interface IERC1822Proxiable {
    /**
     * @dev Returns the storage slot that the proxiable contract assumes is being used to store the implementation
     * address.
     *
     * IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks
     * bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this
     * function revert if invoked through a proxy.
     */
    function proxiableUUID() external view returns (bytes32);
}
