// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {ICryftDelegation} from "./ICryftDelegation.sol";

/// @title ICryftDelegationRegistry
/// @notice Authoritative release directory and readiness view for Cryft EIP-7702.
/// @custom:version 3.0.0
/// @custom:security-contact security@cryft.cards
interface ICryftDelegationRegistry {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @notice One recorded account-logic release.
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

    /// @notice The whole delegation route and its health, in one read.
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

    /// @notice One account's delegation state. `proxyInitialized` reports whether the immutable route is valid.
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

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The registry was linked and configured.
    event RegistryInitialized(
        address indexed dispatcher,
        address indexed beacon,
        address indexed gasSponsor,
        address initialRootAdmin,
        bytes32 protocolId
    );

    /// @notice A registry administrator handover was proposed (zero `pendingAdmin`: cancelled).
    event RegistryAdminTransferProposed(address indexed currentAdmin, address indexed pendingAdmin);

    /// @notice The registry administrator changed.
    event RegistryAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    /// @notice A release was recorded in the directory.
    event DelegationReleaseRecorded(
        uint64 indexed sequence,
        address indexed implementation,
        bytes32 indexed implementationCodeHash,
        bytes32 protocolId,
        uint256 capabilities,
        string version
    );

    /// @notice A delegation upgrade was scheduled; members can react before `readyAt`.
    event DelegationUpgradeScheduled(
        address indexed implementation,
        bytes32 indexed implementationCodeHash,
        address indexed scheduledBy,
        uint256 scheduledAt,
        uint256 readyAt
    );

    /// @notice The scheduled delegation upgrade was cancelled.
    event DelegationUpgradeCancelled(
        address indexed implementation,
        bytes32 indexed implementationCodeHash,
        address indexed cancelledBy
    );

    /// @notice The scheduled delegation upgrade was executed.
    event DelegationUpgradeExecuted(
        address indexed previousImplementation,
        address indexed newImplementation,
        bytes32 indexed implementationCodeHash
    );

    /// @notice The upgrade delay changed (raises apply at once; decreases after the old delay).
    event UpgradeDelayUpdated(uint256 previousDelay, uint256 newDelay);

    /// @notice An upgrade delay decrease was scheduled.
    event UpgradeDelayDecreaseScheduled(uint256 currentDelay, uint256 newDelay, uint256 readyAt);

    /// @notice A scheduled upgrade delay decrease was cancelled.
    event UpgradeDelayDecreaseCancelled(uint256 newDelay, address indexed cancelledBy);

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice First-links the registry through the genesis proxy link (with data); the live root caller becomes
    ///         the registry administrator.
    /// @param upgradeDelay_ Initial seconds between schedule and execute (0 to MAX_UPGRADE_DELAY).
    function initialize(address dispatcher_, address beacon_, address gasSponsor_, uint256 upgradeDelay_) external;

    /// @notice Same as `initialize`, with an explicit registry administrator.
    function initializeWithAdmin(
        address dispatcher_,
        address beacon_,
        address gasSponsor_,
        address admin,
        uint256 upgradeDelay_
    ) external;

    /// @notice Proposes a new registry administrator (step 1 of 2).
    function proposeAdmin(address pendingAdmin) external;

    /// @notice Accepts the pending registry administrator role (step 2 of 2).
    function acceptAdmin() external;

    /// @notice Cancels a pending registry administrator handover.
    function cancelAdminTransfer() external;

    /// @notice Schedules a beacon upgrade (registry administrator, one at a time). A rollback is the same call
    ///         with an earlier release's implementation and code hash (see `releaseAt`).
    /// @param newImplementation Verified deployment to activate.
    /// @param expectedCodeHash Code hash from the archived build artifact.
    function scheduleDelegationUpgrade(address newImplementation, bytes32 expectedCodeHash) external;

    /// @notice Executes the scheduled upgrade once the upgrade delay has passed (registry administrator).
    ///         Arguments must match the scheduled upgrade.
    function executeDelegationUpgrade(address newImplementation, bytes32 expectedCodeHash) external;

    /// @notice Cancels the scheduled upgrade (registry administrator or genesis-proxy guardian).
    function cancelDelegationUpgrade() external;

    /// @notice Raises the upgrade delay at once, or schedules a decrease that applies after the current delay.
    function setUpgradeDelay(uint256 newDelay) external;

    /// @notice Applies a scheduled upgrade delay decrease once it is ready (registry administrator).
    function executeUpgradeDelayDecrease() external;

    /// @notice Cancels a scheduled upgrade delay decrease (registry administrator or genesis-proxy guardian).
    function cancelUpgradeDelayDecrease() external;

