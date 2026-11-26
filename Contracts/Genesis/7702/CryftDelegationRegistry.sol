// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {Initializable} from "../Upgradeable/Initializable.sol";
import {ICryftDelegation} from "./Interfaces/ICryftDelegation.sol";
import {ICryftDelegationRegistry} from "./Interfaces/ICryftDelegationRegistry.sol";
import {IGasSponsor} from "./Interfaces/IGasSponsor.sol";
import {CryftDelegationCapabilities} from "./Libraries/CryftDelegationCapabilities.sol";

/// @title ICryftDelegationBeaconControl
/// @notice The beacon surface the registry drives.
interface ICryftDelegationBeaconControl {
    /// @notice Points the beacon at `newImplementation`.
    function upgradeTo(address newImplementation) external;

    /// @notice The beacon's current implementation.
    function implementation() external view returns (address);

    /// @notice The beacon's owner.
    function owner() external view returns (address);
}

/// @title ICryftDelegationRootRegistry
/// @notice The root-overlord check of the validator contract 0x…1111.
interface ICryftDelegationRootRegistry {
    /// @notice Whether `account` is a live root overlord.
    function isRootOverlord(address account) external view returns (bool);
}

/// @title ICryftDelegationGenesisProxy
/// @notice The guardian check of the genesis proxy that hosts the registry.
interface ICryftDelegationGenesisProxy {
    /// @notice Whether `account` is a guardian of the proxy.
    function proxy_isGuardian(address account) external view returns (bool);
}

