// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.19 <0.9.0;

/// @dev Shared, bounded membership reads. Failed providers never silently remove voters.
library GovernanceMembers {
    uint256 internal constant MAX_MEMBERS = 64;
    uint256 internal constant MAX_PROVIDERS = 16;
    uint256 internal constant PROVIDER_GAS = 300000;
    error InvalidMember();
    error TooManyMembers();
    error InvalidProvider(address provider);
    error ProviderReadFailed(address provider);

    function contains(address[] memory members, address member) internal pure returns (bool) {
        for (uint256 i; i < members.length; ++i) if (members[i] == member) return true;
        return false;
    }

    function read(address provider, bytes4 selector) internal view returns (address[] memory members) {
        if (provider == address(this) || provider.code.length == 0) revert InvalidProvider(provider);
        bytes memory input = abi.encodeWithSelector(selector);
        bool success;
        uint256 size;
        // Do not allocate/copy unbounded return data from a provider.
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

    function collect(address[] memory local, address[] memory providers, bytes4 selector)
        internal view returns (address[] memory result)
    {
        if (providers.length > MAX_PROVIDERS) revert TooManyMembers();
        result = new address[](MAX_MEMBERS);
        uint256 count = append(result, 0, local);
        for (uint256 i; i < providers.length; ++i) {
            for (uint256 j; j < i; ++j) if (providers[j] == providers[i]) revert InvalidProvider(providers[i]);
            count = append(result, count, read(providers[i], selector));
        }
        assembly ("memory-safe") { mstore(result, count) }
        // Canonical order makes electorate fingerprints independent of provider ordering.
        for (uint256 i = 1; i < count; ++i) {
            address item = result[i];
            uint256 j = i;
            while (j > 0 && result[j - 1] > item) { result[j] = result[j - 1]; --j; }
            result[j] = item;
        }
    }

    function append(address[] memory result, uint256 count, address[] memory members)
        private view returns (uint256)
    {
        if (members.length > MAX_MEMBERS) revert TooManyMembers();
        for (uint256 i; i < members.length; ++i) {
            address member = members[i];
            if (member == address(0) || member == address(this)
                || member == 0x0000000000000000000000000000000000FacAdE) revert InvalidMember();
            bool found;
            for (uint256 j; j < count; ++j) if (result[j] == member) { found = true; break; }
            if (!found) {
                if (count == MAX_MEMBERS) revert TooManyMembers();
                result[count++] = member;
            }
        }
        return count;
    }
}
