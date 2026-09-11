// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

import "./IDakotaDelegation.sol";

/// @title IDakotaDelegationRegistry
/// @notice Authoritative release and readiness view for Dakota EIP-7702.
interface IDakotaDelegationRegistry {
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

    event BeaconOwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event BeaconOwnershipTransferProposed(address indexed previousOwner, address indexed pendingOwner);

    /// @notice First-links the control plane; the live root caller is admin.
    function initialize(
        address dispatcher,
        address beacon,
        address gasSponsor
    ) external;

    function proposeAdmin(address pendingAdmin_) external;

    function acceptAdmin() external;

    function cancelAdminTransfer() external;

    /// @notice Atomically upgrades the controlled beacon and records release.
    /// @param newImplementation Verified deployment to activate.
    /// @param expectedCodeHash Code hash from the archived build artifact.
    function upgradeDelegation(
        address newImplementation,
        bytes32 expectedCodeHash
    ) external;

    /// @notice Records a current beacon implementation changed before control.
    function recordCurrentImplementation() external;

    /// @notice Proposes an ownership handover; the recipient must accept on the beacon.
    function transferBeaconOwnership(address newOwner) external;

    /// @notice Accept a beacon ownership handover proposed to this registry.
    function acceptBeaconOwnership() external;
    /// @notice Cancel an outgoing handover while this registry still owns the beacon.
    function cancelBeaconOwnershipTransfer() external;

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
        IDakotaDelegation.Call[] calldata calls,
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