/// @title CryftDelegationRegistry
/// @notice Release authority and introspection surface for Cryft EIP-7702.
/// @dev The upgradeable release control plane at 0x…de1E6A7E. Linked behind that genesis proxy, which hosts the
///      registry state; the shared beacon names this entry as its owner from construction (no handover), and
///      user EOAs designate the immutable dispatcher. Initialization runs only through the genesis proxy link,
///      for a live root, and checks the dispatcher's immutable beacon, its v2 protocol and that this entry owns
///      the beacon. Delegation upgrades are scheduled, wait the upgrade delay, then execute, with public events;
///      the registry administrator or a genesis-proxy guardian may cancel. The delay is configurable
///      (0 to MAX_UPGRADE_DELAY): a raise applies at once, a decrease waits the current delay. A rollback is a
///      scheduled upgrade to an earlier recorded release. Releases are checked for code hash, protocol,
///      capabilities and interfaces; account readiness checks the EIP-7702 designator, the dispatcher runtime and
///      the account protocol. The registry administrator changes by proposal and acceptance.
/// @custom:version 3.0.0
/// @custom:security-contact security@cryft.cards
contract CryftDelegationRegistry is
    Initializable,
    ICryftDelegationRegistry
{
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    struct ImplementationMetadata {
        bytes32 codeHash;
        bytes32 protocolId;
        uint256 capabilities;
        string version;
    }

    /// @custom:storage-location erc7201:cryft.storage.CryftDelegationRegistry
    struct DelegationRegistryStorage {
        bytes32 delegationEntryCodeHash;
        bytes32 expectedAccountCodeHash;
        address dispatcher;
        address beacon;
        address gasSponsor;
        bytes32 expectedProtocolId;
        address registryAdmin;
        address pendingRegistryAdmin;
        Release[] releases;
        // Scheduled delegation upgrade.
        uint256 upgradeDelay;
        address pendingImplementation;
        bytes32 pendingCodeHash;
        uint256 pendingScheduledAt;
        uint256 pendingReadyAt;
        // Scheduled decrease of upgradeDelay (raises apply at once).
        bool delayDecreasePending;
        uint256 pendingDelay;
        uint256 pendingDelayReadyAt;
    }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @notice The highest allowed upgrade delay.
    uint256 public constant MAX_UPGRADE_DELAY = 30 days;

    uint256 public constant CAPABILITY_SPONSORED_EXECUTION =
        CryftDelegationCapabilities.SPONSORED_EXECUTION;
    uint256 public constant CAPABILITY_BATCHED_CALLS =
        CryftDelegationCapabilities.BATCHED_CALLS;
    uint256 public constant CAPABILITY_EIP1271 =
        CryftDelegationCapabilities.EIP1271;
    uint256 public constant CAPABILITY_NATIVE_RECEIVE =
        CryftDelegationCapabilities.NATIVE_RECEIVE;
    uint256 public constant CAPABILITY_ERC721_RECEIVE =
        CryftDelegationCapabilities.ERC721_RECEIVE;
    uint256 public constant CAPABILITY_ERC1155_RECEIVE =
        CryftDelegationCapabilities.ERC1155_RECEIVE;
    uint256 public constant CAPABILITY_TYPED_DATA_HELPERS =
        CryftDelegationCapabilities.TYPED_DATA_HELPERS;
    uint256 public constant CAPABILITY_REPLAY_PROTECTION =
        CryftDelegationCapabilities.REPLAY_PROTECTION;

    uint256 private constant _REQUIRED_CAPABILITIES =
        CryftDelegationCapabilities.REQUIRED_V1;
    uint256 private constant _READ_GAS_LIMIT = 200_000;
    uint256 private constant _MAX_VERSION_BYTES = 64;
    bytes4 private constant _PROXY_GET_IS_INIT_SELECTOR =
        bytes4(keccak256("proxy_getIsInit()"));
    bytes4 private constant _ERC165_INTERFACE_ID = 0x01ffc9a7;
    address private constant _DELEGATION_ENTRY =
        0x00000000000000000000000000000000de1E6A7E;
    address private constant _VALIDATOR_ROOT_REGISTRY =
        0x0000000000000000000000000000000000001111;
    address private constant _GENESIS_PROXY_ADMIN =
        0x0000000000000000000000000000000000FacAdE;
    bytes32 private constant _EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _REGISTRY_STORAGE_LOCATION =
        0xab4cfcf4b885f9dbbc02cc8800e34faa6a47500834aa5c49ef09aafea9c84000;

    // ─── Storage ─────────────────────────────────────────────────────────────────────────────────

    uint256[49] private __gap;

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is not the registry administrator.
    error NotAdmin();

    /// @notice The caller is not the pending registry administrator.
    error NotPendingAdmin();

    /// @notice The caller is not a live root overlord.
    error NotInitializationAuthority(address caller);

    /// @notice Initialization ran somewhere other than the fixed delegation entry.
    error WrongDelegationEntry(address actual);

    /// @notice A required address is zero, or the registry administrator would be this contract or the
    ///         genesis ProxyAdmin.
    error ZeroAddress();

    /// @notice The dispatcher does not route to the given beacon or does not speak protocol v2.
    error InvalidDispatcher();

    /// @notice The address has no code.
    error AddressHasNoCode(address target);

    /// @notice This registry does not own the beacon.
    error BeaconNotControlled(address currentOwner);

    /// @notice The upgrade target is already the active implementation.
    error SameImplementation(address implementation);

    /// @notice The expected code hash is zero.
    error EmptyCodeHash();

    /// @notice The implementation's code hash differs from the expected one.
    error UnexpectedCodeHash(bytes32 expected, bytes32 actual);

    /// @notice The implementation speaks another protocol.
    error IncompatibleProtocol(bytes32 expected, bytes32 actual);

    /// @notice The implementation lacks required capabilities.
    error MissingCapabilities(uint256 required, uint256 supplied);

    /// @notice The implementation does not report the delegation interface through ERC-165.
    error UnsupportedDelegationInterface(address implementation);

    /// @notice The implementation's protocol id, capabilities or version could not be read.
    error InvalidImplementationMetadata(address implementation);

    /// @notice No release exists at the index.
    error InvalidReleaseIndex(uint256 index);

    /// @notice The beacon did not switch to the new implementation.
    error BeaconUpgradeFailed(address expected, address actual);

    /// @notice The caller is neither the registry administrator nor a genesis-proxy guardian.
    error NotAdminOrGuardian(address caller);

    /// @notice The requested upgrade delay is above the maximum.
    error UpgradeDelayTooLong(uint256 requested, uint256 maximum);

    /// @notice The upgrade delay already has this value.
    error SameUpgradeDelay(uint256 delay);

    /// @notice An upgrade is already scheduled.
    error UpgradeAlreadyScheduled(address implementation);

    /// @notice No upgrade is scheduled.
    error NoUpgradeScheduled();

    /// @notice The arguments do not match the scheduled upgrade.
    error ScheduledUpgradeMismatch(address implementation, bytes32 codeHash);

    /// @notice The upgrade delay has not passed yet.
    error UpgradeNotReady(uint256 readyAt, uint256 nowTimestamp);

    /// @notice No upgrade delay decrease is scheduled.
    error NoDelayDecreaseScheduled();

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != _registryStorage().registryAdmin) revert NotAdmin();
        _;
    }

    modifier onlyAdminOrGuardian() {
        if (msg.sender != _registryStorage().registryAdmin && !_isGenesisGuardian(msg.sender)) {
            revert NotAdminOrGuardian(msg.sender);
        }
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    // ─── Initializers ────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ICryftDelegationRegistry
    /// @dev Locked on the implementation (constructor). On the entry it runs once, for a live root caller, so it
    ///      cannot be front-run; the bootstrap links it with data in the same transaction.
    function initialize(
        address dispatcher_,
        address beacon_,
        address gasSponsor_,
        uint256 upgradeDelay_
    ) external override initializer {
        _initializeRegistry(dispatcher_, beacon_, gasSponsor_, msg.sender, upgradeDelay_);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function initializeWithAdmin(
        address dispatcher_,
        address beacon_,
        address gasSponsor_,
        address admin,
        uint256 upgradeDelay_
    ) external override initializer {
        _initializeRegistry(dispatcher_, beacon_, gasSponsor_, admin, upgradeDelay_);
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc ICryftDelegationRegistry
    function proposeAdmin(address pendingAdmin) external override onlyAdmin {
        _requireNonZero(pendingAdmin);
        if (pendingAdmin == address(this) || pendingAdmin == _GENESIS_PROXY_ADMIN) revert ZeroAddress();
        DelegationRegistryStorage storage state = _registryStorage();
        state.pendingRegistryAdmin = pendingAdmin;
        emit RegistryAdminTransferProposed(state.registryAdmin, pendingAdmin);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function acceptAdmin() external override {
        DelegationRegistryStorage storage state = _registryStorage();
        if (msg.sender != state.pendingRegistryAdmin) revert NotPendingAdmin();
        address previousAdmin = state.registryAdmin;
        state.registryAdmin = msg.sender;
        state.pendingRegistryAdmin = address(0);
        emit RegistryAdminTransferred(previousAdmin, msg.sender);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function cancelAdminTransfer() external override onlyAdmin {
        DelegationRegistryStorage storage state = _registryStorage();
        state.pendingRegistryAdmin = address(0);
        emit RegistryAdminTransferProposed(state.registryAdmin, address(0));
    }

    /// @inheritdoc ICryftDelegationRegistry
    function scheduleDelegationUpgrade(
        address newImplementation,
        bytes32 expectedCodeHash
    ) external override onlyAdmin {
        DelegationRegistryStorage storage state = _registryStorage();
        if (state.pendingImplementation != address(0)) {
            revert UpgradeAlreadyScheduled(state.pendingImplementation);
        }
        _checkUpgradeTarget(state, newImplementation, expectedCodeHash);

        uint256 readyAt = block.timestamp + state.upgradeDelay;
        state.pendingImplementation = newImplementation;
        state.pendingCodeHash = expectedCodeHash;
        state.pendingScheduledAt = block.timestamp;
        state.pendingReadyAt = readyAt;
        emit DelegationUpgradeScheduled(newImplementation, expectedCodeHash, msg.sender, block.timestamp, readyAt);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function executeDelegationUpgrade(
        address newImplementation,
        bytes32 expectedCodeHash
    ) external override onlyAdmin {
        DelegationRegistryStorage storage state = _registryStorage();
        address scheduled = state.pendingImplementation;
        if (scheduled == address(0)) revert NoUpgradeScheduled();
        if (scheduled != newImplementation || state.pendingCodeHash != expectedCodeHash) {
            revert ScheduledUpgradeMismatch(newImplementation, expectedCodeHash);
        }
        uint256 readyAt = _upgradeReadyAt(state);
        if (block.timestamp < readyAt) revert UpgradeNotReady(readyAt, block.timestamp);

        // Checked again at activation: code hash, metadata, protocol, interfaces.
        (
            ICryftDelegationBeaconControl beaconControl,
            address previousImplementation,
            ImplementationMetadata memory metadata
        ) = _checkUpgradeTarget(state, newImplementation, expectedCodeHash);
        _clearPendingUpgrade(state);

        beaconControl.upgradeTo(newImplementation);
        address activatedImplementation = beaconControl.implementation();
        if (activatedImplementation != newImplementation) {
            revert BeaconUpgradeFailed(newImplementation, activatedImplementation);
        }

        _recordRelease(newImplementation, metadata);
        emit DelegationUpgradeExecuted(previousImplementation, newImplementation, metadata.codeHash);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function cancelDelegationUpgrade() external override onlyAdminOrGuardian {
        DelegationRegistryStorage storage state = _registryStorage();
        address scheduled = state.pendingImplementation;
        if (scheduled == address(0)) revert NoUpgradeScheduled();
        bytes32 codeHash = state.pendingCodeHash;
        _clearPendingUpgrade(state);
        emit DelegationUpgradeCancelled(scheduled, codeHash, msg.sender);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function setUpgradeDelay(uint256 newDelay) external override onlyAdmin {
        if (newDelay > MAX_UPGRADE_DELAY) revert UpgradeDelayTooLong(newDelay, MAX_UPGRADE_DELAY);
        DelegationRegistryStorage storage state = _registryStorage();
        uint256 currentDelay = state.upgradeDelay;
        if (newDelay == currentDelay) revert SameUpgradeDelay(newDelay);

        if (newDelay > currentDelay) {
            // A raise applies at once and replaces any scheduled decrease.
            if (state.delayDecreasePending) {
                emit UpgradeDelayDecreaseCancelled(state.pendingDelay, msg.sender);
                _clearPendingDelay(state);
            }
            state.upgradeDelay = newDelay;
            emit UpgradeDelayUpdated(currentDelay, newDelay);
            return;
        }

        // A decrease waits the current delay (and replaces an earlier decrease).
        uint256 readyAt = block.timestamp + currentDelay;
        state.delayDecreasePending = true;
        state.pendingDelay = newDelay;
        state.pendingDelayReadyAt = readyAt;
        emit UpgradeDelayDecreaseScheduled(currentDelay, newDelay, readyAt);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function executeUpgradeDelayDecrease() external override onlyAdmin {
        DelegationRegistryStorage storage state = _registryStorage();
        if (!state.delayDecreasePending) revert NoDelayDecreaseScheduled();
        uint256 readyAt = state.pendingDelayReadyAt;
        if (block.timestamp < readyAt) revert UpgradeNotReady(readyAt, block.timestamp);
        uint256 previousDelay = state.upgradeDelay;
        uint256 newDelay = state.pendingDelay;
        _clearPendingDelay(state);
        state.upgradeDelay = newDelay;
        emit UpgradeDelayUpdated(previousDelay, newDelay);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function cancelUpgradeDelayDecrease() external override onlyAdminOrGuardian {
        DelegationRegistryStorage storage state = _registryStorage();
        if (!state.delayDecreasePending) revert NoDelayDecreaseScheduled();
        uint256 newDelay = state.pendingDelay;
        _clearPendingDelay(state);
        emit UpgradeDelayDecreaseCancelled(newDelay, msg.sender);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function delegationEntry() external view override returns (address) {
        return _registryStorage().dispatcher;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function delegationEntryCodeHash() external view override returns (bytes32) {
        return _registryStorage().delegationEntryCodeHash;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function expectedAccountCodeHash() external view override returns (bytes32) {
        return _registryStorage().expectedAccountCodeHash;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function dispatcher() external view override returns (address) {
        return _registryStorage().dispatcher;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function beacon() external view override returns (address) {
        return _registryStorage().beacon;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function gasSponsor() external view override returns (address) {
        return _registryStorage().gasSponsor;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function expectedProtocolId() external view override returns (bytes32) {
        return _registryStorage().expectedProtocolId;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function registryAdmin() external view override returns (address) {
        return _registryStorage().registryAdmin;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function pendingRegistryAdmin() external view override returns (address) {
        return _registryStorage().pendingRegistryAdmin;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function registryImplementation() external view override returns (address implementation) {
        return _registryImplementation();
    }

    /// @inheritdoc ICryftDelegationRegistry
    function upgradeDelay() external view override returns (uint256) {
        return _registryStorage().upgradeDelay;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function pendingDelegationUpgrade()
        external
        view
        override
        returns (address implementation, bytes32 implementationCodeHash, uint256 scheduledAt, uint256 readyAt)
    {
        DelegationRegistryStorage storage state = _registryStorage();
        implementation = state.pendingImplementation;
        implementationCodeHash = state.pendingCodeHash;
        scheduledAt = state.pendingScheduledAt;
        readyAt = implementation == address(0) ? 0 : _upgradeReadyAt(state);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function pendingUpgradeDelayDecrease()
        external
        view
        override
        returns (bool pending, uint256 newDelay, uint256 readyAt)
    {
        DelegationRegistryStorage storage state = _registryStorage();
        return (state.delayDecreasePending, state.pendingDelay, state.pendingDelayReadyAt);
    }

    /// @inheritdoc ICryftDelegationRegistry
    function currentSnapshot() external view override returns (DelegationSnapshot memory snapshot) {
        DelegationRegistryStorage storage state = _registryStorage();
        ICryftDelegationBeaconControl beaconControl = ICryftDelegationBeaconControl(state.beacon);
        address implementation = beaconControl.implementation();
        address beaconOwner = beaconControl.owner();
        (bool metadataValid, ImplementationMetadata memory metadata) = _tryImplementationMetadata(implementation);
        bool interfacesValid = _supportsRequiredInterfaces(implementation);

        bool sponsorUsesEntry;
        (bool sponsorDelegateSuccess, address approvedDelegate) = _tryReadAddress(
            state.gasSponsor,
            abi.encodeCall(IGasSponsor.approvedDelegate, ())
        );
        if (sponsorDelegateSuccess) {
            sponsorUsesEntry = approvedDelegate == state.dispatcher;
        }

        bool matchesLatest;
        uint256 count = state.releases.length;
        if (count != 0) {
            Release storage latest = state.releases[count - 1];
            matchesLatest =
                latest.implementation == implementation &&
                latest.implementationCodeHash == implementation.codehash;
        }

        snapshot = DelegationSnapshot({
            delegationEntry: state.dispatcher,
            delegationEntryCodeHash: state.delegationEntryCodeHash,
            expectedAccountCodeHash: state.expectedAccountCodeHash,
            dispatcher: state.dispatcher,
            beacon: state.beacon,
            beaconOwner: beaconOwner,
            registryImplementation: _registryImplementation(),
            registryVersion: "3.0.0",
            implementation: implementation,
            implementationCodeHash: implementation.codehash,
            protocolId: metadata.protocolId,
            capabilities: metadata.capabilities,
            version: metadata.version,
            implementationCompatible: metadataValid &&
                metadata.protocolId == state.expectedProtocolId &&
                (metadata.capabilities & _REQUIRED_CAPABILITIES) == _REQUIRED_CAPABILITIES &&
                interfacesValid,
            registryControlsBeacon: beaconOwner == address(this),
            sponsorUsesDelegationEntry: sponsorUsesEntry,
            matchesLatestRelease: matchesLatest
        });
    }

    /// @inheritdoc ICryftDelegationRegistry
    function isAccountReady(address account) external view override returns (bool) {
        AccountStatus memory status = accountStatus(account);
        return
            status.delegatedToEntry &&
            status.proxyInitialized &&
            status.protocolCompatible &&
            status.interfaceCompatible &&
            status.sponsorReady &&
            (status.capabilities & _REQUIRED_CAPABILITIES) == _REQUIRED_CAPABILITIES;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function supportsCurrentCapability(uint256 capabilityMask) external view override returns (bool) {
        if (capabilityMask == 0) return false;
        DelegationRegistryStorage storage state = _registryStorage();
        address implementation = ICryftDelegationBeaconControl(state.beacon).implementation();
        (bool success, uint256 capabilities) = _tryReadUint256(
            implementation,
            abi.encodeCall(ICryftDelegation.delegationCapabilities, ())
        );
        return success && (capabilities & capabilityMask) == capabilityMask;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function releaseAt(uint256 index) external view override returns (Release memory release, bool active) {
        DelegationRegistryStorage storage state = _registryStorage();
        uint256 count = state.releases.length;
        if (index >= count) revert InvalidReleaseIndex(index);
        release = state.releases[index];
        active =
            index == count - 1 &&
            release.implementation == ICryftDelegationBeaconControl(state.beacon).implementation();
    }

    /// @inheritdoc ICryftDelegationRegistry
    function currentRelease() external view override returns (Release memory release) {
        DelegationRegistryStorage storage state = _registryStorage();
        uint256 count = state.releases.length;
        if (count == 0) revert InvalidReleaseIndex(0);
        release = state.releases[count - 1];
    }

    /// @inheritdoc ICryftDelegationRegistry
    function releaseCount() external view override returns (uint256) {
        return _registryStorage().releases.length;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function getAccountNonce(address account) external view override returns (uint256) {
        return ICryftDelegation(account).getNonce();
    }

    /// @inheritdoc ICryftDelegationRegistry
    function getAccountDomainSeparator(address account) external view override returns (bytes32) {
        return ICryftDelegation(account).domainSeparator();
    }

    /// @inheritdoc ICryftDelegationRegistry
    function getAccountExecutionDigest(
        address account,
        bytes32 operationId,
        address executor,
        ICryftDelegation.Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view override returns (bytes32) {
        return ICryftDelegation(account).getExecutionDigest(
            operationId,
            executor,
            calls,
            nonce,
            deadline,
            executionGasLimit
        );
    }

    /// @inheritdoc ICryftDelegationRegistry
    function registryVersion() external pure override returns (string memory) {
        return "3.0.0";
    }

    /// @inheritdoc ICryftDelegationRegistry
    function registryStorageLocation() external pure override returns (bytes32) {
        return _REGISTRY_STORAGE_LOCATION;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function genesisProxyAdmin() external pure override returns (address) {
        return _GENESIS_PROXY_ADMIN;
    }

    /// @inheritdoc ICryftDelegationRegistry
    function validatorRootRegistry() external pure override returns (address) {
        return _VALIDATOR_ROOT_REGISTRY;
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ICryftDelegationRegistry
    function accountStatus(address account) public view override returns (AccountStatus memory status) {
        if (account == address(0)) return status;

        DelegationRegistryStorage storage state = _registryStorage();
        status.delegatedToEntry = account.codehash == state.expectedAccountCodeHash;
        if (!status.delegatedToEntry) return status;

        // ABI field kept: direct dispatch needs no account proxy slots, so it reports the route's validity.
        status.proxyInitialized = state.dispatcher.codehash == state.delegationEntryCodeHash;
        (status.protocolCompatible, status.protocolId) = _accountProtocol(account);
        status.capabilities = _accountCapabilities(account);
        status.interfaceCompatible = _accountInterfaceCompatible(account);
        status.nonce = _accountNonce(account);
        status.implementationVersion = _accountVersion(account);
        status.sponsorReady = _accountSponsorReady(account);
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    function _initializeRegistry(
        address dispatcher_,
        address beacon_,
        address gasSponsor_,
        address admin,
        uint256 upgradeDelay_
    ) private {
        if (admin == address(0) || admin == address(this) || admin == _GENESIS_PROXY_ADMIN) revert ZeroAddress();
        if (address(this) != _DELEGATION_ENTRY) revert WrongDelegationEntry(address(this));
        if (!_isInitializationAuthority(msg.sender)) revert NotInitializationAuthority(msg.sender);
        _requireContract(dispatcher_);
        _requireContract(beacon_);
        _requireContract(gasSponsor_);

        DelegationRegistryStorage storage state = _registryStorage();
        (bool beaconMatches, address embeddedBeacon) = _tryReadAddress(
            dispatcher_,
            abi.encodeWithSignature("delegationBeacon()")
        );
        if (!beaconMatches || embeddedBeacon != beacon_) revert InvalidDispatcher();
        (bool protocolMatches, bytes memory protocolData) = dispatcher_.staticcall{gas: _READ_GAS_LIMIT}(
            abi.encodeWithSignature("dispatcherProtocolId()")
        );
        if (
            !protocolMatches ||
            protocolData.length != 32 ||
            abi.decode(protocolData, (bytes32)) != keccak256("cryft.delegation.direct-beacon-dispatch.v2")
        ) {
            revert InvalidDispatcher();
        }
        state.delegationEntryCodeHash = dispatcher_.codehash;
        state.expectedAccountCodeHash = keccak256(abi.encodePacked(hex"ef0100", dispatcher_));
        state.dispatcher = dispatcher_;
        state.beacon = beacon_;
        state.gasSponsor = gasSponsor_;
        state.registryAdmin = admin;

        address beaconOwner = ICryftDelegationBeaconControl(beacon_).owner();
        if (beaconOwner != address(this)) revert BeaconNotControlled(beaconOwner);
        if (upgradeDelay_ > MAX_UPGRADE_DELAY) revert UpgradeDelayTooLong(upgradeDelay_, MAX_UPGRADE_DELAY);
        state.upgradeDelay = upgradeDelay_;
        emit UpgradeDelayUpdated(0, upgradeDelay_);

        address initialImplementation = ICryftDelegationBeaconControl(beacon_).implementation();
        ImplementationMetadata memory metadata = _validatedMetadata(initialImplementation, bytes32(0));
        state.expectedProtocolId = metadata.protocolId;
        _recordRelease(initialImplementation, metadata);

        emit RegistryInitialized(dispatcher_, beacon_, gasSponsor_, admin, metadata.protocolId);
        emit RegistryAdminTransferred(address(0), admin);
    }

    function _recordRelease(address implementation, ImplementationMetadata memory metadata) private {
        DelegationRegistryStorage storage state = _registryStorage();
        uint64 sequence = uint64(state.releases.length + 1);
        state.releases.push(
            Release({
                sequence: sequence,
                activationBlock: uint64(block.number),
                activationTimestamp: uint64(block.timestamp),
                implementation: implementation,
                implementationCodeHash: metadata.codeHash,
                protocolId: metadata.protocolId,
                capabilities: metadata.capabilities,
                version: metadata.version
            })
        );
        emit DelegationReleaseRecorded(
            sequence,
            implementation,
            metadata.codeHash,
            metadata.protocolId,
            metadata.capabilities,
            metadata.version
        );
    }

    function _clearPendingUpgrade(DelegationRegistryStorage storage state) private {
        state.pendingImplementation = address(0);
        state.pendingCodeHash = bytes32(0);
        state.pendingScheduledAt = 0;
        state.pendingReadyAt = 0;
    }

    function _clearPendingDelay(DelegationRegistryStorage storage state) private {
        state.delayDecreasePending = false;
        state.pendingDelay = 0;
        state.pendingDelayReadyAt = 0;
    }

    /// @dev The ready time never shortens below the delay in force at execution: raising the delay also holds
    ///      back an upgrade already scheduled.
    function _upgradeReadyAt(DelegationRegistryStorage storage state) private view returns (uint256) {
        uint256 byCurrentDelay = state.pendingScheduledAt + state.upgradeDelay;
        uint256 scheduledReadyAt = state.pendingReadyAt;
        return byCurrentDelay > scheduledReadyAt ? byCurrentDelay : scheduledReadyAt;
    }

    function _checkUpgradeTarget(
        DelegationRegistryStorage storage state,
        address newImplementation,
        bytes32 expectedCodeHash
    )
        private
        view
        returns (
            ICryftDelegationBeaconControl beaconControl,
            address previousImplementation,
            ImplementationMetadata memory metadata
        )
    {
        if (expectedCodeHash == bytes32(0)) revert EmptyCodeHash();
        beaconControl = ICryftDelegationBeaconControl(state.beacon);
        address beaconOwner = beaconControl.owner();
        if (beaconOwner != address(this)) revert BeaconNotControlled(beaconOwner);
        previousImplementation = beaconControl.implementation();
        if (newImplementation == previousImplementation) revert SameImplementation(newImplementation);
        metadata = _validatedMetadata(newImplementation, expectedCodeHash);
        if (metadata.protocolId != state.expectedProtocolId) {
            revert IncompatibleProtocol(state.expectedProtocolId, metadata.protocolId);
        }
    }

    function _validatedMetadata(
        address implementation,
        bytes32 expectedCodeHash
    ) private view returns (ImplementationMetadata memory metadata) {
        _requireContract(implementation);
        bytes32 actualCodeHash = implementation.codehash;
        if (expectedCodeHash != bytes32(0) && expectedCodeHash != actualCodeHash) {
            revert UnexpectedCodeHash(expectedCodeHash, actualCodeHash);
        }

        (bool success, ImplementationMetadata memory inspected) = _tryImplementationMetadata(implementation);
        if (!success) revert InvalidImplementationMetadata(implementation);
        if ((inspected.capabilities & _REQUIRED_CAPABILITIES) != _REQUIRED_CAPABILITIES) {
            revert MissingCapabilities(_REQUIRED_CAPABILITIES, inspected.capabilities);
        }

        if (!_supportsRequiredInterfaces(implementation)) revert UnsupportedDelegationInterface(implementation);
        metadata = inspected;
    }

    function _tryImplementationMetadata(
        address implementation
    ) private view returns (bool success, ImplementationMetadata memory metadata) {
        if (implementation == address(0) || implementation.code.length == 0) return (false, metadata);

        (bool protocolSuccess, bytes32 protocolId) = _tryReadBytes32(
            implementation,
            abi.encodeCall(ICryftDelegation.delegationProtocolId, ())
        );
        (bool capabilitiesSuccess, uint256 capabilities) = _tryReadUint256(
            implementation,
            abi.encodeCall(ICryftDelegation.delegationCapabilities, ())
        );
        (bool versionSuccess, string memory version) = _tryReadString(
            implementation,
            abi.encodeCall(ICryftDelegation.implementationVersion, ())
        );

        success =
            protocolSuccess &&
            protocolId != bytes32(0) &&
            capabilitiesSuccess &&
            capabilities != 0 &&
            versionSuccess &&
            bytes(version).length != 0;
        metadata = ImplementationMetadata({
            codeHash: implementation.codehash,
            protocolId: protocolId,
            capabilities: capabilities,
            version: version
        });
    }

    function _supportsRequiredInterfaces(address implementation) private view returns (bool) {
        (bool erc165Success, bool supportsErc165) = _tryReadBool(
            implementation,
            abi.encodeCall(ICryftDelegation.supportsInterface, (_ERC165_INTERFACE_ID))
        );
        if (!erc165Success || !supportsErc165) return false;

        (bool delegationSuccess, bool supportsDelegation) = _tryReadBool(
            implementation,
            abi.encodeCall(ICryftDelegation.supportsInterface, (type(ICryftDelegation).interfaceId))
        );
        return delegationSuccess && supportsDelegation;
    }

    function _accountProxyInitialized(address account) private view returns (bool) {
        (bool success, bool initialized) = _tryReadBool(
            account,
            abi.encodeWithSelector(_PROXY_GET_IS_INIT_SELECTOR)
        );
        return success && initialized;
    }

    function _accountProtocol(address account) private view returns (bool compatible, bytes32 protocolId) {
        (bool success, bytes32 value) = _tryReadBytes32(
            account,
            abi.encodeCall(ICryftDelegation.delegationProtocolId, ())
        );
        protocolId = value;
        compatible = success && value == _registryStorage().expectedProtocolId;
    }

    function _accountCapabilities(address account) private view returns (uint256) {
        (bool success, uint256 value) = _tryReadUint256(
            account,
            abi.encodeCall(ICryftDelegation.delegationCapabilities, ())
        );
        return success ? value : 0;
    }

    function _accountInterfaceCompatible(address account) private view returns (bool) {
        (bool success, bool supported) = _tryReadBool(
            account,
            abi.encodeCall(ICryftDelegation.supportsInterface, (type(ICryftDelegation).interfaceId))
        );
        return success && supported;
    }

    function _accountNonce(address account) private view returns (uint256) {
        (bool success, uint256 value) = _tryReadUint256(account, abi.encodeCall(ICryftDelegation.getNonce, ()));
        return success ? value : 0;
    }

    function _accountVersion(address account) private view returns (string memory) {
        (bool success, string memory value) = _tryReadString(
            account,
            abi.encodeCall(ICryftDelegation.implementationVersion, ())
        );
        return success ? value : "";
    }

    function _accountSponsorReady(address account) private view returns (bool) {
        (bool success, bool ready) = _tryReadBool(
            _registryStorage().gasSponsor,
            abi.encodeCall(IGasSponsor.isDelegationReady, (account))
        );
        return success && ready;
    }

    /// @dev Reads one address word with capped gas; a failed call, a short answer or a dirty word reads as false.
    function _tryReadAddress(
        address target,
        bytes memory callData
    ) private view returns (bool success, address value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length != 32) return (false, address(0));
        uint256 raw;
        assembly ("memory-safe") {
            raw := mload(add(result, 0x20))
        }
        if (raw > type(uint160).max) return (false, address(0));
        value = address(uint160(raw));
    }

    function _tryReadBool(address target, bytes memory callData) private view returns (bool success, bool value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length != 32) return (false, false);
        uint256 raw;
        assembly ("memory-safe") {
            raw := mload(add(result, 0x20))
        }
        if (raw > 1) return (false, false);
        value = raw == 1;
    }

    function _tryReadBytes32(
        address target,
        bytes memory callData
    ) private view returns (bool success, bytes32 value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length != 32) return (false, bytes32(0));
        assembly ("memory-safe") {
            value := mload(add(result, 0x20))
        }
    }

    function _tryReadUint256(
        address target,
        bytes memory callData
    ) private view returns (bool success, uint256 value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length != 32) return (false, 0);
        assembly ("memory-safe") {
            value := mload(add(result, 0x20))
        }
    }

    /// @dev Reads one ABI string of 1 to _MAX_VERSION_BYTES bytes with capped gas; anything else reads as false.
    function _tryReadString(
        address target,
        bytes memory callData
    ) private view returns (bool success, string memory value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length < 96) return (false, "");

        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(result, 0x20))
            length := mload(add(result, 0x40))
        }
        if (offset != 32 || length == 0 || length > _MAX_VERSION_BYTES) return (false, "");
        uint256 paddedLength = (length + 31) & ~uint256(31);
        if (result.length < 64 + paddedLength) return (false, "");
        value = abi.decode(result, (string));
    }

    function _registryImplementation() private view returns (address implementation) {
        bytes32 slot = _EIP1967_IMPLEMENTATION_SLOT;
        assembly ("memory-safe") {
            implementation := sload(slot)
        }
    }

    function _isInitializationAuthority(address caller) private view returns (bool) {
        try ICryftDelegationRootRegistry(_VALIDATOR_ROOT_REGISTRY).isRootOverlord(caller) returns (bool authorized) {
            return authorized;
        } catch {
            return false;
        }
    }

    /// @dev Genesis-proxy guardians (and the live root) may cancel, never schedule.
    function _isGenesisGuardian(address caller) private view returns (bool) {
        try ICryftDelegationGenesisProxy(address(this)).proxy_isGuardian(caller) returns (bool guardian) {
            return guardian;
        } catch {
            return false;
        }
    }

    function _requireContract(address target) private view {
        _requireNonZero(target);
        if (target.code.length == 0) revert AddressHasNoCode(target);
    }

    function _registryStorage() private pure returns (DelegationRegistryStorage storage state) {
        bytes32 location = _REGISTRY_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }

    function _requireNonZero(address value) private pure {
        if (value == address(0)) revert ZeroAddress();
    }
}
