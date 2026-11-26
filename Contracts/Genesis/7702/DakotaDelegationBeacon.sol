// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/*
  ___       _        _          ___
 |   \ __ _| | _____| |_ __ _  | _ ) ___ __ _ __ ___ _ _
 | |) / _` | |/ / _ \  _/ _` | | _ \/ -_) _` / _/ _ \ ' \
 |___/\__,_|_|\_\___/\__\__,_| |___/\___\__,_\__\___/_||_|
                                              By: CryftCreator

  Version 2.0.0 - Production Dakota Delegation Beacon
  [REGISTRY-OWNED FROM CONSTRUCTION]

  +-------------------- Contract Architecture --------------------+
  |                                                               |
  |  NATIVE EIP-7702 SHARED IMPLEMENTATION CONTROL                |
  |                                                               |
  |  Ownership (audit X-2):                                       |
  |    - owner is the fixed registry entry 0x0000...de1E6A7E,     |
  |      a constant set at construction; anyone may deploy        |
  |    - no EOA-owner window, no handover, no renounce            |
  |    - only the registry may change the implementation, and     |
  |      the registry does so only through its two-phase,         |
  |      delayed schedule/execute upgrade                         |
  |                                                               |
  |  Delegated-account route:                                     |
  |    user EOA -> immutable dispatcher                           |
  |    -> this beacon -> DakotaDelegation implementation          |
  |                                                               |
  |  Self-contained (audit L-4): no OpenZeppelin URL import.      |
  +---------------------------------------------------------------+
*/

import "../Upgradeable/Proxy/Beacon/IBeacon.sol";

/// @title DakotaDelegationBeacon
/// @notice Shared implementation pointer for Dakota EIP-7702 accounts.
/// @dev The owner is the delegation registry entry for the beacon's whole life.
contract DakotaDelegationBeacon is IBeacon {
    error BeaconUnauthorizedAccount(address account);
    error BeaconInvalidImplementation(address implementation);

    /// @dev Same event as OpenZeppelin UpgradeableBeacon, for explorers/indexers.
    event Upgraded(address indexed implementation);
    /// @dev Emitted once at construction so indexers see the fixed owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    address private constant _REGISTRY =
        0x00000000000000000000000000000000de1E6A7E;

    address private _implementation;

    constructor(address implementation_) {
        _setImplementation(implementation_);
        emit OwnershipTransferred(address(0), _REGISTRY);
    }

    /// @inheritdoc IBeacon
    function implementation() external view override returns (address) {
        return _implementation;
    }

    /// @notice The only account that may change the implementation.
    function owner() external pure returns (address) {
        return _REGISTRY;
    }

    /// @notice Registry-only implementation change.
    function upgradeTo(address newImplementation) external {
        if (msg.sender != _REGISTRY) {
            revert BeaconUnauthorizedAccount(msg.sender);
        }
        _setImplementation(newImplementation);
    }

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
