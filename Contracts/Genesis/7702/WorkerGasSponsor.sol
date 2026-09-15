// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.20 <0.9.0;

import "./GasSponsor.sol";

interface IWorkerAllowancePolicy {
    function workerSettlementVersion() external view returns (uint256);
}

/// @notice Enterprise worker accounting alongside the existing open delegation path.
/// @dev A platform-authorized worker attests receipt costs; these are NOT verified
/// receipt proofs. The tenant must explicitly opt in. Funds remain locked in the
/// sponsor engine until bounded settlement to a platform-fixed treasury. No user
/// receives funds. Revocation prevents new reservations without trapping old ones.
contract WorkerGasSponsor is GasSponsor {
    bytes32 private constant WORKER_SLOT = keccak256("dakota.storage.WorkerGasSponsor.v1");
    struct Reservation {
        address sponsor;
        address wallet;
        address worker;
        address treasury;
        address policy;
        bytes32 requestHash;
        uint256 maximum;
        uint256 created;
    }
    struct WorkerStorage {
        mapping(address => address) treasuries;
        mapping(address => mapping(address => bool)) tenantWorkers;
        mapping(address => uint256) reserved;
        mapping(bytes32 => Reservation) operations;
        mapping(address => uint256) unpaidRevenue;
    }
    error WorkerNotAuthorized();
    error InvalidWorkerOperation();
    event WorkerConfigured(address indexed worker, address indexed treasury);
    event TenantWorkerConfigured(address indexed sponsor, address indexed worker, bool enabled);
    event WorkerReserved(bytes32 indexed operationId, address indexed sponsor, address indexed wallet,
        address worker, bytes32 requestHash, uint256 maximum);
    event WorkerSettled(bytes32 indexed operationId, address indexed sponsor, address indexed wallet,
        uint256 cost, uint256 reportedCost, bytes32 evidenceHash);
    event WorkerRevenueDeferred(address indexed treasury, uint256 amount);
    event WorkerRevenueClaimed(address indexed treasury, address indexed recipient, uint256 amount);

    function implementationVersion() external pure override returns (string memory) { return "1.3.0"; }

    function configureWorker(address worker, address treasury) external onlyPlatformAdmin {
        if (worker == address(0) || treasury == address(this)) revert InvalidWorkerOperation();
        _workers().treasuries[worker] = treasury;
        emit WorkerConfigured(worker, treasury);
    }

    function setTenantWorker(address sponsor, address worker, bool enabled) external onlySponsorManager(sponsor) {
        if (worker == address(0) || (enabled && _workers().treasuries[worker] == address(0))) revert InvalidWorkerOperation();
        _workers().tenantWorkers[sponsor][worker] = enabled;
        emit TenantWorkerConfigured(sponsor, worker, enabled);
    }

    function workerConfiguration(address sponsor, address worker) external view returns (address treasury, bool enabled, uint256 reserved) {
        WorkerStorage storage s = _workers();
        return (s.treasuries[worker], s.tenantWorkers[sponsor][worker], s.reserved[sponsor]);
    }
    function workerReservation(bytes32 id) external view returns (Reservation memory) { return _workers().operations[id]; }
    function pendingWorkerCost(address sponsor) external view returns (uint256) { return _workers().reserved[sponsor]; }
    function unpaidWorkerRevenue(address treasury) external view returns (uint256) { return _workers().unpaidRevenue[treasury]; }

    /// @notice A rejecting treasury cannot lock a tenant's completed reservation.
    /// Only that treasury can subsequently claim its own deferred revenue.
    function claimWorkerRevenue(address payable recipient, uint256 amount) external nonReentrant {
        WorkerStorage storage s = _workers();
        if (recipient == address(0) || recipient == address(this) || amount == 0 || amount > s.unpaidRevenue[msg.sender]) revert InvalidWorkerOperation();
        s.unpaidRevenue[msg.sender] -= amount;
        (bool sent,) = recipient.call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
        emit WorkerRevenueClaimed(msg.sender, recipient, amount);
    }

    function reserveWorker(address sponsor, address wallet, bytes32 id, bytes32 requestHash, uint256 maximum) external nonReentrant {
        GasSponsorStorage storage base = _sponsorStorage();
        WorkerStorage storage s = _workers();
        if (base.paused) revert SponsorshipIsPaused();
        address treasury = s.treasuries[msg.sender];
        if (treasury == address(0) || !s.tenantWorkers[sponsor][msg.sender]) revert WorkerNotAuthorized();
        if (id == bytes32(0) || requestHash == bytes32(0) || maximum == 0 || wallet == address(0)
            || base.consumedOperations[id] || s.operations[id].worker != address(0)) revert InvalidWorkerOperation();
        SponsorState storage account = _sponsorState(sponsor);
        if (!account.adminEnabled || !account.tenantEnabled) revert SponsorDisabled(sponsor);
        if (!isWalletSponsored(sponsor, wallet)) revert WalletNotSponsored(sponsor, wallet);
        if (maximum > account.adminMaxCostPerOperation || maximum > account.tenantMaxCostPerOperation) revert InvalidWorkerOperation();
        _resetDailySpendIfNeeded(account);
        uint256 committed = account.dailySpent + s.reserved[sponsor] + maximum;
        if (committed > account.adminDailyLimit || committed > account.tenantDailyLimit) revert InvalidWorkerOperation();
        if (maximum > account.balance - s.reserved[sponsor]) revert InvalidWorkerOperation();
        address policy = base.allowancePolicies[sponsor];
        // Mandatory user accounting; an old synchronous-only template is unsafe.
        if (policy == address(0) || IWorkerAllowancePolicy(policy).workerSettlementVersion() != 1) revert InvalidAllowancePolicy();
        _callPolicy(policy, abi.encodeCall(ITenantAllowancePolicy.reserve, (id, wallet, maximum)), ITenantAllowancePolicy.reserve.selector);
        s.reserved[sponsor] += maximum;
        s.operations[id] = Reservation(sponsor,wallet,msg.sender,treasury,policy,requestHash,maximum,block.timestamp);
        base.consumedOperations[id] = true;
        emit WorkerReserved(id,sponsor,wallet,msg.sender,requestHash,maximum);
    }

    /// @notice Reconcile once, including failed transaction costs. Lost workers can
    /// be reconciled by platform governance after reviewing the durable journal.
    /// No automatic timeout releases funds while a transaction may still settle.
    function settleWorker(bytes32 id, uint256 reportedCost, bytes32 evidenceHash) external nonReentrant returns (uint256 cost) {
        uint256 startGas = gasleft();
        WorkerStorage storage s = _workers();
        Reservation memory r = s.operations[id];
        if (r.worker == address(0) || evidenceHash == bytes32(0) || reportedCost > r.maximum) revert InvalidWorkerOperation();
        if (msg.sender != r.worker && msg.sender != _sponsorStorage().platformAdmin) revert WorkerNotAuthorized();
        // The same bounded overhead convention as delegated sponsorship covers
        // this settlement transaction. Uncovered excess remains a platform cost.
        uint256 measured = reportedCost + (startGas - gasleft() + this.costOverheadGas(r.sponsor)) * tx.gasprice;
        cost = measured < r.maximum ? measured : r.maximum;
        delete s.operations[id];
        s.reserved[r.sponsor] -= r.maximum;
        SponsorState storage account = _sponsorState(r.sponsor);
        _resetDailySpendIfNeeded(account);
        account.dailySpent += cost;
        account.balance -= cost;
        uint256 credit = _sponsorStorage().restrictedGasCredit[r.sponsor];
        _sponsorStorage().restrictedGasCredit[r.sponsor] -= cost < credit ? cost : credit;
        _callPolicy(r.policy, abi.encodeCall(ITenantAllowancePolicy.settle, (id, cost)), ITenantAllowancePolicy.settle.selector);
        // Always pay the treasury captured at reservation, never a user-supplied address.
        (bool sent,) = payable(r.treasury).call{value: cost, gas: 30000}("");
        if (!sent) {
            s.unpaidRevenue[r.treasury] += cost;
            emit WorkerRevenueDeferred(r.treasury, cost);
        }
        emit WorkerSettled(id,r.sponsor,r.wallet,cost,reportedCost,evidenceHash);
    }

    function _pendingWorkerCost(address sponsor) internal view override returns (uint256) { return _workers().reserved[sponsor]; }
    function _workers() private pure returns (WorkerStorage storage s) {
        bytes32 slot = WORKER_SLOT;
        assembly ("memory-safe") { s.slot := slot }
    }
}
