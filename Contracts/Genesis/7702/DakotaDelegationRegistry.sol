// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/*
Dakota delegation registry v2: upgradeable release control plane at 0x...de1E6A7E.
The genesis proxy hosts registry state and owns the shared beacon after a two-step
handover. User EOAs designate the immutable dispatcher, not this proxy.
Initialization validates the dispatcher's immutable beacon and v2 protocol.
Releases validate implementation code hash, protocol, capabilities and interfaces.
Account readiness verifies the EIP-7702 designator, dispatcher runtime and account
protocol. The legacy proxyInitialized result now indicates immutable-route validity.
Registry administration and beacon ownership use explicit proposal/acceptance.
*/

import "./Interfaces/IDakotaDelegation.sol";
import "./Interfaces/IDakotaDelegationRegistry.sol";
import "./Interfaces/IGasSponsor.sol";
import "./Libraries/DakotaDelegationCapabilities.sol";
import "../Upgradeable/Initializable.sol";

interface IDakotaDelegationBeaconControl {
    function implementation() external view returns (address);

    function owner() external view returns (address);

    function upgradeTo(address newImplementation) external;

    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function cancelOwnershipTransfer() external;
}

interface IDakotaDelegationRootRegistry {
    function isRootOverlord(address account) external view returns (bool);
}

