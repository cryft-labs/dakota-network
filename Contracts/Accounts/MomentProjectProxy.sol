// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/proxy/transparent/ProxyAdmin.sol";

/// @dev Separate admin contract keeps the owner's application calls transparent.
contract MomentProjectAdmin is ProxyAdmin {
    address public pendingOwner;
    event OwnershipTransferStarted(address indexed owner, address indexed candidate);
    constructor(address admin) { require(admin != address(0), "zero admin"); _transferOwnership(admin); }
    function renounceOwnership() public override onlyOwner { revert("renounce disabled"); }
    function transferOwnership(address candidate) public override onlyOwner {
        require(candidate != address(0), "zero owner"); pendingOwner = candidate; emit OwnershipTransferStarted(owner(), candidate);
    }
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "pending owner"); pendingOwner = address(0); _transferOwnership(msg.sender);
    }
}
contract MomentProjectProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address admin, bytes memory initialization)
        TransparentUpgradeableProxy(implementation, admin, initialization) {
        require(initialization.length > 0 && admin.code.length > 0, "atomic initialization and admin required");
    }
}
