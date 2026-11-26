// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {Initializable} from "../Upgradeable/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "../Upgradeable/ReentrancyGuardUpgradeable.sol";
import {ICryftDelegation} from "./Interfaces/ICryftDelegation.sol";
import {IGasSponsor} from "./Interfaces/IGasSponsor.sol";
import {ITenantAllowancePolicy} from "./Interfaces/ITenantAllowancePolicy.sol";
import {DelegationGas} from "./DelegationGas.sol";
import {CryftECDSA} from "./Libraries/CryftECDSA.sol";

/// @title IERC1271VoucherSigner
/// @notice EIP-1271 check of a contract voucher signer.
interface IERC1271VoucherSigner {
    /// @notice Returns the EIP-1271 magic value when `signature` is valid for `digest`.
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4);
}

/// @title IRootOverlordRegistry
/// @notice The root-overlord check of the validator contract 0x…1111.
interface IRootOverlordRegistry {
    /// @notice Whether `account` is a live root overlord.
    function isRootOverlord(address account) external view returns (bool);
}

/// @title GasSponsor
/// @notice Native EIP-7702 gas sponsorship with optional tenant-owned allowance enforcement.
/// @dev Linked behind the genesis proxy 0x…FEeD (ProgramGasSponsor is the deployed leaf). No ERC-4337, bundler,
///      EntryPoint or paymaster. The uninitialized proxy first-links through proxy_linkLogicAdmin; later
///      upgrades go through the fixed ProxyAdmin and wait the network upgrade delay. Sponsorship starts paused.
///      The platform administrator (handed over in two steps) sets the voucher signer, the approved delegate
///      (the immutable v2 dispatcher), the relayers, the pause, the fixed overhead gas and each sponsor's identity,
///      manager, hard limits and switch. A sponsor's manager sets limits within the hard limits; both switches
///      must be on. Deposits keep refundable coin apart from restricted gas credit. A voucher binds operation and
///      campaign ids, sponsor, tenant, account, relayer, delegate, execution hash, gas, cost and deadline, and is
///      signed by an EOA or EIP-1271 signer; operation ids are single-use per sponsor. Execution checks the
///      delegated account and the inner CryftDelegation envelope, enforces per-operation, daily, balance,
///      gas-price and operations-per-day caps, bounds calldata and return data, and reimburses measured gas
///      within the signed maximum cost; a failed inner call still consumes the operation id and reimburses the
///      relayer. All sponsor state lives in one ERC-7201 namespace (cryft.storage.GasSponsor); the inherited
///      initializer and reentrancy slots stay reserved.
/// @custom:version 1.5.2
/// @custom:security-contact security@cryft.cards
contract GasSponsor is
    Initializable,
    ReentrancyGuardUpgradeable,
    IGasSponsor
{
    using CryftECDSA for bytes32;

    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    struct SponsorState {
        bytes32 tenantId;
        address manager;
        uint256 balance;
        uint256 adminMaxCostPerOperation;
        uint256 tenantMaxCostPerOperation;
        uint256 adminDailyLimit;
        uint256 tenantDailyLimit;
        uint256 dailySpent;
        uint256 lastResetDay;
        bool adminEnabled;
        bool tenantEnabled;
    }

    /// @custom:storage-location erc7201:cryft.storage.GasSponsor
    struct GasSponsorStorage {
        address platformAdmin;
        address pendingPlatformAdmin;
        address voucherSigner;
        address approvedDelegate;
        uint256 fixedOverheadGas;
        bool paused;
        mapping(address => bool) relayers;
        mapping(bytes32 => bool) consumedOperations;
        mapping(address => SponsorState) sponsors;
        bytes32 approvedDelegateCodeHash;
        mapping(address => uint256) restrictedGasCredit;
        // Append-only from here: allowance policies and wallet permissions.
        mapping(address => address) allowancePolicies;
        mapping(address => bool) walletApprovalRequired;
        mapping(address => mapping(address => uint8)) sponsoredWallets;
        // Append-only from here: the pauser and every sponsor's operations-per-day counter.
        address pauser;
        mapping(address => uint256) opsPerDay;
        mapping(address => uint256) opsDay;
        mapping(address => uint256) opsCount;
    }

    struct PolicyContext {
        address policy;
        uint256 overhead;
    }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    uint256 private constant _POLICY_CALL_GAS = 350_000;
    uint256 private constant _POLICY_SETTLEMENT_OVERHEAD = 150_000;
    /// @dev Settle runs with a budget below the overhead it is charged as, so a policy can never make the relayer
    ///      pay for more settle gas than it is reimbursed for. It is best-effort: a reverting policy cannot sink
    ///      the relayer's transaction.
    uint256 private constant _POLICY_SETTLE_GAS = 120_000;
    /// @dev Gas kept back around the settle call (EIP-150 rule and bookkeeping).
    uint256 private constant _POLICY_SETTLE_RESERVE = 40_000;
    uint256 private constant _POLICY_SETTLE_CALL_OVERHEAD = 20_000;

    bytes32 private constant _GAS_SPONSOR_STORAGE_LOCATION =
        0x1517881409dbca238e515328317c78f643c8aa79fdd0217b0d2dee62cd1df100;

    address private constant _GENESIS_PROXY_ADMIN =
        0x0000000000000000000000000000000000FacAdE;
    address private constant _VALIDATOR_ROOT_REGISTRY =
        0x0000000000000000000000000000000000001111;

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256("CryftGasSponsor");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _VOUCHER_TYPEHASH = keccak256(
        "SponsorshipVoucher(bytes32 operationId,bytes32 tenantId,bytes32 campaignId,address sponsor,address account,address relayer,address delegate,bytes32 executionHash,uint256 callGasLimit,uint256 maxFeePerGas,uint256 maxCost,uint256 deadline)"
    );

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;
    bytes32 private constant _EXPECTED_DELEGATION_PROTOCOL_ID =
        keccak256("cryft.delegation.sponsored-execution.v1");
    uint256 private constant _MIN_CALL_GAS_LIMIT = 25_000;
    uint256 private constant _MAX_CALL_GAS_LIMIT = 5_000_000;
    uint256 private constant _MIN_OVERHEAD_GAS = 50_000;
    uint256 private constant _MAX_OVERHEAD_GAS = 500_000;
    uint256 private constant _POST_CALL_GAS_RESERVE = 60_000;
    uint256 private constant _MAX_EXECUTION_DATA_BYTES = 65_536;
    uint256 private constant _MAX_RETURN_DATA_BYTES = 512;
    uint256 private constant _ERC1271_GAS_LIMIT = 50_000;
    uint256 private constant _READINESS_CALL_GAS_LIMIT = 100_000;
    /// @dev Smallest ABI encoding of executeSponsored(request, signature) with one empty call.
    uint256 private constant _MIN_ENVELOPE_BYTES = 260;
    uint8 private constant _WALLET_DENIED = 2;
    uint8 private constant _WALLET_APPROVED = 1;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A sponsor's allowance policy was set or removed.
    event SponsorPolicyUpdated(address indexed sponsor, address indexed policy);

    /// @notice A sponsor's approved-wallets switch changed.
    event WalletApprovalRequired(address indexed sponsor, bool required);

    /// @notice A wallet's permission for a sponsor changed.
    event SponsoredWalletUpdated(address indexed sponsor, address indexed wallet, uint8 permission);

    /// @notice The pauser changed (zero: none).
    event PauserUpdated(address indexed pauser);

    /// @notice A sponsor's operations per day changed.
    event SponsorOpsPerDayUpdated(address indexed sponsor, uint256 opsPerDay);

    /// @notice A policy's best-effort settle failed; the operation stands.
    event AllowancePolicySettleFailed(bytes32 indexed operationId, address indexed policy);

    /// @notice Restricted gas credit was deposited for a sponsor.
    event GasCreditDeposited(address indexed sponsor, address indexed funder, uint256 amount);

    /// @notice Restricted gas credit was recovered from a sponsor.
    event GasCreditRecovered(address indexed sponsor, address indexed recipient, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is neither the genesis ProxyAdmin nor a live root overlord.
    error NotInitializationAuthority(address caller);

    /// @notice The caller is not the platform administrator (or the pauser, where it may act).
    error NotPlatformAdmin();

    /// @notice The caller is not the pending platform administrator.
    error NotPendingPlatformAdmin();

    /// @notice The caller is not the sponsor's manager.
    error NotSponsorManager();

    /// @notice A required address is zero (or the delegate has no code).
    error ZeroAddress();

    /// @notice No coin was sent.
    error ZeroValue();

    /// @notice A setting is out of range or not allowed.
    error InvalidConfiguration();

    /// @notice The sponsor has not been configured.
    error SponsorNotConfigured(address sponsor);

    /// @notice One of the sponsor's switches is off.
    error SponsorDisabled(address sponsor);

    /// @notice The tenant does not match the sponsor's tenant.
    error TenantMismatch(bytes32 expected, bytes32 supplied);

    /// @notice Sponsorship is paused.
    error SponsorshipIsPaused();

    /// @notice The caller is not an allowed relayer.
    error RelayerNotAuthorized(address relayer);

    /// @notice The voucher does not match the call.
    error InvalidVoucher();

    /// @notice The voucher signer did not sign the voucher.
    error InvalidVoucherSignature();

    /// @notice The voucher deadline has passed.
    error VoucherExpired();

    /// @notice The sponsor has already consumed the operation id.
    error OperationAlreadyConsumed(bytes32 operationId);

    /// @notice The account is not delegated to the approved dispatcher or speaks another protocol.
    error InvalidDelegation(address account);

    /// @notice The execution data is not a valid executeSponsored call for this voucher.
    error InvalidExecutionEnvelope();

    /// @notice The execution data is too long.
    error InvalidExecutionLength(uint256 length);

    /// @notice The voucher's call gas limit is out of range.
    error InvalidCallGasLimit(uint256 gasLimit);

    /// @notice The transaction gas price is above the voucher's maximum.
    error GasPriceTooHigh(uint256 actual, uint256 maximum);

    /// @notice The voucher's maximum cost does not match its gas and fee.
    error CostEnvelopeMismatch(uint256 expected, uint256 supplied);

    /// @notice The voucher's maximum cost is above the sponsor's per-operation limit.
    error CostLimitExceeded(uint256 limit, uint256 requested);

    /// @notice The operation would pass the sponsor's daily limit.
    error DailyLimitExceeded(uint256 limit, uint256 requested);

    /// @notice The sponsor's available balance is too low.
    error InsufficientSponsorBalance(uint256 available, uint256 required);

    /// @notice Too little gas is left for the bounded call.
    error InsufficientExecutionGas(uint256 available, uint256 required);

    /// @notice A native coin transfer failed.
    error NativeTransferFailed();

    /// @notice Plain coin transfers to the sponsor are refused.
    error DirectNativeTransferDisabled();

    /// @notice The sponsor does not pay for this wallet.
    error WalletNotSponsored(address sponsor, address wallet);

    /// @notice The allowance policy or wallet permission is not valid for this sponsor.
    error InvalidAllowancePolicy();

    /// @notice The allowance policy refused or failed the request.
    error AllowancePolicyFailed(address policy, bytes4 action);

    /// @notice The sponsor has run all its operations for this UTC day.
    error DailyOpsReached(address sponsor, uint256 opsPerDay);

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    /// @dev The checks live in functions rather than inline per use, to fit the code size limit.
    modifier onlyPlatformAdmin() {
        _onlyPlatformAdmin();
        _;
    }

    modifier onlySponsorManager(address sponsor) {
        _onlySponsorManager(sponsor);
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    // ─── Initializers ────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IGasSponsor
    function initialize(
        address platformAdmin_,
        address voucherSigner_,
        address approvedDelegate_,
        uint256 fixedOverheadGas_
    ) external override initializer {
        if (!_isInitializationAuthority(msg.sender)) revert NotInitializationAuthority(msg.sender);
        _requireNonZero(platformAdmin_);
        if (platformAdmin_ == address(this) || platformAdmin_ == _GENESIS_PROXY_ADMIN) revert InvalidConfiguration();
        _requireNonZero(voucherSigner_);
        _requireDelegate(approvedDelegate_);
        _validateOverheadGas(fixedOverheadGas_);

        __ReentrancyGuard_init();

        GasSponsorStorage storage state = _sponsorStorage();
        state.platformAdmin = platformAdmin_;
        state.voucherSigner = voucherSigner_;
        state.approvedDelegate = approvedDelegate_;
        state.approvedDelegateCodeHash = approvedDelegate_.codehash;
        state.fixedOverheadGas = fixedOverheadGas_;
        state.paused = true;

        emit GasSponsorInitialized(platformAdmin_, voucherSigner_, approvedDelegate_, fixedOverheadGas_);
        emit SponsorshipPaused(true);
    }

    // ─── receive / fallback ──────────────────────────────────────────────────────────────────────

    /// @notice Refuses plain coin transfers; use depositFor or depositGasCredit.
    receive() external payable {
        revert DirectNativeTransferDisabled();
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc IGasSponsor
    function proposePlatformAdmin(address pendingAdmin) external override onlyPlatformAdmin {
        _requireNonZero(pendingAdmin);
        if (pendingAdmin == address(this) || pendingAdmin == _GENESIS_PROXY_ADMIN) revert InvalidConfiguration();
        GasSponsorStorage storage state = _sponsorStorage();
        state.pendingPlatformAdmin = pendingAdmin;
        emit PlatformAdminTransferProposed(state.platformAdmin, pendingAdmin);
    }

    /// @inheritdoc IGasSponsor
    function acceptPlatformAdmin() external override {
        GasSponsorStorage storage state = _sponsorStorage();
        if (msg.sender != state.pendingPlatformAdmin) revert NotPendingPlatformAdmin();
        address previousAdmin = state.platformAdmin;
        state.platformAdmin = msg.sender;
        state.pendingPlatformAdmin = address(0);
        emit PlatformAdminTransferred(previousAdmin, msg.sender);
    }

    /// @inheritdoc IGasSponsor
    function cancelPlatformAdminTransfer() external override onlyPlatformAdmin {
        GasSponsorStorage storage state = _sponsorStorage();
        state.pendingPlatformAdmin = address(0);
        emit PlatformAdminTransferProposed(state.platformAdmin, address(0));
    }

    /// @inheritdoc IGasSponsor
    function setVoucherSigner(address signer) external override onlyPlatformAdmin {
        _requireNonZero(signer);
        GasSponsorStorage storage state = _sponsorStorage();
        address previousSigner = state.voucherSigner;
        state.voucherSigner = signer;
        emit VoucherSignerUpdated(previousSigner, signer);
    }

    /// @inheritdoc IGasSponsor
    function setApprovedDelegate(address delegate) external override onlyPlatformAdmin {
        _requireDelegate(delegate);
        GasSponsorStorage storage state = _sponsorStorage();
        address previousDelegate = state.approvedDelegate;
        state.approvedDelegate = delegate;
        state.approvedDelegateCodeHash = delegate.codehash;
        emit ApprovedDelegateUpdated(previousDelegate, delegate);
    }

    /// @inheritdoc IGasSponsor
    function setRelayer(address relayer, bool allowed) external override onlyPlatformAdmin {
        _requireNonZero(relayer);
        _sponsorStorage().relayers[relayer] = allowed;
        emit RelayerUpdated(relayer, allowed);
    }

    /// @inheritdoc IGasSponsor
    /// @dev The pauser may only pause; resuming stays with the platform administrator.
    function setPaused(bool paused_) external override {
        _onlyAdminOrStopping(paused_);
        _sponsorStorage().paused = paused_;
        emit SponsorshipPaused(paused_);
    }

    /// @inheritdoc IGasSponsor
    /// @dev The pauser is the fast guardian: it can pause sponsorship and disable a sponsor, nothing else. It
    ///      moves no coin and changes no role. Zero removes it. The platform administrator (intended to be a
    ///      timelock) sets it.
    function setPauser(address pauser_) external override onlyPlatformAdmin {
        _sponsorStorage().pauser = pauser_;
        emit PauserUpdated(pauser_);
    }

    /// @inheritdoc IGasSponsor
    /// @dev Counts vouchers and worker reservations. Zero (the default) runs none: with free gas and free
    ///      addresses a coin cap alone bounds nothing, this count does.
    function setSponsorOpsPerDay(address sponsor, uint256 opsPerDay) external override onlyPlatformAdmin {
        _sponsorState(sponsor);
        _beforeAdminSponsorChange(sponsor);
        _sponsorStorage().opsPerDay[sponsor] = opsPerDay;
        emit SponsorOpsPerDayUpdated(sponsor, opsPerDay);
    }

    /// @inheritdoc IGasSponsor
    function setFixedOverheadGas(uint256 overheadGas) external override onlyPlatformAdmin {
        _validateOverheadGas(overheadGas);
        GasSponsorStorage storage state = _sponsorStorage();
        uint256 previousOverheadGas = state.fixedOverheadGas;
        state.fixedOverheadGas = overheadGas;
        emit FixedOverheadGasUpdated(previousOverheadGas, overheadGas);
    }

    /// @inheritdoc IGasSponsor
    function configureSponsor(
        address sponsor,
        bytes32 tenantId,
        address manager,
        uint256 adminMaxCostPerOperation,
        uint256 adminDailyLimit,
        bool adminEnabled
    ) external override onlyPlatformAdmin {
        _requireNonZero(sponsor);
        _requireNonZero(manager);
        _beforeAdminSponsorChange(sponsor);
        if (tenantId == bytes32(0) || adminMaxCostPerOperation == 0 || adminDailyLimit < adminMaxCostPerOperation) {
            revert InvalidConfiguration();
        }

        SponsorState storage sponsorState = _sponsorStorage().sponsors[sponsor];
        bool isNew = sponsorState.manager == address(0);
        if (!isNew && sponsorState.tenantId != tenantId) revert TenantMismatch(sponsorState.tenantId, tenantId);

        sponsorState.tenantId = tenantId;
        sponsorState.manager = manager;
        sponsorState.adminMaxCostPerOperation = adminMaxCostPerOperation;
        sponsorState.adminDailyLimit = adminDailyLimit;
        sponsorState.adminEnabled = adminEnabled;

        if (
            isNew ||
            sponsorState.tenantMaxCostPerOperation == 0 ||
            sponsorState.tenantMaxCostPerOperation > adminMaxCostPerOperation
        ) {
            sponsorState.tenantMaxCostPerOperation = adminMaxCostPerOperation;
        }
        if (isNew || sponsorState.tenantDailyLimit == 0 || sponsorState.tenantDailyLimit > adminDailyLimit) {
            sponsorState.tenantDailyLimit = adminDailyLimit;
        }
        if (isNew) {
            sponsorState.tenantEnabled = true;
            sponsorState.lastResetDay = block.timestamp / 1 days;
            // A new sponsor pays only for wallets its manager approved, until the manager opts out.
            _sponsorStorage().walletApprovalRequired[sponsor] = true;
        }

        emit SponsorConfigured(sponsor, tenantId, manager, adminMaxCostPerOperation, adminDailyLimit, adminEnabled);
    }

    /// @inheritdoc IGasSponsor
    function setSponsorManager(address sponsor, address manager) external override onlyPlatformAdmin {
        _requireNonZero(manager);
        _beforeAdminSponsorChange(sponsor);
        SponsorState storage sponsorState = _sponsorState(sponsor);
        address previousManager = sponsorState.manager;
        sponsorState.manager = manager;
        emit SponsorManagerUpdated(sponsor, previousManager, manager);
    }

    /// @inheritdoc IGasSponsor
    /// @dev The pauser may only disable.
    function setSponsorAdminEnabled(address sponsor, bool enabled) external override {
        _onlyAdminOrStopping(!enabled);
        _sponsorState(sponsor).adminEnabled = enabled;
        emit SponsorAdminStatusUpdated(sponsor, enabled);
    }

    /// @inheritdoc IGasSponsor
    function setTenantLimits(
        address sponsor,
        uint256 maxCostPerOperation,
        uint256 dailyLimit
    ) external override onlySponsorManager(sponsor) {
        SponsorState storage sponsorState = _sponsorState(sponsor);
        if (
            maxCostPerOperation == 0 ||
            dailyLimit < maxCostPerOperation ||
            maxCostPerOperation > sponsorState.adminMaxCostPerOperation ||
            dailyLimit > sponsorState.adminDailyLimit
        ) {
            revert InvalidConfiguration();
        }
        sponsorState.tenantMaxCostPerOperation = maxCostPerOperation;
        sponsorState.tenantDailyLimit = dailyLimit;
        emit TenantLimitsUpdated(sponsor, maxCostPerOperation, dailyLimit);
    }

    /// @inheritdoc IGasSponsor
    function setTenantEnabled(address sponsor, bool enabled) external override onlySponsorManager(sponsor) {
        _sponsorState(sponsor).tenantEnabled = enabled;
        emit SponsorTenantStatusUpdated(sponsor, enabled);
    }

    /// @inheritdoc IGasSponsor
    function depositFor(address sponsor) external payable override {
        if (msg.value == 0) revert ZeroValue();
        _beforeRefundableDeposit(sponsor);
        SponsorState storage sponsorState = _sponsorState(sponsor);
        sponsorState.balance += msg.value;
        emit Deposited(sponsor, msg.sender, msg.value);
    }

    /// @inheritdoc IGasSponsor
    /// @dev Restricted subsidy: usable for gas, never a tenant withdrawal. depositFor stays the refundable path.
    function depositGasCredit(address sponsor) external payable override {
        if (msg.value == 0) revert ZeroValue();
        _beforeGasCreditDeposit(sponsor);
        _sponsorState(sponsor).balance += msg.value;
        _sponsorStorage().restrictedGasCredit[sponsor] += msg.value;
        emit GasCreditDeposited(sponsor, msg.sender, msg.value);
    }

    /// @notice Sends up to `amount` of a sponsor's restricted gas credit to `recipient` (platform administrator,
    ///         or as a later implementation narrows it).
    function recoverGasCredit(address sponsor, address payable recipient, uint256 amount) external nonReentrant {
        _authorizeGasCreditRecovery(sponsor, recipient);
        _requireNonZero(recipient);
        SponsorState storage sponsorState = _sponsorState(sponsor);
        uint256 credit = _sponsorStorage().restrictedGasCredit[sponsor];
        if (amount == 0 || amount > credit || amount > sponsorState.balance - _pendingWorkerCost(sponsor)) {
            revert InsufficientSponsorBalance(credit, amount);
        }
        _sponsorStorage().restrictedGasCredit[sponsor] = credit - amount;
        sponsorState.balance -= amount;
        _sendValue(recipient, amount);
        emit GasCreditRecovered(sponsor, recipient, amount);
    }

    /// @inheritdoc IGasSponsor
    function withdrawSponsor(
        address sponsor,
        address payable recipient,
        uint256 amount
    ) external override onlySponsorManager(sponsor) nonReentrant {
        _beforeSponsorWithdrawal(sponsor);
        _requireNonZero(recipient);
        if (amount == 0) revert ZeroValue();
        SponsorState storage sponsorState = _sponsorState(sponsor);
        if (
            sponsorState.balance - _sponsorStorage().restrictedGasCredit[sponsor] < amount ||
            sponsorState.balance - _pendingWorkerCost(sponsor) < amount
        ) {
            revert InsufficientSponsorBalance(
                sponsorState.balance - _sponsorStorage().restrictedGasCredit[sponsor],
                amount
            );
        }
        sponsorState.balance -= amount;
        _sendValue(recipient, amount);
        emit Withdrawn(sponsor, recipient, amount);
    }

    /// @inheritdoc IGasSponsor
    /// @dev The policy must name exactly this sponsor engine and sponsor. Removing a broken policy does not call
    ///      it, so its code cannot trap account management.
    function setSponsorPolicy(address sponsor, address policy) external override onlySponsorManager(sponsor) {
        if (_pendingWorkerCost(sponsor) != 0) revert InvalidConfiguration();
        if (policy != address(0)) {
            if (policy.code.length == 0) revert InvalidAllowancePolicy();
            if (
                ITenantAllowancePolicy(policy).gasSponsor() != address(this) ||
                ITenantAllowancePolicy(policy).sponsor() != sponsor
            ) {
                revert InvalidAllowancePolicy();
            }
        }
        _sponsorStorage().allowancePolicies[sponsor] = policy;
        emit SponsorPolicyUpdated(sponsor, policy);
    }

    /// @inheritdoc IGasSponsor
    /// @dev Explicit denies always apply.
    function setWalletApprovalRequired(address sponsor, bool required) external override onlySponsorManager(sponsor) {
        _sponsorStorage().walletApprovalRequired[sponsor] = required;
        emit WalletApprovalRequired(sponsor, required);
    }

    /// @inheritdoc IGasSponsor
    /// @dev Approval only permits sponsorship: it grants no budget and no target-contract authority.
    function setSponsoredWallet(
        address sponsor,
        address wallet,
        uint8 permission
    ) external override onlySponsorManager(sponsor) {
        if (wallet == address(0) || permission > _WALLET_DENIED) revert InvalidAllowancePolicy();
        _sponsorStorage().sponsoredWallets[sponsor][wallet] = permission;
        emit SponsoredWalletUpdated(sponsor, wallet, permission);
    }

    /// @inheritdoc IGasSponsor
    function executeSponsored(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData,
        bytes calldata voucherSignature
    )
        external
        override
        nonReentrant
        returns (bool success, bytes memory boundedReturnData, uint256 reimbursement)
    {
        uint256 gasStart = gasleft();
        _validateVoucherEnvelope(voucher, executionData);
        _validateSponsorBudget(voucher);
        _validateDelegationAndSignature(voucher, executionData, voucherSignature);
        _beforeSponsoredExecution(voucher, executionData);

        PolicyContext memory context = PolicyContext(
            _sponsorStorage().allowancePolicies[voucher.sponsor],
            costOverheadGas(voucher.sponsor)
        );
        if (context.policy != address(0)) _reservePolicy(context.policy, voucher, executionData);

        _sponsorStorage().consumedOperations[_operationKey(voucher.sponsor, voucher.operationId)] = true;

        // After the optional policy callbacks, before the gas reserve check.
        _validateSponsoredTargets(executionData);

        // Checked inside _boundedCall, after the calldata copy has paid its memory expansion.
        uint256 requiredGas =
            voucher.callGasLimit +
            (voucher.callGasLimit / 63) +
            _POST_CALL_GAS_RESERVE +
            (context.policy == address(0) ? 0 : _POLICY_SETTLE_GAS + _POLICY_SETTLE_CALL_OVERHEAD);

        uint256 returnDataSize;
        (success, boundedReturnData, returnDataSize) = _boundedCall(
            voucher.account,
            voucher.callGasLimit,
            executionData,
            requiredGas
        );

        reimbursement = _settleSponsoredOperation(
            voucher,
            gasStart,
            success,
            returnDataSize,
            boundedReturnData,
            context
        );
    }

    /// @notice A sponsor's refundable coin and restricted gas credit.
    function getSponsorFunding(address sponsor) external view returns (uint256 refundable, uint256 gasCredit) {
        gasCredit = _sponsorStorage().restrictedGasCredit[sponsor];
        refundable = _sponsorStorage().sponsors[sponsor].balance - gasCredit;
    }

    /// @inheritdoc IGasSponsor
    function pauser() external view override returns (address) {
        return _sponsorStorage().pauser;
    }

    /// @inheritdoc IGasSponsor
    /// @return limit The sponsor's operations per day (a program sponsor's comes from its program's tier and
    ///         reads as 0 here).
    /// @return today This UTC day's operations so far.
    function sponsorOps(address sponsor) external view override returns (uint256 limit, uint256 today) {
        GasSponsorStorage storage state = _sponsorStorage();
        limit = state.opsPerDay[sponsor];
        today = state.opsDay[sponsor] == block.timestamp / 1 days ? state.opsCount[sponsor] : 0;
    }

    /// @inheritdoc IGasSponsor
    function getSponsorPolicy(address sponsor) external view override returns (address policy, bool approvalRequired) {
        return (_sponsorStorage().allowancePolicies[sponsor], _walletApprovalRequired(sponsor));
    }

    /// @inheritdoc IGasSponsor
    function sponsoredWalletPermission(address sponsor, address wallet) external view override returns (uint8) {
        return _sponsorStorage().sponsoredWallets[sponsor][wallet];
    }

    /// @inheritdoc IGasSponsor
    function getSponsorAccount(address sponsor) external view override returns (SponsorAccount memory account) {
        SponsorState storage sponsorState = _sponsorStorage().sponsors[sponsor];
        uint256 currentDay = block.timestamp / 1 days;
        (uint256 hardPerOperation, uint256 hardDaily) = _hardCaps(sponsor);
        uint256 spent = currentDay == sponsorState.lastResetDay ? sponsorState.dailySpent : 0;
        account = SponsorAccount({
            tenantId: sponsorState.tenantId,
            manager: sponsorState.manager,
            balance: sponsorState.balance,
            adminMaxCostPerOperation: sponsorState.adminMaxCostPerOperation,
            tenantMaxCostPerOperation: sponsorState.tenantMaxCostPerOperation,
            effectiveMaxCostPerOperation: _min(
                _min(sponsorState.adminMaxCostPerOperation, sponsorState.tenantMaxCostPerOperation),
                hardPerOperation
            ),
            adminDailyLimit: sponsorState.adminDailyLimit,
            tenantDailyLimit: sponsorState.tenantDailyLimit,
            effectiveDailyLimit: _min(_min(sponsorState.adminDailyLimit, sponsorState.tenantDailyLimit), hardDaily),
            dailySpent: spent,
            adminEnabled: sponsorState.adminEnabled,
            tenantEnabled: sponsorState.tenantEnabled
        });
    }

    /// @inheritdoc IGasSponsor
    function voucherDigest(SponsorshipVoucher calldata voucher) external view override returns (bytes32) {
        return _voucherDigest(voucher);
    }

    /// @inheritdoc IGasSponsor
    function isDelegationReady(address account) external view override returns (bool) {
        return _isDelegationReady(account, _sponsorStorage().approvedDelegate);
    }

    /// @inheritdoc IGasSponsor
    function isOperationConsumed(address sponsor, bytes32 operationId) external view override returns (bool) {
        return _sponsorStorage().consumedOperations[_operationKey(sponsor, operationId)];
    }

    /// @inheritdoc IGasSponsor
    function isRelayer(address relayer) external view override returns (bool) {
        return _sponsorStorage().relayers[relayer];
    }

    /// @inheritdoc IGasSponsor
    function platformAdmin() external view override returns (address) {
        return _sponsorStorage().platformAdmin;
    }

    /// @inheritdoc IGasSponsor
    function pendingPlatformAdmin() external view override returns (address) {
        return _sponsorStorage().pendingPlatformAdmin;
    }

    /// @inheritdoc IGasSponsor
    function voucherSigner() external view override returns (address) {
        return _sponsorStorage().voucherSigner;
    }

    /// @inheritdoc IGasSponsor
    function approvedDelegate() external view override returns (address) {
        return _sponsorStorage().approvedDelegate;
    }

    /// @inheritdoc IGasSponsor
    function fixedOverheadGas() external view override returns (uint256) {
        return _sponsorStorage().fixedOverheadGas;
    }

    /// @inheritdoc IGasSponsor
    function paused() external view override returns (bool) {
        return _sponsorStorage().paused;
    }

    /// @notice The outer call gas a voucher needs for `executionGasLimit` and `executionDataBytes` of calldata.
    function minimumCallGas(uint256 executionGasLimit, uint256 executionDataBytes) external pure returns (uint256) {
        return DelegationGas.minimumCallGas(executionGasLimit, executionDataBytes);
    }

    /// @inheritdoc IGasSponsor
    function expectedDelegationCodeHash(address delegate) external pure override returns (bytes32) {
        return _delegationCodeHash(delegate);
    }

    /// @inheritdoc IGasSponsor
    function sponsorStorageLocation() external pure override returns (bytes32) {
        return _GAS_SPONSOR_STORAGE_LOCATION;
    }

    /// @inheritdoc IGasSponsor
    function implementationVersion() external pure virtual override returns (string memory) {
        return "1.5.2";
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IGasSponsor
    function isWalletSponsored(address sponsor, address wallet) public view override returns (bool) {
        GasSponsorStorage storage state = _sponsorStorage();
        uint8 permission = state.sponsoredWallets[sponsor][wallet];
        return
            wallet != address(0) &&
            permission != _WALLET_DENIED &&
            (permission == _WALLET_APPROVED || !_walletApprovalRequired(sponsor));
    }

    /// @inheritdoc IGasSponsor
    /// @dev The reimbursement model includes bounded bookkeeping overhead; it does not reproduce the
    ///      transaction receipt's gas charge exactly.
    function costOverheadGas(address sponsor) public view override returns (uint256) {
        return
            _sponsorStorage().fixedOverheadGas +
            (_sponsorStorage().allowancePolicies[sponsor] == address(0) ? 0 : _POLICY_SETTLEMENT_OVERHEAD);
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @dev Asks the sponsor's allowance policy to reserve this operation. ProgramGasSponsor may ask a V2 policy
    ///      with the whole execution envelope instead.
    function _reservePolicy(
        address policy,
        SponsorshipVoucher calldata voucher,
        bytes calldata
    ) internal virtual {
        _callPolicy(
            policy,
            abi.encodeCall(ITenantAllowancePolicy.reserve, (voucher.operationId, voucher.account, voucher.maxCost)),
            ITenantAllowancePolicy.reserve.selector
        );
    }

    /// @dev Checks on a voucher and its validated execution envelope, after the budget, the delegation and both
    ///      signatures, before the policy and the call: counts the operation against the sponsor's ops per day
    ///      (ProgramGasSponsor counts a program sponsor's against its tier instead). Reverts to refuse.
    function _beforeSponsoredExecution(SponsorshipVoucher calldata voucher, bytes calldata) internal virtual {
        _countOperation(voucher.sponsor, _sponsorStorage().opsPerDay[voucher.sponsor]);
    }

    /// @dev Calls a policy with a fixed gas budget and requires the `expected` selector back.
    function _callPolicy(address policy, bytes memory input, bytes4 expected) internal {
        bool ok;
        uint256 size;
        bytes32 response;
        uint256 budget = _POLICY_CALL_GAS;
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            ok := call(budget, policy, 0, add(input, 32), mload(input), output, 32)
            size := returndatasize()
            response := mload(output)
        }
        if (!ok || size != 32 || bytes4(response) != expected) revert AllowancePolicyFailed(policy, expected);
    }

    /// @dev The policy's settle with exactly `budget` gas (the whole call reverts for want of it); returns whether
    ///      the policy accepted it.
    function _trySettle(address policy, bytes32 operationId, uint256 cost, uint256 budget) internal returns (bool) {
        if (gasleft() < budget + budget / 63 + _POLICY_SETTLE_RESERVE) {
            revert InsufficientExecutionGas(gasleft(), budget);
        }
        (bool ok, bytes memory answer) = policy.call{gas: budget}(
            abi.encodeCall(ITenantAllowancePolicy.settle, (operationId, cost))
        );
        return ok && answer.length == 32 && bytes4(answer) == ITenantAllowancePolicy.settle.selector;
    }

    /// @dev One more operation for `sponsor` today, at most `limit` a UTC day. Saturating by construction: the
    ///      count only grows while below `limit`, so it never overflows and stops nothing but this sponsor's
    ///      extra operations.
    function _countOperation(address sponsor, uint256 limit) internal {
        GasSponsorStorage storage state = _sponsorStorage();
        uint256 today = block.timestamp / 1 days;
        uint256 used = state.opsDay[sponsor] == today ? state.opsCount[sponsor] : 0;
        if (used >= limit) revert DailyOpsReached(sponsor, limit);
        state.opsDay[sponsor] = today;
        state.opsCount[sponsor] = used + 1;
    }

    function _sendValue(address recipient, uint256 amount) internal {
        (bool sent, ) = payable(recipient).call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
    }

    function _resetDailySpendIfNeeded(SponsorState storage sponsorState) internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (sponsorState.lastResetDay != currentDay) {
            sponsorState.lastResetDay = currentDay;
            sponsorState.dailySpent = 0;
        }
    }

    /// @dev Lets a later implementation refuse the platform administrator's configureSponsor, setSponsorManager
    ///      or setSponsorOpsPerDay for `sponsor` (ProgramGasSponsor: a program sponsor is its program's alone).
    function _beforeAdminSponsorChange(address sponsor) internal view virtual {}

    /// @dev Caps above the stored ones, applied at spend time (ProgramGasSponsor: the program's hard caps).
    function _hardCaps(address) internal view virtual returns (uint256, uint256) {
        return (type(uint256).max, type(uint256).max);
    }

    /// @dev Whether `sponsor` pays only for approved wallets (ProgramGasSponsor: always, for a program sponsor).
    function _walletApprovalRequired(address sponsor) internal view virtual returns (bool) {
        return _sponsorStorage().walletApprovalRequired[sponsor];
    }

    /// @dev Lets a later implementation check every call target of the validated envelope.
    function _validateSponsoredTargets(bytes calldata) internal view virtual {}

    /// @dev Lets a later implementation refuse a refundable deposit to `sponsor` (ProgramGasSponsor: a program
    ///      sponsor holds gas credit only). Reverts to refuse.
    function _beforeRefundableDeposit(address sponsor) internal view virtual {}

    /// @dev Lets a later implementation refuse restricted gas credit for `sponsor` from `msg.sender`
    ///      (ProgramGasSponsor: a program sponsor's credit comes from its program alone). Reverts to refuse.
    function _beforeGasCreditDeposit(address sponsor) internal view virtual {}

    /// @dev Lets a later implementation refuse a manager's withdrawal from `sponsor` (ProgramGasSponsor: nothing
    ///      leaves a program sponsor as coin). Reverts to refuse.
    function _beforeSponsorWithdrawal(address sponsor) internal view virtual {}

    /// @dev Who may recover `sponsor`'s restricted gas credit, and to where: the platform administrator, to any
    ///      non-zero address. ProgramGasSponsor narrows a program sponsor's to its program.
    function _authorizeGasCreditRecovery(address, address) internal view virtual {
        if (msg.sender != _sponsorStorage().platformAdmin) revert NotPlatformAdmin();
    }

    /// @dev Coin reserved by open worker reservations (WorkerGasSponsor); none here.
    function _pendingWorkerCost(address) internal view virtual returns (uint256) {
        return 0;
    }

    function _sponsorState(address sponsor) internal view returns (SponsorState storage sponsorState) {
        sponsorState = _sponsorStorage().sponsors[sponsor];
        if (sponsorState.manager == address(0)) revert SponsorNotConfigured(sponsor);
    }

    /// @dev The consumed-operation key, per sponsor, so no sponsor (or its worker) can burn another's ids.
    function _operationKey(address sponsor, bytes32 operationId) internal pure returns (bytes32) {
        return keccak256(abi.encode(sponsor, operationId));
    }

    function _sponsorStorage() internal pure returns (GasSponsorStorage storage state) {
        bytes32 location = _GAS_SPONSOR_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    function _validateSponsorBudget(SponsorshipVoucher calldata voucher) private {
        SponsorState storage sponsorState = _sponsorState(voucher.sponsor);
        if (!sponsorState.adminEnabled || !sponsorState.tenantEnabled) revert SponsorDisabled(voucher.sponsor);
        if (sponsorState.tenantId != voucher.tenantId) revert TenantMismatch(sponsorState.tenantId, voucher.tenantId);

        if (!isWalletSponsored(voucher.sponsor, voucher.account)) {
            revert WalletNotSponsored(voucher.sponsor, voucher.account);
        }

        // A later implementation's hard caps clamp the stored ones (a lowered program cap binds at once).
        (uint256 hardPerOperation, uint256 hardDaily) = _hardCaps(voucher.sponsor);
        uint256 effectivePerOperation = _min(
            _min(sponsorState.adminMaxCostPerOperation, sponsorState.tenantMaxCostPerOperation),
            hardPerOperation
        );
        if (voucher.maxCost > effectivePerOperation) revert CostLimitExceeded(effectivePerOperation, voucher.maxCost);

        _resetDailySpendIfNeeded(sponsorState);
        uint256 effectiveDailyLimit = _min(
            _min(sponsorState.adminDailyLimit, sponsorState.tenantDailyLimit),
            hardDaily
        );
        uint256 reservedDailySpend =
            sponsorState.dailySpent + _pendingWorkerCost(voucher.sponsor) + voucher.maxCost;
        if (reservedDailySpend > effectiveDailyLimit) {
            revert DailyLimitExceeded(effectiveDailyLimit, reservedDailySpend);
        }

        uint256 available = _min(sponsorState.balance - _pendingWorkerCost(voucher.sponsor), address(this).balance);
        if (available < voucher.maxCost) revert InsufficientSponsorBalance(available, voucher.maxCost);
    }

    function _settleSponsoredOperation(
        SponsorshipVoucher calldata voucher,
        uint256 gasStart,
        bool success,
        uint256 returnDataSize,
        bytes memory boundedReturnData,
        PolicyContext memory context
    ) private returns (uint256 reimbursement) {
        uint256 measuredGas = gasStart - gasleft() + context.overhead;
        uint256 measuredCost = measuredGas * tx.gasprice;
        bool reimbursementCapped = measuredCost > voucher.maxCost;
        reimbursement = reimbursementCapped ? voucher.maxCost : measuredCost;

        SponsorState storage sponsorState = _sponsorState(voucher.sponsor);
        uint256 creditUsed = _min(reimbursement, _sponsorStorage().restrictedGasCredit[voucher.sponsor]);
        _sponsorStorage().restrictedGasCredit[voucher.sponsor] -= creditUsed;
        sponsorState.balance -= reimbursement;
        sponsorState.dailySpent += reimbursement;

        if (context.policy != address(0)) _settlePolicy(context.policy, voucher.operationId, reimbursement);

        if (reimbursement != 0) _sendValue(msg.sender, reimbursement);

        _emitOperation(voucher, success);
        emit RelayerReimbursed(voucher.operationId, msg.sender, reimbursement, measuredGas, reimbursementCapped);
        emit SponsoredReturnData(voucher.operationId, returnDataSize, keccak256(boundedReturnData));
    }

    function _emitOperation(SponsorshipVoucher calldata voucher, bool success) private {
        emit SponsoredOperation(
            voucher.operationId,
            voucher.tenantId,
            voucher.account,
            voucher.sponsor,
            voucher.campaignId,
            success
        );
    }

    /// @dev The policy's settle, best-effort with a fixed budget (charged inside the settlement overhead). The
    ///      caller must leave it that budget: too little gas reverts the whole transaction rather than silently
    ///      skipping it.
    function _settlePolicy(address policy, bytes32 operationId, uint256 cost) private {
        if (!_trySettle(policy, operationId, cost, _POLICY_SETTLE_GAS)) {
            emit AllowancePolicySettleFailed(operationId, policy);
        }
    }

    /// @dev Copies the execution data, checks the gas reserve, then calls the account with exactly
    ///      `callGasLimit` gas and keeps at most _MAX_RETURN_DATA_BYTES of its return data.
    function _boundedCall(
        address account,
        uint256 callGasLimit,
        bytes calldata executionData,
        uint256 requiredGas
    ) private returns (bool success, bytes memory boundedReturnData, uint256 returnDataSize) {
        uint256 inputPointer;
        assembly ("memory-safe") {
            inputPointer := mload(0x40)
            calldatacopy(inputPointer, executionData.offset, executionData.length)
            mstore(0x40, and(add(add(inputPointer, executionData.length), 0x1f), not(0x1f)))
        }
        if (gasleft() < requiredGas) revert InsufficientExecutionGas(gasleft(), requiredGas);
        assembly ("memory-safe") {
            success := call(callGasLimit, account, 0, inputPointer, executionData.length, 0, 0)
            returnDataSize := returndatasize()
        }

        uint256 copySize = returnDataSize > _MAX_RETURN_DATA_BYTES ? _MAX_RETURN_DATA_BYTES : returnDataSize;
        boundedReturnData = new bytes(copySize);
        assembly ("memory-safe") {
            returndatacopy(add(boundedReturnData, 0x20), 0, copySize)
        }
    }

    function _onlyPlatformAdmin() private view {
        if (msg.sender != _sponsorStorage().platformAdmin) revert NotPlatformAdmin();
    }

    function _onlySponsorManager(address sponsor) private view {
        if (msg.sender != _sponsorState(sponsor).manager) revert NotSponsorManager();
    }

    /// @dev The platform administrator always; the pauser only when `stopping`.
    function _onlyAdminOrStopping(bool stopping) private view {
        GasSponsorStorage storage state = _sponsorStorage();
        bool pauserStopping = stopping && msg.sender == state.pauser && msg.sender != address(0);
        if (msg.sender != state.platformAdmin && !pauserStopping) revert NotPlatformAdmin();
    }

    function _voucherDigest(SponsorshipVoucher calldata voucher) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _VOUCHER_TYPEHASH,
                voucher.operationId,
                voucher.tenantId,
                voucher.campaignId,
                voucher.sponsor,
                voucher.account,
                voucher.relayer,
                voucher.delegate,
                voucher.executionHash,
                voucher.callGasLimit,
                voucher.maxFeePerGas,
                voucher.maxCost,
                voucher.deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _validateVoucherEnvelope(SponsorshipVoucher calldata voucher, bytes calldata executionData) private view {
        GasSponsorStorage storage state = _sponsorStorage();
        if (state.paused) revert SponsorshipIsPaused();
        if (!state.relayers[msg.sender]) revert RelayerNotAuthorized(msg.sender);
        if (
            voucher.operationId == bytes32(0) ||
            voucher.account == address(0) ||
            voucher.relayer != msg.sender ||
            voucher.delegate != state.approvedDelegate ||
            voucher.executionHash != keccak256(executionData)
        ) {
            revert InvalidVoucher();
        }
        if (block.timestamp > voucher.deadline) revert VoucherExpired();
        if (state.consumedOperations[_operationKey(voucher.sponsor, voucher.operationId)]) {
            revert OperationAlreadyConsumed(voucher.operationId);
        }
        if (executionData.length > _MAX_EXECUTION_DATA_BYTES) revert InvalidExecutionLength(executionData.length);
        if (voucher.callGasLimit < _MIN_CALL_GAS_LIMIT || voucher.callGasLimit > _MAX_CALL_GAS_LIMIT) {
            revert InvalidCallGasLimit(voucher.callGasLimit);
        }
        if (voucher.maxFeePerGas == 0 || tx.gasprice > voucher.maxFeePerGas) {
            revert GasPriceTooHigh(tx.gasprice, voucher.maxFeePerGas);
        }

        uint256 expectedCostCap = (voucher.callGasLimit + costOverheadGas(voucher.sponsor)) * voucher.maxFeePerGas;
        if (voucher.maxCost != expectedCostCap) revert CostEnvelopeMismatch(expectedCostCap, voucher.maxCost);
    }

    function _validateDelegationAndSignature(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData,
        bytes calldata voucherSignature
    ) private view {
        if (!_isDelegationReady(voucher.account, voucher.delegate)) revert InvalidDelegation(voucher.account);
        _validateExecutionEnvelope(executionData, voucher.operationId, voucher.deadline, voucher.callGasLimit);

        GasSponsorStorage storage state = _sponsorStorage();
        if (!_isValidVoucherSignature(state.voucherSigner, _voucherDigest(voucher), voucherSignature)) {
            revert InvalidVoucherSignature();
        }
    }

    /// @dev The execution data must be executeSponsored(request, signature) with the request at offset 64, this
    ///      sponsor as executor, the voucher's operation id and deadline, and an execution gas limit the outer call
    ///      gas can carry.
    function _validateExecutionEnvelope(
        bytes calldata executionData,
        bytes32 expectedOperationId,
        uint256 expectedDeadline,
        uint256 outerCallGasLimit
    ) private view {
        if (executionData.length < _MIN_ENVELOPE_BYTES) revert InvalidExecutionEnvelope();

        bytes4 selector;
        uint256 executionOffset;
        uint256 executionBase;
        bytes32 operationId;
        uint256 executorWord;
        uint256 delegatedDeadline;
        uint256 delegatedExecutionGasLimit;
        assembly ("memory-safe") {
            selector := calldataload(executionData.offset)
            executionOffset := calldataload(add(executionData.offset, 4))
        }
        if (executionOffset != 64) revert InvalidExecutionEnvelope();
        executionBase = 4 + executionOffset;
        if (executionData.length < executionBase + 192) revert InvalidExecutionEnvelope();
        assembly ("memory-safe") {
            operationId := calldataload(add(executionData.offset, executionBase))
            executorWord := calldataload(add(add(executionData.offset, executionBase), 32))
            delegatedDeadline := calldataload(add(add(executionData.offset, executionBase), 128))
            delegatedExecutionGasLimit := calldataload(add(add(executionData.offset, executionBase), 160))
        }

        if (
            selector != ICryftDelegation.executeSponsored.selector ||
            operationId != expectedOperationId ||
            address(uint160(executorWord)) != address(this) ||
            delegatedDeadline != expectedDeadline ||
            delegatedExecutionGasLimit == 0 ||
            delegatedExecutionGasLimit > DelegationGas.MAX_EXECUTION_GAS ||
            DelegationGas.minimumCallGas(delegatedExecutionGasLimit, executionData.length) > outerCallGasLimit
        ) {
            revert InvalidExecutionEnvelope();
        }
    }

    function _isValidVoucherSignature(
        address signer,
        bytes32 digest,
        bytes calldata signature
    ) private view returns (bool) {
        if (signer.code.length == 0) return digest.tryRecover(signature) == signer;

        (bool success, bytes memory result) = signer.staticcall{gas: _ERC1271_GAS_LIMIT}(
            abi.encodeCall(IERC1271VoucherSigner.isValidSignature, (digest, signature))
        );
        return success && result.length >= 32 && bytes4(result) == _EIP1271_MAGIC;
    }

    function _isDelegationReady(address account, address delegate) private view returns (bool) {
        if (account == address(0) || account.codehash != _delegationCodeHash(delegate)) return false;

        if (delegate.codehash != _sponsorStorage().approvedDelegateCodeHash) return false;

        (bool protocolSuccess, bytes memory protocolResult) = account.staticcall{gas: _READINESS_CALL_GAS_LIMIT}(
            abi.encodeCall(ICryftDelegation.delegationProtocolId, ())
        );
        return
            protocolSuccess &&
            protocolResult.length == 32 &&
            abi.decode(protocolResult, (bytes32)) == _EXPECTED_DELEGATION_PROTOCOL_ID;
    }

    /// @dev The delegate must be a dispatcher that speaks the direct-beacon-dispatch v2 protocol.
    function _requireDelegate(address delegate) private view {
        if (delegate == address(0) || delegate.code.length == 0) revert ZeroAddress();
        (bool ok, bytes memory result) = delegate.staticcall{gas: _READINESS_CALL_GAS_LIMIT}(
            abi.encodeWithSignature("dispatcherProtocolId()")
        );
        if (
            !ok ||
            result.length != 32 ||
            abi.decode(result, (bytes32)) != keccak256("cryft.delegation.direct-beacon-dispatch.v2")
        ) {
            revert InvalidConfiguration();
        }
    }

    function _isInitializationAuthority(address caller) private view returns (bool) {
        if (caller == _GENESIS_PROXY_ADMIN) return true;
        try IRootOverlordRegistry(_VALIDATOR_ROOT_REGISTRY).isRootOverlord(caller) returns (bool authorized) {
            return authorized;
        } catch {
            return false;
        }
    }

    function _delegationCodeHash(address delegate) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"ef0100", delegate));
    }

    function _requireNonZero(address value) private pure {
        if (value == address(0)) revert ZeroAddress();
    }

    function _validateOverheadGas(uint256 overheadGas) private pure {
        if (overheadGas < _MIN_OVERHEAD_GAS || overheadGas > _MAX_OVERHEAD_GAS) revert InvalidConfiguration();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
