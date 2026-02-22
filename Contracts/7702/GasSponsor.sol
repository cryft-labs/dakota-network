// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   _____          ____
  / ___/__ ______/ __/__  ___  ___  ___  ___  ____
 / (_ / _ `(_-< _\ \/ _ \/ _ \/ _ \(_-< / _ \/ __/
 \___/\_,_/___//___/ .__/\___/_//_/___/\___/_/
                  /_/            By: CryftCreator

  Version 1.0 — On-Chain Gas Sponsorship Treasury  [UPGRADEABLE]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  Per-sponsor gas deposit and reimbursement.          │
  │  Sponsors deposit native tokens and authorise        │
  │  relayers to claim reimbursement for sponsored       │
  │  transactions.                                       │
  │                                                      │
  │  Features:                                           │
  │    • Per-sponsor deposits and withdrawals            │
  │    • Authorised relayer management per sponsor       │
  │    • Max-per-claim and daily spending limits         │
  │    • Target contract allowlisting (optional)         │
  │    • Integrated sponsored-call forwarding with       │
  │      automatic gas metering & reimbursement          │
  │    • Reentrancy protection                           │
  │                                                      │
  │  Designed for use with DakotaDelegation and          │
  │  EIP-7702 delegation targets.  Complements           │
  │  thirdweb's hosted gas sponsorship with a            │
  │  self-hosted, on-chain alternative.                  │
  │                                                      │
  │  Upgradeable (Initializable + proxy pattern).        │
  │  Not voter-governed — each sponsor independently     │
  │  manages their own relayers and limits.              │
  └──────────────────────────────────────────────────────┘
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/security/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/proxy/utils/Initializable.sol";

import "./interfaces/IGasSponsor.sol";

/// @dev Minimal interface to call GasManager.executeFundGas.
interface IGasManager {
    function executeFundGas(address payable _to, uint256 _amount) external;
    function approvedFunds(bytes32 fundKey) external view returns (bool);
    function isGuardian(address) external view returns (bool);
}

contract GasSponsor is Initializable, ReentrancyGuardUpgradeable, IGasSponsor {

    // ═══════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════

    struct SponsorState {
        uint256 balance;            // deposited native tokens
        uint256 maxClaimPerTx;      // max per single claim  (0 = unlimited)
        uint256 dailyLimit;         // max daily spend total (0 = unlimited)
        uint256 dailySpent;         // amount spent in current day
        uint256 lastResetDay;       // day number (block.timestamp / 1 days)
        bool    active;             // sponsor is initialised
        bool    useTargetAllowlist; // restrict calls to allowed targets
    }

    mapping(address => SponsorState)                    private _sponsors;
    mapping(address => mapping(address => bool))        private _authorizedRelayers;
    mapping(address => mapping(address => bool))        private _allowedTargets;

    /// @notice The GasManager genesis contract.
    address constant public GAS_MANAGER = 0x000000000000000000000000000000000000cafE;

    /// @dev Approximate gas overhead for sponsoredCall housekeeping.
    ///      Covers: base TX cost (~21k), pre-call checks, post-call
    ///      accounting, and reimbursement transfer.
    uint256 private constant _OVERHEAD_GAS = 50_000;

    // ═══════════════════════════════════════════════════════
    //  Initialisation
    // ═══════════════════════════════════════════════════════

    /// @dev Prevent the implementation contract from being initialised.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the proxy instance.  Call once via the proxy.
    function initialize() public virtual initializer {
        __ReentrancyGuard_init();
    }

    // ═══════════════════════════════════════════════════════
    //  Sponsor Management
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IGasSponsor
    function deposit() external payable override {
        require(msg.value > 0, "GasSponsor: zero deposit");
        SponsorState storage s = _sponsors[msg.sender];
        if (!s.active) {
            s.active       = true;
            s.lastResetDay = block.timestamp / 1 days;
        }
        s.balance += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @inheritdoc IGasSponsor
    function withdraw(uint256 amount) external override nonReentrant {
        SponsorState storage s = _sponsors[msg.sender];
        require(s.balance >= amount, "GasSponsor: insufficient balance");
        s.balance -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "GasSponsor: transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @inheritdoc IGasSponsor
    function authorizeRelayer(address relayer) external override {
        require(relayer != address(0), "GasSponsor: zero address");
        _authorizedRelayers[msg.sender][relayer] = true;
        emit RelayerAuthorized(msg.sender, relayer);
    }

    /// @inheritdoc IGasSponsor
    function revokeRelayer(address relayer) external override {
        _authorizedRelayers[msg.sender][relayer] = false;
        emit RelayerRevoked(msg.sender, relayer);
    }

    /// @inheritdoc IGasSponsor
    function setMaxClaimPerTx(uint256 amount) external override {
        _sponsors[msg.sender].maxClaimPerTx = amount;
        emit ConfigUpdated(msg.sender, "maxClaimPerTx", amount);
    }

    /// @inheritdoc IGasSponsor
    function setDailyLimit(uint256 amount) external override {
        _sponsors[msg.sender].dailyLimit = amount;
        emit ConfigUpdated(msg.sender, "dailyLimit", amount);
    }

    /// @inheritdoc IGasSponsor
    function addAllowedTarget(address target) external override {
        require(target != address(0), "GasSponsor: zero address");
        _allowedTargets[msg.sender][target]  = true;
        _sponsors[msg.sender].useTargetAllowlist = true;
        emit TargetAllowed(msg.sender, target);
    }

    /// @inheritdoc IGasSponsor
    function removeAllowedTarget(address target) external override {
        _allowedTargets[msg.sender][target] = false;
        emit TargetRemoved(msg.sender, target);
    }

    /// @inheritdoc IGasSponsor
    function disableTargetAllowlist() external override {
        _sponsors[msg.sender].useTargetAllowlist = false;
        emit ConfigUpdated(msg.sender, "targetAllowlist", 0);
    }

    // ═══════════════════════════════════════════════════════
    //  Top-Off from GasManager
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IGasSponsor
    function topOff(address sponsor, uint256 amount) external override nonReentrant {
        require(amount > 0, "GasSponsor: zero amount");
        require(
            IGasManager(GAS_MANAGER).isGuardian(msg.sender),
            "GasSponsor: caller is not a GasManager guardian"
        );

        SponsorState storage s = _sponsors[sponsor];
        if (!s.active) {
            s.active       = true;
            s.lastResetDay = block.timestamp / 1 days;
        }

        // Verify that the GasManager has an approved fund for this contract
        // with the requested amount.  The fundKey matches GasManager's
        // keccak256(abi.encodePacked(_to, _amount)).
        bytes32 fundKey = keccak256(
            abi.encodePacked(address(this), amount)
        );
        require(
            IGasManager(GAS_MANAGER).approvedFunds(fundKey),
            "GasSponsor: fund not approved in GasManager"
        );

        uint256 balBefore = address(this).balance;

        // Pull the approved funds from GasManager into this contract.
        // GasManager.executeFundGas allows msg.sender == _to,
        // so this contract calls it with _to = address(this).
        IGasManager(GAS_MANAGER).executeFundGas(
            payable(address(this)),
            amount
        );

        uint256 received = address(this).balance - balBefore;
        require(received == amount, "GasSponsor: amount mismatch");

        // Credit the sponsor's balance
        s.balance += amount;

        emit ToppedOff(sponsor, amount);
    }

    // ═══════════════════════════════════════════════════════
    //  Reimbursement
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IGasSponsor
    function claim(address sponsor, uint256 amount)
        external
        override
        nonReentrant
    {
        _validateAndDebit(sponsor, msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "GasSponsor: transfer failed");
        emit Claimed(sponsor, msg.sender, amount);
    }

    /// @inheritdoc IGasSponsor
    function sponsoredCall(
        address sponsor,
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        override
        nonReentrant
        returns (bytes memory result)
    {
        require(
            _authorizedRelayers[sponsor][msg.sender],
            "GasSponsor: not authorized"
        );

        SponsorState storage s = _sponsors[sponsor];
        require(s.active, "GasSponsor: sponsor not active");

        if (s.useTargetAllowlist) {
            require(
                _allowedTargets[sponsor][target],
                "GasSponsor: target not allowed"
            );
        }

        // Pre-check that sponsor can cover at least the forwarded value
        require(
            s.balance >= value,
            "GasSponsor: insufficient for value"
        );

        uint256 gasStart = gasleft();

        // Forward the call
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            if (ret.length > 0) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }
            revert("GasSponsor: call reverted");
        }

        // Calculate total cost: forwarded value + gas reimbursement
        uint256 gasUsed  = gasStart - gasleft() + _OVERHEAD_GAS;
        uint256 gasCost  = gasUsed * tx.gasprice;
        uint256 totalCost = value + gasCost;

        _validateAndDebit(sponsor, msg.sender, totalCost);

        // Reimburse relayer for gas (value already went to target)
        (bool sent, ) = payable(msg.sender).call{value: gasCost}("");
        require(sent, "GasSponsor: reimbursement failed");

        emit SponsoredCallExecuted(sponsor, msg.sender, target, totalCost);
        return ret;
    }

    // ═══════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IGasSponsor
    function getSponsorInfo(address sponsor)
        external
        view
        override
        returns (
            uint256 balance,
            uint256 maxClaimPerTx,
            uint256 dailyLimit,
            uint256 dailySpent,
            bool    active,
            bool    useTargetAllowlist
        )
    {
        SponsorState storage s = _sponsors[sponsor];
        uint256 currentDay = block.timestamp / 1 days;
        uint256 spent = (currentDay == s.lastResetDay) ? s.dailySpent : 0;

        return (
            s.balance,
            s.maxClaimPerTx,
            s.dailyLimit,
            spent,
            s.active,
            s.useTargetAllowlist
        );
    }

    /// @inheritdoc IGasSponsor
    function isAuthorizedRelayer(address sponsor, address relayer)
        external
        view
        override
        returns (bool)
    {
        return _authorizedRelayers[sponsor][relayer];
    }

    /// @inheritdoc IGasSponsor
    function isAllowedTarget(address sponsor, address target)
        external
        view
        override
        returns (bool)
    {
        return _allowedTargets[sponsor][target];
    }

    // ═══════════════════════════════════════════════════════
    //  Internal
    // ═══════════════════════════════════════════════════════

    /// @dev Validate authorisation and spending limits, then debit
    ///      the sponsor's balance.
    function _validateAndDebit(
        address sponsor,
        address relayer,
        uint256 amount
    ) internal {
        require(
            _authorizedRelayers[sponsor][relayer],
            "GasSponsor: not authorized"
        );

        SponsorState storage s = _sponsors[sponsor];
        require(s.active,            "GasSponsor: sponsor not active");
        require(s.balance >= amount, "GasSponsor: insufficient balance");

        // Per-claim limit
        if (s.maxClaimPerTx > 0) {
            require(
                amount <= s.maxClaimPerTx,
                "GasSponsor: exceeds max per claim"
            );
        }

        // Daily limit with automatic 24-hour rolling reset
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay != s.lastResetDay) {
            s.dailySpent   = 0;
            s.lastResetDay = currentDay;
        }
        if (s.dailyLimit > 0) {
            require(
                s.dailySpent + amount <= s.dailyLimit,
                "GasSponsor: daily limit exceeded"
            );
        }

        s.balance    -= amount;
        s.dailySpent += amount;
    }

    /// @notice Accept bare native token transfers as sponsor deposits.
    receive() external payable {
        if (msg.value > 0) {
            SponsorState storage s = _sponsors[msg.sender];
            if (!s.active) {
                s.active       = true;
                s.lastResetDay = block.timestamp / 1 days;
            }
            s.balance += msg.value;
            emit Deposited(msg.sender, msg.value);
        }
    }
}
