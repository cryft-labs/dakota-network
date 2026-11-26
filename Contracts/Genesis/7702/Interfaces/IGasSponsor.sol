// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title IGasSponsor
/// @notice Managed native EIP-7702 gas sponsorship for Cryft tenants.
/// @custom:version 1.5.2
/// @custom:security-contact security@cryft.cards
interface IGasSponsor {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @notice The voucher signer's approval of one sponsored operation.
    struct SponsorshipVoucher {
        bytes32 operationId;
        bytes32 tenantId;
        bytes32 campaignId;
        address sponsor;
        address account;
        address relayer;
        address delegate;
        bytes32 executionHash;
        uint256 callGasLimit;
        uint256 maxFeePerGas;
        uint256 maxCost;
        uint256 deadline;
    }

    /// @notice A sponsor account as reported by `getSponsorAccount`.
    struct SponsorAccount {
        bytes32 tenantId;
        address manager;
        uint256 balance;
        uint256 adminMaxCostPerOperation;
        uint256 tenantMaxCostPerOperation;
        uint256 effectiveMaxCostPerOperation;
        uint256 adminDailyLimit;
        uint256 tenantDailyLimit;
        uint256 effectiveDailyLimit;
        uint256 dailySpent;
        bool adminEnabled;
        bool tenantEnabled;
    }

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The sponsor was linked and configured; sponsorship starts paused.
    event GasSponsorInitialized(
        address indexed platformAdmin,
        address indexed voucherSigner,
        address indexed approvedDelegate,
        uint256 fixedOverheadGas
    );

    /// @notice A platform administrator handover was proposed (zero `pendingAdmin`: cancelled).
    event PlatformAdminTransferProposed(address indexed currentAdmin, address indexed pendingAdmin);

    /// @notice The platform administrator changed.
    event PlatformAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    /// @notice The voucher signer changed.
    event VoucherSignerUpdated(address indexed previousSigner, address indexed newSigner);

    /// @notice The approved delegate (dispatcher) changed.
    event ApprovedDelegateUpdated(address indexed previousDelegate, address indexed newDelegate);

    /// @notice A relayer was allowed or removed.
    event RelayerUpdated(address indexed relayer, bool allowed);

    /// @notice Sponsorship was paused or resumed.
    event SponsorshipPaused(bool paused);

    /// @notice The fixed overhead gas charged per operation changed.
    event FixedOverheadGasUpdated(uint256 previousOverheadGas, uint256 newOverheadGas);

    /// @notice A sponsor was configured by the platform administrator (or opened by the program).
    event SponsorConfigured(
        address indexed sponsor,
        bytes32 indexed tenantId,
        address indexed manager,
        uint256 adminMaxCostPerOperation,
        uint256 adminDailyLimit,
        bool adminEnabled
    );

    /// @notice A sponsor's manager changed.
    event SponsorManagerUpdated(address indexed sponsor, address indexed previousManager, address indexed newManager);

    /// @notice A sponsor's manager changed its own limits.
    event TenantLimitsUpdated(address indexed sponsor, uint256 maxCostPerOperation, uint256 dailyLimit);

    /// @notice The platform switch of a sponsor changed.
    event SponsorAdminStatusUpdated(address indexed sponsor, bool enabled);

    /// @notice The manager switch of a sponsor changed.
    event SponsorTenantStatusUpdated(address indexed sponsor, bool enabled);

    /// @notice Refundable coin was deposited for a sponsor.
    event Deposited(address indexed sponsor, address indexed depositor, uint256 amount);

    /// @notice A sponsor's manager withdrew refundable coin.
    event Withdrawn(address indexed sponsor, address indexed recipient, uint256 amount);

    /// @notice A sponsored operation ran (`success` is the inner call's result).
    event SponsoredOperation(
        bytes32 indexed operationId,
        bytes32 indexed tenantId,
        address indexed account,
        address sponsor,
        bytes32 campaignId,
        bool success
    );

    /// @notice The relayer was reimbursed for an operation.
    event RelayerReimbursed(
        bytes32 indexed operationId,
        address indexed relayer,
        uint256 reimbursement,
        uint256 measuredGas,
        bool reimbursementCapped
    );

    /// @notice The size and hash of an operation's (bounded) return data.
    event SponsoredReturnData(bytes32 indexed operationId, uint256 returnDataSize, bytes32 returnedDataHash);

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice First-links the sponsor through the genesis proxy link.
    function initialize(
        address platformAdmin_,
        address voucherSigner_,
        address approvedDelegate_,
        uint256 fixedOverheadGas_
    ) external;

    /// @notice Proposes a new platform administrator (step 1 of 2).
    function proposePlatformAdmin(address pendingAdmin) external;

    /// @notice Accepts the pending platform administrator role (step 2 of 2).
    function acceptPlatformAdmin() external;

    /// @notice Cancels a pending handover without changing the active platform administrator.
    function cancelPlatformAdminTransfer() external;

    /// @notice Sets the voucher signer (an EOA or an EIP-1271 contract).
    function setVoucherSigner(address signer) external;

    /// @notice Sets the approved delegate (the immutable v2 dispatcher).
    function setApprovedDelegate(address delegate) external;

