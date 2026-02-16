// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./TransparentUpgradeableProxy.sol";

/**
 * @dev Auxiliary contract assigned as the admin of {TransparentUpgradeableProxy} instances.
 *      Instead of a single owner, each proxy's own guardian/overlord sets
 *      (defined on TransparentUpgradeableProxy) control upgrade authority.
 *
 *      - Guardians of a proxy can upgrade its implementation.
 *      - Overlords of a proxy change the admin via proposeAdminChange() on the proxy itself
 *        (2/3 threshold vote). This contract no longer exposes a direct changeProxyAdmin.
 *
 *      This eliminates the single-owner bottleneck and allows each proxy
 *      to be independently governed by its own controller set.
 */
contract ProxyAdmin {

    modifier onlyGuardianOf(ITransparentUpgradeableProxy proxy) {
        require(
            TransparentUpgradeableProxy(payable(address(proxy))).isGuardian(msg.sender),
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
        require(success);
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
        require(success);
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
        rootRevoked = p.isRootOverlordRevoked();
        overlordCount = p.getOverlordCount();
        guardianCount = p.getGuardianCount();
        overlordThreshold = p.getOverlordThreshold();

        // Voting session
        votingSessionActive = p.isVotingSessionActive();
        (activeProposalId, activeProposalStartBlock, activeProposalExpired) = p.getActiveProposal();

        // Epoch and expiry
        voteEpoch = p.getVoteEpoch();
        voteExpiry = p.getVoteExpiry();
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
        return TransparentUpgradeableProxy(payable(address(proxy))).getGuardians();
    }
}
