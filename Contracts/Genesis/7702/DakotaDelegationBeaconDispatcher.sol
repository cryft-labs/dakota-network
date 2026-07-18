// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

import "../Upgradeable/Proxy/Beacon/IBeacon.sol";

/// @title DakotaDelegationBeaconDispatcher
/// @notice Immutable bridge from each delegated account's EIP-1967 slot to the
///         shared Dakota delegation beacon.
/// @dev This contract deliberately exposes no function selectors. Every call
///      resolves the beacon implementation and delegates with the caller's
///      original account context and storage.
contract DakotaDelegationBeaconDispatcher {
    error InvalidBeacon(address beacon);
    error InvalidImplementation(address implementation);

    address private immutable _beacon;
    address private immutable _dispatcher;

    constructor(address beacon_) {
        if (beacon_ == address(0) || beacon_.code.length == 0) {
            revert InvalidBeacon(beacon_);
        }
        _beacon = beacon_;
        _dispatcher = address(this);
        _implementation();
    }

    fallback() external payable {
        address implementation_ = _implementation();
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(
                gas(),
                implementation_,
                0,
                calldatasize(),
                0,
                0
            )
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    function _implementation() private view returns (address implementation_) {
        (bool success, bytes memory result) = _beacon.staticcall(
            abi.encodeCall(IBeacon.implementation, ())
        );
        if (!success || result.length != 32) {
            revert InvalidBeacon(_beacon);
        }
        implementation_ = abi.decode(result, (address));
        if (
            implementation_ == address(0) ||
            implementation_ == _beacon ||
            implementation_ == _dispatcher ||
            implementation_.code.length == 0
        ) {
            revert InvalidImplementation(implementation_);
        }
    }
}
