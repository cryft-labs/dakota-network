// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {ITenantAllowancePolicy} from "./Interfaces/ITenantAllowancePolicy.sol";
import {GasSponsor} from "./GasSponsor.sol";

/// @title IWorkerAllowancePolicy
/// @notice The settlement version a worker sponsor's allowance policy must report.
interface IWorkerAllowancePolicy {
    /// @notice The worker settlement protocol the policy implements (1).
    function workerSettlementVersion() external view returns (uint256);
}

/// @title WorkerGasSponsor
/// @notice Enterprise worker accounting alongside the open delegation path.
/// @dev A platform-authorized worker attests receipt costs; these are not verified receipt proofs. The tenant
///      must opt in. Coin stays locked in the sponsor engine until bounded settlement to a platform-fixed
///      treasury; no user receives coin. Revoking a worker stops new reservations without trapping old ones.
///      State lives in its own namespace (cryft.storage.WorkerGasSponsor.v1).
/// @custom:version 1.5.2
/// @custom:security-contact security@cryft.cards
contract WorkerGasSponsor is GasSponsor {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

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

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @notice How long a reservation may stay open before anyone may release it. A worker's transaction lands
    ///         or is dropped within minutes; a week is far past any honest settlement.
    uint256 public constant RESERVATION_RELEASE_AFTER = 7 days;

    bytes32 private constant _WORKER_SLOT = keccak256("cryft.storage.WorkerGasSponsor.v1");
    uint256 private constant _RELEASE_POLICY_GAS = 200_000;
    uint256 private constant _TREASURY_CALL_GAS = 30000;
    uint256 private constant _WORKER_SETTLEMENT_VERSION = 1;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A worker's treasury was set (zero: the worker is revoked).
    event WorkerConfigured(address indexed worker, address indexed treasury);

    /// @notice A sponsor's manager enabled or disabled a worker.
    event TenantWorkerConfigured(address indexed sponsor, address indexed worker, bool enabled);

    /// @notice A worker reserved up to `maximum` of a sponsor's balance for an operation.
    event WorkerReserved(
        bytes32 indexed operationId,
        address indexed sponsor,
        address indexed wallet,
        address worker,
        bytes32 requestHash,
        uint256 maximum
    );

    /// @notice A reservation was settled at `cost`.
    event WorkerSettled(
        bytes32 indexed operationId,
        address indexed sponsor,
        address indexed wallet,
        uint256 cost,
        uint256 reportedCost,
        bytes32 evidenceHash
    );

    /// @notice A treasury refused coin; its revenue waits to be claimed.
    event WorkerRevenueDeferred(address indexed treasury, uint256 amount);

    /// @notice A treasury claimed deferred revenue.
    event WorkerRevenueClaimed(address indexed treasury, address indexed recipient, uint256 amount);

    /// @notice A stuck reservation was released (`cost`: its maximum by the platform administrator, 0 on timeout;
    ///         `policySettled`: whether its policy accepted the settle).
    event WorkerReleased(
        bytes32 indexed operationId,
        address indexed sponsor,
        address indexed by,
        uint256 cost,
        bool policySettled
    );

    /// @notice Deferred revenue of `from` (a treasury that refuses coin and cannot claim) moved to `to`.
    event WorkerRevenueRedirected(address indexed from, address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is not an enabled worker of the sponsor (or not allowed to act on the reservation).
    error WorkerNotAuthorized();

    /// @notice The worker request is not valid.
    error InvalidWorkerOperation();

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Sets a worker's treasury (platform administrator); zero revokes the worker.
    function configureWorker(address worker, address treasury) external onlyPlatformAdmin {
        if (worker == address(0) || treasury == address(this)) revert InvalidWorkerOperation();
        _workers().treasuries[worker] = treasury;
        emit WorkerConfigured(worker, treasury);
    }

    /// @notice Enables or disables a configured worker for a sponsor (manager).
    function setTenantWorker(address sponsor, address worker, bool enabled) external onlySponsorManager(sponsor) {
        if (worker == address(0) || (enabled && _workers().treasuries[worker] == address(0))) {
            revert InvalidWorkerOperation();
        }
        _workers().tenantWorkers[sponsor][worker] = enabled;
        emit TenantWorkerConfigured(sponsor, worker, enabled);
    }

    /// @notice Claims the caller's deferred treasury revenue to `recipient`.
    /// @dev A refusing treasury cannot lock a tenant's completed reservation; only that treasury can claim its own
    ///      deferred revenue.
    function claimWorkerRevenue(address payable recipient, uint256 amount) external nonReentrant {
        WorkerStorage storage s = _workers();
        if (
            recipient == address(0) ||
            recipient == address(this) ||
            amount == 0 ||
            amount > s.unpaidRevenue[msg.sender]
        ) {
            revert InvalidWorkerOperation();
        }
        s.unpaidRevenue[msg.sender] -= amount;
        _sendValue(recipient, amount);
        emit WorkerRevenueClaimed(msg.sender, recipient, amount);
    }

    /// @notice Moves all of a treasury's deferred revenue to another claimant (platform administrator).
    /// @dev For a treasury that can neither take coin nor call claimWorkerRevenue. Moves the ledger only (no coin
    ///      is sent here), so it can never lock or double-count anything: the new claimant claims as any treasury.
    function redirectWorkerRevenue(address from, address to) external onlyPlatformAdmin {
        WorkerStorage storage s = _workers();
        uint256 amount = s.unpaidRevenue[from];
        if (to == address(0) || to == address(this) || to == from || amount == 0) revert InvalidWorkerOperation();
        s.unpaidRevenue[from] = 0;
        s.unpaidRevenue[to] += amount;
        emit WorkerRevenueRedirected(from, to, amount);
    }

    /// @notice Reserves up to `maximum` of `sponsor`'s balance for operation `id` (an enabled worker).
    function reserveWorker(
        address sponsor,
        address wallet,
        bytes32 id,
        bytes32 requestHash,
        uint256 maximum
    ) external nonReentrant {
        GasSponsorStorage storage base = _sponsorStorage();
        WorkerStorage storage s = _workers();
        if (base.paused) revert SponsorshipIsPaused();
        _beforeWorkerReservation(sponsor);
        address treasury = s.treasuries[msg.sender];
        if (treasury == address(0) || !s.tenantWorkers[sponsor][msg.sender]) revert WorkerNotAuthorized();
        bytes32 key = _operationKey(sponsor, id);
        if (
            id == bytes32(0) ||
            requestHash == bytes32(0) ||
            maximum == 0 ||
            wallet == address(0) ||
            base.consumedOperations[key] ||
            s.operations[id].worker != address(0)
        ) {
            revert InvalidWorkerOperation();
        }
        SponsorState storage account = _sponsorState(sponsor);
        if (!account.adminEnabled || !account.tenantEnabled) revert SponsorDisabled(sponsor);
        if (!isWalletSponsored(sponsor, wallet)) revert WalletNotSponsored(sponsor, wallet);
        if (maximum > account.adminMaxCostPerOperation || maximum > account.tenantMaxCostPerOperation) {
            revert InvalidWorkerOperation();
        }
        _resetDailySpendIfNeeded(account);
        uint256 committed = account.dailySpent + s.reserved[sponsor] + maximum;
        if (committed > account.adminDailyLimit || committed > account.tenantDailyLimit) {
            revert InvalidWorkerOperation();
        }
        if (maximum > account.balance - s.reserved[sponsor]) revert InvalidWorkerOperation();
        // A reservation is an operation.
        _countOperation(sponsor, base.opsPerDay[sponsor]);
        address policy = base.allowancePolicies[sponsor];
        // Mandatory user accounting; an old synchronous-only policy is unsafe.
        if (
            policy == address(0) ||
            IWorkerAllowancePolicy(policy).workerSettlementVersion() != _WORKER_SETTLEMENT_VERSION
        ) {
            revert InvalidAllowancePolicy();
        }
        _callPolicy(
            policy,
            abi.encodeCall(ITenantAllowancePolicy.reserve, (id, wallet, maximum)),
            ITenantAllowancePolicy.reserve.selector
        );
        s.reserved[sponsor] += maximum;
        s.operations[id] = Reservation({
            sponsor: sponsor,
            wallet: wallet,
            worker: msg.sender,
            treasury: treasury,
            policy: policy,
            requestHash: requestHash,
            maximum: maximum,
            created: block.timestamp
        });
        base.consumedOperations[key] = true;
        emit WorkerReserved(id, sponsor, wallet, msg.sender, requestHash, maximum);
    }

    /// @notice Settles a reservation once, failed transaction costs included (its worker or the platform
    ///         administrator).
    /// @dev A lost worker's reservation is reconciled by the platform administrator after reviewing the durable
    ///      journal. No timeout settles while a transaction may still land; releaseWorker closes one that is stuck.
    function settleWorker(
        bytes32 id,
        uint256 reportedCost,
        bytes32 evidenceHash
    ) external nonReentrant returns (uint256 cost) {
        uint256 startGas = gasleft();
        WorkerStorage storage s = _workers();
        Reservation memory r = s.operations[id];
        if (r.worker == address(0) || evidenceHash == bytes32(0) || reportedCost > r.maximum) {
            revert InvalidWorkerOperation();
        }
        if (msg.sender != r.worker && msg.sender != _sponsorStorage().platformAdmin) revert WorkerNotAuthorized();
        // The same bounded overhead as delegated sponsorship covers this settlement transaction; any uncovered
        // excess stays a platform cost.
        uint256 measured = reportedCost + (startGas - gasleft() + costOverheadGas(r.sponsor)) * tx.gasprice;
        cost = measured < r.maximum ? measured : r.maximum;
        _closeReservation(s, id, r, cost);
        _callPolicy(
            r.policy,
            abi.encodeCall(ITenantAllowancePolicy.settle, (id, cost)),
            ITenantAllowancePolicy.settle.selector
        );
        // Always pays the treasury captured at reservation, never a caller-supplied address.
        _payTreasury(s, r.treasury, cost);
        emit WorkerSettled(id, r.sponsor, r.wallet, cost, reportedCost, evidenceHash);
    }

    /// @notice Releases a stuck reservation, so a lost worker can never lock a sponsor's balance or its policy's
    ///         allowance for good.
    /// @dev The platform administrator at any time, charging its maximum (after reviewing the worker's journal);
    ///      anyone once RESERVATION_RELEASE_AFTER has passed, charging nothing (a lost worker is the platform's
    ///      failure, never the tenant's bill). Idempotent: an operation already settled or released (or never
    ///      reserved) changes nothing and returns 0. The policy's settle gets a fixed budget, which the caller must
    ///      supply (too little gas reverts rather than skipping it); a refusing policy does not keep the
    ///      reservation stuck, the event reports it.
    function releaseWorker(bytes32 id) external nonReentrant returns (uint256 cost) {
        WorkerStorage storage s = _workers();
        Reservation memory r = s.operations[id];
        if (r.worker == address(0)) return 0;
        if (msg.sender == _sponsorStorage().platformAdmin) {
            cost = r.maximum;
        } else if (block.timestamp < r.created + RESERVATION_RELEASE_AFTER) {
            revert WorkerNotAuthorized();
        }
        _closeReservation(s, id, r, cost);
        bool settled = _trySettle(r.policy, id, cost, _RELEASE_POLICY_GAS);
        if (cost != 0) _payTreasury(s, r.treasury, cost);
        emit WorkerReleased(id, r.sponsor, msg.sender, cost, settled);
    }

    /// @notice A worker's treasury, whether it is enabled for `sponsor`, and the sponsor's reserved coin.
    function workerConfiguration(
        address sponsor,
        address worker
    ) external view returns (address treasury, bool enabled, uint256 reserved) {
        WorkerStorage storage s = _workers();
        return (s.treasuries[worker], s.tenantWorkers[sponsor][worker], s.reserved[sponsor]);
    }

    /// @notice An open reservation.
    /// @dev Worker reservation ids are one book across the platform's workers; a voucher's id is per sponsor.
    function workerReservation(bytes32 id) external view returns (Reservation memory) {
        return _workers().operations[id];
    }

    /// @notice Coin reserved by `sponsor`'s open reservations.
    function pendingWorkerCost(address sponsor) external view returns (uint256) {
        return _workers().reserved[sponsor];
    }

    /// @notice A treasury's deferred revenue.
    function unpaidWorkerRevenue(address treasury) external view returns (uint256) {
        return _workers().unpaidRevenue[treasury];
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    function _pendingWorkerCost(address sponsor) internal view virtual override returns (uint256) {
        return _workers().reserved[sponsor];
    }

    /// @dev Lets a later implementation refuse a reservation for `sponsor` (ProgramGasSponsor: none for a program
    ///      sponsor).
    function _beforeWorkerReservation(address sponsor) internal view virtual {}

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    /// @dev Closes the reservation and charges `cost` (at most its maximum) to its sponsor: the day's spend, the
    ///      balance, and the restricted credit first.
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

    /// @dev Pays the treasury captured at reservation, or defers its revenue (a refusing treasury never locks
    ///      anything).
    function _payTreasury(WorkerStorage storage s, address treasury, uint256 cost) private {
        (bool sent, ) = payable(treasury).call{value: cost, gas: _TREASURY_CALL_GAS}("");
        if (!sent) {
            s.unpaidRevenue[treasury] += cost;
            emit WorkerRevenueDeferred(treasury, cost);
        }
    }

    function _workers() private pure returns (WorkerStorage storage s) {
        bytes32 slot = _WORKER_SLOT;
        assembly ("memory-safe") {
            s.slot := slot
        }
    }
}
