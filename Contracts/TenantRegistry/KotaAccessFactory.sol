// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cryft Labs
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IKotaTenantAccessReceiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

interface IKotaRegistryFactoryPolicy {
    function maxHoldersForRegistry(address registry) external view returns (uint256);
    function validateTenantOperator(address operator_)
        external view returns (uint256 maxRegistries, uint256 maxHoldersPerRegistry);
    function registryFeatureEnabled(address registry, uint256 feature) external view returns (bool);
    function coordinateTenantOperatorChange(address newOperator) external;
}

/// @title KotaTenantAccessSBT — standardized per-tenant soulbound membership registry
/// @notice Deployed ONLY by KotaAccessFactory. Non-transferable ERC-721 (ERC-5192).
///         Two authority planes:
///           * PLATFORM (factory admin): can lock/unlock the whole registry.
///             While locked, `balanceOf` reports 0 for everyone, so every
///             router gate and third-party balance check fails instantly —
///             suspension needs no router redeploy. (Documented deviation:
///             lock changes reported balances without Transfer events;
///             `rawBalanceOf` exposes the true holdings for tooling.)
///           * TENANT (operator): issues/revokes its own user credentials.
contract KotaTenantAccessSBT is Initializable {
    using Strings for uint256;

    uint256 public constant MAX_BATCH_SIZE = 100;
    address private immutable _implementationSelf = address(this);

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Locked(uint256 tokenId); // ERC-5192: locked unless operator approves a transfer
    event Unlocked(uint256 tokenId);
    event TransferApproved(uint256 indexed tokenId, address indexed to);
    event TransferApprovalCancelled(uint256 indexed tokenId);
    event RegistryLockChanged(bool locked);
    event OperatorChanged(address indexed previousOperator, address indexed newOperator);
    event AccessGranted(address indexed holder, uint256 indexed tokenId);
    event AccessRevoked(address indexed holder, uint256 indexed tokenId);
    event TierCreated(uint32 indexed tierId, string label);
    event TierMetadataUpdated(uint32 indexed tierId);
    event TierAssigned(address indexed holder, uint32 indexed tierId);
    event DefaultTierChanged(uint32 indexed previousTierId, uint32 indexed newTierId);
    event OriginAdded(string origin);
    event OriginRemoved(string origin);

    error UnknownTier();
    error NotHolder();
    error NotBackup();
    error NoPendingOperator();
    error HolderCapReached();

    event BackupApproverChanged(address indexed backup);
    event OperatorChangeProposed(address indexed proposed);
    event MinterChanged(address indexed minter, bool allowed);
    event CollectionMetadataUpdated(string name, string symbol, string contractMetadataURI);
    event TokenMetadataConfigurationUpdated(
        string baseTokenURI,
        string tokenURISuffix,
        string placeholderTokenURI,
        bool revealed
    );
    event PerTokenMetadataEnabled(bool enabled);
    event TokenMetadataURIUpdated(uint256 indexed tokenId, string metadataURI);
    event MetadataUpdaterChanged(address indexed updater);

    error NotFactory();
    error NotOperator();
    error RegistryIsLocked();
    error Soulbound();
    error AlreadyHolder();
    error UnknownToken();
    error ZeroAddress();
    error NotAuthorizedToBurn();
    error UnsafeRecipient();
    error AlreadyInitialized();
    error TierFeatureRequired();
    error InvalidMetadataURI();
    error InvalidCollectionIdentity();
    error PerTokenMetadataNotEnabled();
    error BatchLengthMismatch();
    error BatchTooLarge();

    string public name;
    string public symbol;
    string public tenantId;
    address public operator;      // tenant wallet managing this registry
    bool public registryLocked;   // platform suspension switch
    uint256 public totalMinted;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(address => uint256) public tokenOf; // one credential per wallet
    mapping(uint256 => address) private _approvedTransferTo; // operator-approved escrow

    // ---- appendable tenant-defined tiers (optional; 0 = default) ----
    // The platform predefines nothing: tenants append tiers post-deploy and
    // assign holders as their own system's rules require. Tier 0 is retained
    // for legacy holders; new grants use the operator-selected default tier.
    uint32 public tierCount; // ids 1..tierCount; 0 is the implicit default
    mapping(uint32 => string) public tierLabel;
    mapping(uint32 => string) public tierMetadata; // tenant-owned rules blob/URI
    mapping(address => uint32) public tierOf;      // holder -> tier (0 default)

    // ---- origin/domain whitelist (anti resource-theft) ----
    // Together with the registry address serving as the tenant's public
    // routing key, these origins define which domains may consume the
    // tenant's paid plan. Kota enforces origin binding at the router.
    string[] private _allowedOrigins;

    /// @dev Preserves the v2 fixed `maxHolders` storage position. New v3
    /// registries derive the effective limit from the factory and never read or
    /// write this slot. It must remain here and must never be repurposed.
    uint256 private _legacyMaxHoldersSlot;

    /// Registry standard version (factory upgrade migrations query this).
    string public constant registryVersion = "kota.tenant_registry.v8";
    uint256 public activeHolders;
    /// Operator-delegated minting keys (tenant backend hot wallets).
    mapping(address => bool) private _minters;
    /// Optional tenant-set second-approval wallet for operator changes.
    address public backupApprover;
    address public pendingOperator;

    // ---- append-only registry and metadata state (slots 19+) ----
    // The v3 layout through pendingOperator is intentionally unchanged.
    address public factory;
    string private _contractMetadataURI;
    string private _baseTokenURI;
    string private _placeholderTokenURI;
    string private _tokenURISuffix;
    bool public metadataRevealed;
    bool public perTokenMetadataEnabled;
    mapping(uint256 => string) private _tokenMetadataURI;

    // Append-only recovery epochs; legacy values remain effective at epoch zero.
    uint256 public authorityEpoch;
    mapping(address => uint256) private _minterEpoch;
    mapping(uint256 => uint256) private _transferApprovalEpoch;
    event AuthorityPermissionsInvalidated(uint256 epoch);

    // Append-only: zero preserves enrollment behavior until the operator selects
    // an existing tier. Changing this does not change any existing credential.
    uint32 public defaultTierId;

    // Append-only: the one key, besides the operator, that may write per-token metadata URIs (and nothing else). It lets a
    // service keep each pass's picture current (its plan's) without ever holding the operator's key. Bound to the authority
    // epoch exactly as minters are, so an operator recovery (factory setOperator) drops it with every other delegated key.
    address private _metadataUpdater;
    uint256 private _metadataUpdaterEpoch;

    function metadataUpdater() public view returns (address) {
        return _metadataUpdaterEpoch == authorityEpoch ? _metadataUpdater : address(0);
    }

    function minters(address account) public view returns (bool) {
        return _minters[account] && _minterEpoch[account] == authorityEpoch;
    }

    modifier onlyFactory() { if (msg.sender != factory) revert NotFactory(); _; }
    modifier onlyOperator() { if (msg.sender != operator) revert NotOperator(); _; }
    modifier whenUnlocked() { if (registryLocked) revert RegistryIsLocked(); _; }
    modifier onlyMetadataWriter() {
        if (msg.sender != operator && msg.sender != metadataUpdater()) revert NotOperator();  // a cleared updater is zero: never a sender
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata tenantId_,
        address operator_,
        string[] calldata initialOrigins
    ) external initializer {
        if (factory != address(0)) revert AlreadyInitialized();
        if (operator_ == address(0)) revert ZeroAddress();
        if (msg.sender == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        tenantId = tenantId_;
        factory = msg.sender;
        operator = operator_;
        for (uint256 i = 0; i < initialOrigins.length; i++) {
            _allowedOrigins.push(initialOrigins[i]);
            emit OriginAdded(initialOrigins[i]);
        }
        emit OperatorChanged(address(0), operator_);
    }

    // ---- tier management (tenant plane) ----
    function createTier(string calldata label, string calldata metadata)
        external onlyOperator whenUnlocked returns (uint32 tierId)
    {
        tierId = ++tierCount;
        tierLabel[tierId] = label;
        tierMetadata[tierId] = metadata;
        emit TierCreated(tierId, label);
    }

    function setTierMetadata(uint32 tierId, string calldata metadata) external onlyOperator whenUnlocked {
        if (tierId == 0 || tierId > tierCount) revert UnknownTier();
        tierMetadata[tierId] = metadata;
        emit TierMetadataUpdated(tierId);
    }

    /// @notice Choose the existing tier assigned atomically by every new grant.
    /// Minters cannot choose a different tier or change this policy.
    function setDefaultTier(uint32 tierId) external onlyOperator whenUnlocked {
        if (tierId == 0 || tierId > tierCount) revert UnknownTier();
        uint32 previous = defaultTierId;
        defaultTierId = tierId;
        emit DefaultTierChanged(previous, tierId);
    }

    /// @notice Compatibility with membership-aware sponsorship policies.
    /// Tenant tiers cannot be deleted; suspension uses registryLocked instead.
    function tierActive(uint32 tierId) external view returns (bool) {
        return !registryLocked && tierId <= tierCount;
    }

    function assignTier(address holder, uint32 tierId) public onlyOperator whenUnlocked {
        if (tierId > tierCount) revert UnknownTier(); // 0 resets to default
        if (_balanceOf[holder] == 0) revert NotHolder();
        tierOf[holder] = tierId;
        emit TierAssigned(holder, tierId);
    }

    function assignTierBatch(address[] calldata holders, uint32 tierId) external onlyOperator whenUnlocked {
        if (tierId > tierCount) revert UnknownTier();
        for (uint256 i = 0; i < holders.length; i++) {
            if (_balanceOf[holders[i]] != 0) {
                tierOf[holders[i]] = tierId;
                emit TierAssigned(holders[i], tierId);
            }
        }
    }

    // ---- origin whitelist management (tenant plane) ----
    function addAllowedOrigin(string calldata origin) external onlyOperator whenUnlocked {
        _allowedOrigins.push(origin);
        emit OriginAdded(origin);
    }

    function removeAllowedOrigin(uint256 index) external onlyOperator whenUnlocked {
        if (index >= _allowedOrigins.length) revert UnknownToken();
        emit OriginRemoved(_allowedOrigins[index]);
        _allowedOrigins[index] = _allowedOrigins[_allowedOrigins.length - 1];
        _allowedOrigins.pop();
    }

    function allowedOrigins() external view returns (string[] memory) {
        return _allowedOrigins;
    }

    function _requireFeature(uint256 feature) private view {
        if (!IKotaRegistryFactoryPolicy(factory).registryFeatureEnabled(address(this), feature)) {
            revert TierFeatureRequired();
        }
    }

    function _requireIpfsOrEmpty(string memory uri) private pure {
        bytes memory value = bytes(uri);
        if (value.length == 0) return;
        if (
            value.length < 7
                || value[0] != "i" || value[1] != "p" || value[2] != "f"
                || value[3] != "s" || value[4] != ":" || value[5] != "/"
                || value[6] != "/"
        ) revert InvalidMetadataURI();
    }

    /// @notice Tier-gated collection branding and contract-level metadata.
    ///         The URI must identify an IPFS JSON metadata document.
    function setCollectionMetadata(
        string calldata name_,
        string calldata symbol_,
        string calldata contractMetadataURI_
    ) external onlyOperator whenUnlocked {
        _requireFeature(1 << 0);
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert InvalidCollectionIdentity();
        }
        _requireIpfsOrEmpty(contractMetadataURI_);
        name = name_;
        symbol = symbol_;
        _contractMetadataURI = contractMetadataURI_;
        emit CollectionMetadataUpdated(name_, symbol_, contractMetadataURI_);
    }

    /// @notice Configure shared ERC-721 metadata and optional pre-reveal JSON.
    function setTokenMetadataConfiguration(
        string calldata baseTokenURI_,
        string calldata tokenURISuffix_,
        string calldata placeholderTokenURI_,
        bool revealed_
    ) external onlyOperator whenUnlocked {
        _requireFeature(1 << 0);
        _requireIpfsOrEmpty(baseTokenURI_);
        _requireIpfsOrEmpty(placeholderTokenURI_);
        _baseTokenURI = baseTokenURI_;
        _tokenURISuffix = tokenURISuffix_;
        _placeholderTokenURI = placeholderTokenURI_;
        metadataRevealed = revealed_;
        emit TokenMetadataConfigurationUpdated(
            baseTokenURI_, tokenURISuffix_, placeholderTokenURI_, revealed_
        );
    }

    function setMetadataRevealed(bool revealed_) external onlyOperator whenUnlocked {
        _requireFeature(1 << 0);
        metadataRevealed = revealed_;
        emit TokenMetadataConfigurationUpdated(
            _baseTokenURI, _tokenURISuffix, _placeholderTokenURI, revealed_
        );
    }

    /// @notice Enabling custom token JSON requires the tier feature. Disabling
    ///         remains available so an operator can always return to base data.
    function setPerTokenMetadataEnabled(bool enabled) external onlyOperator whenUnlocked {
        if (enabled) _requireFeature(1 << 1);
        perTokenMetadataEnabled = enabled;
        emit PerTokenMetadataEnabled(enabled);
    }

    /// @notice The operator names (or clears, with zero) the metadata updater: a key allowed ONLY setTokenMetadataURI and
    ///         setTokenMetadataURIBatch, under every check they keep (tier feature, per-token switch, known token, ipfs://).
    function setMetadataUpdater(address updater) external onlyOperator whenUnlocked {
        _metadataUpdater = updater;
        _metadataUpdaterEpoch = authorityEpoch;
        emit MetadataUpdaterChanged(updater);
    }

    function setTokenMetadataURI(uint256 tokenId, string calldata metadataURI)
        public onlyMetadataWriter whenUnlocked
    {
        _requireFeature(1 << 1);
        if (!perTokenMetadataEnabled) revert PerTokenMetadataNotEnabled();
        if (_ownerOf[tokenId] == address(0)) revert UnknownToken();
        _requireIpfsOrEmpty(metadataURI);
        _tokenMetadataURI[tokenId] = metadataURI;
        emit TokenMetadataURIUpdated(tokenId, metadataURI);
    }

    function setTokenMetadataURIBatch(
        uint256[] calldata tokenIds,
        string[] calldata metadataURIs
    ) external onlyMetadataWriter whenUnlocked {
        _requireFeature(1 << 1);
        if (!perTokenMetadataEnabled) revert PerTokenMetadataNotEnabled();
        if (tokenIds.length != metadataURIs.length) revert BatchLengthMismatch();
        if (tokenIds.length == 0 || tokenIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_ownerOf[tokenIds[i]] == address(0)) revert UnknownToken();
            _requireIpfsOrEmpty(metadataURIs[i]);
        }
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            _tokenMetadataURI[tokenId] = metadataURIs[i];
            emit TokenMetadataURIUpdated(tokenId, metadataURIs[i]);
        }
    }

    function contractURI() external view returns (string memory) {
        return _contractMetadataURI;
    }

    function baseTokenURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    function placeholderTokenURI() external view returns (string memory) {
        return _placeholderTokenURI;
    }

    function tokenURISuffix() external view returns (string memory) {
        return _tokenURISuffix;
    }

    function tokenMetadataURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf[tokenId] == address(0)) revert UnknownToken();
        return _tokenMetadataURI[tokenId];
    }

    /// @notice Live plan-derived cap for this registry. Zero means unlimited.
    function maxHolders() public view returns (uint256) {
        return IKotaRegistryFactoryPolicy(factory).maxHoldersForRegistry(address(this));
    }

    // ---- platform plane (via factory only) ----
    function setRegistryLocked(bool locked_) external onlyFactory {
        registryLocked = locked_;
        emit RegistryLockChanged(locked_);
    }

    // ---- tenant plane ----
    modifier onlyMinting() {
        if (msg.sender != operator && !minters(msg.sender)) revert NotOperator();
        _;
    }

    function setMinter(address minter, bool allowed) external onlyOperator whenUnlocked {
        if (minter == address(0)) revert ZeroAddress();
        _minters[minter] = allowed;
        _minterEpoch[minter] = authorityEpoch;
        emit MinterChanged(minter, allowed);
    }

    function grantAccess(address holder) external onlyMinting whenUnlocked returns (uint256 tokenId) {
        if (holder == address(0)) revert ZeroAddress();
        if (_balanceOf[holder] != 0) revert AlreadyHolder();
        uint256 holderLimit = maxHolders();
        if (holderLimit != 0 && activeHolders >= holderLimit) revert HolderCapReached();
        activeHolders++;
        tokenId = ++totalMinted;
        _ownerOf[tokenId] = holder;
        _balanceOf[holder] = 1;
        tokenOf[holder] = tokenId;
        tierOf[holder] = defaultTierId;
        emit Transfer(address(0), holder, tokenId);
        emit Locked(tokenId);
        emit AccessGranted(holder, tokenId);
        emit TierAssigned(holder, defaultTierId);
    }

    function grantAccessBatch(address[] calldata holders) external onlyMinting whenUnlocked {
        if (holders.length == 0 || holders.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        uint256 holderLimit = maxHolders();
        uint256 newHolderCount;
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            if (holder == address(0)) revert ZeroAddress();
            if (_balanceOf[holder] != 0) continue;
            bool duplicate;
            for (uint256 j = 0; j < i; j++) {
                if (holders[j] == holder) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) newHolderCount++;
        }
        if (holderLimit != 0 && activeHolders + newHolderCount > holderLimit) {
            revert HolderCapReached();
        }
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            if (_balanceOf[holder] != 0) continue; // idempotent onboarding
            activeHolders++;
            uint256 tokenId = ++totalMinted;
            _ownerOf[tokenId] = holder;
            _balanceOf[holder] = 1;
            tokenOf[holder] = tokenId;
            tierOf[holder] = defaultTierId;
            emit Transfer(address(0), holder, tokenId);
            emit Locked(tokenId);
            emit AccessGranted(holder, tokenId);
            emit TierAssigned(holder, defaultTierId);
        }
    }

    function revokeAccess(address holder) external {
        uint256 tokenId = tokenOf[holder];
        if (tokenId == 0) revert UnknownToken();
        // Operator revokes (when unlocked); holders may always renounce.
        if (msg.sender == operator) {
            if (registryLocked) revert RegistryIsLocked();
        } else if (msg.sender != holder) {
            revert NotAuthorizedToBurn();
        }
        delete _ownerOf[tokenId];
        delete tokenOf[holder];
        delete _approvedTransferTo[tokenId];
        delete tierOf[holder];
        _balanceOf[holder] = 0;
        if (activeHolders > 0) activeHolders--;
        emit Transfer(holder, address(0), tokenId);
        emit AccessRevoked(holder, tokenId);
    }

    /// @notice Tenant sets (or clears) the wallet whose second approval is
    ///         required for operator changes. Optional hardening.
    function setBackupApprover(address backup) external onlyOperator whenUnlocked {
        delete pendingOperator;
        backupApprover = backup;
        emit BackupApproverChanged(backup);
    }

    /// @notice Operator change. Factory (platform recovery) applies instantly.
    ///         Operator-initiated changes apply instantly ONLY when no backup
    ///         approver is set; otherwise they await the backup's approval tx.
    function setOperator(address newOperator) external {
        if (newOperator == address(0)) revert ZeroAddress();
        IKotaRegistryFactoryPolicy(factory).validateTenantOperator(newOperator);
        if (msg.sender == factory) {
            if (newOperator != operator) {
                authorityEpoch++;
                delete backupApprover;
                emit BackupApproverChanged(address(0));
                emit AuthorityPermissionsInvalidated(authorityEpoch);
            }
            emit OperatorChanged(operator, newOperator);
            operator = newOperator;
            delete pendingOperator;
            return;
        }
        if (msg.sender != operator) revert NotOperator();
        if (backupApprover == address(0)) {
            IKotaRegistryFactoryPolicy(factory).coordinateTenantOperatorChange(newOperator);
        } else {
            pendingOperator = newOperator;
            emit OperatorChangeProposed(newOperator);
        }
    }

    /// @notice Second-approval tx from the tenant's backup wallet.
    function approveOperatorChange() external {
        if (msg.sender != backupApprover) revert NotBackup();
        if (pendingOperator == address(0)) revert NoPendingOperator();
        IKotaRegistryFactoryPolicy(factory).validateTenantOperator(pendingOperator);
        IKotaRegistryFactoryPolicy(factory).coordinateTenantOperatorChange(pendingOperator);
    }

    // ---- ERC-165 / ERC-5192 / ERC-721 views ----
    /// @dev 0x4b4f5441 ("KOTA") marks a genuine Kota tenant registry.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0x5b5e139f
            || id == 0xb45a3c0e || id == 0x4b4f5441;
    }

    /// @notice Identifies the direct logic deployment. Calls through another
    ///         proxy return the underlying logic address, allowing the factory
    ///         to reject unsafe proxy-behind-proxy beacon implementations.
    function implementationSelf() external view returns (address) {
        return _implementationSelf;
    }

    /// @notice Effective approval; changing authority invalidates all older approvals.
    function approvedTransferTo(uint256 tokenId) public view returns (address) {
        return _transferApprovalEpoch[tokenId] == authorityEpoch
            ? _approvedTransferTo[tokenId] : address(0);
    }

    function locked(uint256 tokenId) external view returns (bool) {
        if (_ownerOf[tokenId] == address(0)) revert UnknownToken();
        return approvedTransferTo(tokenId) == address(0);
    }

    /// @notice Reports 0 while the registry is platform-locked (enforcement).
    function balanceOf(address holder) external view returns (uint256) {
        if (holder == address(0)) revert ZeroAddress();
        return registryLocked ? 0 : _balanceOf[holder];
    }

    /// @notice True holdings regardless of lock (tooling/audits).
    function rawBalanceOf(address holder) external view returns (uint256) {
        return _balanceOf[holder];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address holder = _ownerOf[tokenId];
        if (holder == address(0)) revert UnknownToken();
        return holder;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf[tokenId] == address(0)) revert UnknownToken();
        if (!metadataRevealed && bytes(_placeholderTokenURI).length != 0) {
            return _placeholderTokenURI;
        }
        if (perTokenMetadataEnabled && bytes(_tokenMetadataURI[tokenId]).length != 0) {
            return _tokenMetadataURI[tokenId];
        }
        if (bytes(_baseTokenURI).length == 0) return "";
        return string.concat(_baseTokenURI, tokenId.toString(), _tokenURISuffix);
    }

    // Transfers execute ONLY along a tenant-operator-approved escrow path,
    // and never while the registry is platform-locked.
    function approveTransfer(uint256 tokenId, address to) external onlyOperator whenUnlocked {
        if (_ownerOf[tokenId] == address(0)) revert UnknownToken();
        if (to == address(0)) revert ZeroAddress();
        if (_balanceOf[to] != 0) revert AlreadyHolder();
        _approvedTransferTo[tokenId] = to;
        _transferApprovalEpoch[tokenId] = authorityEpoch;
        emit TransferApproved(tokenId, to);
        emit Unlocked(tokenId);
    }

    function cancelTransferApproval(uint256 tokenId) external onlyOperator {
        if (_ownerOf[tokenId] == address(0)) revert UnknownToken();
        delete _approvedTransferTo[tokenId];
        emit TransferApprovalCancelled(tokenId);
        emit Locked(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public whenUnlocked {
        address holder = _ownerOf[tokenId];
        if (holder == address(0)) revert UnknownToken();
        if (holder != from || msg.sender != holder && msg.sender != operator) revert Soulbound();
        if (to == address(0)) revert ZeroAddress();
        if (approvedTransferTo(tokenId) != to) revert Soulbound();
        if (_balanceOf[to] != 0) revert AlreadyHolder();
        delete _approvedTransferTo[tokenId];
        delete tokenOf[from];
        _balanceOf[from] = 0;
        _ownerOf[tokenId] = to;
        _balanceOf[to] = 1;
        tokenOf[to] = tokenId;
        // Tier assignment follows the credential to the new wallet.
        tierOf[to] = tierOf[from];
        delete tierOf[from];
        emit Transfer(from, to, tokenId);
        emit Locked(tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, "");
    }
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data)
        private
    {
        if (to.code.length == 0) return;
        try IKotaTenantAccessReceiver(to).onERC721Received(msg.sender, from, tokenId, data)
            returns (bytes4 response)
        {
            if (response != IKotaTenantAccessReceiver.onERC721Received.selector) {
                revert UnsafeRecipient();
            }
        } catch {
            revert UnsafeRecipient();
        }
    }
    function approve(address, uint256) external pure { revert Soulbound(); }
    function setApprovalForAll(address, bool) external pure { revert Soulbound(); }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }
}

