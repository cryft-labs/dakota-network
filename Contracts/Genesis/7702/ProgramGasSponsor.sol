// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.20 <0.9.0;

import "./WorkerGasSponsor.sol";
import "./ApprovedGasSponsor.sol";

/// @notice What GasSponsor asks the developer gas program about one of its sponsors, in one bounded read.
interface IDeveloperGasProgramLimits {
    /// @return eligible      the sponsor's developer holds an active Pass and the program is not paused
    /// @return maxFeePerGas  the most a voucher of this sponsor may offer a unit of gas (its tier's)
    /// @return opsPerDay     how many operations this sponsor may run in one UTC day (its tier's)
    function sponsorLimits(address sponsor) external view returns (bool eligible, uint256 maxFeePerGas, uint256 opsPerDay);
}

/// @notice A sponsor's allowance policy that also sees the calls it pays for (detected by ERC-165; V1's `reserve` otherwise).
/// 1.5.2: it is handed the whole validated execution envelope (IDakotaDelegation.executeSponsored calldata: every call's target,
/// value and data) instead of target and selector arrays, so a policy can check anything about the calls (the 32 KB budget).
interface ITenantAllowancePolicyV2 {
    function reserveCalls(bytes32 operationId, address wallet, uint256 maximumCost, bytes calldata executionData)
        external returns (bytes4);
}

