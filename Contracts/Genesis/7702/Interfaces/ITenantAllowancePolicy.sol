// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.20 <0.9.0;

/// @notice Optional, tenant-scoped accounting. A policy never receives native funds.
interface ITenantAllowancePolicy {
    function gasSponsor() external view returns (address);
    function sponsor() external view returns (address);
    function reserve(bytes32 operationId, address wallet, uint256 maximumCost) external returns (bytes4);
    function settle(bytes32 operationId, uint256 chargedCost) external returns (bytes4);
}
