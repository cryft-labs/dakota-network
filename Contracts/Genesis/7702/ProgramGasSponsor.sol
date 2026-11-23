// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.20 <0.9.0;

import "./WorkerGasSponsor.sol";

/// @notice What GasSponsor asks the developer gas program about one of its sponsors, in one bounded read.
interface IDeveloperGasProgramLimits {
    /// @return eligible      the sponsor's developer holds an active Pass and the program is not paused
    /// @return maxFeePerGas  the most a voucher of this sponsor may offer a unit of gas (its tier's)
    /// @return opsPerDay     how many operations this sponsor may run in one UTC day (its tier's)
    function sponsorLimits(address sponsor) external view returns (bool eligible, uint256 maxFeePerGas, uint256 opsPerDay);
}

/// @notice A sponsor's allowance policy that also sees the calls it pays for (detected by ERC-165; V1's `reserve` otherwise).
interface ITenantAllowancePolicyV2 {
    function reserveCalls(bytes32 operationId, address wallet, uint256 maximumCost, address[] calldata targets, bytes4[] calldata selectors)
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
/// way credit leaves a program sponsor. Every other sponsor is exactly as in 1.5.0. No new storage.
/// @dev Append-only: the base and worker storage are untouched; this version's state lives in its own slot. 1.5.0 and 1.5.1 add no state.
contract ProgramGasSponsor is WorkerGasSponsor {
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
    }
    uint256 private constant _MAX_CALLS = 32;
    uint256 private constant _TARGETS_BATCH_MOST = 64;
    uint256 private constant _ERC165_GAS = 30_000;

    error NotProgram();
    error NotProgramSponsor(address sponsor);
    error SponsorExists(address sponsor);
    error ProgramCapExceeded();
    error ProgramSponsorIneligible(address sponsor);
    error ProgramFeeTooHigh(uint256 offered, uint256 maximum);
    error ProgramDailyOpsReached(address sponsor, uint256 opsPerDay);
    error ProgramSponsorHasNoWorkers(address sponsor);
    error TargetNotSponsored(address sponsor, address target);
    error ProgramTargetDenied(address sponsor, address target);
    error ProgramSponsorGasOnly(address sponsor);
    error ProgramSponsorNoWithdraw(address sponsor);
    error ProgramSponsorRecoverToProgram(address sponsor, address program);

    event ProgramConfigured(address indexed program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit);
    event ProgramSponsorOpened(address indexed sponsor, bytes32 indexed tenantId, address indexed manager,
        uint256 maxCostPerOperation, uint256 dailyLimit);
    event ProgramSponsorCapsSet(address indexed sponsor, uint256 maxCostPerOperation, uint256 dailyLimit);
    event TargetApprovalRequired(address indexed sponsor, bool required);
    event SponsoredTargetUpdated(address indexed sponsor, address indexed target, bool allowed);
    event ProgramTargetDeniedSet(address indexed target, bool denied);

    function implementationVersion() external pure override returns (string memory) { return "1.5.1"; }

    modifier onlyProgram() {
        if (msg.sender != _program().program || msg.sender == address(0)) revert NotProgram();
        _;
    }

    /// @notice The program and its hard caps. A zero program stops new sponsors and makes every program sponsor ineligible
    /// (its read cannot be answered) until one is set again.
    function setProgram(address program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit) external onlyPlatformAdmin {
        if (program == address(this) || hardMaxCostPerOperation == 0 || hardDailyLimit < hardMaxCostPerOperation) revert InvalidConfiguration();
        ProgramStorage storage p = _program();
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
        emit SponsorConfigured(sponsor, tenantId, manager, maxCostPerOperation, dailyLimit, true);
        emit ProgramSponsorOpened(sponsor, tenantId, manager, maxCostPerOperation, dailyLimit);
    }

