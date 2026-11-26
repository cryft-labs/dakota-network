// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {ICryftDelegation} from "./Interfaces/ICryftDelegation.sol";
import {ApprovedGasSponsor} from "./ApprovedGasSponsor.sol";
import {GasSponsor} from "./GasSponsor.sol";
import {WorkerGasSponsor} from "./WorkerGasSponsor.sol";

/// @title IDeveloperGasProgramLimits
/// @notice What the sponsor asks the developer gas program about one of its sponsors, in one bounded read.
interface IDeveloperGasProgramLimits {
    /// @notice The program's current limits for `sponsor`.
    /// @return eligible The sponsor's developer holds an active Pass and the program is not paused.
    /// @return maxFeePerGas The most a voucher of this sponsor may offer per unit of gas (its tier's).
    /// @return opsPerDay How many operations this sponsor may run in one UTC day (its tier's).
    function sponsorLimits(
        address sponsor
    ) external view returns (bool eligible, uint256 maxFeePerGas, uint256 opsPerDay);
}

/// @title ITenantAllowancePolicyV2
/// @notice A sponsor's allowance policy that also sees the calls it pays for (detected by ERC-165; the V1
///         `reserve` otherwise).
interface ITenantAllowancePolicyV2 {
    /// @notice Reserves up to `maximumCost` for `wallet`'s operation, given the whole validated execution envelope
    ///         (ICryftDelegation.executeSponsored calldata); returns this function's selector to accept.
    function reserveCalls(
        bytes32 operationId,
        address wallet,
        uint256 maximumCost,
        bytes calldata executionData
    ) external returns (bytes4);
}