    /// @notice Allows or removes a relayer.
    function setRelayer(address relayer, bool allowed) external;

    /// @notice Pauses or resumes sponsorship (the pauser may only pause).
    function setPaused(bool paused_) external;

    /// @notice Sets the fixed overhead gas charged per operation.
    function setFixedOverheadGas(uint256 overheadGas) external;

    /// @notice Configures a sponsor's tenant, manager, hard limits and platform switch.
    function configureSponsor(
        address sponsor,
        bytes32 tenantId,
        address manager,
        uint256 adminMaxCostPerOperation,
        uint256 adminDailyLimit,
        bool adminEnabled
    ) external;

    /// @notice Changes a sponsor's manager.
    function setSponsorManager(address sponsor, address manager) external;

    /// @notice Sets a sponsor's platform switch (the pauser may only disable).
    function setSponsorAdminEnabled(address sponsor, bool enabled) external;

    /// @notice Sets a sponsor's own limits, within the platform's hard limits (manager).
    function setTenantLimits(address sponsor, uint256 maxCostPerOperation, uint256 dailyLimit) external;

    /// @notice Sets a sponsor's manager switch (manager).
    function setTenantEnabled(address sponsor, bool enabled) external;

    /// @notice Deposits refundable coin for a sponsor.
    function depositFor(address sponsor) external payable;

    /// @notice Deposits restricted gas credit for a sponsor: usable for gas, never withdrawn by the tenant.
    function depositGasCredit(address sponsor) external payable;

    /// @notice Withdraws refundable coin from a sponsor (manager).
    function withdrawSponsor(address sponsor, address payable recipient, uint256 amount) external;

    /// @notice Runs a voucher-approved operation through the account and reimburses the relayer.
    function executeSponsored(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData,
        bytes calldata voucherSignature
    ) external returns (bool success, bytes memory boundedReturnData, uint256 reimbursement);

    /// @notice Sets or removes a sponsor's allowance policy (manager).
    function setSponsorPolicy(address sponsor, address policy) external;

    /// @notice Sets whether a sponsor pays only for approved wallets (manager).
    function setWalletApprovalRequired(address sponsor, bool required) external;

    /// @notice Sets a wallet's permission for a sponsor: 0 inherit, 1 approved, 2 denied (manager).
    function setSponsoredWallet(address sponsor, address wallet, uint8 permission) external;

    /// @notice Sets the pauser, which can only pause sponsorship and disable sponsors.
    function setPauser(address pauser_) external;

    /// @notice Sets how many operations a sponsor may run in one UTC day.
    function setSponsorOpsPerDay(address sponsor, uint256 opsPerDay) external;

    /// @notice A sponsor account with its effective limits.
    function getSponsorAccount(address sponsor) external view returns (SponsorAccount memory);

    /// @notice The EIP-712 digest the voucher signer signs.
    function voucherDigest(SponsorshipVoucher calldata voucher) external view returns (bytes32);

    /// @notice Whether `account` is delegated to the approved dispatcher and speaks the expected protocol.
    function isDelegationReady(address account) external view returns (bool);

    /// @notice Whether `sponsor` has consumed `operationId` (operation ids are per sponsor).
    function isOperationConsumed(address sponsor, bytes32 operationId) external view returns (bool);

    /// @notice Whether `relayer` may relay operations.
    function isRelayer(address relayer) external view returns (bool);

    /// @notice The platform administrator.
    function platformAdmin() external view returns (address);

    /// @notice The proposed platform administrator, if any.
    function pendingPlatformAdmin() external view returns (address);

    /// @notice The voucher signer.
    function voucherSigner() external view returns (address);

    /// @notice The approved delegate (dispatcher).
    function approvedDelegate() external view returns (address);

    /// @notice The fixed overhead gas charged per operation.
    function fixedOverheadGas() external view returns (uint256);

    /// @notice Whether sponsorship is paused.
    function paused() external view returns (bool);

    /// @notice A sponsor's allowance policy and whether it pays only for approved wallets.
    function getSponsorPolicy(address sponsor) external view returns (address policy, bool approvalRequired);

    /// @notice A wallet's stored permission for a sponsor.
    function sponsoredWalletPermission(address sponsor, address wallet) external view returns (uint8);

    /// @notice Whether `sponsor` pays for `wallet`.
    function isWalletSponsored(address sponsor, address wallet) external view returns (bool);

    /// @notice The overhead gas charged per operation of `sponsor`.
    function costOverheadGas(address sponsor) external view returns (uint256);

    /// @notice The pauser.
    function pauser() external view returns (address);

    /// @notice A sponsor's operations per day and this UTC day's count.
    function sponsorOps(address sponsor) external view returns (uint256 limit, uint256 today);

    /// @notice The code hash of an account delegated to `delegate` (0xef0100 || delegate).
    function expectedDelegationCodeHash(address delegate) external pure returns (bytes32);

    /// @notice The ERC-7201 slot of the sponsor's storage.
    function sponsorStorageLocation() external pure returns (bytes32);

    /// @notice The sponsor logic's version.
    function implementationVersion() external pure returns (string memory);
}
