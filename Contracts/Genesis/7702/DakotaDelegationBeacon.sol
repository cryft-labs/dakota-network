// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.
//
// Uses OpenZeppelin Contracts v5.2.0 UpgradeableBeacon (MIT).

pragma solidity >=0.8.20 <0.9.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.2.0/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title DakotaDelegationBeacon
/// @notice Shared implementation authority for Dakota EIP-7702 accounts.
/// @dev Deploy with the retained Dakota root authority as initial owner.
contract DakotaDelegationBeacon is UpgradeableBeacon {
    constructor(
        address implementation_,
        address initialOwner_
    ) UpgradeableBeacon(implementation_, initialOwner_) {}
}
