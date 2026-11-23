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

/// @notice GasSponsor 1.4.0: WorkerGasSponsor 1.3.0 and the developer gas program (2026-11-22). One PROGRAM address, set by the
/// platform administrator, opens sponsors that never existed and sets their caps, within program-wide HARD caps the
/// administrator sets; its gas reaches them through the existing restricted `depositGasCredit` (gas only, never withdrawable).
/// A program sponsor is spent from only while the program says it is eligible (its developer's Pass active, the program not
/// paused), with a voucher fee no higher than its tier's, and at most its tier's operations a UTC day: a saturating counter,
/// reset by the day, that can never overflow nor stop anything but that sponsor's own extra operations. Every other sponsor
/// (cryft.app's own, the tenants') is exactly as in 1.3.0.
/// @dev Append-only: the base and worker storage are untouched; this version's state lives in its own slot.
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
    }

    error NotProgram();
    error NotProgramSponsor(address sponsor);
    error SponsorExists(address sponsor);
    error ProgramCapExceeded();
    error ProgramSponsorIneligible(address sponsor);
    error ProgramFeeTooHigh(uint256 offered, uint256 maximum);
    error ProgramDailyOpsReached(address sponsor, uint256 opsPerDay);
    error ProgramSponsorHasNoWorkers(address sponsor);

    event ProgramConfigured(address indexed program, uint256 hardMaxCostPerOperation, uint256 hardDailyLimit);
    event ProgramSponsorOpened(address indexed sponsor, bytes32 indexed tenantId, address indexed manager,
        uint256 maxCostPerOperation, uint256 dailyLimit);
    event ProgramSponsorCapsSet(address indexed sponsor, uint256 maxCostPerOperation, uint256 dailyLimit);

    function implementationVersion() external pure override returns (string memory) { return "1.4.0"; }

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

    function _beforeSponsoredExecution(SponsorshipVoucher calldata voucher) internal override {
        ProgramStorage storage p = _program();
        if (!p.programSponsor[voucher.sponsor]) return;                     // every other sponsor: exactly as 1.3.0
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

    function _checkCaps(ProgramStorage storage p, uint256 maxCostPerOperation, uint256 dailyLimit) private view {
        if (maxCostPerOperation == 0 || dailyLimit < maxCostPerOperation) revert InvalidConfiguration();
        if (maxCostPerOperation > p.hardMaxCostPerOperation || dailyLimit > p.hardDailyLimit) revert ProgramCapExceeded();
    }

    function _program() private pure returns (ProgramStorage storage p) {
        bytes32 slot = PROGRAM_SLOT;
        assembly ("memory-safe") { p.slot := slot }
    }
}