/// @notice GasSponsor 1.4.0: WorkerGasSponsor 1.3.0 and the developer gas program (2026-11-22). One PROGRAM address, set by the
/// platform administrator, opens sponsors that never existed and sets their caps, within program-wide HARD caps the
/// administrator sets; its gas reaches them through the existing restricted `depositGasCredit` (gas only, never withdrawable).
/// A program sponsor is spent from only while the program says it is eligible (its developer's Pass active, the program not
/// paused), with a voucher fee no higher than its tier's, and at most its tier's operations a UTC day: a saturating counter,
/// reset by the day, that can never overflow nor stop anything but that sponsor's own extra operations. Every other sponsor
/// (cryft.app's own, the tenants') is exactly as in 1.3.0, but for two choices every manager now has, both off by default:
/// ALLOWED TARGETS (setTargetApprovalRequired, setSponsoredTarget[s]): every call's `to` in the execution envelope must be one the
/// manager approved; and a V2 ALLOWANCE POLICY (ITenantAllowancePolicyV2, by ERC-165) is asked with the calls' targets and selectors.
///
/// 1.5.0 (2026-11-23, Chad: developer gas is "only spendable and not transferrable … only ever a function of the blockchain"):
/// a PROGRAM SPONSOR holds gas credit and nothing else. `depositFor` to it reverts ProgramSponsorGasOnly (no refundable coin goes
/// in); `withdrawSponsor` from it reverts ProgramSponsorNoWithdraw (no coin comes out to its manager); `depositGasCredit` for it
/// is accepted from the program alone (NotProgram otherwise); and `recoverGasCredit` for it, by the platform administrator or
/// the program, sends only to the program (ProgramSponsorRecoverToProgram otherwise): back into the program's budget, never to
/// any other address. Every other sponsor is exactly as in 1.4.0.
///
/// 1.5.1 (2026-11-23, the independent review's P2-D): `recoverGasCredit` for a program sponsor is the PROGRAM's alone (the
/// platform administrator's path is gone), so the program's own rules (the 90-day freeze, a paid top-up's refund) are the only
/// way credit leaves a program sponsor. Two more from the safe-coding review of the live contracts (Chad: "fix all of them"):
///  - C3: the platform's CALL APPROVALS (ApprovedGasSponsor, GasSponsor 1.2: target, selector, value, code and implementation
///    hashes) are enforced on chain again for every sponsor but a developer program's (whose calls the program's deny list,
///    the manager's targets and the router's lists govern); their storage is ApprovedGasSponsor's own namespaced slot
///    keccak256("dakota.storage.ApprovedGasSponsor.v1"), the one 1.2 wrote (0x…FEeD still holds its entries);
///  - C4: releaseWorker(id): a stuck worker reservation settled at its maximum, by the platform administrator or, after
///    RESERVATION_RELEASE_AFTER (7 days), by anyone.
/// Every other behavior is exactly as in 1.5.0. No new plain storage; the approvals' namespace is proven apart.
///
/// 1.5.2 (2026-11-25, the contract audit's P-1, for the fresh chain 113211):
///  - X-18: each program sponsor remembers the program that OPENED it (`openedBy`); only that program funds it, sets its caps,
///    recovers its credit (to itself) and answers its eligibility. `setProgram` is ONE-TIME for the address (later calls may only
///    re-set the hard caps of the same program): the program is a proxy at a stable address, upgraded behind it, so it never
///    needs to move, and a one-time set is smaller and stronger than tracking whether any program sponsor still holds credit.
///  - X-20: `setProgram` reverts until the deny list holds at least one entry (the release tool seeds the platform's own
///    non-genesis contracts first), and every reserved low address (below 2^32: the genesis system contracts 0x…1111, cafE,
///    c0DE, FacAdE, FEeD, de1E6A7E, and the precompiles) is denied to program credit in code, seeded or not.
///  - X-60: configureSponsor / setSponsorManager / setSponsorOpsPerDay revert for a program sponsor, and the hard caps clamp its
///    caps at spend time (a lowered hard cap binds every open program sponsor at once).
///  - X-19: a program sponsor always requires approved wallets; its ops/day count is the base's counter (one for every sponsor).
/// @dev Append-only: the base and worker storage are untouched; this version's state lives in its own slot. 1.5.0 and 1.5.1 add no
/// state; 1.5.2 appends `openedBy` and `deniedCount` (`opsDay`/`opsCount` stay, unread: the base counts every sponsor now).
contract ProgramGasSponsor is ApprovedGasSponsor, WorkerGasSponsor {
    bytes32 private constant PROGRAM_SLOT = keccak256("dakota.storage.ProgramGasSponsor.v1");
    uint256 private constant _PROGRAM_READ_GAS = 100_000;

    struct ProgramStorage {
        address program;
        uint256 hardMaxCostPerOperation;
        uint256 hardDailyLimit;
        mapping(address => bool) programSponsor;
        mapping(address => uint256) opsDay;
        mapping(address => uint256) opsCount;
        mapping(address => bool) targetsRequired;
        mapping(address => mapping(address => bool)) sponsoredTargets;
        mapping(address => bool) programDenied;          // targets no program sponsor ever pays for (the platform's own contracts)
        mapping(address => address) openedBy;            // 1.5.2: the program that opened each program sponsor
        uint256 deniedCount;                             // 1.5.2: entries of programDenied that are true
    }
    uint256 private constant _TARGETS_BATCH_MOST = 64;
    uint256 private constant _ERC165_GAS = 30_000;

    error NotProgram();
    error NotProgramSponsor(address sponsor);
    error SponsorExists(address sponsor);
    error ProgramCapExceeded();
    error ProgramSponsorIneligible(address sponsor);
    error ProgramFeeTooHigh(uint256 offered, uint256 maximum);
    error ProgramSponsorHasNoWorkers(address sponsor);
    error TargetNotSponsored(address sponsor, address target);
    error ProgramTargetDenied(address sponsor, address target);
    error ProgramSponsorGasOnly(address sponsor);
    error ProgramSponsorNoWithdraw(address sponsor);
    error ProgramSponsorRecoverToProgram(address sponsor, address program);
    error ProgramSponsorAdminLocked(address sponsor);

    event ProgramConfigured(address indexed program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit);
    event ProgramSponsorOpened(address indexed sponsor, bytes32 indexed tenantId, address indexed manager,
        uint256 maxCostPerOperation, uint256 dailyLimit);
    event ProgramSponsorCapsSet(address indexed sponsor, uint256 maxCostPerOperation, uint256 dailyLimit);
    event TargetApprovalRequired(address indexed sponsor, bool required);
    event SponsoredTargetUpdated(address indexed sponsor, address indexed target, bool allowed);
    event ProgramTargetDeniedSet(address indexed target, bool denied);

    modifier onlyProgram() {
        if (msg.sender != _program().program || msg.sender == address(0)) revert NotProgram();
        _;
    }

    /// @notice The program (ONCE: a contract, after the deny list is seeded) and its hard caps (re-settable for the same program;
    /// a lowered cap binds every open program sponsor at its next spend).
    function setProgram(address program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit) external onlyPlatformAdmin {
        ProgramStorage storage p = _program();
        if (program == address(this) || program.code.length == 0 || (p.program != address(0) && program != p.program)
            || p.deniedCount == 0 || hardMaxCostPerOperation == 0 || hardDailyLimit < hardMaxCostPerOperation) revert InvalidConfiguration();
        p.program = program;
        p.hardMaxCostPerOperation = hardMaxCostPerOperation;
        p.hardDailyLimit = hardDailyLimit;
        emit ProgramConfigured(program, hardMaxCostPerOperation, hardDailyLimit);
    }

    /// @notice A program sponsor opened: only an address no sponsor has ever had, within the hard caps, enabled.
    function openProgramSponsor(address sponsor, bytes32 tenantId, address manager, uint256 maxCostPerOperation, uint256 dailyLimit)
        external onlyProgram
    {
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

    /// @notice A program sponsor's caps (a tier change), within the hard caps; the manager's own caps are clamped down to them.
    /// 1.5.2: by the program that opened it.
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
        emit ProgramSponsorCapsSet(sponsor, maxCostPerOperation, dailyLimit);
    }

    /// @notice Targets no program sponsor pays for, whatever its manager allows (the rogue-gas audit, 2026-11-22: program credit
    /// must never make griefing the platform's own contracts cheaper). The platform administrator's alone.
    function setProgramDeniedTargets(address[] calldata targets, bool denied) external onlyPlatformAdmin {
        if (targets.length == 0 || targets.length > _TARGETS_BATCH_MOST) revert InvalidConfiguration();
        ProgramStorage storage p = _program();
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == address(0)) revert InvalidConfiguration();
            if (p.programDenied[targets[i]] != denied) {                 // the count moves only on a change: never under/overflows
                p.programDenied[targets[i]] = denied;
                if (denied) ++p.deniedCount; else --p.deniedCount;
            }
            emit ProgramTargetDeniedSet(targets[i], denied);
        }
    }

    function isProgramDeniedTarget(address target) external view returns (bool) { return _program().programDenied[target]; }

    /// @notice Whether this sponsor pays only for calls to targets its manager approved (off by default, any sponsor).
    function setTargetApprovalRequired(address sponsor, bool required) external onlySponsorManager(sponsor) {
        _program().targetsRequired[sponsor] = required;
        emit TargetApprovalRequired(sponsor, required);
    }

    function setSponsoredTarget(address sponsor, address target, bool allowed) external onlySponsorManager(sponsor) {
        _setTarget(sponsor, target, allowed);
    }

    function setSponsoredTargets(address sponsor, address[] calldata targets, bool allowed) external onlySponsorManager(sponsor) {
        if (targets.length == 0 || targets.length > _TARGETS_BATCH_MOST) revert InvalidConfiguration();
        for (uint256 i; i < targets.length; ++i) _setTarget(sponsor, targets[i], allowed);
    }

    function targetApprovalRequired(address sponsor) external view returns (bool) { return _program().targetsRequired[sponsor]; }
    function isTargetSponsored(address sponsor, address target) external view returns (bool) { return _program().sponsoredTargets[sponsor][target]; }

    function programConfiguration() external view returns (address program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit) {
        ProgramStorage storage p = _program();
        return (p.program, p.hardMaxCostPerOperation, p.hardDailyLimit);
    }

    function isProgramSponsor(address sponsor) external view returns (bool) { return _program().programSponsor[sponsor]; }

    /// @notice 1.5.2: the program that opened `sponsor` (zero for any other sponsor) and how many deny-list entries are set.
    function programSponsorOpener(address sponsor) external view returns (address opener, uint256 deniedTargets) {
        ProgramStorage storage p = _program();
        return (p.openedBy[sponsor], p.deniedCount);
    }

    /// @dev 1.5.1 (C3): the approval check moves here, where the sponsor is known: a developer program's sponsor is exempt.
    function _validateSponsoredTargets(bytes calldata) internal view override(GasSponsor, ApprovedGasSponsor) {}

    function _pendingWorkerCost(address sponsor) internal view override(GasSponsor, WorkerGasSponsor) returns (uint256) {
        return super._pendingWorkerCost(sponsor);
    }

    function _beforeSponsoredExecution(SponsorshipVoucher calldata voucher, bytes calldata executionData) internal override {
        ProgramStorage storage p = _program();
        address sponsor = voucher.sponsor;
        bool program = p.programSponsor[sponsor];
        bool targets = p.targetsRequired[sponsor];                          // the manager's own choice, any sponsor
        IDakotaDelegation.Call[] memory calls = _calls(executionData);      // 1.5.2: decoded once
        if (!program) _requireApprovedCalls(calls);                         // C3: every other sponsor
        for (uint256 i; i < calls.length; ++i) {
            address target = calls[i].target;
            if (targets && !p.sponsoredTargets[sponsor][target]) revert TargetNotSponsored(sponsor, target);
            // 1.5.2 (X-20): for program credit, reserved low addresses (genesis system contracts, precompiles) are always denied
            if (program && (p.programDenied[target] || target == address(this) || uint160(target) <= type(uint32).max))
                revert ProgramTargetDenied(sponsor, target);
        }
        if (!program) return super._beforeSponsoredExecution(voucher, executionData);  // ops/day as the admin set
        (bool eligible, uint256 maxFee, uint256 opsPerDay) = _limits(p.openedBy[voucher.sponsor], voucher.sponsor);
        if (!eligible) revert ProgramSponsorIneligible(voucher.sponsor);
        if (voucher.maxFeePerGas > maxFee) revert ProgramFeeTooHigh(voucher.maxFeePerGas, maxFee);
        _countOperation(voucher.sponsor, opsPerDay);                        // the tier's ops/day, on the base's counter
    }

    function _reservePolicy(address policy, SponsorshipVoucher calldata voucher, bytes calldata executionData) internal override {
        if (!_supportsV2(policy)) return super._reservePolicy(policy, voucher, executionData);
        _callPolicy(policy, abi.encodeCall(ITenantAllowancePolicyV2.reserveCalls,
            (voucher.operationId, voucher.account, voucher.maxCost, executionData)), ITenantAllowancePolicyV2.reserveCalls.selector);
    }

    /// @dev 1.5.0: a program sponsor takes no refundable deposit, from anyone (its program included).
    function _beforeRefundableDeposit(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorGasOnly(sponsor);
    }

    /// @dev 1.5.0: a program sponsor's gas credit comes from its program alone (1.5.2: the one that opened it).
    function _beforeGasCreditDeposit(address sponsor) internal view override {
        ProgramStorage storage p = _program();
        if (p.programSponsor[sponsor] && msg.sender != p.openedBy[sponsor]) revert NotProgram();
    }

    /// @dev 1.5.0: nothing leaves a program sponsor as coin to its manager.
    function _beforeSponsorWithdrawal(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorNoWithdraw(sponsor);
    }

    /// @dev 1.5.1: a program sponsor's credit is recovered by the program ALONE (its reclaim after the 90-day freeze, or a paid
    /// top-up's refund), and only to the program (its budget): the platform administrator has no path around the program's
    /// rules. Every other sponsor's, by the platform administrator to any non-zero address, as before.
    /// 1.5.2 (X-18): the program that OPENED the sponsor, to itself; a later setProgram gives no path to it.
    function _authorizeGasCreditRecovery(address sponsor, address recipient) internal view override {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[sponsor]) return super._authorizeGasCreditRecovery(sponsor, recipient);
        address opener = p.openedBy[sponsor];
        if (msg.sender != opener) revert NotProgram();
        if (recipient != opener) revert ProgramSponsorRecoverToProgram(sponsor, opener);
    }

    /// @dev 1.5.2 (X-60): a program sponsor is its program's alone; the platform administrator cannot reconfigure it.
    function _beforeAdminSponsorChange(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorAdminLocked(sponsor);
    }

    /// @dev 1.5.2 (X-60): the program's hard caps bind a program sponsor at every spend.
    function _hardCaps(address sponsor) internal view override returns (uint256, uint256) {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[sponsor]) return super._hardCaps(sponsor);
        return (p.hardMaxCostPerOperation, p.hardDailyLimit);
    }

    /// @dev 1.5.2 (X-19): a program sponsor always pays only for wallets its manager approved.
    function _walletApprovalRequired(address sponsor) internal view override returns (bool) {
        return _program().programSponsor[sponsor] || super._walletApprovalRequired(sponsor);
    }

    function _beforeWorkerReservation(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorHasNoWorkers(sponsor);
    }

    /// @dev The program's answer, read with bounded gas and returned data; anything else (no program, a revert, a short or
    /// malformed answer) is ineligible: fail closed.
    function _limits(address program, address sponsor) private view returns (bool eligible, uint256 maxFee, uint256 opsPerDay) {
        if (program == address(0) || program.code.length == 0) return (false, 0, 0);
        (bool ok, bytes memory answer) = program.staticcall{gas: _PROGRAM_READ_GAS}(
            abi.encodeCall(IDeveloperGasProgramLimits.sponsorLimits, (sponsor)));
        if (!ok || answer.length != 96) return (false, 0, 0);
        uint256 flag;
        (flag, maxFee, opsPerDay) = abi.decode(answer, (uint256, uint256, uint256));
        if (flag > 1) return (false, 0, 0);
        eligible = flag == 1;
    }

    /// @dev ERC-165, bounded: supports 0x01ffc9a7, not 0xffffffff, and ITenantAllowancePolicyV2.
    function _supportsV2(address policy) private view returns (bool) {
        return _supports(policy, 0x01ffc9a7) && !_supports(policy, 0xffffffff) && _supports(policy, type(ITenantAllowancePolicyV2).interfaceId);
    }

    function _supports(address target, bytes4 id) private view returns (bool) {
        (bool ok, bytes memory answer) = target.staticcall{gas: _ERC165_GAS}(abi.encodeWithSelector(0x01ffc9a7, id));
        return ok && answer.length == 32 && abi.decode(answer, (uint256)) == 1;
    }

    function _setTarget(address sponsor, address target, bool allowed) private {
        if (target == address(0) || target == address(this)) revert InvalidConfiguration();
        _program().sponsoredTargets[sponsor][target] = allowed;
        emit SponsoredTargetUpdated(sponsor, target, allowed);
    }

    function _checkCaps(ProgramStorage storage p, uint256 maxCostPerOperation, uint256 dailyLimit) private view {
        if (maxCostPerOperation == 0 || dailyLimit < maxCostPerOperation) revert InvalidConfiguration();
        if (maxCostPerOperation > p.hardMaxCostPerOperation || dailyLimit > p.hardDailyLimit) revert ProgramCapExceeded();
    }

    function _program() private pure returns (ProgramStorage storage p) {
        bytes32 slot = PROGRAM_SLOT;
        assembly ("memory-safe") { p.slot := slot }
    }
}
