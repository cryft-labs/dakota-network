// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProxyAdmin} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/access/Ownable.sol";
import {Ownable2Step} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/access/Ownable2Step.sol";
import {TransparentUpgradeableProxy} from "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Local authority for an application proxy, including inside Pente.
/// @dev Does not call the public chain's validator registry from private state.
contract ManagedProxyAdmin is ProxyAdmin, Ownable2Step {
    constructor(address initialOwner) {
        require(initialOwner != address(0) && initialOwner != address(this), "Invalid owner");
        _transferOwnership(initialOwner);
    }

    function transferOwnership(address next) public override(Ownable, Ownable2Step) onlyOwner {
        require(next != address(0) && next != address(this) && next != owner(), "Invalid owner");
        super.transferOwnership(next);
    }

    function renounceOwnership() public override onlyOwner {
        revert("Ownership must be transferred");
    }

    function _transferOwnership(address next) internal override(Ownable, Ownable2Step) {
        super._transferOwnership(next);
    }
}

/// @notice Standard OZ transparent proxy with mandatory atomic initialization.
contract ManagedApplicationProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address admin, bytes memory initializer)
        TransparentUpgradeableProxy(implementation, admin, initializer)
    {
        require(admin.code.length != 0 && initializer.length != 0, "Atomic managed initialization required");
    }
}
