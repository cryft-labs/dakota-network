// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity >=0.8.19 <0.9.0;

/// @title GovernanceMembers
/// @notice Bounded membership reads shared by the validator contract, the genesis proxy shell and the managers.
/// @dev Lists hold at most MAX_MEMBERS addresses and read at most MAX_PROVIDERS providers. A provider that fails
///      to answer makes the read revert, so a failed provider never silently removes members. Compiled by the
///      validator contract with solc 0.8.19, so it uses no newer syntax.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
library GovernanceMembers {
    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @dev Most members in one list (local or one provider's answer).
    uint256 internal constant MAX_MEMBERS = 64;
    /// @dev Most providers read for one list.
    uint256 internal constant MAX_PROVIDERS = 16;
    /// @dev Gas forwarded to one provider read.
    uint256 internal constant PROVIDER_GAS = 300000;

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A member is the zero address, this contract or the ProxyAdmin.
    error InvalidMember();
    /// @notice A list or provider set is over its cap.
    error TooManyMembers();
    /// @notice A provider is this contract, has no code or is listed twice.
    error InvalidProvider(address provider);
    /// @notice A provider call failed or returned a malformed list.
    error ProviderReadFailed(address provider);

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @dev Reads one provider's list without copying unbounded return data. Bounded by MAX_MEMBERS.
    function read(address provider, bytes4 selector) internal view returns (address[] memory members) {
        if (provider == address(this) || provider.code.length == 0) revert InvalidProvider(provider);
        bytes memory input = abi.encodeWithSelector(selector);
        bool success;
        uint256 size;
        // Do not allocate or copy unbounded return data from a provider.
        assembly ("memory-safe") {
            success := staticcall(PROVIDER_GAS, provider, add(input, 32), mload(input), 0, 0)
            size := returndatasize()
        }
        if (!success || size < 64 || size > 64 + 32 * MAX_MEMBERS) revert ProviderReadFailed(provider);
        bytes memory data = new bytes(size);
        assembly ("memory-safe") { returndatacopy(add(data, 32), 0, size) }
        uint256 offset;
        uint256 count;
        assembly ("memory-safe") { offset := mload(add(data, 32)) count := mload(add(data, 64)) }
        if (offset != 32 || count > MAX_MEMBERS || size != 64 + count * 32) revert ProviderReadFailed(provider);
        members = abi.decode(data, (address[]));
        for (uint256 i; i < members.length; ++i) if (members[i] == address(0)) revert InvalidMember();
    }

    /// @dev Union of the local list and every provider's list, deduplicated and sorted. Bounded by
    ///      MAX_PROVIDERS providers and MAX_MEMBERS results.
    function collect(address[] memory local, address[] memory providers, bytes4 selector)
        internal
        view
        returns (address[] memory result)
    {
        if (providers.length > MAX_PROVIDERS) revert TooManyMembers();
        result = new address[](MAX_MEMBERS);
        uint256 count = _append(result, 0, local);
        for (uint256 i; i < providers.length; ++i) {
            for (uint256 j; j < i; ++j) if (providers[j] == providers[i]) revert InvalidProvider(providers[i]);
            count = _append(result, count, read(providers[i], selector));
        }
        assembly ("memory-safe") { mstore(result, count) }
        // Canonical order makes electorate fingerprints independent of provider order.
        for (uint256 i = 1; i < count; ++i) {
            address item = result[i];
            uint256 j = i;
            while (j > 0 && result[j - 1] > item) { result[j] = result[j - 1]; --j; }
            result[j] = item;
        }
    }

    /// @dev Proxy roots and local controllers each keep their own 64-member limit, so their union can hold
    ///      128 unique members: a root update upstream must not strand valid local proxy governance.
    function combineControllers(address[] memory local, address[] memory roots)
        internal
        view
        returns (address[] memory result)
    {
        result = new address[](2 * MAX_MEMBERS);
        uint256 count = _append(result, 0, local);
        count = _append(result, count, roots);
        assembly ("memory-safe") { mstore(result, count) }
        for (uint256 i = 1; i < count; ++i) {
            address item = result[i];
            uint256 j = i;
            while (j > 0 && result[j - 1] > item) { result[j] = result[j - 1]; --j; }
            result[j] = item;
        }
    }

    /// @dev Membership test over a bounded list.
    function contains(address[] memory members, address member) internal pure returns (bool) {
        for (uint256 i; i < members.length; ++i) if (members[i] == member) return true;
        return false;
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    /// @dev Appends unique valid members to `result`. Bounded by MAX_MEMBERS and the length of `result`.
    function _append(address[] memory result, uint256 count, address[] memory members)
        private
        view
        returns (uint256)
    {
        if (members.length > MAX_MEMBERS) revert TooManyMembers();
        for (uint256 i; i < members.length; ++i) {
            address member = members[i];
            if (
                member == address(0) || member == address(this)
                    || member == 0x0000000000000000000000000000000000FacAdE
            ) revert InvalidMember();
            bool found;
            for (uint256 j; j < count; ++j) {
                if (result[j] == member) { found = true; break; }
            }
            if (!found) {
                if (count == result.length) revert TooManyMembers();
                result[count++] = member;
            }
        }
        return count;
    }
}
