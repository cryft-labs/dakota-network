// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

import "./ICryftDelegation.sol";

/// @title ICryftDelegationRegistry
/// @notice Authoritative release and readiness view for Cryft EIP-7702.
interface ICryftDelegationRegistry {
    struct Release {
        uint64 sequence;
        uint64 activationBlock;
        uint64 activationTimestamp;
        address implementation;
        bytes32 implementationCodeHash;
        bytes32 protocolId;
        uint256 capabilities;
        string version;
    }

    struct DelegationSnapshot {
        address delegationEntry;
        bytes32 delegationEntryCodeHash;
        bytes32 expectedAccountCodeHash;
        address dispatcher;
        address beacon;
        address beaconOwner;
        address registryImplementation;
        string registryVersion;
        address implementation;
        bytes32 implementationCodeHash;
        bytes32 protocolId;
        uint256 capabilities;
        string version;
        bool implementationCompatible;
        bool registryControlsBeacon;
        bool sponsorUsesDelegationEntry;
        bool matchesLatestRelease;
    }

    struct AccountStatus {
        bool delegatedToEntry;
        bool proxyInitialized;
        bool protocolCompatible;
        bool interfaceCompatible;
        bool sponsorReady;
        uint256 nonce;
        bytes32 protocolId;
        uint256 capabilities;
        string implementationVersion;
    }

    event RegistryInitialized(
        address indexed dispatcher,
        address indexed beacon,
        address indexed gasSponsor,
        address initialRootAdmin,
        bytes32 protocolId
    );

    event RegistryAdminTransferProposed(
        address indexed currentAdmin,
        address indexed pendingAdmin
    );

    event RegistryAdminTransferred(
        address indexed previousAdmin,
        address indexed newAdmin
    );

    event DelegationReleaseRecorded(
        uint64 indexed sequence,
        address indexed implementation,
        bytes32 indexed implementationCodeHash,
        bytes32 protocolId,
        uint256 capabilities,
        string version
    );

    /// @notice A delegation upgrade was scheduled; members can react before readyAt.
    event DelegationUpgradeScheduled(
        address indexed implementation,
        bytes32 indexed implementationCodeHash,
        address indexed scheduledBy,
        uint256 scheduledAt,
        uint256 readyAt
    );
    event DelegationUpgradeCancelled(
        address indexed implementation,
        bytes32 indexed implementationCodeHash,
        address indexed cancelledBy
    );
    event DelegationUpgradeExecuted(
        address indexed previousImplementation,
        address indexed newImplementation,
        bytes32 indexed implementationCodeHash
    );
    /// @notice The upgrade delay changed (raises apply at once; lowers after the old delay).
    event UpgradeDelayChanged(uint256 previousDelay, uint256 newDelay);
    event UpgradeDelayDecreaseScheduled(uint256 currentDelay, uint256 newDelay, uint256 readyAt);
    event UpgradeDelayDecreaseCancelled(uint256 newDelay, address indexed cancelledBy);

    /// @notice First-links the control plane through the genesis proxy link
    ///         (with data); the live root caller is admin.
    /// @param upgradeDelay Initial seconds between schedule and execute (0..MAX).
    function initialize(
        address dispatcher,
        address beacon,
        address gasSponsor,
        uint256 upgradeDelay
    ) external;

    /// @notice Same as initialize, with an explicit registry admin.
    function initializeWithAdmin(
        address dispatcher,
        address beacon,
        address gasSponsor,
        address admin,
        uint256 upgradeDelay
    ) external;

    function proposeAdmin(address pendingAdmin_) external;

    function acceptAdmin() external;

    function cancelAdminTransfer() external;

    /// @notice Phase 1 (admin): validate and schedule a beacon upgrade. One at a time.
    ///         A rollback is the same call with an earlier release's
    ///         implementation and code hash (see releaseAt).
    /// @param newImplementation Verified deployment to activate.
    /// @param expectedCodeHash Code hash from the archived build artifact.
    function scheduleDelegationUpgrade(
        address newImplementation,
        bytes32 expectedCodeHash
    ) external;

    /// @notice Phase 2 (admin): activate the scheduled upgrade once it is ready.
    ///         Arguments must match the scheduled upgrade.
    function executeDelegationUpgrade(
        address newImplementation,
        bytes32 expectedCodeHash
    ) external;

    /// @notice Cancel the scheduled upgrade (admin or genesis-proxy guardian).
    function cancelDelegationUpgrade() external;

    /// @notice Raise (immediate) or schedule a lower (after the current delay) upgrade delay.
    function setUpgradeDelay(uint256 newDelay) external;

    /// @notice Apply a scheduled delay decrease once it is ready (admin).
    function executeUpgradeDelayDecrease() external;

    /// @notice Cancel a scheduled delay decrease (admin or genesis-proxy guardian).
    function cancelUpgradeDelayDecrease() external;

    function upgradeDelay() external view returns (uint256);

    function MAX_UPGRADE_DELAY() external view returns (uint256);

    function pendingDelegationUpgrade()
        external
        view
        returns (
            address implementation,
            bytes32 implementationCodeHash,
            uint256 scheduledAt,
            uint256 readyAt
        );

    function pendingUpgradeDelayDecrease()
        external
        view
        returns (bool pending, uint256 newDelay, uint256 readyAt);

    function currentSnapshot()
        external
        view
        returns (DelegationSnapshot memory snapshot);

    function accountStatus(
        address account
    ) external view returns (AccountStatus memory status);

    function isAccountReady(address account) external view returns (bool);

    function supportsCurrentCapability(
        uint256 capabilityMask
    ) external view returns (bool);

    function releaseAt(
        uint256 index
    ) external view returns (Release memory release_, bool active);

    function currentRelease() external view returns (Release memory release_);

    function releaseCount() external view returns (uint256);

    function getAccountNonce(
        address account
    ) external view returns (uint256);

    function getAccountDomainSeparator(
        address account
    ) external view returns (bytes32);

    function getAccountExecutionDigest(
        address account,
        bytes32 operationId,
        address executor,
        ICryftDelegation.Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view returns (bytes32);

    function registryAdmin() external view returns (address);

    function pendingRegistryAdmin() external view returns (address);

    function delegationEntry() external view returns (address);

    function delegationEntryCodeHash() external view returns (bytes32);

    function expectedAccountCodeHash() external view returns (bytes32);

    function dispatcher() external view returns (address);

    function beacon() external view returns (address);

    function gasSponsor() external view returns (address);

    function expectedProtocolId() external view returns (bytes32);

    /// @notice Current control-plane logic in the fixed proxy's EIP-1967 slot.
    function registryImplementation() external view returns (address);

    function registryVersion() external pure returns (string memory);

    function registryStorageLocation() external pure returns (bytes32);

    function genesisProxyAdmin() external pure returns (address);

    function validatorRootRegistry() external pure returns (address);

    function CAPABILITY_SPONSORED_EXECUTION()
        external
        view
        returns (uint256);

    function CAPABILITY_BATCHED_CALLS()
        external
        view
        returns (uint256);

    function CAPABILITY_EIP1271()
        external
        view
        returns (uint256);

    function CAPABILITY_NATIVE_RECEIVE()
        external
        view
        returns (uint256);

    function CAPABILITY_ERC721_RECEIVE()
        external
        view
        returns (uint256);

    function CAPABILITY_ERC1155_RECEIVE()
        external
        view
        returns (uint256);

    function CAPABILITY_TYPED_DATA_HELPERS()
        external
        view
        returns (uint256);

    function CAPABILITY_REPLAY_PROTECTION()
        external
        view
        returns (uint256);
}
