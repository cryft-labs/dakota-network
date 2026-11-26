// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {IBeacon} from "../Upgradeable/Proxy/Beacon/IBeacon.sol";

/// @title CryftBeaconDispatcher
/// @notice Immutable route from an EIP-7702 account to its shared beacon (direct dispatch, protocol v2).
/// @dev Route: user EOA -> this dispatcher -> shared beacon -> CryftDelegation. The EIP-7702 authorization
///      designates this deployed dispatcher directly: there is no per-account EIP-1967 link or initializer, and
///      immutables work in the account's execution context. `delegationBeacon()` and `dispatcherProtocolId()`
///      expose the route; every other selector is delegated with the account's caller, value and storage.
///      Beacon and implementation code are checked on every call, and direct cycles are refused.
/// @custom:version 2.0.0
/// @custom:security-contact security@cryft.cards
contract CryftBeaconDispatcher {
    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    address private immutable _BEACON;
    address private immutable _DISPATCHER;

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The beacon has no code or did not answer `implementation()` with one word.
    error InvalidBeacon(address beacon);

    /// @notice The beacon's implementation is zero, the beacon, this dispatcher, or has no code.
    error InvalidImplementation(address implementation);

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor(address beacon) {
        if (beacon == address(0) || beacon.code.length == 0) revert InvalidBeacon(beacon);
        _BEACON = beacon;
        _DISPATCHER = address(this);
        _implementation();
    }

    // ─── receive / fallback ──────────────────────────────────────────────────────────────────────

    /// @notice Delegates the call to the beacon's current implementation in the account's context.
    fallback() external payable {
        address implementation = _implementation();
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            calldatacopy(pointer, 0, calldatasize())
            let result := delegatecall(gas(), implementation, pointer, calldatasize(), 0, 0)
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

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice The shared beacon this dispatcher routes to.
    function delegationBeacon() external view returns (address) {
        return _BEACON;
    }

    /// @notice The route's protocol id.
    function dispatcherProtocolId() external pure returns (bytes32) {
        return keccak256("cryft.delegation.direct-beacon-dispatch.v2");
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    function _implementation() private view returns (address implementation) {
        (bool success, bytes memory result) = _BEACON.staticcall(abi.encodeCall(IBeacon.implementation, ()));
        if (!success || result.length != 32) revert InvalidBeacon(_BEACON);
        implementation = abi.decode(result, (address));
        if (
            implementation == address(0) ||
            implementation == _BEACON ||
            implementation == _DISPATCHER ||
            implementation.code.length == 0
        ) {
            revert InvalidImplementation(implementation);
        }
    }
}
