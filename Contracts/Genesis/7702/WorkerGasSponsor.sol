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
    bytes32 private constant WORKER_SLOT = keccak256("cryft.storage.WorkerGasSponsor.v1");
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
    /// GasSponsor 1.5.1 (C4): a stuck reservation released (`cost`: its maximum by the platform administrator, 0 on timeout since
    /// 1.5.2; `policySettled`: its policy took the settle).
    event WorkerReleased(bytes32 indexed operationId, address indexed sponsor, address indexed by, uint256 cost, bool policySettled);

    /// @notice How long a reservation may stay open before ANYONE may release it (GasSponsor 1.5.1, C4): 7 days. A worker's
    /// transaction lands or is dropped within minutes; a week is far past any honest settlement.
    uint256 public constant RESERVATION_RELEASE_AFTER = 7 days;

    /// 1.5.2 (X-57): deferred revenue of `from` (a treasury that rejects coin and cannot claim) moved to `to`, who claims it.
    event WorkerRevenueRedirected(address indexed from, address indexed to, uint256 amount);

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
    /// @dev Worker reservation ids are one book among the platform's workers; a voucher's id is per sponsor (1.5.2, X-58).
    function workerReservation(bytes32 id) external view returns (Reservation memory) { return _workers().operations[id]; }
    function pendingWorkerCost(address sponsor) external view returns (uint256) { return _workers().reserved[sponsor]; }
    function unpaidWorkerRevenue(address treasury) external view returns (uint256) { return _workers().unpaidRevenue[treasury]; }

    /// @notice A rejecting treasury cannot lock a tenant's completed reservation.
    /// Only that treasury can subsequently claim its own deferred revenue.
    function claimWorkerRevenue(address payable recipient, uint256 amount) external nonReentrant {
        WorkerStorage storage s = _workers();
        if (recipient == address(0) || recipient == address(this) || amount == 0 || amount > s.unpaidRevenue[msg.sender]) revert InvalidWorkerOperation();
        s.unpaidRevenue[msg.sender] -= amount;
        _sendValue(recipient, amount);
        emit WorkerRevenueClaimed(msg.sender, recipient, amount);
    }

    /// @notice 1.5.2 (X-57): the platform administrator moves ALL of a treasury's deferred revenue to another claimant, for a
    /// treasury that can neither take coin nor call claimWorkerRevenue. Moves the ledger only (no coin is sent here), so it can
    /// never lock or double-count anything: the new claimant claims as any treasury does.
    function redirectWorkerRevenue(address from, address to) external onlyPlatformAdmin {
        WorkerStorage storage s = _workers();
        uint256 amount = s.unpaidRevenue[from];
        if (to == address(0) || to == address(this) || to == from || amount == 0) revert InvalidWorkerOperation();
        s.unpaidRevenue[from] = 0;
        s.unpaidRevenue[to] += amount;
        emit WorkerRevenueRedirected(from, to, amount);
    }

    function reserveWorker(address sponsor, address wallet, bytes32 id, bytes32 requestHash, uint256 maximum) external nonReentrant {
        GasSponsorStorage storage base = _sponsorStorage();
        WorkerStorage storage s = _workers();
        if (base.paused) revert SponsorshipIsPaused();
        _beforeWorkerReservation(sponsor);
        address treasury = s.treasuries[msg.sender];
        if (treasury == address(0) || !s.tenantWorkers[sponsor][msg.sender]) revert WorkerNotAuthorized();
        bytes32 key = _operationKey(sponsor, id);
        if (id == bytes32(0) || requestHash == bytes32(0) || maximum == 0 || wallet == address(0)
            || base.consumedOperations[key] || s.operations[id].worker != address(0)) revert InvalidWorkerOperation();
        SponsorState storage account = _sponsorState(sponsor);
        if (!account.adminEnabled || !account.tenantEnabled) revert SponsorDisabled(sponsor);
        if (!isWalletSponsored(sponsor, wallet)) revert WalletNotSponsored(sponsor, wallet);
        if (maximum > account.adminMaxCostPerOperation || maximum > account.tenantMaxCostPerOperation) revert InvalidWorkerOperation();
        _resetDailySpendIfNeeded(account);
        uint256 committed = account.dailySpent + s.reserved[sponsor] + maximum;
        if (committed > account.adminDailyLimit || committed > account.tenantDailyLimit) revert InvalidWorkerOperation();
        if (maximum > account.balance - s.reserved[sponsor]) revert InvalidWorkerOperation();
        _countOperation(sponsor, base.opsPerDay[sponsor]);                  // 1.5.2 (X-19): a reservation is an operation
        address policy = base.allowancePolicies[sponsor];
        // Mandatory user accounting; an old synchronous-only template is unsafe.
        if (policy == address(0) || IWorkerAllowancePolicy(policy).workerSettlementVersion() != 1) revert InvalidAllowancePolicy();
        _callPolicy(policy, abi.encodeCall(ITenantAllowancePolicy.reserve, (id, wallet, maximum)), ITenantAllowancePolicy.reserve.selector);
        s.reserved[sponsor] += maximum;
        s.operations[id] = Reservation(sponsor,wallet,msg.sender,treasury,policy,requestHash,maximum,block.timestamp);
        base.consumedOperations[key] = true;
        emit WorkerReserved(id,sponsor,wallet,msg.sender,requestHash,maximum);
    }

    /// @notice Reconcile once, including failed transaction costs. Lost workers can
    /// be reconciled by platform governance after reviewing the durable journal.
    /// No automatic timeout releases funds while a transaction may still settle; releaseWorker (1.5.1) closes one that is stuck.
    function settleWorker(bytes32 id, uint256 reportedCost, bytes32 evidenceHash) external nonReentrant returns (uint256 cost) {
        uint256 startGas = gasleft();
        WorkerStorage storage s = _workers();
        Reservation memory r = s.operations[id];
        if (r.worker == address(0) || evidenceHash == bytes32(0) || reportedCost > r.maximum) revert InvalidWorkerOperation();
        if (msg.sender != r.worker && msg.sender != _sponsorStorage().platformAdmin) revert WorkerNotAuthorized();
        // The same bounded overhead convention as delegated sponsorship covers
        // this settlement transaction. Uncovered excess remains a platform cost.
        uint256 measured = reportedCost + (startGas - gasleft() + costOverheadGas(r.sponsor)) * tx.gasprice;
        cost = measured < r.maximum ? measured : r.maximum;
        _closeReservation(s, id, r, cost);
        _callPolicy(r.policy, abi.encodeCall(ITenantAllowancePolicy.settle, (id, cost)), ITenantAllowancePolicy.settle.selector);
        // Always pay the treasury captured at reservation, never a user-supplied address.
        _payTreasury(s, r.treasury, cost);
        emit WorkerSettled(id,r.sponsor,r.wallet,cost,reportedCost,evidenceHash);
    }

    /// @notice GasSponsor 1.5.1 (C4), 1.5.2 (X-57): a STUCK reservation released, so a lost worker can never lock a sponsor's
    /// balance or its policy's allowance for good. The platform administrator at any time, charging its maximum (after
    /// reviewing the worker's journal); ANYONE once RESERVATION_RELEASE_AFTER has passed, charging NOTHING (a lost worker is
    /// the platform's failure, never the tenant's bill). Idempotent: an operation already settled or released (or never
    /// reserved) changes nothing and returns 0. The policy's settle is asked with a fixed budget, which the caller must supply
    /// (too little gas reverts rather than skipping it); its refusal does not keep the reservation stuck: the event says.
    function releaseWorker(bytes32 id) external nonReentrant returns (uint256 cost) {
        WorkerStorage storage s = _workers();
        Reservation memory r = s.operations[id];
        if (r.worker == address(0)) return 0;
        if (msg.sender == _sponsorStorage().platformAdmin) cost = r.maximum;
        else if (block.timestamp < r.created + RESERVATION_RELEASE_AFTER) revert WorkerNotAuthorized();
        _closeReservation(s, id, r, cost);
        bool settled = _trySettle(r.policy, id, cost, _RELEASE_POLICY_GAS);
        if (cost != 0) _payTreasury(s, r.treasury, cost);
        emit WorkerReleased(id, r.sponsor, msg.sender, cost, settled);
    }

    uint256 private constant _RELEASE_POLICY_GAS = 200_000;

    /// @dev The reservation closed and `cost` (at most its maximum) charged to its sponsor: the day's spend, the balance and the
    /// restricted credit first, as settleWorker always did.
    function _closeReservation(WorkerStorage storage s, bytes32 id, Reservation memory r, uint256 cost) private {
        delete s.operations[id];
        s.reserved[r.sponsor] -= r.maximum;
        SponsorState storage account = _sponsorState(r.sponsor);
        _resetDailySpendIfNeeded(account);
        account.dailySpent += cost;
        account.balance -= cost;
        uint256 credit = _sponsorStorage().restrictedGasCredit[r.sponsor];
        _sponsorStorage().restrictedGasCredit[r.sponsor] -= cost < credit ? cost : credit;
    }

    /// @dev The treasury captured at reservation paid, or its revenue deferred (a rejecting treasury never locks anything).
    function _payTreasury(WorkerStorage storage s, address treasury, uint256 cost) private {
        (bool sent,) = payable(treasury).call{value: cost, gas: 30000}("");
        if (!sent) {
            s.unpaidRevenue[treasury] += cost;
            emit WorkerRevenueDeferred(treasury, cost);
        }
    }

    function _pendingWorkerCost(address sponsor) internal view virtual override returns (uint256) { return _workers().reserved[sponsor]; }
    /// @dev A later implementation's own refusal of a reservation for `sponsor` (ProgramGasSponsor 1.4.0: none for a program sponsor).
    function _beforeWorkerReservation(address sponsor) internal view virtual {}
    function _workers() private pure returns (WorkerStorage storage s) {
        bytes32 slot = WORKER_SLOT;
        assembly ("memory-safe") { s.slot := slot }
    }
}
