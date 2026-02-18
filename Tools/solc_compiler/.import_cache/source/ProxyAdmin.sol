// SPDX-License-Identifier: MIT
//
// Based on OpenZeppelin Contracts v4.9.0 (proxy/transparent/ProxyAdmin.sol).
// Modified by Cryft Labs — guardian/overlord governance replaces single-owner pattern.
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.

pragma solidity ^0.8.0;

import "./TransparentUpgradeableProxy.sol";

/*
  ┌──────────────── Contract Architecture ──────────────────────┐
  │                                                             │
  │  Auxiliary contract assigned as the ERC1967 admin of        │
  │  TransparentUpgradeableProxy instances.                     │
  │                                                             │
  │  Replaces OpenZeppelin's single-owner pattern with          │
  │  per-proxy guardian/overlord governance.                    │
  │                                                             │
  │  Access control:                                            │
  │    Guardian — upgrade proxy implementation                  │
  │    Overlord — change admin via threshold vote on proxy      │
  │                                                             │
  │  Provides:                                                  │
  │    - upgrade() / upgradeAndCall() — guardian-gated          │
  │    - getProxyGovernanceStatus()   — full state snapshot     │
  │    - getProxyGuardians()          — guardian enumeration    │
  │    - getProxyAdmin/Implementation — admin introspection     │
  │                                                             │
  │  Each proxy is independently governed by its own            │
  │  controller set — no single-owner bottleneck.               │
  └─────────────────────────────────────────────────────────────┘
*/
contract ProxyAdmin {

    modifier onlyGuardianOf(ITransparentUpgradeableProxy proxy) {
        require(
            TransparentUpgradeableProxy(payable(address(proxy))).proxy_isGuardian(msg.sender),
            "ProxyAdmin: caller is not a guardian of this proxy"
        );
        _;
    }

    /**
     * @dev Returns the current implementation of `proxy`.
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     */
    function getProxyImplementation(
        ITransparentUpgradeableProxy proxy
    ) public view virtual returns (address) {
        // We need to manually run the static call since the getter cannot be flagged as view
        // bytes4(keccak256("implementation()")) == 0x5c60da1b
        (bool success, bytes memory returndata) = address(proxy).staticcall(
            hex"5c60da1b"
        );
        require(success, "ProxyAdmin: implementation() call failed");
        return abi.decode(returndata, (address));
    }

    /**
     * @dev Returns the current admin of `proxy`.
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     */
    function getProxyAdmin(
        ITransparentUpgradeableProxy proxy
    ) public view virtual returns (address) {
        // We need to manually run the static call since the getter cannot be flagged as view
        // bytes4(keccak256("admin()")) == 0xf851a440
        (bool success, bytes memory returndata) = address(proxy).staticcall(
            hex"f851a440"
        );
        require(success, "ProxyAdmin: admin() call failed");
        return abi.decode(returndata, (address));
    }

    /**
     * @dev Returns a governance status snapshot for `proxy`.
     *      Useful for dashboards, monitoring, and quick review of the proxy's state.
     */
    function getProxyGovernanceStatus(
        ITransparentUpgradeableProxy proxy
    )
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

        // Admin and implementation via raw staticcall (admin-only selectors)
        currentAdmin = getProxyAdmin(proxy);
        currentImplementation = getProxyImplementation(proxy);

        // Governance state
        rootRevoked = p.proxy_isRootOverlordRevoked();
        overlordCount = p.proxy_getOverlordCount();
        guardianCount = p.proxy_getGuardianCount();
        overlordThreshold = p.proxy_getOverlordThreshold();

        // Voting session
        votingSessionActive = p.proxy_isVotingSessionActive();
        (activeProposalId, activeProposalStartBlock, activeProposalExpired) = p.proxy_getActiveProposal();

        // Epoch and expiry
        voteEpoch = p.proxy_getVoteEpoch();
        voteExpiry = p.proxy_getVoteExpiry();
    }

    /**
     * @dev Upgrades `proxy` to `implementation`. See {TransparentUpgradeableProxy-upgradeTo}.
     *      Restricted to guardians of the proxy (operational-level action).
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     * - Caller must be a guardian of `proxy`.
     */
    function upgrade(
        ITransparentUpgradeableProxy proxy,
        address implementation
    ) public virtual onlyGuardianOf(proxy) {
        proxy.upgradeTo(implementation);
    }

    /**
     * @dev Upgrades `proxy` to `implementation` and calls a function on the new implementation. See
     * {TransparentUpgradeableProxy-upgradeToAndCall}.
     *      Restricted to guardians of the proxy (operational-level action).
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     * - Caller must be a guardian of `proxy`.
     */
    function upgradeAndCall(
        ITransparentUpgradeableProxy proxy,
        address implementation,
        bytes memory data
    ) public payable virtual onlyGuardianOf(proxy) {
        proxy.upgradeToAndCall{value: msg.value}(implementation, data);
    }

    /**
     * @dev Returns the list of guardians for `proxy`.
     */
    function getProxyGuardians(
        ITransparentUpgradeableProxy proxy
    ) public view returns (address[] memory) {
        return TransparentUpgradeableProxy(payable(address(proxy))).proxy_getGuardians();
    }
}
