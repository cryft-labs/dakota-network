// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/*
   ___           ___
  / __|__ _ ___ / __|_ __  ___ _ _  ___ ___ _ _
 | (_ / _` (_-< \__ \ '_ \/ _ \ ' \(_-</ _ \ '_|
  \___\__,_/__/ |___/ .__/\___/_||_/__/\___/_|
                    |_|                 By: CryftCreator

  Version 1.1.0 — Native Gas Sponsor with tenant allowance policies [UPGRADEABLE]

  ┌──────────────── Contract Architecture ─────────────────────────────┐
  │                                                                    │
  │  NATIVE EIP-7702 GAS SPONSORSHIP                                   │
  │                                                                    │
  │  Fixed proxy: 0x0000...FEeD                                        │
  │  Approved delegate: immutable v2 dispatcher                      │
  │  No ERC-4337, bundler, EntryPoint, or paymaster.                   │
  │                                                                    │
  │  Initial release:                                                  │
  │    • one-time initialize() through proxy_linkLogicAdmin            │
  │    • implementation constructor disables direct initialization     │
  │    • sponsorship starts paused                                     │
  │                                                                    │
  │  Platform controls:                                                │
  │    • two-step platform-admin transfer                              │
  │    • voucher signer, approved delegate, and relayer allowlist      │
  │    • global pause and calibrated fixed gas overhead                │
  │    • sponsor identity, manager, hard limits, and enable switch     │
  │                                                                    │
  │  Tenant sponsor accounts:                                          │
  │    • stable sponsor address bound to canonical tenant ID hash      │
  │    • manager sets limits no greater than platform hard limits      │
  │    • platform and tenant enable switches must both be active       │
  │    • deposits split refundable funds from restricted gas credit     │
  │                                                                    │
  │  Signed voucher envelope:                                          │
  │    • operation and campaign IDs, sponsor, tenant, account,         │
  │      relayer, delegate, execution hash, gas, cost, and deadline    │
  │    • EOA or EIP-1271 voucher signer                                │
  │    • single-use operation IDs prevent replay                       │
  │                                                                    │
  │  Execution and settlement:                                         │
  │    • validates delegated-account code and dispatcher readiness     │
  │    • binds the inner DakotaDelegation execution envelope           │
  │    • enforces per-operation, daily, balance, and gas-price caps    │
  │    • bounds execution calldata and returned data                   │
  │    • reimburses measured gas within the signed maximum cost        │
  │    • failed inner execution still consumes the operation ID        │
  │      and reimburses the relayer within the signed cap              │
  │                                                                    │
  │  Storage and upgrades:                                             │
  │    • ERC-7201 namespace: dakota.storage.GasSponsor                 │
  │    • inherited initializer/reentrancy slots remain reserved        │
  │    • later logic upgrades use the fixed Dakota ProxyAdmin          │
  └────────────────────────────────────────────────────────────────────┘
*/

import "./DelegationGas.sol";
import "../Upgradeable/ReentrancyGuardUpgradeable.sol";
import "../Upgradeable/Initializable.sol";

import "./Interfaces/IDakotaDelegation.sol";
import "./Interfaces/IGasSponsor.sol";
import "./Interfaces/ITenantAllowancePolicy.sol";
import "./Libraries/DakotaECDSA.sol";

interface IERC1271VoucherSigner {
    function isValidSignature(
        bytes32 digest,
        bytes calldata signature
    ) external view returns (bytes4);
}

interface IRootOverlordRegistry {
    function isRootOverlord(address account) external view returns (bool);
}

/// @title GasSponsor
/// @notice Native EIP-7702 sponsorship with optional tenant-owned allowance enforcement.
/// @dev All sponsor state lives under one ERC-7201 namespace. The uninitialized
///      genesis proxy first-links through proxy_linkLogicAdmin; later upgrades
///      use the fixed ProxyAdmin.
contract GasSponsor is
    Initializable,
    ReentrancyGuardUpgradeable,
    IGasSponsor
{
    using DakotaECDSA for bytes32;

    error NotInitializationAuthority(address caller);
    error NotPlatformAdmin();
    error NotPendingPlatformAdmin();
    error NotSponsorManager();
    error ZeroAddress();
    error ZeroValue();
    error InvalidConfiguration();
    error SponsorNotConfigured(address sponsor);
    error SponsorDisabled(address sponsor);
    error TenantMismatch(bytes32 expected, bytes32 supplied);
    error SponsorshipIsPaused();
    error RelayerNotAuthorized(address relayer);
    error InvalidVoucher();
    error InvalidVoucherSignature();
    error VoucherExpired();
    error OperationAlreadyConsumed(bytes32 operationId);
    error InvalidDelegation(address account);
    error InvalidExecutionEnvelope();
    error InvalidExecutionLength(uint256 length);
    error InvalidCallGasLimit(uint256 gasLimit);
    error GasPriceTooHigh(uint256 actual, uint256 maximum);
    error CostEnvelopeMismatch(uint256 expected, uint256 supplied);
    error CostLimitExceeded(uint256 limit, uint256 requested);
    error DailyLimitExceeded(uint256 limit, uint256 requested);
    error InsufficientSponsorBalance(uint256 available, uint256 required);
    error InsufficientExecutionGas(uint256 available, uint256 required);
    error NativeTransferFailed();
    error DirectNativeTransferDisabled();

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

    /// @custom:storage-location erc7201:dakota.storage.GasSponsor
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
        // Append-only: existing balances, authorities and voucher nonces are preserved.
        mapping(address => address) allowancePolicies;
        mapping(address => bool) walletApprovalRequired;
        mapping(address => mapping(address => uint8)) sponsoredWallets;
    }

    error WalletNotSponsored(address sponsor, address wallet);
    error InvalidAllowancePolicy();
    struct PolicyContext { address policy; uint256 overhead; }
    error AllowancePolicyFailed(address policy, bytes4 action);
    event SponsorPolicyUpdated(address indexed sponsor, address indexed policy);
    event WalletApprovalRequired(address indexed sponsor, bool required);
    event SponsoredWalletUpdated(address indexed sponsor, address indexed wallet, uint8 permission);

    uint256 private constant _POLICY_CALL_GAS = 350_000;
    uint256 private constant _POLICY_SETTLEMENT_OVERHEAD = 150_000;

    bytes32 private constant _GAS_SPONSOR_STORAGE_LOCATION =
        0x1517881409dbca238e515328317c78f643c8aa79fdd0217b0d2dee62cd1df100;

    address private constant _GENESIS_PROXY_ADMIN =
        0x0000000000000000000000000000000000FacAdE;
    address private constant _VALIDATOR_ROOT_REGISTRY =
        0x0000000000000000000000000000000000001111;

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256("DakotaGasSponsor");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _VOUCHER_TYPEHASH = keccak256(
        "SponsorshipVoucher(bytes32 operationId,bytes32 tenantId,bytes32 campaignId,address sponsor,address account,address relayer,address delegate,bytes32 executionHash,uint256 callGasLimit,uint256 maxFeePerGas,uint256 maxCost,uint256 deadline)"
    );

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;
    bytes32 private constant _EXPECTED_DELEGATION_PROTOCOL_ID =
        keccak256("dakota.delegation.sponsored-execution.v1");
    uint256 private constant _MIN_CALL_GAS_LIMIT = 25_000;
    uint256 private constant _MAX_CALL_GAS_LIMIT = 5_000_000;
    uint256 private constant _MIN_OVERHEAD_GAS = 50_000;
    uint256 private constant _MAX_OVERHEAD_GAS = 500_000;
    uint256 private constant _POST_CALL_GAS_RESERVE = 60_000;
    uint256 private constant _MAX_EXECUTION_DATA_BYTES = 65_536;
    uint256 private constant _MAX_RETURN_DATA_BYTES = 512;
    uint256 private constant _ERC1271_GAS_LIMIT = 50_000;
    uint256 private constant _READINESS_CALL_GAS_LIMIT = 100_000;

    constructor() {
        _disableInitializers();
    }

    modifier onlyPlatformAdmin() {
        if (msg.sender != _sponsorStorage().platformAdmin) {
            revert NotPlatformAdmin();
        }
        _;
    }

    modifier onlySponsorManager(address sponsor) {
        if (msg.sender != _sponsorState(sponsor).manager) {
            revert NotSponsorManager();
        }
        _;
    }

    /// @inheritdoc IGasSponsor
    function initialize(
        address platformAdmin_,
        address voucherSigner_,
        address approvedDelegate_,
        uint256 fixedOverheadGas_
    ) external override initializer {
        if (!_isInitializationAuthority(msg.sender)) {
            revert NotInitializationAuthority(msg.sender);
        }
        _requireNonZero(platformAdmin_);
        require(platformAdmin_ != address(this) && platformAdmin_ != _GENESIS_PROXY_ADMIN, "Invalid platform administrator");
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

        emit GasSponsorInitialized(
            platformAdmin_,
            voucherSigner_,
            approvedDelegate_,
            fixedOverheadGas_
        );
        emit SponsorshipPaused(true);
    }

    /// @inheritdoc IGasSponsor
    function proposePlatformAdmin(
        address pendingAdmin_
    ) external override onlyPlatformAdmin {
        _requireNonZero(pendingAdmin_);
        require(pendingAdmin_ != address(this) && pendingAdmin_ != _GENESIS_PROXY_ADMIN, "Invalid platform administrator");
        GasSponsorStorage storage state = _sponsorStorage();
        state.pendingPlatformAdmin = pendingAdmin_;
        emit PlatformAdminTransferProposed(
            state.platformAdmin,
            pendingAdmin_
        );
    }

    /// @inheritdoc IGasSponsor
    function acceptPlatformAdmin() external override {
        GasSponsorStorage storage state = _sponsorStorage();
        if (msg.sender != state.pendingPlatformAdmin) {
            revert NotPendingPlatformAdmin();
        }
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
    function setVoucherSigner(
        address signer
    ) external override onlyPlatformAdmin {
        _requireNonZero(signer);
        GasSponsorStorage storage state = _sponsorStorage();
        address previousSigner = state.voucherSigner;
        state.voucherSigner = signer;
        emit VoucherSignerUpdated(previousSigner, signer);
    }

    /// @inheritdoc IGasSponsor
    function setApprovedDelegate(
        address delegate
    ) external override onlyPlatformAdmin {
        _requireDelegate(delegate);
        GasSponsorStorage storage state = _sponsorStorage();
        address previousDelegate = state.approvedDelegate;
        state.approvedDelegate = delegate;
        state.approvedDelegateCodeHash = delegate.codehash;
        emit ApprovedDelegateUpdated(previousDelegate, delegate);
    }

    /// @inheritdoc IGasSponsor
    function setRelayer(
        address relayer,
        bool allowed
    ) external override onlyPlatformAdmin {
        _requireNonZero(relayer);
        _sponsorStorage().relayers[relayer] = allowed;
        emit RelayerUpdated(relayer, allowed);
    }

    /// @inheritdoc IGasSponsor
    function setPaused(
        bool paused_
    ) external override onlyPlatformAdmin {
        _sponsorStorage().paused = paused_;
        emit SponsorshipPaused(paused_);
    }

    /// @inheritdoc IGasSponsor
    function setFixedOverheadGas(
        uint256 overheadGas
    ) external override onlyPlatformAdmin {
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
        if (
            tenantId == bytes32(0) ||
            adminMaxCostPerOperation == 0 ||
            adminDailyLimit < adminMaxCostPerOperation
        ) {
            revert InvalidConfiguration();
        }

        SponsorState storage sponsorState =
            _sponsorStorage().sponsors[sponsor];
        bool isNew = sponsorState.manager == address(0);
        if (!isNew && sponsorState.tenantId != tenantId) {
            revert TenantMismatch(sponsorState.tenantId, tenantId);
        }

        sponsorState.tenantId = tenantId;
        sponsorState.manager = manager;
        sponsorState.adminMaxCostPerOperation =
            adminMaxCostPerOperation;
        sponsorState.adminDailyLimit = adminDailyLimit;
        sponsorState.adminEnabled = adminEnabled;

        if (
            isNew ||
            sponsorState.tenantMaxCostPerOperation == 0 ||
            sponsorState.tenantMaxCostPerOperation >
            adminMaxCostPerOperation
        ) {
            sponsorState.tenantMaxCostPerOperation =
                adminMaxCostPerOperation;
        }
        if (
            isNew ||
            sponsorState.tenantDailyLimit == 0 ||
            sponsorState.tenantDailyLimit > adminDailyLimit
        ) {
            sponsorState.tenantDailyLimit = adminDailyLimit;
        }
        if (isNew) {
            sponsorState.tenantEnabled = true;
            sponsorState.lastResetDay = block.timestamp / 1 days;
        }

        emit SponsorConfigured(
            sponsor,
            tenantId,
            manager,
            adminMaxCostPerOperation,
            adminDailyLimit,
            adminEnabled
        );
    }

    /// @inheritdoc IGasSponsor
    function setSponsorManager(
        address sponsor,
        address manager
    ) external override onlyPlatformAdmin {
        _requireNonZero(manager);
        SponsorState storage sponsorState = _sponsorState(sponsor);
        address previousManager = sponsorState.manager;
        sponsorState.manager = manager;
        emit SponsorManagerUpdated(sponsor, previousManager, manager);
    }

    /// @inheritdoc IGasSponsor
    function setSponsorAdminEnabled(
        address sponsor,
        bool enabled
    ) external override onlyPlatformAdmin {
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
            maxCostPerOperation >
            sponsorState.adminMaxCostPerOperation ||
            dailyLimit > sponsorState.adminDailyLimit
        ) {
            revert InvalidConfiguration();
        }
        sponsorState.tenantMaxCostPerOperation = maxCostPerOperation;
        sponsorState.tenantDailyLimit = dailyLimit;
        emit TenantLimitsUpdated(
            sponsor,
            maxCostPerOperation,
            dailyLimit
        );
    }

    /// @inheritdoc IGasSponsor
    function setTenantEnabled(
        address sponsor,
        bool enabled
    ) external override onlySponsorManager(sponsor) {
        _sponsorState(sponsor).tenantEnabled = enabled;
        emit SponsorTenantStatusUpdated(sponsor, enabled);
    }

    /// @inheritdoc IGasSponsor
    function depositFor(address sponsor) external payable override {
        if (msg.value == 0) revert ZeroValue();
        SponsorState storage sponsorState = _sponsorState(sponsor);
        sponsorState.balance += msg.value;
        emit Deposited(sponsor, msg.sender, msg.value);
    }

    event GasCreditDeposited(address indexed sponsor, address indexed funder, uint256 amount);
    event GasCreditRecovered(address indexed sponsor, address indexed recipient, uint256 amount);

    /// @notice Restricted subsidy: usable for gas, never a tenant withdrawal.
    /// Ordinary depositFor retains its refundable deposit/grant behavior.
    function depositGasCredit(address sponsor) external payable override {
        if (msg.value == 0) revert ZeroValue();
        _sponsorState(sponsor).balance += msg.value;
        _sponsorStorage().restrictedGasCredit[sponsor] += msg.value;
        emit GasCreditDeposited(sponsor, msg.sender, msg.value);
    }

    function getSponsorFunding(address sponsor) external view returns (uint256 refundable, uint256 gasCredit) {
        gasCredit = _sponsorStorage().restrictedGasCredit[sponsor];
        refundable = _sponsorStorage().sponsors[sponsor].balance - gasCredit;
    }

    function recoverGasCredit(address sponsor, address payable recipient, uint256 amount) external onlyPlatformAdmin nonReentrant {
        _requireNonZero(recipient);
        require(amount > 0 && amount <= _sponsorStorage().restrictedGasCredit[sponsor], "Insufficient gas credit");
        require(amount <= _sponsorState(sponsor).balance - _pendingWorkerCost(sponsor), "Funds reserved for work");
        _sponsorStorage().restrictedGasCredit[sponsor] -= amount;
        _sponsorState(sponsor).balance -= amount;
        (bool sent,) = recipient.call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
        emit GasCreditRecovered(sponsor, recipient, amount);
    }

    function minimumCallGas(uint256 executionGasLimit, uint256 executionDataBytes) external pure returns (uint256) {
        return DelegationGas.minimumCallGas(executionGasLimit, executionDataBytes);
    }

    /// @inheritdoc IGasSponsor
    function withdrawSponsor(
        address sponsor,
        address payable recipient,
        uint256 amount
    )
        external
        override
        onlySponsorManager(sponsor)
        nonReentrant
    {
        _requireNonZero(recipient);
        if (amount == 0) revert ZeroValue();
        SponsorState storage sponsorState = _sponsorState(sponsor);
        if (sponsorState.balance - _sponsorStorage().restrictedGasCredit[sponsor] < amount
            || sponsorState.balance - _pendingWorkerCost(sponsor) < amount) {
            revert InsufficientSponsorBalance(
                sponsorState.balance - _sponsorStorage().restrictedGasCredit[sponsor],
                amount
            );
        }
        sponsorState.balance -= amount;
        (bool sent, ) = recipient.call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
        emit Withdrawn(sponsor, recipient, amount);
    }

    /// @notice Optional policy is scoped to exactly this tenant and sponsor engine.
    /// Removing a broken policy does not call it, so its code cannot trap account management.
    function setSponsorPolicy(address sponsor, address policy) external override onlySponsorManager(sponsor) {
        require(_pendingWorkerCost(sponsor) == 0, "Unsettled worker operations");
        if (policy != address(0)) {
            if (policy.code.length == 0) revert InvalidAllowancePolicy();
            if (ITenantAllowancePolicy(policy).gasSponsor() != address(this)
                || ITenantAllowancePolicy(policy).sponsor() != sponsor) revert InvalidAllowancePolicy();
        }
        _sponsorStorage().allowancePolicies[sponsor] = policy;
        emit SponsorPolicyUpdated(sponsor, policy);
    }

    /// @notice Explicit denies always apply. Requiring approval is opt-in for legacy accounts.
    function setWalletApprovalRequired(address sponsor, bool required) external override onlySponsorManager(sponsor) {
        _sponsorStorage().walletApprovalRequired[sponsor] = required;
        emit WalletApprovalRequired(sponsor, required);
    }

    /// @param permission 0 = inherit account rules, 1 = approved, 2 = denied.
    /// Approval only permits sponsorship: it does not grant budget or target-contract authority.
    function setSponsoredWallet(address sponsor, address wallet, uint8 permission) external override onlySponsorManager(sponsor) {
        if (wallet == address(0) || permission > 2) revert InvalidAllowancePolicy();
        _sponsorStorage().sponsoredWallets[sponsor][wallet] = permission;
        emit SponsoredWalletUpdated(sponsor, wallet, permission);
    }

    function getSponsorPolicy(address sponsor) external view override returns (address policy, bool approvalRequired) {
        return (_sponsorStorage().allowancePolicies[sponsor], _sponsorStorage().walletApprovalRequired[sponsor]);
    }
    function sponsoredWalletPermission(address sponsor, address wallet) external view override returns (uint8) {
        return _sponsorStorage().sponsoredWallets[sponsor][wallet];
    }
    function isWalletSponsored(address sponsor, address wallet) public view override returns (bool) {
        GasSponsorStorage storage state = _sponsorStorage();
        uint8 permission = state.sponsoredWallets[sponsor][wallet];
        return wallet != address(0) && permission != 2 && (permission == 1 || !state.walletApprovalRequired[sponsor]);
    }
    /// @notice The documented reimbursement model includes bounded bookkeeping overhead.
    /// This is not an exact reproduction of the full transaction receipt's gas charge.
    function costOverheadGas(address sponsor) public view override returns (uint256) {
        return _sponsorStorage().fixedOverheadGas
            + (_sponsorStorage().allowancePolicies[sponsor] == address(0) ? 0 : _POLICY_SETTLEMENT_OVERHEAD);
    }

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

    /// @inheritdoc IGasSponsor
    function executeSponsored(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData,
        bytes calldata voucherSignature
    )
        external
        override
        nonReentrant
        returns (
            bool success,
            bytes memory boundedReturnData,
            uint256 reimbursement
        )
    {
        uint256 gasStart = gasleft();
        _validateVoucherEnvelope(voucher, executionData);
        _validateSponsorBudget(voucher);
        _validateDelegationAndSignature(
            voucher,
            executionData,
            voucherSignature
        );

        PolicyContext memory context = PolicyContext(_sponsorStorage().allowancePolicies[voucher.sponsor], costOverheadGas(voucher.sponsor));
        if (context.policy != address(0)) {
            _callPolicy(context.policy, abi.encodeCall(ITenantAllowancePolicy.reserve,
                (voucher.operationId, voucher.account, voucher.maxCost)), ITenantAllowancePolicy.reserve.selector);
        }

        GasSponsorStorage storage state = _sponsorStorage();
        state.consumedOperations[voucher.operationId] = true;

        // Validate after optional policy callbacks, before checking the gas reserve.
        _validateSponsoredTargets(executionData);

        uint256 requiredGas =
            voucher.callGasLimit +
            (voucher.callGasLimit / 63) +
            _POST_CALL_GAS_RESERVE + (context.policy == address(0) ? 0 : _POLICY_CALL_GAS + 20_000);
        if (gasleft() < requiredGas) {
            revert InsufficientExecutionGas(
                gasleft(),
                requiredGas
            );
        }

        uint256 returnDataSize;
        (success, boundedReturnData, returnDataSize) = _boundedCall(
            voucher.account,
            voucher.callGasLimit,
            executionData
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

    /// @inheritdoc IGasSponsor
    function getSponsorAccount(
        address sponsor
    ) external view override returns (SponsorAccount memory account) {
        SponsorState storage sponsorState =
            _sponsorStorage().sponsors[sponsor];
        uint256 currentDay = block.timestamp / 1 days;
        uint256 spent = currentDay == sponsorState.lastResetDay
            ? sponsorState.dailySpent
            : 0;
        account = SponsorAccount({
            tenantId: sponsorState.tenantId,
            manager: sponsorState.manager,
            balance: sponsorState.balance,
            adminMaxCostPerOperation:
                sponsorState.adminMaxCostPerOperation,
            tenantMaxCostPerOperation:
                sponsorState.tenantMaxCostPerOperation,
            effectiveMaxCostPerOperation: _min(
                sponsorState.adminMaxCostPerOperation,
                sponsorState.tenantMaxCostPerOperation
            ),
            adminDailyLimit: sponsorState.adminDailyLimit,
            tenantDailyLimit: sponsorState.tenantDailyLimit,
            effectiveDailyLimit: _min(
                sponsorState.adminDailyLimit,
                sponsorState.tenantDailyLimit
            ),
            dailySpent: spent,
            adminEnabled: sponsorState.adminEnabled,
            tenantEnabled: sponsorState.tenantEnabled
        });
    }

    /// @inheritdoc IGasSponsor
    function voucherDigest(
        SponsorshipVoucher calldata voucher
    ) external view override returns (bytes32) {
        return _voucherDigest(voucher);
    }

    /// @inheritdoc IGasSponsor
    function expectedDelegationCodeHash(
        address delegate
    ) external pure override returns (bytes32) {
        return _delegationCodeHash(delegate);
    }

    /// @inheritdoc IGasSponsor
    function isDelegationReady(
        address account
    ) external view override returns (bool) {
        return _isDelegationReady(
            account,
            _sponsorStorage().approvedDelegate
        );
    }

    /// @inheritdoc IGasSponsor
    function isOperationConsumed(
        bytes32 operationId
    ) external view override returns (bool) {
        return _sponsorStorage().consumedOperations[operationId];
    }

    /// @inheritdoc IGasSponsor
    function isRelayer(
        address relayer
    ) external view override returns (bool) {
        return _sponsorStorage().relayers[relayer];
    }

    /// @inheritdoc IGasSponsor
    function platformAdmin() external view override returns (address) {
        return _sponsorStorage().platformAdmin;
    }

    /// @inheritdoc IGasSponsor
    function pendingPlatformAdmin()
        external
        view
        override
        returns (address)
    {
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
    function fixedOverheadGas()
        external
        view
        override
        returns (uint256)
    {
        return _sponsorStorage().fixedOverheadGas;
    }

    /// @inheritdoc IGasSponsor
    function paused() external view override returns (bool) {
        return _sponsorStorage().paused;
    }

    /// @inheritdoc IGasSponsor
    function sponsorStorageLocation()
        external
        pure
        override
        returns (bytes32)
    {
        return _GAS_SPONSOR_STORAGE_LOCATION;
    }

    /// @inheritdoc IGasSponsor
    function implementationVersion()
        external
        pure
        virtual
        override
        returns (string memory)
    {
        return "1.1.0";
    }

    receive() external payable {
        revert DirectNativeTransferDisabled();
    }

    function _voucherDigest(
        SponsorshipVoucher calldata voucher
    ) private view returns (bytes32) {
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
            abi.encode(
                _DOMAIN_TYPEHASH,
                _NAME_HASH,
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
        return keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
    }

    function _validateVoucherEnvelope(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData
    ) private view {
        GasSponsorStorage storage state = _sponsorStorage();
        if (state.paused) revert SponsorshipIsPaused();
        if (!state.relayers[msg.sender]) {
            revert RelayerNotAuthorized(msg.sender);
        }
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
        if (state.consumedOperations[voucher.operationId]) {
            revert OperationAlreadyConsumed(voucher.operationId);
        }
        if (executionData.length > _MAX_EXECUTION_DATA_BYTES) {
            revert InvalidExecutionLength(executionData.length);
        }
        if (
            voucher.callGasLimit < _MIN_CALL_GAS_LIMIT ||
            voucher.callGasLimit > _MAX_CALL_GAS_LIMIT
        ) {
            revert InvalidCallGasLimit(voucher.callGasLimit);
        }
        if (
            voucher.maxFeePerGas == 0 ||
            tx.gasprice > voucher.maxFeePerGas
        ) {
            revert GasPriceTooHigh(
                tx.gasprice,
                voucher.maxFeePerGas
            );
        }

        uint256 expectedCostCap =
            (voucher.callGasLimit + costOverheadGas(voucher.sponsor)) *
            voucher.maxFeePerGas;
        if (voucher.maxCost != expectedCostCap) {
            revert CostEnvelopeMismatch(
                expectedCostCap,
                voucher.maxCost
            );
        }
    }

    function _validateSponsorBudget(
        SponsorshipVoucher calldata voucher
    ) private {
        SponsorState storage sponsorState =
            _sponsorState(voucher.sponsor);
        if (
            !sponsorState.adminEnabled ||
            !sponsorState.tenantEnabled
        ) {
            revert SponsorDisabled(voucher.sponsor);
        }
        if (sponsorState.tenantId != voucher.tenantId) {
            revert TenantMismatch(
                sponsorState.tenantId,
                voucher.tenantId
            );
        }

        if (!isWalletSponsored(voucher.sponsor, voucher.account)) {
            revert WalletNotSponsored(voucher.sponsor, voucher.account);
        }

        uint256 effectivePerOperation = _min(
            sponsorState.adminMaxCostPerOperation,
            sponsorState.tenantMaxCostPerOperation
        );
        if (voucher.maxCost > effectivePerOperation) {
            revert CostLimitExceeded(
                effectivePerOperation,
                voucher.maxCost
            );
        }

        _resetDailySpendIfNeeded(sponsorState);
        uint256 effectiveDailyLimit = _min(
            sponsorState.adminDailyLimit,
            sponsorState.tenantDailyLimit
        );
        uint256 reservedDailySpend =
            sponsorState.dailySpent + _pendingWorkerCost(voucher.sponsor) + voucher.maxCost;
        if (reservedDailySpend > effectiveDailyLimit) {
            revert DailyLimitExceeded(
                effectiveDailyLimit,
                reservedDailySpend
            );
        }

        uint256 available = _min(
            sponsorState.balance - _pendingWorkerCost(voucher.sponsor),
            address(this).balance
        );
        if (available < voucher.maxCost) {
            revert InsufficientSponsorBalance(
                available,
                voucher.maxCost
            );
        }
    }

    function _validateDelegationAndSignature(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData,
        bytes calldata voucherSignature
    ) private view {
        if (!_isDelegationReady(voucher.account, voucher.delegate)) {
            revert InvalidDelegation(voucher.account);
        }
        _validateExecutionEnvelope(
            executionData,
            voucher.operationId,
            voucher.deadline,
            voucher.callGasLimit
        );

        GasSponsorStorage storage state = _sponsorStorage();
        if (
            !_isValidVoucherSignature(
                state.voucherSigner,
                _voucherDigest(voucher),
                voucherSignature
            )
        ) {
            revert InvalidVoucherSignature();
        }
    }

    function _settleSponsoredOperation(
        SponsorshipVoucher calldata voucher,
        uint256 gasStart,
        bool success,
        uint256 returnDataSize,
        bytes memory boundedReturnData,
        PolicyContext memory context
    ) private returns (uint256 reimbursement) {
        uint256 measuredGas =
            gasStart - gasleft() + context.overhead;
        uint256 measuredCost = measuredGas * tx.gasprice;
        bool reimbursementCapped = measuredCost > voucher.maxCost;
        reimbursement = reimbursementCapped
            ? voucher.maxCost
            : measuredCost;

        SponsorState storage sponsorState =
            _sponsorState(voucher.sponsor);
        uint256 creditUsed = _min(reimbursement, _sponsorStorage().restrictedGasCredit[voucher.sponsor]);
        _sponsorStorage().restrictedGasCredit[voucher.sponsor] -= creditUsed;
        sponsorState.balance -= reimbursement;
        sponsorState.dailySpent += reimbursement;

        {
            if (context.policy != address(0)) {
                _callPolicy(context.policy, abi.encodeCall(ITenantAllowancePolicy.settle,
                    (voucher.operationId, reimbursement)), ITenantAllowancePolicy.settle.selector);
            }
        }

        if (reimbursement != 0) {
            (bool sent, ) = payable(msg.sender).call{
                value: reimbursement
            }("");
            if (!sent) revert NativeTransferFailed();
        }

        _emitOperation(voucher, success);
        emit RelayerReimbursed(
            voucher.operationId,
            msg.sender,
            reimbursement,
            measuredGas,
            reimbursementCapped
        );
        emit SponsoredReturnData(
            voucher.operationId,
            returnDataSize,
            keccak256(boundedReturnData)
        );
    }

    function _emitOperation(SponsorshipVoucher calldata voucher, bool success) private {
        emit SponsoredOperation(voucher.operationId, voucher.tenantId, voucher.account,
            voucher.sponsor, voucher.campaignId, success);
    }

    function _validateSponsoredTargets(bytes calldata) internal view virtual {}

    function _validateExecutionEnvelope(
        bytes calldata executionData,
        bytes32 expectedOperationId,
        uint256 expectedDeadline,
        uint256 outerCallGasLimit
    ) private view {
        if (executionData.length < 260) {
            revert InvalidExecutionEnvelope();
        }

        bytes4 selector;
        uint256 executionOffset;
        uint256 executionBase;
        bytes32 operationId;
        uint256 executorWord;
        uint256 delegatedDeadline;
        uint256 delegatedExecutionGasLimit;
        assembly ("memory-safe") {
            selector := calldataload(executionData.offset)
            executionOffset := calldataload(
                add(executionData.offset, 4)
            )
        }
        if (executionOffset != 64) {
            revert InvalidExecutionEnvelope();
        }
        executionBase = 4 + executionOffset;
        if (executionData.length < executionBase + 192) {
            revert InvalidExecutionEnvelope();
        }
        assembly ("memory-safe") {
            operationId := calldataload(
                add(executionData.offset, executionBase)
            )
            executorWord := calldataload(
                add(add(executionData.offset, executionBase), 32)
            )
            delegatedDeadline := calldataload(
                add(add(executionData.offset, executionBase), 128)
            )
            delegatedExecutionGasLimit := calldataload(
                add(add(executionData.offset, executionBase), 160)
            )
        }

        if (
            selector != IDakotaDelegation.executeSponsored.selector ||
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
        if (signer.code.length == 0) {
            return digest.tryRecover(signature) == signer;
        }

        (bool success, bytes memory result) = signer.staticcall{
            gas: _ERC1271_GAS_LIMIT
        }(
            abi.encodeCall(
                IERC1271VoucherSigner.isValidSignature,
                (digest, signature)
            )
        );
        return success &&
            result.length >= 32 &&
            bytes4(result) == _EIP1271_MAGIC;
    }

    function _boundedCall(
        address account,
        uint256 callGasLimit,
        bytes calldata executionData
    )
        private
        returns (
            bool success,
            bytes memory boundedReturnData,
            uint256 returnDataSize
        )
    {
        assembly ("memory-safe") {
            let inputPointer := mload(0x40)
            calldatacopy(
                inputPointer,
                executionData.offset,
                executionData.length
            )
            mstore(
                0x40,
                and(
                    add(
                        add(inputPointer, executionData.length),
                        0x1f
                    ),
                    not(0x1f)
                )
            )
            success := call(
                callGasLimit,
                account,
                0,
                inputPointer,
                executionData.length,
                0,
                0
            )
            returnDataSize := returndatasize()
        }

        uint256 copySize = returnDataSize > _MAX_RETURN_DATA_BYTES
            ? _MAX_RETURN_DATA_BYTES
            : returnDataSize;
        boundedReturnData = new bytes(copySize);
        assembly ("memory-safe") {
            returndatacopy(
                add(boundedReturnData, 0x20),
                0,
                copySize
            )
        }
    }

    function _sponsorState(
        address sponsor
    ) internal view returns (SponsorState storage sponsorState) {
        sponsorState = _sponsorStorage().sponsors[sponsor];
        if (sponsorState.manager == address(0)) {
            revert SponsorNotConfigured(sponsor);
        }
    }

    function _resetDailySpendIfNeeded(
        SponsorState storage sponsorState
    ) internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (sponsorState.lastResetDay != currentDay) {
            sponsorState.lastResetDay = currentDay;
            sponsorState.dailySpent = 0;
        }
    }

    function _delegationCodeHash(
        address delegate
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"ef0100", delegate));
    }

    function _isDelegationReady(
        address account,
        address delegate
    ) private view returns (bool) {
        if (
            account == address(0) ||
            account.codehash != _delegationCodeHash(delegate)
        ) {
            return false;
        }

        if (delegate.codehash != _sponsorStorage().approvedDelegateCodeHash) return false;

        (bool protocolSuccess, bytes memory protocolResult) =
            account.staticcall{gas: _READINESS_CALL_GAS_LIMIT}(
                abi.encodeCall(
                    IDakotaDelegation.delegationProtocolId,
                    ()
                )
            );
        return protocolSuccess &&
            protocolResult.length == 32 &&
            abi.decode(protocolResult, (bytes32)) ==
            _EXPECTED_DELEGATION_PROTOCOL_ID;
    }

    function _requireDelegate(address delegate) private view {
        if (delegate == address(0) || delegate.code.length == 0) revert ZeroAddress();
        (bool ok, bytes memory result) = delegate.staticcall{gas: _READINESS_CALL_GAS_LIMIT}(
            abi.encodeWithSignature("dispatcherProtocolId()"));
        if (!ok || result.length != 32 || abi.decode(result, (bytes32)) !=
            keccak256("dakota.delegation.direct-beacon-dispatch.v2")) revert InvalidConfiguration();
    }

    function _requireNonZero(address value) private pure {
        if (value == address(0)) revert ZeroAddress();
    }

    function _validateOverheadGas(uint256 overheadGas) private pure {
        if (
            overheadGas < _MIN_OVERHEAD_GAS ||
            overheadGas > _MAX_OVERHEAD_GAS
        ) {
            revert InvalidConfiguration();
        }
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _isInitializationAuthority(
        address caller
    ) private view returns (bool) {
        if (caller == _GENESIS_PROXY_ADMIN) {
            return true;
        }
        try IRootOverlordRegistry(
            _VALIDATOR_ROOT_REGISTRY
        ).isRootOverlord(caller) returns (bool authorized) {
            return authorized;
        } catch {
            return false;
        }
    }

    function _pendingWorkerCost(address) internal view virtual returns (uint256) { return 0; }

    function _sponsorStorage()
        internal
        pure
        returns (GasSponsorStorage storage state)
    {
        bytes32 location = _GAS_SPONSOR_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }
}
