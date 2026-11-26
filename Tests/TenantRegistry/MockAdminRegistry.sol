// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cryft Labs
pragma solidity ^0.8.24;

/// Test only: the platform access registry's policy ABI (IKotaAdminRegistry) with settable answers.
contract MockAdminRegistry {
    mapping(address => uint8) public roleOf;
    mapping(address => uint32) public tierOf;
    mapping(uint32 => bool) public tierActive;
    mapping(uint32 => uint256) public maxRegistriesOfTier;
    mapping(uint32 => uint256) public maxHoldersOfTier;
    mapping(uint32 => uint256) public tierFeatures;

    function set(address holder, uint8 role, uint32 tier) external {
        roleOf[holder] = role;
        tierOf[holder] = tier;
    }

    function setTier(uint32 tier, bool active, uint256 maxRegistries, uint256 maxHolders, uint256 features) external {
        tierActive[tier] = active;
        maxRegistriesOfTier[tier] = maxRegistries;
        maxHoldersOfTier[tier] = maxHolders;
        tierFeatures[tier] = features;
    }

    function tierLimits(uint32 tier) external view returns (uint256, uint256) {
        return (maxRegistriesOfTier[tier], maxHoldersOfTier[tier]);
    }

    function balanceOf(address holder) external view returns (uint256) {
        return roleOf[holder] == 0 ? 0 : 1;
    }

    function hasRole(address holder, uint8 minimumRole) external view returns (bool) {
        return roleOf[holder] != 0 && roleOf[holder] >= minimumRole;
    }
}
