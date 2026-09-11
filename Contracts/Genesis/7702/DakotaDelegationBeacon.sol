// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.
//
// Uses OpenZeppelin Contracts v5.2.0 UpgradeableBeacon (MIT).

pragma solidity >=0.8.20 <0.9.0;

/*
  ___       _        _          ___
 |   \ __ _| | _____| |_ __ _  | _ ) ___ __ _ __ ___ _ _
 | |) / _` | |/ / _ \  _/ _` | | _ \/ -_) _` / _/ _ \ ' \
 |___/\__,_|_|\_\___/\__\__,_| |___/\___\__,_\__\___/_||_|
                                              By: CryftCreator

  Version 1.0.0 - Production Dakota Delegation Beacon
  [ROOT-VALIDATED SHARED UPGRADE BEACON]

  +-------------------- Contract Architecture --------------------+
  |                                                               |
  |  NATIVE EIP-7702 SHARED IMPLEMENTATION CONTROL                |
  |                                                               |
  |  Bootstrap authority:                                         |
  |    - constructor accepts only the delegation implementation   |
  |    - deployer must be a live root reported by 0x0000...1111   |
  |    - failed or unavailable root validation rejects deployment |
  |    - validated deployer becomes the temporary beacon owner    |
  |                                                               |
  |  Registry handoff:                                            |
  |    - ownership moves to fixed entry 0x0000...de1E6A7E         |
  |    - Registry validates protocol, capabilities, and code hash |
  |    - accepted upgrades are activated and recorded atomically  |
  |                                                               |
  |  Delegated-account route:                                     |
  |    user EOA -> immutable dispatcher          |
  |    -> this beacon -> DakotaDelegation implementation          |
  |                                                               |
  |  Security and storage:                                        |
  |    - OpenZeppelin UpgradeableBeacon validates implementation  |
  |    - no proxy initializer or migration surface                |
  |    - ownership must not be renounced                          |
  |                                                               |
  +---------------------------------------------------------------+
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.2.0/contracts/proxy/beacon/UpgradeableBeacon.sol";

interface IDakotaDelegationBeaconRootRegistry {
    function isRootOverlord(address account) external view returns (bool);
}

/// @title DakotaDelegationBeacon
/// @notice Shared implementation authority for Dakota EIP-7702 accounts.
/// @dev The deployer must be a live root overlord reported by the canonical
///      validator registry. The validated deployer is the temporary owner
///      until ownership moves to the fixed delegation registry entry.
contract DakotaDelegationBeacon is UpgradeableBeacon {
    error NotRootOverlord(address caller);
    error InvalidOwnershipTransfer();
    error OwnershipRenunciationDisabled();
    address private _pendingOwner;
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    address private constant _VALIDATOR_ROOT_REGISTRY =
        0x0000000000000000000000000000000000001111;

    constructor(
        address implementation_
    ) UpgradeableBeacon(implementation_, msg.sender) {
        if (!_isRootOverlord(msg.sender)) {
            revert NotRootOverlord(msg.sender);
        }
    }

    function validatorRootRegistry() external pure returns (address) {
        return _VALIDATOR_ROOT_REGISTRY;
    }

    /// @notice Ownership stays with the current controller until the recipient accepts.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0) || newOwner == address(this) || newOwner == owner()) revert InvalidOwnershipTransfer();
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    function pendingOwner() external view returns (address) { return _pendingOwner; }

    function acceptOwnership() external {
        if (msg.sender != _pendingOwner) revert InvalidOwnershipTransfer();
        _pendingOwner = address(0);
        _transferOwnership(msg.sender);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        _pendingOwner = address(0);
        emit OwnershipTransferStarted(owner(), address(0));
    }

    /// @notice Permanent loss of the shared account-upgrade controller is disallowed.
    function renounceOwnership() public override onlyOwner { revert OwnershipRenunciationDisabled(); }

    function _isRootOverlord(address caller) private view returns (bool) {
        try IDakotaDelegationBeaconRootRegistry(
            _VALIDATOR_ROOT_REGISTRY
        ).isRootOverlord(caller) returns (bool authorized) {
            return authorized;
        } catch {
            return false;
        }
    }
}
