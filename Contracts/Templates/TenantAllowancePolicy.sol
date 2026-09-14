// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.34;

/// @notice Optional tier source. The tenant may instead use explicit wallet limits.
interface IAllowanceMembership {
    function tokenOf(address wallet) external view returns (uint256);
    function tierOf(address wallet) external view returns (uint32);
    function tierActive(uint32 tier) external view returns (bool);
    function registryLocked() external view returns (bool);
}

/// @title TenantAllowancePolicy
/// @notice Tenant-owned spending permissions, denominated in native-token wei.
/// @dev GasSponsor v1.1+ must bind this policy before it can enforce allowances.
/// No deposits, withdrawals, delegatecalls, arbitrary execution or ownership renounce.
/// Daily limits are per user; tier settings are defaults, not a shared tier pool.
contract TenantAllowancePolicy {
    struct Limit { bool configured; bool enabled; uint256 perOperation; uint256 daily; }
    struct Usage { uint256 day; uint256 spent; uint256 reserved; }
    struct Reservation { address wallet; bytes32 credential; uint256 maximum; uint256 day; }

    address public immutable gasSponsor;
    address public immutable sponsor;
    address public immutable membership;
    address public owner;
    address public pendingOwner;
    bool public paused;
    Limit public defaultLimit;
    mapping(uint32 => Limit) public tierLimits;
    mapping(address => Limit) public walletLimits;
    mapping(address => Usage) private _walletUsage;
    mapping(bytes32 => Usage) private _credentialUsage;
    mapping(bytes32 => Reservation) private _reservations;
    mapping(bytes32 => bool) public consumed;
    uint256 public pendingReservations;

    error Unauthorized();
    error InvalidConfiguration();
    error AllowanceUnavailable();
    error OperationAlreadyUsed();
    error InvalidSettlement();


    event OwnershipProposed(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed owner);
    event PolicyPaused(bool paused);
    event DefaultLimitSet(bool enabled, uint256 perOperation, uint256 daily);
    event TierLimitSet(uint32 indexed tier, bool configured, bool enabled, uint256 perOperation, uint256 daily);
    event WalletLimitSet(address indexed wallet, bool configured, bool enabled, uint256 perOperation, uint256 daily);
    event AllowanceReserved(bytes32 indexed operationId, address indexed wallet, bytes32 indexed credential, uint256 maximumCost, uint256 day);
    event AllowanceCharged(bytes32 indexed operationId, address indexed wallet, bytes32 indexed credential, uint256 cost, uint256 day);

    constructor(address sponsorContract, address tenantAccount, address tenantOwner, address membershipRegistry,
        uint256 initialPerOperation, uint256 initialDaily, address[] memory initialAdminWallets) {
        if (sponsorContract.code.length == 0 || tenantAccount == address(0) || tenantOwner == address(0)
            || (membershipRegistry != address(0) && membershipRegistry.code.length == 0)) revert InvalidConfiguration();
        gasSponsor = sponsorContract;
        sponsor = tenantAccount;
        owner = tenantOwner;
        membership = membershipRegistry;
        bool initiallyEnabled = initialPerOperation != 0 || initialDaily != 0;
        defaultLimit = _limit(true, initiallyEnabled, initialPerOperation, initialDaily);
        // The owner can be sponsored without first minting an end-user credential.
        walletLimits[tenantOwner] = defaultLimit;
        if (initialAdminWallets.length > 32) revert InvalidConfiguration();
        for (uint256 i; i < initialAdminWallets.length; ++i) {
            address wallet = initialAdminWallets[i];
            if (wallet == address(0) || walletLimits[wallet].configured) revert InvalidConfiguration();
            walletLimits[wallet] = defaultLimit;
            emit WalletLimitSet(wallet, true, initiallyEnabled, initialPerOperation, initialDaily);
        }
        emit DefaultLimitSet(initiallyEnabled, initialPerOperation, initialDaily);
        emit WalletLimitSet(tenantOwner, true, initiallyEnabled, initialPerOperation, initialDaily);
        emit OwnershipTransferred(address(0), tenantOwner);
    }

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }
    modifier onlySponsor() { if (msg.sender != gasSponsor) revert Unauthorized(); _; }


    function proposeOwner(address next) external onlyOwner {
        if (next == address(0) || next == owner) revert InvalidConfiguration();
        pendingOwner = next; emit OwnershipProposed(owner, next);
    }
    function cancelOwnerTransfer() external onlyOwner {
        pendingOwner = address(0); emit OwnershipProposed(owner, address(0));
    }
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address previous = owner; owner = msg.sender; pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }
    function setPaused(bool value) external onlyOwner { paused = value; emit PolicyPaused(value); }
    function setDefaultLimit(bool enabled, uint256 perOperation, uint256 daily) external onlyOwner {
        defaultLimit = _limit(true, enabled, perOperation, daily);
        emit DefaultLimitSet(enabled, perOperation, daily);
    }
    function setTierLimit(uint32 tier, bool configured, bool enabled, uint256 perOperation, uint256 daily) external onlyOwner {
        if (membership == address(0)) revert InvalidConfiguration();
        tierLimits[tier] = _limit(configured, enabled, perOperation, daily);
        emit TierLimitSet(tier, configured, enabled, perOperation, daily);
    }
    /// @notice An explicit disabled override revokes spending even when a default allows it.
    /// Removing the override restores tier/default rules; it never resets usage.
    function setWalletLimit(address wallet, bool configured, bool enabled, uint256 perOperation, uint256 daily) external onlyOwner {
        if (wallet == address(0)) revert InvalidConfiguration();
        walletLimits[wallet] = _limit(configured, enabled, perOperation, daily);
        emit WalletLimitSet(wallet, configured, enabled, perOperation, daily);
    }
    function _limit(bool configured, bool enabled, uint256 perOperation, uint256 daily) private pure returns (Limit memory) {
        if ((!configured && (enabled || perOperation != 0 || daily != 0))
            || (enabled && (perOperation == 0 || daily < perOperation))
            || (!enabled && (perOperation != 0 || daily != 0))) revert InvalidConfiguration();
        return Limit(configured, enabled, perOperation, daily);
    }

    function _resolve(address wallet) private view returns (Limit memory limit, bytes32 credential) {
        limit = walletLimits[wallet];
        if (membership != address(0)) {
            // Registry outages/suspension fail closed, including for explicit admin overrides.
            IAllowanceMembership registry = IAllowanceMembership(membership);
            if (registry.registryLocked()) revert AllowanceUnavailable();
            uint256 token = registry.tokenOf(wallet);
            if (token != 0) {
                credential = keccak256(abi.encode(membership, token));
                uint32 tier = registry.tierOf(wallet);
                if (tier != 0 && !registry.tierActive(tier)) revert AllowanceUnavailable();
                if (!limit.configured) limit = tierLimits[tier];
            } else if (!limit.configured) {
                // Non-member admins/service wallets require an explicit allowance.
                return (limit, bytes32(0));
            }
        }
        if (!limit.configured) limit = defaultLimit;
    }

    function _remaining(Usage storage usage, uint256 daily) private view returns (uint256) {
        uint256 used = usage.day == block.timestamp / 1 days ? usage.spent + usage.reserved : 0;
        return used >= daily ? 0 : daily - used;
    }
    function allowance(address wallet) external view returns (bool enabled, uint256 perOperation, uint256 daily, uint256 available, uint256 spent, uint256 reserved, bytes32 credential) {
        Limit memory limit;
        (limit, credential) = _resolve(wallet);
        enabled = limit.configured && limit.enabled && !paused;
        perOperation = limit.perOperation; daily = limit.daily;
        Usage storage usage = _walletUsage[wallet];
        if (usage.day == block.timestamp / 1 days) { spent = usage.spent; reserved = usage.reserved; }
        available = enabled ? _remaining(usage, daily) : 0;
        if (credential != bytes32(0)) {
            uint256 other = _remaining(_credentialUsage[credential], daily);
            if (other < available) available = other;
        }
    }

    function reserve(bytes32 operationId, address wallet, uint256 maximumCost) external onlySponsor returns (bytes4) {
        if (consumed[operationId] || _reservations[operationId].wallet != address(0)) revert OperationAlreadyUsed();
        if (operationId == bytes32(0) || wallet == address(0) || maximumCost == 0 || paused) revert AllowanceUnavailable();
        (Limit memory limit, bytes32 credential) = _resolve(wallet);
        if (!limit.configured || !limit.enabled || maximumCost > limit.perOperation) revert AllowanceUnavailable();
        _reserveUsage(_walletUsage[wallet], maximumCost, limit.daily);
        // Both counters are enforced: wallet rotation and credential re-issuance do not reset a day's spend.
        if (credential != bytes32(0)) _reserveUsage(_credentialUsage[credential], maximumCost, limit.daily);
        uint256 day = block.timestamp / 1 days;
        _reservations[operationId] = Reservation(wallet, credential, maximumCost, day);
        ++pendingReservations;
        emit AllowanceReserved(operationId, wallet, credential, maximumCost, day);
        return this.reserve.selector;
    }
    function _reserveUsage(Usage storage usage, uint256 maximum, uint256 daily) private {
        uint256 day = block.timestamp / 1 days;
        if (usage.day != day) { usage.day = day; usage.spent = 0; usage.reserved = 0; }
        if (usage.spent > daily || usage.reserved > daily - usage.spent || maximum > daily - usage.spent - usage.reserved) revert AllowanceUnavailable();
        usage.reserved += maximum;
    }
    function settle(bytes32 operationId, uint256 chargedCost) external onlySponsor returns (bytes4) {
        Reservation memory reservation = _reservations[operationId];
        if (reservation.wallet == address(0) || chargedCost > reservation.maximum || reservation.day != block.timestamp / 1 days) revert InvalidSettlement();
        consumed[operationId] = true;
        delete _reservations[operationId];
        --pendingReservations;
        _settleUsage(_walletUsage[reservation.wallet], reservation.maximum, chargedCost);
        if (reservation.credential != bytes32(0)) _settleUsage(_credentialUsage[reservation.credential], reservation.maximum, chargedCost);
        emit AllowanceCharged(operationId, reservation.wallet, reservation.credential, chargedCost, reservation.day);
        return this.settle.selector;
    }
    function _settleUsage(Usage storage usage, uint256 maximum, uint256 charged) private {
        usage.reserved -= maximum;
        usage.spent += charged;
    }
}
