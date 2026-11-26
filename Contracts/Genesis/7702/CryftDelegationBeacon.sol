// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {IBeacon} from "../Upgradeable/Proxy/Beacon/IBeacon.sol";

/// @title CryftDelegationBeacon
/// @notice Shared implementation pointer for Cryft EIP-7702 accounts.
/// @dev Route: user EOA -> immutable dispatcher -> this beacon -> CryftDelegation. The owner is the delegation
///      registry entry 0x…de1E6A7E for the beacon's whole life: a constant set at construction, with no handover
///      and no renounce. Anyone may deploy it. Only the registry changes the implementation, and only through
///      its scheduled, delayed upgrade. No external imports.
/// @custom:version 2.0.0
/// @custom:security-contact security@cryft.cards
contract CryftDelegationBeacon is IBeacon {
    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    address private constant _REGISTRY =
        0x00000000000000000000000000000000de1E6A7E;

    // ─── Storage ─────────────────────────────────────────────────────────────────────────────────

    address private _implementation;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The implementation changed (the same event as OpenZeppelin UpgradeableBeacon, for indexers).
    event Upgraded(address indexed implementation);

    /// @notice Emitted once at construction so indexers see the fixed owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is not the registry.
    error BeaconUnauthorizedAccount(address account);

    /// @notice The implementation is zero, this beacon, or has no code.
    error BeaconInvalidImplementation(address implementation);

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor(address implementation_) {
        _setImplementation(implementation_);
        emit OwnershipTransferred(address(0), _REGISTRY);
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Points the beacon at `newImplementation`. Registry only.
    function upgradeTo(address newImplementation) external {
        if (msg.sender != _REGISTRY) revert BeaconUnauthorizedAccount(msg.sender);
        _setImplementation(newImplementation);
    }

    /// @inheritdoc IBeacon
    function implementation() external view override returns (address) {
        return _implementation;
    }

    /// @notice The only account that may change the implementation.
    function owner() external pure returns (address) {
        return _REGISTRY;
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    function _setImplementation(address newImplementation) private {
        if (
            newImplementation == address(0) ||
            newImplementation == address(this) ||
            newImplementation.code.length == 0
        ) {
            revert BeaconInvalidImplementation(newImplementation);
        }
        _implementation = newImplementation;
        emit Upgraded(newImplementation);
    }
}