/// @title ProgramGasSponsor
/// @notice The gas sponsor with worker accounting, platform call approvals and the developer gas program.
/// @dev Linked behind the genesis proxy 0x…FEeD. One program address, set once by the platform administrator
///      (a contract, after the deny list holds at least one entry), opens sponsors that never existed and sets
///      their caps within program-wide hard caps; its gas reaches them only as restricted gas credit. A program
///      sponsor remembers the program that opened it, and only that program funds it, sets its caps, recovers
///      its credit (to itself) and answers its eligibility. A program sponsor holds gas credit and nothing else:
///      no refundable deposit, no manager withdrawal, no platform administrator reconfiguration. It is spent from
///      only while the program says it is eligible, with a voucher fee no higher than its tier's, at most its
///      tier's operations a UTC day, only for approved wallets, never for denied targets or any reserved low
///      address (below 2^32: genesis system contracts and precompiles), and within the hard caps at spend time.
///      Every other sponsor must pass the platform call approvals, kept in ApprovedGasSponsor's namespace
///      keccak256("cryft.storage.ApprovedGasSponsor.v1"). Any sponsor's manager may also require
///      approved targets, and a V2 allowance policy (by ERC-165) is handed the whole execution envelope.
///      Storage is append-only: the base and worker storage are untouched and this contract's state lives in its
///      own namespace (cryft.storage.ProgramGasSponsor.v1); its `opsDay`/`opsCount` stay, unread, because the
///      base counts every sponsor.
/// @custom:version 1.5.2
/// @custom:security-contact security@cryft.cards
contract ProgramGasSponsor is ApprovedGasSponsor, WorkerGasSponsor {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    struct ProgramStorage {
        address program;
        uint256 hardMaxCostPerOperation;
        uint256 hardDailyLimit;
        mapping(address => bool) programSponsor;
        mapping(address => uint256) opsDay;
        mapping(address => uint256) opsCount;
        mapping(address => bool) targetsRequired;
        mapping(address => mapping(address => bool)) sponsoredTargets;
        mapping(address => bool) programDenied;          // targets no program sponsor ever pays for
        mapping(address => address) openedBy;            // the program that opened each program sponsor
        uint256 deniedCount;                             // entries of programDenied that are true
    }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    bytes32 private constant _PROGRAM_SLOT = keccak256("cryft.storage.ProgramGasSponsor.v1");
    uint256 private constant _PROGRAM_READ_GAS = 100_000;
    uint256 private constant _TARGETS_BATCH_MOST = 64;
    uint256 private constant _ERC165_GAS = 30_000;
    bytes4 private constant _ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 private constant _INVALID_INTERFACE_ID = 0xffffffff;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The program and its hard caps were set.
    event ProgramConfigured(address indexed program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit);

    /// @notice The program opened a sponsor.
    event ProgramSponsorOpened(
        address indexed sponsor,
        bytes32 indexed tenantId,
        address indexed manager,
        uint256 maxCostPerOperation,
        uint256 dailyLimit
    );

    /// @notice The program changed a program sponsor's caps.
    event ProgramSponsorCapsUpdated(address indexed sponsor, uint256 maxCostPerOperation, uint256 dailyLimit);

    /// @notice A sponsor's approved-targets switch changed.
    event TargetApprovalRequired(address indexed sponsor, bool required);

    /// @notice A target was allowed or removed for a sponsor.
    event SponsoredTargetUpdated(address indexed sponsor, address indexed target, bool allowed);

    /// @notice A target was added to or removed from the program deny list.
    event ProgramTargetDeniedUpdated(address indexed target, bool denied);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is not the program (or not the program that opened the sponsor).
    error NotProgram();

    /// @notice The sponsor is not a program sponsor.
    error NotProgramSponsor(address sponsor);

    /// @notice A sponsor already exists (or existed) at this address.
    error SponsorExists(address sponsor);

    /// @notice The caps are above the program's hard caps.
    error ProgramCapExceeded();

    /// @notice The program says the sponsor may not spend now.
    error ProgramSponsorIneligible(address sponsor);

    /// @notice The voucher's fee is above the sponsor's tier.
    error ProgramFeeTooHigh(uint256 offered, uint256 maximum);

    /// @notice Program sponsors take no worker reservations.
    error ProgramSponsorHasNoWorkers(address sponsor);

    /// @notice The sponsor's manager has not approved this target.
    error TargetNotSponsored(address sponsor, address target);

    /// @notice Program credit never pays for this target.
    error ProgramTargetDenied(address sponsor, address target);

    /// @notice A program sponsor holds gas credit only.
    error ProgramSponsorGasOnly(address sponsor);

    /// @notice Nothing leaves a program sponsor as coin to its manager.
    error ProgramSponsorNoWithdraw(address sponsor);

    /// @notice A program sponsor's credit is recovered only to its program.
    error ProgramSponsorRecoverToProgram(address sponsor, address program);

    /// @notice The platform administrator cannot reconfigure a program sponsor.
    error ProgramSponsorAdminLocked(address sponsor);

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    modifier onlyProgram() {
        if (msg.sender != _program().program || msg.sender == address(0)) revert NotProgram();
        _;
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Sets the program (once: a contract, after the deny list is seeded) and its hard caps (re-settable
    ///         for the same program; a lowered cap binds every open program sponsor at its next spend).
    function setProgram(
        address program,
        uint256 hardMaxCostPerOperation,
        uint256 hardDailyLimit
    ) external onlyPlatformAdmin {
        ProgramStorage storage p = _program();
        if (
            program == address(this) ||
            program.code.length == 0 ||
            (p.program != address(0) && program != p.program) ||
            p.deniedCount == 0 ||
            hardMaxCostPerOperation == 0 ||
            hardDailyLimit < hardMaxCostPerOperation
        ) {
            revert InvalidConfiguration();
        }
        p.program = program;
        p.hardMaxCostPerOperation = hardMaxCostPerOperation;
        p.hardDailyLimit = hardDailyLimit;
        emit ProgramConfigured(program, hardMaxCostPerOperation, hardDailyLimit);
    }

    /// @notice Opens a program sponsor (program): only at an address no sponsor has ever had, within the hard
    ///         caps, enabled.
    function openProgramSponsor(
        address sponsor,
        bytes32 tenantId,
        address manager,
        uint256 maxCostPerOperation,
        uint256 dailyLimit
    ) external onlyProgram {
        if (sponsor == address(0) || manager == address(0) || tenantId == bytes32(0)) revert InvalidConfiguration();
        ProgramStorage storage p = _program();
        SponsorState storage s = _sponsorStorage().sponsors[sponsor];
        if (s.manager != address(0) || p.programSponsor[sponsor]) revert SponsorExists(sponsor);
        _checkCaps(p, maxCostPerOperation, dailyLimit);
        s.tenantId = tenantId;
        s.manager = manager;
        s.adminMaxCostPerOperation = maxCostPerOperation;
        s.tenantMaxCostPerOperation = maxCostPerOperation;
        s.adminDailyLimit = dailyLimit;
        s.tenantDailyLimit = dailyLimit;
        s.adminEnabled = true;
        s.tenantEnabled = true;
        s.lastResetDay = block.timestamp / 1 days;
        p.programSponsor[sponsor] = true;
        p.openedBy[sponsor] = msg.sender;
        emit SponsorConfigured(sponsor, tenantId, manager, maxCostPerOperation, dailyLimit, true);
        emit ProgramSponsorOpened(sponsor, tenantId, manager, maxCostPerOperation, dailyLimit);
    }

    /// @notice Changes a program sponsor's caps (a tier change) within the hard caps, by the program that opened
    ///         it; the manager's own caps are clamped down to them.
    function setProgramSponsorCaps(address sponsor, uint256 maxCostPerOperation, uint256 dailyLimit) external {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[sponsor]) revert NotProgramSponsor(sponsor);
        if (msg.sender != p.openedBy[sponsor]) revert NotProgram();
        _checkCaps(p, maxCostPerOperation, dailyLimit);
        SponsorState storage s = _sponsorState(sponsor);
        s.adminMaxCostPerOperation = maxCostPerOperation;
        s.adminDailyLimit = dailyLimit;
        if (s.tenantMaxCostPerOperation > maxCostPerOperation) s.tenantMaxCostPerOperation = maxCostPerOperation;
        if (s.tenantDailyLimit > dailyLimit) s.tenantDailyLimit = dailyLimit;
        emit ProgramSponsorCapsUpdated(sponsor, maxCostPerOperation, dailyLimit);
    }

    /// @notice Adds or removes targets no program sponsor pays for, whatever its manager allows (platform
    ///         administrator). Program credit must never make griefing the platform's own contracts cheaper.
    /// @dev Bounded by _TARGETS_BATCH_MOST. The count moves only on a change, so it never underflows or
    ///      overflows.
    function setProgramDeniedTargets(address[] calldata targets, bool denied) external onlyPlatformAdmin {
        if (targets.length == 0 || targets.length > _TARGETS_BATCH_MOST) revert InvalidConfiguration();
        ProgramStorage storage p = _program();
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == address(0)) revert InvalidConfiguration();
            if (p.programDenied[targets[i]] != denied) {
                p.programDenied[targets[i]] = denied;
                if (denied) {
                    ++p.deniedCount;
                } else {
                    --p.deniedCount;
                }
            }
            emit ProgramTargetDeniedUpdated(targets[i], denied);
        }
    }

    /// @notice Sets whether this sponsor pays only for targets its manager approved (manager; off by default).
    function setTargetApprovalRequired(address sponsor, bool required) external onlySponsorManager(sponsor) {
        _program().targetsRequired[sponsor] = required;
        emit TargetApprovalRequired(sponsor, required);
    }

    /// @notice Allows or removes one target for a sponsor (manager).
    function setSponsoredTarget(address sponsor, address target, bool allowed) external onlySponsorManager(sponsor) {
        _setTarget(sponsor, target, allowed);
    }

    /// @notice Allows or removes up to 64 targets for a sponsor (manager).
    function setSponsoredTargets(
        address sponsor,
        address[] calldata targets,
        bool allowed
    ) external onlySponsorManager(sponsor) {
        if (targets.length == 0 || targets.length > _TARGETS_BATCH_MOST) revert InvalidConfiguration();
        for (uint256 i; i < targets.length; ++i) {
            _setTarget(sponsor, targets[i], allowed);
        }
    }

    /// @notice Whether program credit never pays for `target`.
    function isProgramDeniedTarget(address target) external view returns (bool) {
        return _program().programDenied[target];
    }

    /// @notice Whether `sponsor` pays only for approved targets.
    function targetApprovalRequired(address sponsor) external view returns (bool) {
        return _program().targetsRequired[sponsor];
    }

    /// @notice Whether `sponsor`'s manager approved `target`.
    function isTargetSponsored(address sponsor, address target) external view returns (bool) {
        return _program().sponsoredTargets[sponsor][target];
    }

    /// @notice The program and its hard caps.
    function programConfiguration()
        external
        view
        returns (address program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit)
    {
        ProgramStorage storage p = _program();
        return (p.program, p.hardMaxCostPerOperation, p.hardDailyLimit);
    }

    /// @notice Whether `sponsor` is a program sponsor.
    function isProgramSponsor(address sponsor) external view returns (bool) {
        return _program().programSponsor[sponsor];
    }

    /// @notice The program that opened `sponsor` (zero for any other sponsor) and how many deny-list entries are
    ///         set.
    function programSponsorOpener(address sponsor) external view returns (address opener, uint256 deniedTargets) {
        ProgramStorage storage p = _program();
        return (p.openedBy[sponsor], p.deniedCount);
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @dev The call approvals, the manager's targets, the deny list, eligibility, the tier's fee and the
    ///      operations per day. Bounded by _calls (32 calls at most).
    function _beforeSponsoredExecution(
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData
    ) internal override {
        ProgramStorage storage p = _program();
        address sponsor = voucher.sponsor;
        bool program = p.programSponsor[sponsor];
        bool targets = p.targetsRequired[sponsor]; // the manager's own choice, any sponsor
        ICryftDelegation.Call[] memory calls = _calls(executionData);
        if (!program) _requireApprovedCalls(calls); // platform call approvals: every sponsor but a program's
        for (uint256 i; i < calls.length; ++i) {
            address target = calls[i].target;
            if (targets && !p.sponsoredTargets[sponsor][target]) revert TargetNotSponsored(sponsor, target);
            // Program credit never pays a denied target, this contract or a reserved low address.
            if (
                program &&
                (p.programDenied[target] || target == address(this) || uint160(target) <= type(uint32).max)
            ) {
                revert ProgramTargetDenied(sponsor, target);
            }
        }
        if (!program) return super._beforeSponsoredExecution(voucher, executionData); // ops/day as the admin set
        (bool eligible, uint256 maxFee, uint256 opsPerDay) = _limits(p.openedBy[voucher.sponsor], voucher.sponsor);
        if (!eligible) revert ProgramSponsorIneligible(voucher.sponsor);
        if (voucher.maxFeePerGas > maxFee) revert ProgramFeeTooHigh(voucher.maxFeePerGas, maxFee);
        _countOperation(voucher.sponsor, opsPerDay); // the tier's ops per day, on the base's counter
    }

    function _reservePolicy(
        address policy,
        SponsorshipVoucher calldata voucher,
        bytes calldata executionData
    ) internal override {
        if (!_supportsV2(policy)) return super._reservePolicy(policy, voucher, executionData);
        _callPolicy(
            policy,
            abi.encodeCall(
                ITenantAllowancePolicyV2.reserveCalls,
                (voucher.operationId, voucher.account, voucher.maxCost, executionData)
            ),
            ITenantAllowancePolicyV2.reserveCalls.selector
        );
    }

    /// @dev Call approvals are checked in _beforeSponsoredExecution, where the sponsor is known: a developer
    ///      program's sponsor is exempt.
    function _validateSponsoredTargets(bytes calldata) internal view override(GasSponsor, ApprovedGasSponsor) {}

    function _pendingWorkerCost(
        address sponsor
    ) internal view override(GasSponsor, WorkerGasSponsor) returns (uint256) {
        return super._pendingWorkerCost(sponsor);
    }

    /// @dev A program sponsor takes no refundable deposit, from anyone (its program included).
    function _beforeRefundableDeposit(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorGasOnly(sponsor);
    }

    /// @dev A program sponsor's gas credit comes only from the program that opened it.
    function _beforeGasCreditDeposit(address sponsor) internal view override {
        ProgramStorage storage p = _program();
        if (p.programSponsor[sponsor] && msg.sender != p.openedBy[sponsor]) revert NotProgram();
    }

    /// @dev Nothing leaves a program sponsor as coin to its manager.
    function _beforeSponsorWithdrawal(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorNoWithdraw(sponsor);
    }

    /// @dev A program sponsor's credit is recovered only by the program that opened it, and only to that program
    ///      (its budget): the platform administrator has no path around the program's rules, and a later
    ///      setProgram gives none. Every other sponsor's: the platform administrator, to any non-zero address.
    function _authorizeGasCreditRecovery(address sponsor, address recipient) internal view override {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[sponsor]) return super._authorizeGasCreditRecovery(sponsor, recipient);
        address opener = p.openedBy[sponsor];
        if (msg.sender != opener) revert NotProgram();
        if (recipient != opener) revert ProgramSponsorRecoverToProgram(sponsor, opener);
    }

    /// @dev A program sponsor is its program's alone; the platform administrator cannot reconfigure it.
    function _beforeAdminSponsorChange(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorAdminLocked(sponsor);
    }

    /// @dev The program's hard caps bind a program sponsor at every spend.
    function _hardCaps(address sponsor) internal view override returns (uint256, uint256) {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[sponsor]) return super._hardCaps(sponsor);
        return (p.hardMaxCostPerOperation, p.hardDailyLimit);
    }

    /// @dev A program sponsor always pays only for wallets its manager approved.
    function _walletApprovalRequired(address sponsor) internal view override returns (bool) {
        return _program().programSponsor[sponsor] || super._walletApprovalRequired(sponsor);
    }

    /// @dev Program sponsors take no worker reservations.
    function _beforeWorkerReservation(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorHasNoWorkers(sponsor);
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    function _setTarget(address sponsor, address target, bool allowed) private {
        if (target == address(0) || target == address(this)) revert InvalidConfiguration();
        _program().sponsoredTargets[sponsor][target] = allowed;
        emit SponsoredTargetUpdated(sponsor, target, allowed);
    }

    /// @dev The program's answer, read with bounded gas and return data; anything else (no program, a revert, a
    ///      short or malformed answer) is ineligible: fail closed.
    function _limits(
        address program,
        address sponsor
    ) private view returns (bool eligible, uint256 maxFee, uint256 opsPerDay) {
        if (program == address(0) || program.code.length == 0) return (false, 0, 0);
        (bool ok, bytes memory answer) = program.staticcall{gas: _PROGRAM_READ_GAS}(
            abi.encodeCall(IDeveloperGasProgramLimits.sponsorLimits, (sponsor))
        );
        if (!ok || answer.length != 96) return (false, 0, 0);
        uint256 flag;
        (flag, maxFee, opsPerDay) = abi.decode(answer, (uint256, uint256, uint256));
        if (flag > 1) return (false, 0, 0);
        eligible = flag == 1;
    }

    /// @dev ERC-165, bounded: supports 0x01ffc9a7, not 0xffffffff, and ITenantAllowancePolicyV2.
    function _supportsV2(address policy) private view returns (bool) {
        return
            _supports(policy, _ERC165_INTERFACE_ID) &&
            !_supports(policy, _INVALID_INTERFACE_ID) &&
            _supports(policy, type(ITenantAllowancePolicyV2).interfaceId);
    }

    function _supports(address target, bytes4 id) private view returns (bool) {
        (bool ok, bytes memory answer) = target.staticcall{gas: _ERC165_GAS}(
            abi.encodeWithSelector(_ERC165_INTERFACE_ID, id)
        );
        return ok && answer.length == 32 && abi.decode(answer, (uint256)) == 1;
    }

    function _checkCaps(ProgramStorage storage p, uint256 maxCostPerOperation, uint256 dailyLimit) private view {
        if (maxCostPerOperation == 0 || dailyLimit < maxCostPerOperation) revert InvalidConfiguration();
        if (maxCostPerOperation > p.hardMaxCostPerOperation || dailyLimit > p.hardDailyLimit) {
            revert ProgramCapExceeded();
        }
    }

    function _program() private pure returns (ProgramStorage storage p) {
        bytes32 slot = _PROGRAM_SLOT;
        assembly ("memory-safe") {
            p.slot := slot
        }
    }
}