/// @notice Minimal view of the platform admin registry, used to gate
///         deployments by the tenant's on-chain plan tier.
interface IKotaAdminRegistry {
    function tierOf(address holder) external view returns (uint32);
    function tierLimits(uint32 tierId)
        external view returns (uint256 maxRegistries, uint256 maxHoldersPerRegistry);
    function tierActive(uint32 tierId) external view returns (bool);
    function tierFeatures(uint32 tierId) external view returns (uint256);
    function balanceOf(address holder) external view returns (uint256);
    function hasRole(address holder, uint8 minimumRole) external view returns (bool);
}

/// @title KotaAccessFactory — deploys and governs per-tenant access registries
/// @notice The system admin deploys one standardized KotaTenantAccessSBT per
///         tenant, retains the lock/unlock switch on every registry, and can
///         recover operator keys. Tenants manage their own user credentials.
contract KotaAccessFactory is Initializable {
    /// Bounds atomic recovery/lock loops, including retired stable slots.
    uint256 public constant MAX_REGISTRY_SLOTS_PER_TENANT = 128;
    error RegistryHistoryLimitReached();
    error InvalidAdminRegistry();
    uint8 private constant ROLE_TENANT = 1;
    uint8 private constant ROLE_SYSTEM = 3;
    uint256 public constant FEATURE_COLLECTION_METADATA = 1 << 0;
    uint256 public constant FEATURE_PER_TOKEN_METADATA = 1 << 1;
    string public constant DEFAULT_REGISTRY_NAME = "Kota Tenant User Access";
    string public constant DEFAULT_REGISTRY_SYMBOL = "KTUA";

    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event RegistryDeployed(
        string tenantId,
        uint256 indexed registryIndex,
        address indexed registry,
        address indexed operator
    );
    event TenantRegistered(
        string tenantId, address indexed registry, address indexed operator,
        uint256 maxHolders, uint256 timestamp
    );
    event RegistryLockChanged(string tenantId, address indexed registry, bool locked);
    event RegistryMaxHoldersOverrideChanged(
        string tenantId,
        address indexed registry,
        bool enabled,
        uint256 maxHolders,
        address indexed approvedBy
    );
    event TenantRegistryRetired(
        string tenantId,
        address indexed registry,
        uint256 registryIndex,
        address indexed approvedBy
    );
    event TenantRegistryBeaconDeployed(
        address indexed beacon,
        address indexed implementation
    );
    event TenantRegistryBeaconImplementationUpgraded(
        address indexed beacon,
        address indexed previousImplementation,
        address indexed newImplementation
    );
    event TenantStateMigrated(
        string tenantId,
        address indexed operator,
        uint256 activeRegistryCount,
        bool deploymentLocked
    );
    event TenantOperatorChanged(
        string tenantId,
        address indexed previousOperator,
        address indexed newOperator,
        address indexed approvedBy
    );
    event TenantDeploymentLockChanged(
        string tenantId,
        bool locked,
        address indexed approvedBy
    );

    error NotAdmin();
    error ZeroAddress();
    error RegistryExists();
    error RegistryMissing();
    error AlreadyInitialized();

    address public admin;
    /// @dev Preserves the deployed factory's slot 1. Registry selection now
    /// uses the stable `(tenantId, registryIndex)` tuple; never repurpose or
    /// remove this legacy mapping slot.
    mapping(string => address) private _legacyRegistryFor;
    mapping(address => string) public tenantIdOf;  // reverse: registry -> tenantId
    mapping(string => address[]) private _registriesOf; // all registries per tenant
    /// @dev Preserves the deployed factory's slot 4. Tier limits replaced this
    /// manual allowance; keeping it private removes the obsolete getter while
    /// retaining upgrade-safe storage. Never repurpose or delete this slot.
    mapping(string => uint256) private maxRegistriesOf;
    address[] public allRegistries;
    /// Platform admin registry: source of on-chain tier limits.
    address public adminRegistry;
    /// Optional platform-approved per-registry holder limits. A separate flag
    /// allows zero to mean an explicit unlimited override.
    mapping(address => uint256) public registryMaxHoldersOverride;
    mapping(address => bool) public registryMaxHoldersOverrideSet;
    /// Shared upgrade authority for every beacon-backed tenant registry. This remains
    /// at factory slot 9, whose former address value is replaced during the
    /// explicit beacon bootstrap. The validated public view below prevents a
    /// pre-bootstrap logic address from being mistaken for a beacon.
    address private _tenantRegistryBeaconSlot;
    /// @dev Append-only v6 factory state. Slots 0-9 are deployed and immutable.
    /// These mappings occupy slots 10, 11, and 12 respectively.
    mapping(string => address) public tenantOperatorOf;
    mapping(string => uint256) internal _activeRegistryCountByTenant;
    mapping(string => bool) public tenantDeploymentLocked;

    struct RegistryDeployment {
        string tenantId;
        address tenantOperator;
        string name;
        string symbol;
        string[] initialOrigins;
    }

    error RegistryAllowanceReached();
    error TierRequirementsViolated();
    error NotTenantOperator();
    error TenantCredentialRequired();
    error InvalidTenantId();
    error TenantSuspended();
    error NotAdminOrSystem();
    error HolderLimitBelowActiveCount();
    error NotAdminRegistry();
    error RegistryBeaconMissing();
    error RegistryBeaconAlreadyConfigured();
    error InvalidRegistryImplementation();
    error RegistryIndexOutOfBounds();
    error CannotRetireLastRegistry();
    error TierInactive();
    error TierFeatureRequired();
    error TenantStateMissing();
    error TenantStateAlreadyInitialized();
    error RegistryOperatorMismatch();

    event AdminRegistryChanged(address indexed adminRegistry);

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }
    modifier onlyAdminOrSystem() {
        if (msg.sender != admin && !isSystemAddress(msg.sender)) revert NotAdminOrSystem();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ---- proxy initializer (OpenZeppelin TransparentUpgradeableProxy) ----
    /// @notice Runs once behind the proxy (storage starts zeroed), atomically
    ///         binding both factory authority and the platform access registry.
    ///         Upgrades are governed by the external ProxyAdmin, not here.
    function initialize(address initialAdmin, address initialAdminRegistry) external initializer {
        // Retain the state sentinel for proxies initialized by the pre-v1.0.2
        // implementation, whose Initializable version slot was not yet set.
        if (admin != address(0)) revert AlreadyInitialized();
        if (initialAdmin == address(0) || initialAdminRegistry == address(0)) {
            revert ZeroAddress();
        }
        _requireAdminRegistry(initialAdminRegistry);
        admin = initialAdmin;
        adminRegistry = initialAdminRegistry;
        emit AdminChanged(address(0), initialAdmin);
        emit AdminRegistryChanged(initialAdminRegistry);
    }

    function isSystemAddress(address account) public view returns (bool) {
        return adminRegistry != address(0)
            && IKotaAdminRegistry(adminRegistry).hasRole(account, ROLE_SYSTEM);
    }

    function validateTenantOperator(address operator_)
        public view returns (uint256 maxRegistries, uint256 maxHoldersPerRegistry)
    {
        if (operator_ == address(0)) revert ZeroAddress();
        if (adminRegistry == address(0)) revert TenantCredentialRequired();
        IKotaAdminRegistry plans = IKotaAdminRegistry(adminRegistry);
        if (!plans.hasRole(operator_, ROLE_TENANT)) revert TenantCredentialRequired();
        uint32 tierId = plans.tierOf(operator_);
        if (!plans.tierActive(tierId)) revert TierInactive();
        (maxRegistries, maxHoldersPerRegistry) = plans.tierLimits(tierId);
        if (maxRegistries == 0) revert TierRequirementsViolated();
    }

    function _featuresForTenantOperator(address tenantOperator)
        private view returns (uint256 features)
    {
        IKotaAdminRegistry plans = IKotaAdminRegistry(adminRegistry);
        uint32 tierId = plans.tierOf(tenantOperator);
        if (!plans.hasRole(tenantOperator, ROLE_TENANT) || !plans.tierActive(tierId)) {
            revert TierInactive();
        }
        features = plans.tierFeatures(tierId);
    }

    function registryFeatures(address registry) public view returns (uint256 features) {
        string memory tenantId = tenantIdOf[registry];
        if (bytes(tenantId).length == 0) revert RegistryMissing();
        address tenantOperator = tenantOperatorOf[tenantId];
        if (tenantOperator == address(0)) {
            tenantOperator = KotaTenantAccessSBT(registry).operator();
        }
        features = _featuresForTenantOperator(tenantOperator);
    }

    function registryFeatureEnabled(address registry, uint256 feature)
        external view returns (bool)
    {
        return registryFeatures(registry) & feature == feature;
    }

    function _newTenantRegistry(RegistryDeployment memory config)
        private returns (address registry)
    {
        address beacon = tenantRegistryBeacon();
        if (beacon == address(0)) revert RegistryBeaconMissing();
        bytes memory initialization = abi.encodeCall(
            KotaTenantAccessSBT.initialize,
            (
                config.name,
                config.symbol,
                config.tenantId,
                config.tenantOperator,
                config.initialOrigins
            )
        );
        registry = address(new BeaconProxy(beacon, initialization));
    }

    function _registryAt(string memory tenantId, uint256 registryIndex)
        private view returns (address registry)
    {
        address[] storage registries = _registriesOf[tenantId];
        if (registryIndex >= registries.length) revert RegistryIndexOutOfBounds();
        registry = registries[registryIndex];
        if (registry == address(0)) revert RegistryMissing();
    }

    function _scanActiveRegistryCount(string memory tenantId)
        private view returns (uint256 count)
    {
        address[] storage registries = _registriesOf[tenantId];
        for (uint256 i = 0; i < registries.length; i++) {
            if (registries[i] != address(0)) count++;
        }
    }

    function _activeRegistryCount(string memory tenantId)
        private view returns (uint256 count)
    {
        if (tenantOperatorOf[tenantId] == address(0)) {
            return _scanActiveRegistryCount(tenantId);
        }
        return _activeRegistryCountByTenant[tenantId];
    }

    function _requireTenantOperator(string memory tenantId)
        private view returns (address tenantOperator)
    {
        tenantOperator = tenantOperatorOf[tenantId];
        if (tenantOperator == address(0)) revert TenantStateMissing();
    }

    function _scanTenantState(string memory tenantId)
        private view returns (
            address tenantOperator,
            uint256 activeCount,
            bool allActiveRegistriesLocked
        )
    {
        address[] storage registries = _registriesOf[tenantId];
        allActiveRegistriesLocked = true;
        for (uint256 i = 0; i < registries.length; i++) {
            address registry = registries[i];
            if (registry == address(0)) continue;
            address registryOperator = KotaTenantAccessSBT(registry).operator();
            if (tenantOperator == address(0)) {
                tenantOperator = registryOperator;
            } else if (registryOperator != tenantOperator) {
                revert RegistryOperatorMismatch();
            }
            if (!KotaTenantAccessSBT(registry).registryLocked()) {
                allActiveRegistriesLocked = false;
            }
            activeCount++;
        }
        if (activeCount == 0) revert RegistryMissing();
        if (tenantOperator == address(0)) revert RegistryOperatorMismatch();
    }

    function _deployTenantRegistry(RegistryDeployment memory config)
        private returns (address registry)
    {
        if (bytes(config.tenantId).length == 0) revert InvalidTenantId();
        if (config.tenantOperator == address(0)) revert ZeroAddress();
        if (
            _registriesOf[config.tenantId].length != 0
                || tenantOperatorOf[config.tenantId] != address(0)
        ) revert RegistryExists();
        (uint256 allowance, uint256 holderLimit) =
            validateTenantOperator(config.tenantOperator);
        if (allowance == 0) revert RegistryAllowanceReached();
        registry = _newTenantRegistry(config);
        tenantIdOf[registry] = config.tenantId;
        uint256 registryIndex = _registriesOf[config.tenantId].length;
        _registriesOf[config.tenantId].push(registry);
        allRegistries.push(registry);
        tenantOperatorOf[config.tenantId] = config.tenantOperator;
        _activeRegistryCountByTenant[config.tenantId] = 1;
        tenantDeploymentLocked[config.tenantId] = false;
        emit RegistryDeployed(
            config.tenantId,
            registryIndex,
            registry,
            config.tenantOperator
        );
        emit TenantRegistered(
            config.tenantId,
            registry,
            config.tenantOperator,
            holderLimit,
            block.timestamp
        );
    }

    function _deployAdditionalRegistry(
        string memory tenantId,
        RegistryDeployment memory config
    )
        private returns (address registry)
    {
        address tenantOperator = _requireTenantOperator(tenantId);
        if (msg.sender != tenantOperator) revert NotTenantOperator();
        if (tenantDeploymentLocked[tenantId]) revert TenantSuspended();
        (uint256 allowance,) = validateTenantOperator(tenantOperator);
        bool baselineIdentity =
            keccak256(bytes(config.name)) == keccak256(bytes(DEFAULT_REGISTRY_NAME))
                && keccak256(bytes(config.symbol)) == keccak256(bytes(DEFAULT_REGISTRY_SYMBOL));
        if (
            !baselineIdentity
                && _featuresForTenantOperator(tenantOperator) & FEATURE_COLLECTION_METADATA == 0
        ) revert TierFeatureRequired();
        if (_registriesOf[tenantId].length >= MAX_REGISTRY_SLOTS_PER_TENANT) {
            revert RegistryHistoryLimitReached();
        }
        uint256 activeCount = _activeRegistryCountByTenant[tenantId];
        if (activeCount >= allowance) revert RegistryAllowanceReached();
        config.tenantId = tenantId;
        config.tenantOperator = tenantOperator;
        registry = _newTenantRegistry(config);
        tenantIdOf[registry] = config.tenantId;
        uint256 registryIndex = _registriesOf[config.tenantId].length;
        _registriesOf[config.tenantId].push(registry);
        allRegistries.push(registry);
        _activeRegistryCountByTenant[config.tenantId] = activeCount + 1;
        emit RegistryDeployed(config.tenantId, registryIndex, registry, tenantOperator);
    }

    /// @notice Deploy the standardized registry for a tenant.
    function deployTenantRegistry(
        string calldata tenantId,
        address tenantOperator,
        string calldata name_,
        string calldata symbol_,
        string[] calldata initialOrigins
    ) external onlyAdminOrSystem returns (address registry) {
        RegistryDeployment memory config;
        config.tenantId = tenantId;
        config.tenantOperator = tenantOperator;
        config.name = name_;
        config.symbol = symbol_;
        config.initialOrigins = initialOrigins;
        registry = _deployTenantRegistry(config);
    }

    /// @notice Atomic onboarding entrypoint callable only by the access
    ///         registry while it grants a tenant credential and assigns a tier.
    function deployTenantRegistryOnApproval(
        string calldata tenantId,
        address tenantOperator,
        string[] calldata initialOrigins
    ) external returns (address registry) {
        if (msg.sender != adminRegistry) revert NotAdminRegistry();
        RegistryDeployment memory config;
        config.tenantId = tenantId;
        config.tenantOperator = tenantOperator;
        config.name = DEFAULT_REGISTRY_NAME;
        config.symbol = DEFAULT_REGISTRY_SYMBOL;
        config.initialOrigins = initialOrigins;
        registry = _deployTenantRegistry(config);
    }

    /// @notice Initializes canonical tenant state after upgrading a factory
    ///         that already has registries. Every active registry must agree
    ///         on the operator; admin recovery can normalize divergence with
    ///         `setRegistryOperator` instead.
    function migrateTenantState(string calldata tenantId) external onlyAdmin {
        if (tenantOperatorOf[tenantId] != address(0)) {
            revert TenantStateAlreadyInitialized();
        }
        (
            address tenantOperator,
            uint256 activeCount,
            bool allActiveRegistriesLocked
        ) = _scanTenantState(tenantId);
        tenantOperatorOf[tenantId] = tenantOperator;
        _activeRegistryCountByTenant[tenantId] = activeCount;
        tenantDeploymentLocked[tenantId] = allActiveRegistriesLocked;
        emit TenantStateMigrated(
            tenantId,
            tenantOperator,
            activeCount,
            allActiveRegistriesLocked
        );
    }

    function _setTenantOperator(
        string memory tenantId,
        address newOperator,
        address approvedBy
    ) private {
        if (newOperator == address(0)) revert ZeroAddress();
        validateTenantOperator(newOperator);
        address previousOperator = tenantOperatorOf[tenantId];
        address[] storage registries = _registriesOf[tenantId];
        if (previousOperator == address(0)) {
            uint256 activeCount;
            bool allActiveRegistriesLocked = true;
            for (uint256 i = 0; i < registries.length; i++) {
                address registry = registries[i];
                if (registry == address(0)) continue;
                activeCount++;
                if (!KotaTenantAccessSBT(registry).registryLocked()) {
                    allActiveRegistriesLocked = false;
                }
            }
            if (activeCount == 0) revert RegistryMissing();
            _activeRegistryCountByTenant[tenantId] = activeCount;
            tenantDeploymentLocked[tenantId] = allActiveRegistriesLocked;
            tenantOperatorOf[tenantId] = newOperator;
            emit TenantStateMigrated(
                tenantId,
                newOperator,
                activeCount,
                allActiveRegistriesLocked
            );
        } else {
            tenantOperatorOf[tenantId] = newOperator;
        }
        for (uint256 i = 0; i < registries.length; i++) {
            address registry = registries[i];
            if (registry == address(0)) continue;
            KotaTenantAccessSBT(registry).setOperator(newOperator);
        }
        emit TenantOperatorChanged(
            tenantId,
            previousOperator,
            newOperator,
            approvedBy
        );
    }

    /// @notice A live v6 registry uses this callback so an approved operator
    ///         rotation updates the tenant namespace and every active registry
    ///         atomically.
    function coordinateTenantOperatorChange(address newOperator) external {
        string memory tenantId = tenantIdOf[msg.sender];
        if (bytes(tenantId).length == 0) revert RegistryMissing();
        address currentOperator = _requireTenantOperator(tenantId);
        if (KotaTenantAccessSBT(msg.sender).operator() != currentOperator) {
            revert RegistryOperatorMismatch();
        }
        _setTenantOperator(tenantId, newOperator, msg.sender);
    }

    /// @notice Retires one registry by its stable tenant-local index, freeing
    ///         one unit of the tenant's active registry allowance.
    /// @dev The slot becomes a permanent tombstone so every other registry
    ///      keeps its original index. New registries append at new indexes.
    function retireRegistry(string calldata tenantId, uint256 registryIndex) external {
        address registry = _registryAt(tenantId, registryIndex);
        KotaTenantAccessSBT target = KotaTenantAccessSBT(registry);
        address tenantOperator = _requireTenantOperator(tenantId);
        bool platformAuthority = msg.sender == admin || isSystemAddress(msg.sender);
        if (!platformAuthority) {
            if (msg.sender != tenantOperator) revert NotTenantOperator();
            if (tenantDeploymentLocked[tenantId]) revert TenantSuspended();
            validateTenantOperator(tenantOperator);
        }
        uint256 activeCount = _activeRegistryCountByTenant[tenantId];
        if (activeCount <= 1) revert CannotRetireLastRegistry();

        target.setRegistryLocked(true);
        emit RegistryLockChanged(tenantId, registry, true);
        delete _registriesOf[tenantId][registryIndex];
        delete tenantIdOf[registry];
        delete registryMaxHoldersOverride[registry];
        delete registryMaxHoldersOverrideSet[registry];
        _activeRegistryCountByTenant[tenantId] = activeCount - 1;
        emit TenantRegistryRetired(tenantId, registry, registryIndex, msg.sender);
    }

    /// @notice Platform suspension switch: locked registries report zero
    ///         balances, failing every router/NFT gate immediately.
    function setRegistryLocked(string calldata tenantId, bool locked_) external onlyAdmin {
        address[] storage registries = _registriesOf[tenantId];
        if (_activeRegistryCount(tenantId) == 0) revert RegistryMissing();
        for (uint256 i = 0; i < registries.length; i++) {
            address registry = registries[i];
            if (registry == address(0)) continue;
            KotaTenantAccessSBT(registry).setRegistryLocked(locked_);
            emit RegistryLockChanged(tenantId, registry, locked_);
        }
        tenantDeploymentLocked[tenantId] = locked_;
        emit TenantDeploymentLockChanged(tenantId, locked_, msg.sender);
    }

    /// @notice Targeted platform lock for operational recovery or staged
    ///         maintenance. The registry must have been deployed by this factory.
    function setRegistryLockedAt(address registry, bool locked_) external onlyAdmin {
        string memory tenantId = tenantIdOf[registry];
        if (bytes(tenantId).length == 0) revert RegistryMissing();
        KotaTenantAccessSBT(registry).setRegistryLocked(locked_);
        emit RegistryLockChanged(tenantId, registry, locked_);
    }

    /// @notice Recover/replace a tenant's operator wallet.
    function setRegistryOperator(string calldata tenantId, address newOperator) external onlyAdmin {
        _setTenantOperator(tenantId, newOperator, msg.sender);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function registryCount() external view returns (uint256) {
        return allRegistries.length;
    }

    /// @notice TENANT-PLANE write: the canonical tenant operator creates an
    ///         additional registry when the active tier allowance permits it.
    function deployAdditionalRegistry(
        string calldata tenantId,
        string calldata name_,
        string calldata symbol_,
        string[] calldata initialOrigins
    ) external returns (address registry) {
        RegistryDeployment memory config;
        config.name = name_;
        config.symbol = symbol_;
        config.initialOrigins = initialOrigins;
        registry = _deployAdditionalRegistry(tenantId, config);
    }

    /// @notice Current per-registry user cap. The tenant tier is authoritative
    /// unless a platform admin/system address approved an explicit override.
    function maxHoldersForRegistry(address registry) public view returns (uint256) {
        string memory tenantId = tenantIdOf[registry];
        if (bytes(tenantId).length == 0) revert RegistryMissing();
        address tenantOperator = tenantOperatorOf[tenantId];
        if (tenantOperator == address(0)) {
            tenantOperator = KotaTenantAccessSBT(registry).operator();
        }
        (, uint256 holderLimit) = validateTenantOperator(tenantOperator);
        // An override changes capacity only; it never bypasses tenant eligibility.
        return registryMaxHoldersOverrideSet[registry]
            ? registryMaxHoldersOverride[registry] : holderLimit;
    }

    function setRegistryMaxHoldersOverride(address registry, uint256 maxHolders_)
        external onlyAdminOrSystem
    {
        string memory tenantId = tenantIdOf[registry];
        if (bytes(tenantId).length == 0) revert RegistryMissing();
        uint256 active = KotaTenantAccessSBT(registry).activeHolders();
        if (maxHolders_ != 0 && maxHolders_ < active) revert HolderLimitBelowActiveCount();
        registryMaxHoldersOverride[registry] = maxHolders_;
        registryMaxHoldersOverrideSet[registry] = true;
        emit RegistryMaxHoldersOverrideChanged(
            tenantId, registry, true, maxHolders_, msg.sender
        );
    }

    function clearRegistryMaxHoldersOverride(address registry) external onlyAdminOrSystem {
        string memory tenantId = tenantIdOf[registry];
        if (bytes(tenantId).length == 0) revert RegistryMissing();
        delete registryMaxHoldersOverride[registry];
        delete registryMaxHoldersOverrideSet[registry];
        emit RegistryMaxHoldersOverrideChanged(
            tenantId, registry, false, 0, msg.sender
        );
    }

    function _requireCompatibleRegistryImplementation(address implementation) private view {
        if (implementation == address(0) || implementation.code.length == 0) {
            revert InvalidRegistryImplementation();
        }
        bool compatible;
        bool directImplementation;
        try KotaTenantAccessSBT(implementation).supportsInterface(0x4b4f5441)
            returns (bool supported)
        {
            compatible = supported;
        } catch {}
        try KotaTenantAccessSBT(implementation).implementationSelf()
            returns (address implementationSelf)
        {
            directImplementation = implementationSelf == implementation;
        } catch {}
        if (!compatible || !directImplementation) revert InvalidRegistryImplementation();
    }

    function _isFactoryOwnedRegistryBeacon(address candidate) private view returns (bool) {
        if (candidate == address(0) || candidate.code.length == 0) return false;
        try UpgradeableBeacon(candidate).owner() returns (address owner_) {
            if (owner_ != address(this)) return false;
        } catch {
            return false;
        }
        try UpgradeableBeacon(candidate).implementation() returns (address implementation) {
            return implementation != address(0) && implementation.code.length != 0;
        } catch {
            return false;
        }
    }

    /// @notice Returns zero until slot 9 contains the factory-owned beacon.
    function tenantRegistryBeacon() public view returns (address) {
        address candidate = _tenantRegistryBeaconSlot;
        return _isFactoryOwnedRegistryBeacon(candidate) ? candidate : address(0);
    }

    /// @notice One-time beacon bootstrap. The factory proxy deploys and permanently
    ///         owns the beacon; all subsequently created registries use it.
    function deployTenantRegistryBeacon(address initialImplementation)
        external onlyAdmin returns (address beacon)
    {
        if (tenantRegistryBeacon() != address(0)) revert RegistryBeaconAlreadyConfigured();
        _requireCompatibleRegistryImplementation(initialImplementation);
        beacon = address(new UpgradeableBeacon(initialImplementation, address(this)));
        _tenantRegistryBeaconSlot = beacon;
        emit TenantRegistryBeaconDeployed(beacon, initialImplementation);
    }

    /// @notice Atomically upgrades every registry deployed from the shared beacon.
    function upgradeTenantRegistryBeaconImplementation(address newImplementation) external onlyAdmin {
        address beacon = tenantRegistryBeacon();
        if (beacon == address(0)) revert RegistryBeaconMissing();
        _requireCompatibleRegistryImplementation(newImplementation);
        address previousImplementation = UpgradeableBeacon(beacon).implementation();
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit TenantRegistryBeaconImplementationUpgraded(
            beacon,
            previousImplementation,
            newImplementation
        );
    }

    function tenantRegistryBeaconImplementation() external view returns (address) {
        address beacon = tenantRegistryBeacon();
        return beacon == address(0) ? address(0) : UpgradeableBeacon(beacon).implementation();
    }

    /// @notice Point the factory at the platform admin registry (proxy addr)
    ///         so plan-tier limits gate deployments on-chain. This rotates the
    ///         registry established during proxy initialization.
    function _requireAdminRegistry(address candidate) private view {
        if (candidate.code.length == 0) revert InvalidAdminRegistry();
        IKotaAdminRegistry plans = IKotaAdminRegistry(candidate);
        // Exercise the exact policy ABI used by this factory before accepting it.
        plans.hasRole(address(this), ROLE_TENANT);
        plans.tierOf(address(this));
        plans.tierActive(0);
        plans.tierLimits(0);
        plans.tierFeatures(0);
    }

    function setAdminRegistry(address adminRegistry_) external onlyAdmin {
        if (adminRegistry_ == address(0)) revert ZeroAddress();
        _requireAdminRegistry(adminRegistry_);
        adminRegistry = adminRegistry_;
        emit AdminRegistryChanged(adminRegistry_);
    }

    function registriesOf(string calldata tenantId) external view returns (address[] memory) {
        return _registriesOf[tenantId];
    }

    /// @notice Stable registry lookup. Retired slots return the zero address.
    function registryAt(string calldata tenantId, uint256 registryIndex)
        external view returns (address)
    {
        address[] storage registries = _registriesOf[tenantId];
        return registryIndex < registries.length ? registries[registryIndex] : address(0);
    }

    function registrySlotCount(string calldata tenantId) external view returns (uint256) {
        return _registriesOf[tenantId].length;
    }

    function activeRegistryCount(string calldata tenantId) external view returns (uint256) {
        return _activeRegistryCount(tenantId);
    }

    function retiredRegistryCount(string calldata tenantId) external view returns (uint256) {
        return _registriesOf[tenantId].length - _activeRegistryCount(tenantId);
    }
}