/// @title DakotaDelegationRegistry
/// @notice Release authority and introspection surface for Dakota EIP-7702.
/// @dev This implementation is first-linked at the fixed delegation entry.
///      That proxy owns the beacon and stores the shared release directory.
///      EIP-7702 users designate the immutable dispatcher in their authorization.
contract DakotaDelegationRegistry is
    Initializable,
    IDakotaDelegationRegistry
{
    error NotAdmin();
    error NotPendingAdmin();
    error NotInitializationAuthority(address caller);
    error WrongDelegationEntry(address actual);
    error ZeroAddress();
    error AddressHasNoCode(address target);
    error BeaconNotControlled(address currentOwner);
    error SameImplementation(address implementation);
    error EmptyCodeHash();
    error UnexpectedCodeHash(bytes32 expected, bytes32 actual);
    error IncompatibleProtocol(bytes32 expected, bytes32 actual);
    error MissingCapabilities(uint256 required, uint256 supplied);
    error UnsupportedDelegationInterface(address implementation);
    error InvalidImplementationMetadata(address implementation);
    error InvalidReleaseIndex(uint256 index);
    error BeaconUpgradeFailed(address expected, address actual);

    uint256 public constant CAPABILITY_SPONSORED_EXECUTION =
        DakotaDelegationCapabilities.SPONSORED_EXECUTION;
    uint256 public constant CAPABILITY_BATCHED_CALLS =
        DakotaDelegationCapabilities.BATCHED_CALLS;
    uint256 public constant CAPABILITY_EIP1271 =
        DakotaDelegationCapabilities.EIP1271;
    uint256 public constant CAPABILITY_NATIVE_RECEIVE =
        DakotaDelegationCapabilities.NATIVE_RECEIVE;
    uint256 public constant CAPABILITY_ERC721_RECEIVE =
        DakotaDelegationCapabilities.ERC721_RECEIVE;
    uint256 public constant CAPABILITY_ERC1155_RECEIVE =
        DakotaDelegationCapabilities.ERC1155_RECEIVE;
    uint256 public constant CAPABILITY_TYPED_DATA_HELPERS =
        DakotaDelegationCapabilities.TYPED_DATA_HELPERS;
    uint256 public constant CAPABILITY_REPLAY_PROTECTION =
        DakotaDelegationCapabilities.REPLAY_PROTECTION;

    uint256 private constant _REQUIRED_CAPABILITIES =
        DakotaDelegationCapabilities.REQUIRED_V1;
    uint256 private constant _READ_GAS_LIMIT = 200_000;
    uint256 private constant _MAX_VERSION_BYTES = 64;
    bytes4 private constant _PROXY_GET_IS_INIT_SELECTOR =
        bytes4(keccak256("proxy_getIsInit()"));
    bytes4 private constant _ERC165_INTERFACE_ID = 0x01ffc9a7;
    address private constant _DELEGATION_ENTRY =
        0x00000000000000000000000000000000de1E6A7E;
    address private constant _VALIDATOR_ROOT_REGISTRY =
        0x0000000000000000000000000000000000001111;
    bytes32 private constant _EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct ImplementationMetadata {
        bytes32 codeHash;
        bytes32 protocolId;
        uint256 capabilities;
        string version;
    }

    /// @custom:storage-location erc7201:dakota.storage.DakotaDelegationRegistry
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
    }

    bytes32 private constant _REGISTRY_STORAGE_LOCATION =
        0xab4cfcf4b885f9dbbc02cc8800e34faa6a47500834aa5c49ef09aafea9c84000;

    uint256[49] private __gap;

    modifier onlyAdmin() {
        if (msg.sender != _registryStorage().registryAdmin) {
            revert NotAdmin();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function initialize(
        address dispatcher_,
        address beacon_,
        address gasSponsor_
    ) external override initializer {
        _initializeRegistry(dispatcher_, beacon_, gasSponsor_, msg.sender);
    }

    function initializeWithAdmin(address dispatcher_, address beacon_, address gasSponsor_, address admin_) external initializer {
        _initializeRegistry(dispatcher_, beacon_, gasSponsor_, admin_);
    }

    function _initializeRegistry(address dispatcher_, address beacon_, address gasSponsor_, address admin_) private {
        require(admin_ != address(0) && admin_ != address(this)
            && admin_ != 0x0000000000000000000000000000000000FacAdE, "Invalid registry admin");
        if (address(this) != _DELEGATION_ENTRY) {
            revert WrongDelegationEntry(address(this));
        }
        if (!_isInitializationAuthority(msg.sender)) {
            revert NotInitializationAuthority(msg.sender);
        }
        _requireContract(dispatcher_);
        _requireContract(beacon_);
        _requireContract(gasSponsor_);

        DelegationRegistryStorage storage state = _registryStorage();
        (bool beaconMatches, address embeddedBeacon) = _tryReadAddress(dispatcher_, abi.encodeWithSignature("delegationBeacon()"));
        require(beaconMatches && embeddedBeacon == beacon_, "Dispatcher beacon mismatch");
        (bool protocolMatches, bytes memory protocolData) = dispatcher_.staticcall{gas: _READ_GAS_LIMIT}(abi.encodeWithSignature("dispatcherProtocolId()"));
        require(protocolMatches && protocolData.length == 32 && abi.decode(protocolData, (bytes32)) == keccak256("dakota.delegation.direct-beacon-dispatch.v2"), "Invalid dispatcher");
        state.delegationEntryCodeHash = dispatcher_.codehash;
        state.expectedAccountCodeHash = keccak256(
            abi.encodePacked(hex"ef0100", dispatcher_)
        );
        state.dispatcher = dispatcher_;
        state.beacon = beacon_;
        state.gasSponsor = gasSponsor_;
        state.registryAdmin = admin_;

        address initialImplementation =
            IDakotaDelegationBeaconControl(beacon_).implementation();
        ImplementationMetadata memory metadata =
            _validatedMetadata(initialImplementation, bytes32(0));
        state.expectedProtocolId = metadata.protocolId;
        _recordRelease(initialImplementation, metadata);

        emit RegistryInitialized(
            dispatcher_,
            beacon_,
            gasSponsor_,
            admin_,
            metadata.protocolId
        );
        emit RegistryAdminTransferred(address(0), admin_);
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function delegationEntry() external view override returns (address) {
        return _registryStorage().dispatcher;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function delegationEntryCodeHash()
        external
        view
        override
        returns (bytes32)
    {
        return _registryStorage().delegationEntryCodeHash;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function expectedAccountCodeHash()
        external
        view
        override
        returns (bytes32)
    {
        return _registryStorage().expectedAccountCodeHash;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function dispatcher() external view override returns (address) {
        return _registryStorage().dispatcher;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function beacon() external view override returns (address) {
        return _registryStorage().beacon;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function gasSponsor() external view override returns (address) {
        return _registryStorage().gasSponsor;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function expectedProtocolId() external view override returns (bytes32) {
        return _registryStorage().expectedProtocolId;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function registryAdmin() external view override returns (address) {
        return _registryStorage().registryAdmin;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function pendingRegistryAdmin()
        external
        view
        override
        returns (address)
    {
        return _registryStorage().pendingRegistryAdmin;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function registryImplementation()
        external
        view
        override
        returns (address implementation_)
    {
        return _registryImplementation();
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function registryVersion() external pure override returns (string memory) {
        return "1.0.0";
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function registryStorageLocation()
        external
        pure
        override
        returns (bytes32)
    {
        return _REGISTRY_STORAGE_LOCATION;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function genesisProxyAdmin() external pure override returns (address) {
        return 0x0000000000000000000000000000000000FacAdE;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function validatorRootRegistry() external pure override returns (address) {
        return _VALIDATOR_ROOT_REGISTRY;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function proposeAdmin(
        address pendingAdmin_
    ) external override onlyAdmin {
        _requireNonZero(pendingAdmin_);
        require(pendingAdmin_ != address(this) && pendingAdmin_ != 0x0000000000000000000000000000000000FacAdE, "Invalid registry administrator");
        DelegationRegistryStorage storage state = _registryStorage();
        state.pendingRegistryAdmin = pendingAdmin_;
        emit RegistryAdminTransferProposed(
            state.registryAdmin,
            pendingAdmin_
        );
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function acceptAdmin() external override {
        DelegationRegistryStorage storage state = _registryStorage();
        if (msg.sender != state.pendingRegistryAdmin) {
            revert NotPendingAdmin();
        }
        address previousAdmin = state.registryAdmin;
        state.registryAdmin = msg.sender;
        state.pendingRegistryAdmin = address(0);
        emit RegistryAdminTransferred(previousAdmin, msg.sender);
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function cancelAdminTransfer() external override onlyAdmin {
        DelegationRegistryStorage storage state = _registryStorage();
        state.pendingRegistryAdmin = address(0);
        emit RegistryAdminTransferProposed(
            state.registryAdmin,
            address(0)
        );
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function upgradeDelegation(
        address newImplementation,
        bytes32 expectedCodeHash
    ) external override onlyAdmin {
        if (expectedCodeHash == bytes32(0)) revert EmptyCodeHash();
        DelegationRegistryStorage storage state = _registryStorage();
        IDakotaDelegationBeaconControl beaconControl =
            IDakotaDelegationBeaconControl(state.beacon);
        address beaconOwner = beaconControl.owner();
        if (beaconOwner != address(this)) {
            revert BeaconNotControlled(beaconOwner);
        }

        address previousImplementation = beaconControl.implementation();
        if (newImplementation == previousImplementation) {
            revert SameImplementation(newImplementation);
        }

        ImplementationMetadata memory metadata =
            _validatedMetadata(newImplementation, expectedCodeHash);
        if (metadata.protocolId != state.expectedProtocolId) {
            revert IncompatibleProtocol(
                state.expectedProtocolId,
                metadata.protocolId
            );
        }

        beaconControl.upgradeTo(newImplementation);
        address activatedImplementation = beaconControl.implementation();
        if (activatedImplementation != newImplementation) {
            revert BeaconUpgradeFailed(
                newImplementation,
                activatedImplementation
            );
        }

        _recordRelease(newImplementation, metadata);
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function recordCurrentImplementation() external override onlyAdmin {
        DelegationRegistryStorage storage state = _registryStorage();
        address implementation_ =
            IDakotaDelegationBeaconControl(state.beacon).implementation();
        uint256 count = state.releases.length;
        if (
            count != 0 &&
            state.releases[count - 1].implementation == implementation_
        ) {
            revert SameImplementation(implementation_);
        }

        ImplementationMetadata memory metadata =
            _validatedMetadata(implementation_, bytes32(0));
        if (metadata.protocolId != state.expectedProtocolId) {
            revert IncompatibleProtocol(
                state.expectedProtocolId,
                metadata.protocolId
            );
        }
        _recordRelease(implementation_, metadata);
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function transferBeaconOwnership(
        address newOwner
    ) external override onlyAdmin {
        _requireNonZero(newOwner);
        DelegationRegistryStorage storage state = _registryStorage();
        IDakotaDelegationBeaconControl beaconControl =
            IDakotaDelegationBeaconControl(state.beacon);
        address previousOwner = beaconControl.owner();
        if (previousOwner != address(this)) {
            revert BeaconNotControlled(previousOwner);
        }
        beaconControl.transferOwnership(newOwner);
        emit BeaconOwnershipTransferProposed(previousOwner, newOwner);
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function acceptBeaconOwnership() external override onlyAdmin {
        IDakotaDelegationBeaconControl beaconControl = IDakotaDelegationBeaconControl(_registryStorage().beacon);
        address previousOwner = beaconControl.owner();
        beaconControl.acceptOwnership();
        require(beaconControl.owner() == address(this), "Beacon handover failed");
        emit BeaconOwnershipTransferred(previousOwner, address(this));
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function cancelBeaconOwnershipTransfer() external override onlyAdmin {
        IDakotaDelegationBeaconControl(_registryStorage().beacon).cancelOwnershipTransfer();
        emit BeaconOwnershipTransferProposed(address(this), address(0));
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function currentSnapshot()
        external
        view
        override
        returns (DelegationSnapshot memory snapshot)
    {
        DelegationRegistryStorage storage state = _registryStorage();
        IDakotaDelegationBeaconControl beaconControl =
            IDakotaDelegationBeaconControl(state.beacon);
        address implementation_ = beaconControl.implementation();
        address beaconOwner = beaconControl.owner();
        (
            bool metadataValid,
            ImplementationMetadata memory metadata
        ) = _tryImplementationMetadata(implementation_);
        bool interfacesValid =
            _supportsRequiredInterfaces(implementation_);

        bool sponsorUsesEntry;
        (bool sponsorDelegateSuccess, address approvedDelegate_) =
            _tryReadAddress(
                state.gasSponsor,
                abi.encodeCall(IGasSponsor.approvedDelegate, ())
            );
        if (sponsorDelegateSuccess) {
            sponsorUsesEntry = approvedDelegate_ == state.dispatcher;
        }

        bool matchesLatest;
        uint256 count = state.releases.length;
        if (count != 0) {
            Release storage latest = state.releases[count - 1];
            matchesLatest =
                latest.implementation == implementation_ &&
                latest.implementationCodeHash == implementation_.codehash;
        }

        snapshot = DelegationSnapshot({
            delegationEntry: state.dispatcher,
            delegationEntryCodeHash: state.delegationEntryCodeHash,
            expectedAccountCodeHash: state.expectedAccountCodeHash,
            dispatcher: state.dispatcher,
            beacon: state.beacon,
            beaconOwner: beaconOwner,
            registryImplementation: _registryImplementation(),
            registryVersion: "2.0.0",
            implementation: implementation_,
            implementationCodeHash: implementation_.codehash,
            protocolId: metadata.protocolId,
            capabilities: metadata.capabilities,
            version: metadata.version,
            implementationCompatible: metadataValid &&
                metadata.protocolId == state.expectedProtocolId &&
                (metadata.capabilities & _REQUIRED_CAPABILITIES) ==
                _REQUIRED_CAPABILITIES &&
                interfacesValid,
            registryControlsBeacon: beaconOwner == address(this),
            sponsorUsesDelegationEntry: sponsorUsesEntry,
            matchesLatestRelease: matchesLatest
        });
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function accountStatus(
        address account
    ) public view override returns (AccountStatus memory status) {
        if (account == address(0)) {
            return status;
        }

        DelegationRegistryStorage storage state = _registryStorage();
        status.delegatedToEntry =
            account.codehash == state.expectedAccountCodeHash;
        if (!status.delegatedToEntry) {
            return status;
        }

        // Legacy ABI field retained: direct dispatch requires no EOA proxy slots.
        status.proxyInitialized = state.dispatcher.codehash == state.delegationEntryCodeHash;
        (status.protocolCompatible, status.protocolId) =
            _accountProtocol(account);
        status.capabilities = _accountCapabilities(account);
        status.interfaceCompatible = _accountInterfaceCompatible(account);
        status.nonce = _accountNonce(account);
        status.implementationVersion = _accountVersion(account);
        status.sponsorReady = _accountSponsorReady(account);
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function isAccountReady(
        address account
    ) external view override returns (bool) {
        AccountStatus memory status = accountStatus(account);
        return
            status.delegatedToEntry &&
            status.proxyInitialized &&
            status.protocolCompatible &&
            status.interfaceCompatible &&
            status.sponsorReady &&
            (status.capabilities & _REQUIRED_CAPABILITIES) ==
            _REQUIRED_CAPABILITIES;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function supportsCurrentCapability(
        uint256 capabilityMask
    ) external view override returns (bool) {
        if (capabilityMask == 0) {
            return false;
        }
        DelegationRegistryStorage storage state = _registryStorage();
        address implementation_ =
            IDakotaDelegationBeaconControl(state.beacon).implementation();
        (bool success, uint256 capabilities_) = _tryReadUint256(
            implementation_,
            abi.encodeCall(IDakotaDelegation.delegationCapabilities, ())
        );
        return
            success &&
            (capabilities_ & capabilityMask) == capabilityMask;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function releaseAt(
        uint256 index
    ) external view override returns (Release memory release_, bool active) {
        DelegationRegistryStorage storage state = _registryStorage();
        uint256 count = state.releases.length;
        if (index >= count) revert InvalidReleaseIndex(index);
        release_ = state.releases[index];
        active =
            index == count - 1 &&
            release_.implementation ==
            IDakotaDelegationBeaconControl(state.beacon).implementation();
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function currentRelease()
        external
        view
        override
        returns (Release memory release_)
    {
        DelegationRegistryStorage storage state = _registryStorage();
        uint256 count = state.releases.length;
        if (count == 0) revert InvalidReleaseIndex(0);
        release_ = state.releases[count - 1];
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function releaseCount() external view override returns (uint256) {
        return _registryStorage().releases.length;
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function getAccountNonce(
        address account
    ) external view override returns (uint256) {
        return IDakotaDelegation(account).getNonce();
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function getAccountDomainSeparator(
        address account
    ) external view override returns (bytes32) {
        return IDakotaDelegation(account).domainSeparator();
    }

    /// @inheritdoc IDakotaDelegationRegistry
    function getAccountExecutionDigest(
        address account,
        bytes32 operationId,
        address executor,
        IDakotaDelegation.Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        uint256 executionGasLimit
    ) external view override returns (bytes32) {
        return
            IDakotaDelegation(account).getExecutionDigest(
                operationId,
                executor,
                calls,
                nonce,
                deadline,
                executionGasLimit
            );
    }

    function _recordRelease(
        address implementation_,
        ImplementationMetadata memory metadata
    ) private {
        DelegationRegistryStorage storage state = _registryStorage();
        uint64 sequence = uint64(state.releases.length + 1);
        state.releases.push(
            Release({
                sequence: sequence,
                activationBlock: uint64(block.number),
                activationTimestamp: uint64(block.timestamp),
                implementation: implementation_,
                implementationCodeHash: metadata.codeHash,
                protocolId: metadata.protocolId,
                capabilities: metadata.capabilities,
                version: metadata.version
            })
        );
        emit DelegationReleaseRecorded(
            sequence,
            implementation_,
            metadata.codeHash,
            metadata.protocolId,
            metadata.capabilities,
            metadata.version
        );
    }

    function _validatedMetadata(
        address implementation_,
        bytes32 expectedCodeHash
    ) private view returns (ImplementationMetadata memory metadata) {
        _requireContract(implementation_);
        bytes32 actualCodeHash = implementation_.codehash;
        if (
            expectedCodeHash != bytes32(0) &&
            expectedCodeHash != actualCodeHash
        ) {
            revert UnexpectedCodeHash(expectedCodeHash, actualCodeHash);
        }

        (bool success, ImplementationMetadata memory inspected) =
            _tryImplementationMetadata(implementation_);
        if (!success) {
            revert InvalidImplementationMetadata(implementation_);
        }
        if (
            (inspected.capabilities & _REQUIRED_CAPABILITIES) !=
            _REQUIRED_CAPABILITIES
        ) {
            revert MissingCapabilities(
                _REQUIRED_CAPABILITIES,
                inspected.capabilities
            );
        }

        if (!_supportsRequiredInterfaces(implementation_)) {
            revert UnsupportedDelegationInterface(implementation_);
        }
        metadata = inspected;
    }

    function _tryImplementationMetadata(
        address implementation_
    )
        private
        view
        returns (bool success, ImplementationMetadata memory metadata)
    {
        if (implementation_ == address(0) || implementation_.code.length == 0) {
            return (false, metadata);
        }

        (bool protocolSuccess, bytes32 protocolId_) = _tryReadBytes32(
            implementation_,
            abi.encodeCall(IDakotaDelegation.delegationProtocolId, ())
        );
        (bool capabilitiesSuccess, uint256 capabilities_) = _tryReadUint256(
            implementation_,
            abi.encodeCall(IDakotaDelegation.delegationCapabilities, ())
        );
        (bool versionSuccess, string memory version_) = _tryReadString(
            implementation_,
            abi.encodeCall(IDakotaDelegation.implementationVersion, ())
        );

        success =
            protocolSuccess &&
            protocolId_ != bytes32(0) &&
            capabilitiesSuccess &&
            capabilities_ != 0 &&
            versionSuccess &&
            bytes(version_).length != 0;
        metadata = ImplementationMetadata({
            codeHash: implementation_.codehash,
            protocolId: protocolId_,
            capabilities: capabilities_,
            version: version_
        });
    }

    function _supportsRequiredInterfaces(
        address implementation_
    ) private view returns (bool) {
        (bool erc165Success, bool supportsErc165) = _tryReadBool(
            implementation_,
            abi.encodeCall(
                IDakotaDelegation.supportsInterface,
                (_ERC165_INTERFACE_ID)
            )
        );
        if (!erc165Success || !supportsErc165) {
            return false;
        }

        (bool delegationSuccess, bool supportsDelegation) = _tryReadBool(
            implementation_,
            abi.encodeCall(
                IDakotaDelegation.supportsInterface,
                (type(IDakotaDelegation).interfaceId)
            )
        );
        return delegationSuccess && supportsDelegation;
    }

    function _accountProxyInitialized(
        address account
    ) private view returns (bool) {
        (bool success, bool initialized_) = _tryReadBool(
            account,
            abi.encodeWithSelector(_PROXY_GET_IS_INIT_SELECTOR)
        );
        return success && initialized_;
    }

    function _accountProtocol(
        address account
    ) private view returns (bool compatible, bytes32 protocolId_) {
        (bool success, bytes32 value) = _tryReadBytes32(
            account,
            abi.encodeCall(IDakotaDelegation.delegationProtocolId, ())
        );
        protocolId_ = value;
        compatible =
            success &&
            value == _registryStorage().expectedProtocolId;
    }

    function _accountCapabilities(
        address account
    ) private view returns (uint256) {
        (bool success, uint256 value) = _tryReadUint256(
            account,
            abi.encodeCall(IDakotaDelegation.delegationCapabilities, ())
        );
        return success ? value : 0;
    }

    function _accountInterfaceCompatible(
        address account
    ) private view returns (bool) {
        (bool success, bool supported) = _tryReadBool(
            account,
            abi.encodeCall(
                IDakotaDelegation.supportsInterface,
                (type(IDakotaDelegation).interfaceId)
            )
        );
        return success && supported;
    }

    function _accountNonce(
        address account
    ) private view returns (uint256) {
        (bool success, uint256 value) = _tryReadUint256(
            account,
            abi.encodeCall(IDakotaDelegation.getNonce, ())
        );
        return success ? value : 0;
    }

    function _accountVersion(
        address account
    ) private view returns (string memory) {
        (bool success, string memory value) = _tryReadString(
            account,
            abi.encodeCall(IDakotaDelegation.implementationVersion, ())
        );
        return success ? value : "";
    }

    function _accountSponsorReady(
        address account
    ) private view returns (bool) {
        (bool success, bool ready) = _tryReadBool(
            _registryStorage().gasSponsor,
            abi.encodeCall(IGasSponsor.isDelegationReady, (account))
        );
        return success && ready;
    }

    function _tryReadAddress(
        address target,
        bytes memory callData
    ) private view returns (bool success, address value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length != 32) {
            return (false, address(0));
        }
        uint256 raw;
        assembly ("memory-safe") {
            raw := mload(add(result, 0x20))
        }
        if (raw > type(uint160).max) {
            return (false, address(0));
        }
        value = address(uint160(raw));
    }

    function _tryReadBool(
        address target,
        bytes memory callData
    ) private view returns (bool success, bool value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length != 32) {
            return (false, false);
        }
        uint256 raw;
        assembly ("memory-safe") {
            raw := mload(add(result, 0x20))
        }
        if (raw > 1) {
            return (false, false);
        }
        value = raw == 1;
    }

    function _tryReadBytes32(
        address target,
        bytes memory callData
    ) private view returns (bool success, bytes32 value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length != 32) {
            return (false, bytes32(0));
        }
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
        if (!success || result.length != 32) {
            return (false, 0);
        }
        assembly ("memory-safe") {
            value := mload(add(result, 0x20))
        }
    }

    function _tryReadString(
        address target,
        bytes memory callData
    ) private view returns (bool success, string memory value) {
        bytes memory result;
        (success, result) = target.staticcall{gas: _READ_GAS_LIMIT}(callData);
        if (!success || result.length < 96) {
            return (false, "");
        }

        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(result, 0x20))
            length := mload(add(result, 0x40))
        }
        if (
            offset != 32 ||
            length == 0 ||
            length > _MAX_VERSION_BYTES
        ) {
            return (false, "");
        }
        uint256 paddedLength = (length + 31) & ~uint256(31);
        if (result.length < 64 + paddedLength) {
            return (false, "");
        }
        value = abi.decode(result, (string));
    }

    function _registryImplementation()
        private
        view
        returns (address implementation_)
    {
        bytes32 slot = _EIP1967_IMPLEMENTATION_SLOT;
        assembly ("memory-safe") {
            implementation_ := sload(slot)
        }
    }

    function _isInitializationAuthority(
        address caller
    ) private view returns (bool) {
        try IDakotaDelegationRootRegistry(
            _VALIDATOR_ROOT_REGISTRY
        ).isRootOverlord(caller) returns (bool authorized) {
            return authorized;
        } catch {
            return false;
        }
    }

    function _registryStorage()
        private
        pure
        returns (DelegationRegistryStorage storage state)
    {
        bytes32 location = _REGISTRY_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }

    function _requireContract(address target) private view {
        _requireNonZero(target);
        if (target.code.length == 0) {
            revert AddressHasNoCode(target);
        }
    }

    function _requireNonZero(address value) private pure {
        if (value == address(0)) revert ZeroAddress();
    }
}