    /// @notice The upgrade delay in seconds.
    function upgradeDelay() external view returns (uint256);

    /// @notice The highest allowed upgrade delay in seconds.
    function MAX_UPGRADE_DELAY() external view returns (uint256);

    /// @notice The scheduled delegation upgrade (all zero when none).
    function pendingDelegationUpgrade()
        external
        view
        returns (address implementation, bytes32 implementationCodeHash, uint256 scheduledAt, uint256 readyAt);

    /// @notice The scheduled upgrade delay decrease, if any.
    function pendingUpgradeDelayDecrease() external view returns (bool pending, uint256 newDelay, uint256 readyAt);

    /// @notice The whole delegation route and its health.
    function currentSnapshot() external view returns (DelegationSnapshot memory snapshot);

    /// @notice One account's delegation state.
    function accountStatus(address account) external view returns (AccountStatus memory status);

    /// @notice Whether `account` can run sponsored operations now.
    function isAccountReady(address account) external view returns (bool);

    /// @notice Whether the current account logic implements every bit of `capabilityMask`.
    function supportsCurrentCapability(uint256 capabilityMask) external view returns (bool);

    /// @notice The release at `index`, and whether it is the active one.
    function releaseAt(uint256 index) external view returns (Release memory release, bool active);

    /// @notice The latest recorded release.
    function currentRelease() external view returns (Release memory release);

    /// @notice How many releases are recorded.
    function releaseCount() external view returns (uint256);

    /// @notice `account`'s next operation nonce.
    function getAccountNonce(address account) external view returns (uint256);

    /// @notice `account`'s EIP-712 domain separator.
    function getAccountDomainSeparator(address account) external view returns (bytes32);

    /// @notice The digest `account`'s owner signs for an operation.
    function getAccountExecutionDigest(
        address account,
        bytes32 operationId,
        address executor,
        ICryftDelegation.Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view returns (bytes32);

    /// @notice The registry administrator.
    function registryAdmin() external view returns (address);

    /// @notice The proposed registry administrator, if any.
    function pendingRegistryAdmin() external view returns (address);

    /// @notice The address accounts designate in their EIP-7702 authorization (the dispatcher).
    function delegationEntry() external view returns (address);

    /// @notice The dispatcher's code hash recorded at initialization.
    function delegationEntryCodeHash() external view returns (bytes32);

    /// @notice The code hash of an account delegated to the dispatcher (0xef0100 || dispatcher).
    function expectedAccountCodeHash() external view returns (bytes32);

    /// @notice The immutable dispatcher.
    function dispatcher() external view returns (address);

    /// @notice The shared beacon.
    function beacon() external view returns (address);

    /// @notice The gas sponsor.
    function gasSponsor() external view returns (address);

    /// @notice The protocol id every release must implement.
    function expectedProtocolId() external view returns (bytes32);

    /// @notice The registry logic in the fixed proxy's EIP-1967 slot.
    function registryImplementation() external view returns (address);

    /// @notice The registry logic's version.
    function registryVersion() external pure returns (string memory);

    /// @notice The ERC-7201 slot of the registry's storage.
    function registryStorageLocation() external pure returns (bytes32);

    /// @notice The genesis ProxyAdmin (0x…FacAdE).
    function genesisProxyAdmin() external pure returns (address);

    /// @notice The validator contract that lists root overlords (0x…1111).
    function validatorRootRegistry() external pure returns (address);

    /// @notice Capability bit 0: sponsored execution.
    function CAPABILITY_SPONSORED_EXECUTION() external view returns (uint256);

    /// @notice Capability bit 1: batched calls.
    function CAPABILITY_BATCHED_CALLS() external view returns (uint256);

    /// @notice Capability bit 2: EIP-1271.
    function CAPABILITY_EIP1271() external view returns (uint256);

    /// @notice Capability bit 3: native-coin receive.
    function CAPABILITY_NATIVE_RECEIVE() external view returns (uint256);

    /// @notice Capability bit 4: ERC-721 receive.
    function CAPABILITY_ERC721_RECEIVE() external view returns (uint256);

    /// @notice Capability bit 5: ERC-1155 receive.
    function CAPABILITY_ERC1155_RECEIVE() external view returns (uint256);

    /// @notice Capability bit 6: typed-data digest helpers.
    function CAPABILITY_TYPED_DATA_HELPERS() external view returns (uint256);

    /// @notice Capability bit 7: replay-protected account nonce.
    function CAPABILITY_REPLAY_PROTECTION() external view returns (uint256);
}
