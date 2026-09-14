// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/// @title IGasSponsor
/// @notice Managed native EIP-7702 gas sponsorship for Dakota tenants.
interface IGasSponsor {
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

    event GasSponsorInitialized(
        address indexed platformAdmin,
        address indexed voucherSigner,
        address indexed approvedDelegate,
        uint256 fixedOverheadGas
    );
    event PlatformAdminTransferProposed(
        address indexed currentAdmin,
        address indexed pendingAdmin
    );
    event PlatformAdminTransferred(
        address indexed previousAdmin,
        address indexed newAdmin
    );
    event VoucherSignerUpdated(
        address indexed previousSigner,
        address indexed newSigner
    );
    event ApprovedDelegateUpdated(
        address indexed previousDelegate,
        address indexed newDelegate
    );
    event RelayerUpdated(address indexed relayer, bool allowed);
    event SponsorshipPaused(bool paused);
    event FixedOverheadGasUpdated(
        uint256 previousOverheadGas,
        uint256 newOverheadGas
    );
    event SponsorConfigured(
        address indexed sponsor,
        bytes32 indexed tenantId,
        address indexed manager,
        uint256 adminMaxCostPerOperation,
        uint256 adminDailyLimit,
        bool adminEnabled
    );
    event SponsorManagerUpdated(
        address indexed sponsor,
        address indexed previousManager,
        address indexed newManager
    );
    event TenantLimitsUpdated(
        address indexed sponsor,
        uint256 maxCostPerOperation,
        uint256 dailyLimit
    );
    event SponsorAdminStatusUpdated(address indexed sponsor, bool enabled);
    event SponsorTenantStatusUpdated(address indexed sponsor, bool enabled);
    event Deposited(
        address indexed sponsor,
        address indexed depositor,
        uint256 amount
    );
    event Withdrawn(
        address indexed sponsor,
        address indexed recipient,
        uint256 amount
    );
    event SponsoredOperation(
        bytes32 indexed operationId,
        bytes32 indexed tenantId,
        address indexed account,
        address sponsor,
        bytes32 campaignId,
        bool success
    );
    event RelayerReimbursed(
        bytes32 indexed operationId,
        address indexed relayer,
        uint256 reimbursement,
        uint256 measuredGas,
        bool reimbursementCapped
    );
    event SponsoredReturnData(
        bytes32 indexed operationId,
        uint256 returnDataSize,
        bytes32 returnedDataHash
    );

    function initialize(
        address platformAdmin_,
        address voucherSigner_,
        address approvedDelegate_,
        uint256 fixedOverheadGas_
    ) external;

    function proposePlatformAdmin(address pendingAdmin_) external;

    function acceptPlatformAdmin() external;
    /// @notice Cancel a pending handover without changing the active administrator.
    function cancelPlatformAdminTransfer() external;

    function setVoucherSigner(address signer) external;

    function setApprovedDelegate(address delegate) external;

    function setRelayer(address relayer, bool allowed) external;

    function setPaused(bool paused_) external;

    function setFixedOverheadGas(uint256 overheadGas) external;

    function configureSponsor(
        address sponsor,
        bytes32 tenantId,
        address manager,
        uint256 adminMaxCostPerOperation,
        uint256 adminDailyLimit,
        bool adminEnabled
    ) external;

    function setSponsorManager(address sponsor, address manager) external;

    function setSponsorAdminEnabled(address sponsor, bool enabled) external;

    function setTenantLimits(
        address sponsor,
        uint256 maxCostPerOperation,
        uint256 dailyLimit
    ) external;

    function setTenantEnabled(address sponsor, bool enabled) external;

    function depositFor(address sponsor) external payable;

    function withdrawSponsor(
        address sponsor,
        address payable recipient,
        uint256 amount
    ) external;

    function executeSponsored(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData,
        bytes calldata voucherSignature
    )
        external
        returns (
            bool success,
            bytes memory boundedReturnData,
            uint256 reimbursement
        );

    function getSponsorAccount(
        address sponsor
    ) external view returns (SponsorAccount memory);

    function voucherDigest(
        SponsorshipVoucher calldata voucher
    ) external view returns (bytes32);

    function expectedDelegationCodeHash(
        address delegate
    ) external pure returns (bytes32);

    function isDelegationReady(address account) external view returns (bool);

    function isOperationConsumed(
        bytes32 operationId
    ) external view returns (bool);

    function isRelayer(address relayer) external view returns (bool);

    function platformAdmin() external view returns (address);

    function pendingPlatformAdmin() external view returns (address);

    function voucherSigner() external view returns (address);

    function approvedDelegate() external view returns (address);

    function fixedOverheadGas() external view returns (uint256);

    function paused() external view returns (bool);

    function sponsorStorageLocation() external pure returns (bytes32);

    function implementationVersion() external pure returns (string memory);
    function depositGasCredit(address sponsor) external payable;

    /// @notice Optional, tenant-bound allowance enforcement and wallet permissions.
    function setSponsorPolicy(address sponsor, address policy) external;
    function setWalletApprovalRequired(address sponsor, bool required) external;
    function setSponsoredWallet(address sponsor, address wallet, uint8 permission) external;
    function getSponsorPolicy(address sponsor) external view returns (address policy, bool approvalRequired);
    function sponsoredWalletPermission(address sponsor, address wallet) external view returns (uint8);
    function isWalletSponsored(address sponsor, address wallet) external view returns (bool);
    function costOverheadGas(address sponsor) external view returns (uint256);
}