    /// @notice A program sponsor's caps (a tier change), within the hard caps; the manager's own caps are clamped down to them.
    function setProgramSponsorCaps(address sponsor, uint256 maxCostPerOperation, uint256 dailyLimit) external onlyProgram {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[sponsor]) revert NotProgramSponsor(sponsor);
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
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == address(0)) revert InvalidConfiguration();
            _program().programDenied[targets[i]] = denied;
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

    /// @notice This UTC day's operations so far for a program sponsor (0 on a new day).
    function programOpsToday(address sponsor) external view returns (uint256) {
        ProgramStorage storage p = _program();
        return p.opsDay[sponsor] == block.timestamp / 1 days ? p.opsCount[sponsor] : 0;
    }

    function _beforeSponsoredExecution(SponsorshipVoucher calldata voucher, bytes calldata executionData) internal override {
        ProgramStorage storage p = _program();
        if (p.targetsRequired[voucher.sponsor]) {                           // the manager's own choice, any sponsor
            IDakotaDelegation.Call[] memory calls = _calls(executionData);
            for (uint256 i; i < calls.length; ++i)
                if (!p.sponsoredTargets[voucher.sponsor][calls[i].target]) revert TargetNotSponsored(voucher.sponsor, calls[i].target);
        }
        if (!p.programSponsor[voucher.sponsor]) return;                     // every other sponsor: as 1.3.0
        {
            IDakotaDelegation.Call[] memory calls = _calls(executionData);
            for (uint256 i; i < calls.length; ++i)
                if (p.programDenied[calls[i].target] || calls[i].target == address(this)) revert ProgramTargetDenied(voucher.sponsor, calls[i].target);
        }
        (bool eligible, uint256 maxFee, uint256 opsPerDay) = _limits(p.program, voucher.sponsor);
        if (!eligible) revert ProgramSponsorIneligible(voucher.sponsor);
        if (voucher.maxFeePerGas > maxFee) revert ProgramFeeTooHigh(voucher.maxFeePerGas, maxFee);
        uint256 today = block.timestamp / 1 days;
        if (p.opsDay[voucher.sponsor] != today) {
            p.opsDay[voucher.sponsor] = today;
            p.opsCount[voucher.sponsor] = 0;
        }
        uint256 used = p.opsCount[voucher.sponsor];
        if (used >= opsPerDay) revert ProgramDailyOpsReached(voucher.sponsor, opsPerDay);
        p.opsCount[voucher.sponsor] = used + 1;                             // used < opsPerDay <= max: cannot overflow
    }

    function _reservePolicy(address policy, SponsorshipVoucher calldata voucher, bytes calldata executionData) internal override {
        if (!_supportsV2(policy)) return super._reservePolicy(policy, voucher, executionData);
        IDakotaDelegation.Call[] memory calls = _calls(executionData);
        address[] memory targets = new address[](calls.length);
        bytes4[] memory selectors = new bytes4[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            targets[i] = calls[i].target;
            selectors[i] = calls[i].data.length >= 4 ? bytes4(calls[i].data) : bytes4(0);
        }
        _callPolicy(policy, abi.encodeCall(ITenantAllowancePolicyV2.reserveCalls,
            (voucher.operationId, voucher.account, voucher.maxCost, targets, selectors)), ITenantAllowancePolicyV2.reserveCalls.selector);
    }

    /// @dev 1.5.0: a program sponsor takes no refundable deposit, from anyone (its program included).
    function _beforeRefundableDeposit(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorGasOnly(sponsor);
    }

    /// @dev 1.5.0: a program sponsor's gas credit comes from the program alone (a zero program: from nobody).
    function _beforeGasCreditDeposit(address sponsor) internal view override {
        ProgramStorage storage p = _program();
        if (p.programSponsor[sponsor] && (msg.sender != p.program || msg.sender == address(0))) revert NotProgram();
    }

    /// @dev 1.5.0: nothing leaves a program sponsor as coin to its manager.
    function _beforeSponsorWithdrawal(address sponsor) internal view override {
        if (_program().programSponsor[sponsor]) revert ProgramSponsorNoWithdraw(sponsor);
    }

    /// @dev 1.5.1: a program sponsor's credit is recovered by the program ALONE (its reclaim after the 90-day freeze, or a paid
    /// top-up's refund), and only to the program (its budget): the platform administrator has no path around the program's
    /// rules. Every other sponsor's, by the platform administrator to any non-zero address, as before.
    function _authorizeGasCreditRecovery(address sponsor, address recipient) internal view override {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[sponsor]) return super._authorizeGasCreditRecovery(sponsor, recipient);
        if (msg.sender != p.program || msg.sender == address(0)) revert NotProgram();
        if (recipient != p.program) revert ProgramSponsorRecoverToProgram(sponsor, p.program);
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

    /// @dev The envelope's calls (its shape is validated before this runs): 1 to _MAX_CALLS of them.
    function _calls(bytes calldata executionData) private pure returns (IDakotaDelegation.Call[] memory calls) {
        (IDakotaDelegation.SponsoredExecutionRequest memory request,) =
            abi.decode(executionData[4:], (IDakotaDelegation.SponsoredExecutionRequest, bytes));
        calls = request.calls;
        if (calls.length == 0 || calls.length > _MAX_CALLS) revert InvalidExecutionEnvelope();
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
