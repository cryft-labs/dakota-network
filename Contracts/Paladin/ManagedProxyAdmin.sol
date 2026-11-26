// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {Ownable} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/access/Ownable.sol";
import {Ownable2Step} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/access/Ownable2Step.sol";
import {ProxyAdmin} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title ManagedProxyAdmin
/// @notice Local authority for an application proxy, including inside a Pente privacy group.
/// @dev Ownership moves only by the two-step handover and can never be renounced. Does not call the public chain's
///      validator contract from private state. Built for EVM Shanghai (Pente).
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
contract ManagedProxyAdmin is ProxyAdmin, Ownable2Step {
    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The owner is the zero address, this contract, or already the owner.
    error InvalidOwner();
    /// @notice Ownership cannot be renounced; it must be transferred.
    error RenounceDisabled();

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor(address initialOwner) {
        if (initialOwner == address(0) || initialOwner == address(this)) revert InvalidOwner();
        _transferOwnership(initialOwner);
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @notice Starts a two-step ownership handover to `next`, who must accept it.
    function transferOwnership(address next) public override(Ownable, Ownable2Step) onlyOwner {
        if (next == address(0) || next == address(this) || next == owner()) revert InvalidOwner();
        super.transferOwnership(next);
    }

    /// @notice Always reverts: ownership must be transferred, never renounced.
    function renounceOwnership() public override onlyOwner {
        revert RenounceDisabled();
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    function _transferOwnership(address next) internal override(Ownable, Ownable2Step) {
        super._transferOwnership(next);
    }
}

/// @title ManagedApplicationProxy
/// @notice Standard OpenZeppelin transparent proxy that must be initialized in its constructor.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
contract ManagedApplicationProxy is TransparentUpgradeableProxy {
    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The admin has no code or the initializer data is empty.
    error AtomicInitializationRequired();

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor(address implementation, address admin, bytes memory initializer)
        TransparentUpgradeableProxy(implementation, admin, initializer)
    {
        if (admin.code.length == 0 || initializer.length == 0) revert AtomicInitializationRequired();
    }
}
