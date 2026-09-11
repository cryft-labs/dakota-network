// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Test-only capability probe. No authorization or asset-handling policy.
/// Never use this contract as a production delegated wallet.
contract DelegationProbe {
    uint256 public value;
    address public lastCaller;
    function write(uint256 next) external { value = next; lastCaller = msg.sender; }
    function marker() external pure returns (bytes32) { return keccak256("kota-private-delegation-test"); }
    function codeOf(address target) external view returns (bytes memory) { return target.code; }
    function readFrom(address target) external view returns (bool ok, bytes memory data) {
        return target.staticcall(abi.encodeWithSignature("value()"));
    }
    function delegateTo(address implementation, uint256 next) external {
        (bool ok, bytes memory data) = implementation.delegatecall(abi.encodeWithSignature("write(uint256)", next));
        if (!ok) { assembly ("memory-safe") { revert(add(data,32),mload(data)) } }
    }
}
