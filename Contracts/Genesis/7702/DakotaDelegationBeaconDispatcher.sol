// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/*
Dakota direct delegation dispatcher, protocol v2 (immutable).
User EOA -> immutable dispatcher -> shared beacon -> DakotaDelegation.
The EIP-7702 authorization designates this deployed dispatcher directly. There is
no per-account EIP-1967 link or initializer. Immutable configuration works in the
EOA's execution context. delegationBeacon() and dispatcherProtocolId() expose
the route; other selectors delegate with the account's caller, value and storage.
The dispatcher validates beacon/implementation code and rejects direct cycles.
*/

import "../Upgradeable/Proxy/Beacon/IBeacon.sol";

/// @title DakotaDelegationBeaconDispatcher
/// @notice Immutable route from an EIP-7702 account to its shared beacon.
/// @dev Configuration getters read immutables; fallback resolves the shared logic
///      and delegates in the original account context without account linking.
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

    /// @notice Read immutable routing configuration on the dispatcher itself.
    function delegationBeacon() external view returns (address) { return _beacon; }
    function dispatcherProtocolId() external pure returns (bytes32) {
        return keccak256("dakota.delegation.direct-beacon-dispatch.v2");
    }

    fallback() external payable {
        address implementation_ = _implementation();
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            calldatacopy(pointer, 0, calldatasize())
            let result := delegatecall(
                gas(),
                implementation_,
                pointer,
                calldatasize(),
                0,
                0
            )
            returndatacopy(pointer, 0, returndatasize())
            switch result
            case 0 {
                revert(pointer, returndatasize())
            }
            default {
                return(pointer, returndatasize())
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
