// SPDX-License-Identifier: MIT
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// Derived from OpenZeppelin Contracts v4.9.0 (proxy/transparent/ProxyAdmin.sol), MIT.
pragma solidity 0.8.37;

import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "./TransparentUpgradeableProxy.sol";

/// @title ProxyAdmin
/// @notice The ERC-1967 admin of every genesis proxy: runs scheduled upgrades and reports proxy governance state.
/// @dev Baked into genesis at 0x…FacAdE. There is no owner: each proxy is governed by its own controllers. A
///      guardian of a proxy (roots count as guardians) may run an upgrade that was scheduled on that proxy
///      (proxy_scheduleUpgrade) once the network upgrade delay set in 0x…1111 has passed; the proxy checks the
///      schedule.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
contract ProxyAdmin {
    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is not a guardian of the proxy.
    error NotGuardian();
    /// @notice The proxy did not answer an admin read.
    error ProxyReadFailed();
    /// @notice upgradeAndCall needs call data; use upgrade() without it.
    error EmptyInitData();

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    modifier onlyGuardianOf(ITransparentUpgradeableProxy proxy) {
        if (!TransparentUpgradeableProxy(payable(address(proxy))).proxy_isGuardian(msg.sender)) revert NotGuardian();
        _;
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @notice Upgrades `proxy` to the scheduled `implementation` with no call (guardians of `proxy` only).
    /// @dev This contract must be the admin of `proxy`. See {TransparentUpgradeableProxy-upgradeTo}.
    function upgrade(ITransparentUpgradeableProxy proxy, address implementation)
        public
        virtual
        onlyGuardianOf(proxy)
    {
        proxy.upgradeTo(implementation);
    }

    /// @notice Upgrades `proxy` to the scheduled `implementation` and calls it with `data` (guardians of `proxy`
    ///         only).
    /// @dev This contract must be the admin of `proxy`. See {TransparentUpgradeableProxy-upgradeToAndCall}.
    function upgradeAndCall(ITransparentUpgradeableProxy proxy, address implementation, bytes memory data)
        public
        payable
        virtual
        onlyGuardianOf(proxy)
    {
        if (data.length == 0) revert EmptyInitData();
        proxy.upgradeToAndCall{value: msg.value}(implementation, data);
    }

    /// @notice Returns the current implementation of `proxy`.
    /// @dev This contract must be the admin of `proxy`.
    function getProxyImplementation(ITransparentUpgradeableProxy proxy) public view virtual returns (address) {
        // A raw static call, since the dispatched getter cannot be declared view.
        // bytes4(keccak256("implementation()")) == 0x5c60da1b
        (bool success, bytes memory returndata) = address(proxy).staticcall(hex"5c60da1b");
        if (!success) revert ProxyReadFailed();
        return abi.decode(returndata, (address));
    }

    /// @notice Returns the current admin of `proxy`.
    /// @dev This contract must be the admin of `proxy`.
    function getProxyAdmin(ITransparentUpgradeableProxy proxy) public view virtual returns (address) {
        // A raw static call, since the dispatched getter cannot be declared view.
        // bytes4(keccak256("admin()")) == 0xf851a440
        (bool success, bytes memory returndata) = address(proxy).staticcall(hex"f851a440");
        if (!success) revert ProxyReadFailed();
        return abi.decode(returndata, (address));
    }

    /// @notice Returns a snapshot of `proxy`'s governance state for dashboards and monitoring.
    function getProxyGovernanceStatus(ITransparentUpgradeableProxy proxy)
        public
        view
        returns (
            address currentAdmin,
            address currentImplementation,
            bool rootRevoked,
            uint256 overlordCount,
            uint256 guardianCount,
            uint256 overlordThreshold,
            bool votingSessionActive,
            bytes32 activeProposalId,
            uint256 activeProposalStartBlock,
            bool activeProposalExpired,
            uint256 voteEpoch,
            uint256 voteExpiry
        )
    {
        TransparentUpgradeableProxy p = TransparentUpgradeableProxy(payable(address(proxy)));

        // Admin and implementation through raw static calls (admin-only selectors).
        currentAdmin = getProxyAdmin(proxy);
        currentImplementation = getProxyImplementation(proxy);

        rootRevoked = p.proxy_isRootOverlordRevoked();
        overlordCount = p.proxy_getOverlordCount();
        guardianCount = p.proxy_getGuardianCount();
        overlordThreshold = p.proxy_getOverlordThreshold();

        votingSessionActive = p.proxy_isVotingSessionActive();
        (activeProposalId, activeProposalStartBlock, activeProposalExpired) = p.proxy_getActiveProposal();

        voteEpoch = p.proxy_getVoteEpoch();
        voteExpiry = p.proxy_getVoteExpiry();
    }

    /// @notice Returns the guardians of `proxy`.
    function getProxyGuardians(ITransparentUpgradeableProxy proxy) public view returns (address[] memory) {
        return TransparentUpgradeableProxy(payable(address(proxy))).proxy_getGuardians();
    }
}
