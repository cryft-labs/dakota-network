// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity 0.8.37;

/*
   _____          __  ___
  / ___/__ ______/  |/  /__ ____  ___ ____ ____ ____
 / (_ / _ `( -< / /|_/ / _ `/ _ \/ _ `/ _ `/ -_) __/
 \___/\_,_/___//_/  /_/\_,_/_//_/\_,_/\_, /\_ /_/
                                     /___/ By: CryftCreator

    Version 2.6 — Production Gas Manager  [UPGRADEABLE]

  Gas beneficiary (genesis proxy 0x…cafE): voter-governed funding and burns.
  2/3 supermajority quorum for every state change; approved voter changes
  invalidate pending ballots and every pending burn approval.

  Two-phase treasury operations: vote → approve → (delay) → execute.
    • Every approval becomes executable only after `executionDelay` seconds
      and expires `fundApprovalWindow` seconds after that (audit X-4, X-56).
    • Native outflows (funding, sponsor funding, coin burns) share a per-period
      cap: at most `outflowCap` wei every `outflowPeriod` seconds (X-4).
    • Voters may cancel any pending approval during its delay.
  All windows are block.timestamp seconds, never block counts (X-14).

  Funding: fundKey = keccak256(abi.encode(fundingId, nonce)); the recipient,
  amount and note hash are bound at proposal time. Sponsor funding deposits
  into FEeD for a sponsor bound at proposal time; program sponsors are refused
  at proposal time (they only accept credit from their program).

  Setup: `initializeWithVoters` only through the proxy link, by a guardian of
  the hosting proxy (X-16). The implementation's initializers are locked.
*/

import "../Governance/GovernanceMembers.sol";
import "../Governance/GovernanceVotes.sol";

import "../Upgradeable/ReentrancyGuardUpgradeable.sol";
import "../Upgradeable/Initializable.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IGasSponsorDepository {
    function depositGasCredit(address sponsor) external payable;
}

contract GasManager is Initializable, ReentrancyGuardUpgradeable {
    error GasManagerAlreadyAGuardian();
    error GasManagerAmountMustBeGreaterThanZero();
    error GasManagerBurnFailed();
    error GasManagerBurnNotApproved();
    error GasManagerExactAmountNotTransferred();
    error GasManagerExpiredFundCleanupNotAuthorized();
    error GasManagerFundAlreadyApproved();
    error GasManagerFundNotApproved();
    error GasManagerFundProposalAlreadyExecuted();
    error GasManagerFundProposalAlreadyExists();
    error GasManagerFundProposalNotFound();
    error GasManagerFundingIDShouldNotBeZero();
    error GasManagerGuardianAddressShouldNotBeZero();
    error GasManagerInsufficientBalance();
    error GasManagerInvalidCleanupBatchSize();
    error GasManagerInvalidRecipientAddress();
    error GasManagerInvalidTokenAddress();
    error GasManagerNoApprovedFundingsToScan();
    error GasManagerNoGuardiansToClear();
    error GasManagerNoVotersAvailable();
    error GasManagerNonceMustBeGreaterThanZero();
    error GasManagerNotAGuardian();
    error GasManagerNoteTooLong();
    error GasManagerOnlyGuardian();
    error GasManagerOnlyGuardianOrFundedAddress();
    error GasManagerOnlyVotersCanCallThisFunction();
    error GasManagerStartOutOfRange();
    error GasManagerStringMustBe132Bytes();
    error GasManagerTokenBurnFailed();
    error GasManagerTransferFailed();
    error InvalidSponsor();
    error InvalidSponsorFundingProposal();
    error SponsorFundingExecutorRequired();
    error UnauthorizedSponsorFundingExecutor();
    error GasSponsorUnavailable();
    error SponsorFundingTransferMismatch();
    error ProgramSponsorNotFundable(address sponsor);
    error TooManyGuardians();
    error ExecutionDelayActive(uint256 executableAt);
    error OutflowCapExceeded(uint256 remaining);
    error InvalidParameter();
    error NothingToCancel();
    error InitializerNotLinkGuardian();

    struct Approval {
        uint256 executableAt;
        uint256 expiresAt;
        uint256 epoch;      // governance epoch at approval; a voter change voids the approval
    }

    struct FundProposal {
        bytes32 fundingId;
        bytes32 noteHash;
        address payable to;
        uint256 amount;
        uint256 nonce;
        bool executed;
        bool exists;
    }

    enum Parameter { EXECUTION_DELAY, APPROVAL_WINDOW, OUTFLOW_CAP, OUTFLOW_PERIOD }
    struct ParameterChange { Parameter parameter; uint256 value; }

    /// @dev Ballot window in SECONDS (name kept from the block-count era; slot unchanged).
    uint256 public voteTallyBlockThreshold;
    uint256 public totalGasFunded;
    uint256 private __reserved53;

    address[] public votersArray;
    address[] public otherVoterContracts;
    address[] public guardiansArray;

    mapping(address => bool) public isGuardian;
    uint256 private __reserved58;
    uint256 private __reserved59;
    /// @dev Token and native-coin burn approvals (keys never collide: coin keys are prefixed "nativeBurn").
    mapping(bytes32 => Approval) private _burnApprovals;
    mapping(bytes32 => bool) public approvedFunds;
    uint256 private __reserved62;

    /// @custom:storage-location erc7201:dakota.storage.GasManagerSponsorFunding
    struct SponsorFundingStorage {
        mapping(bytes32 => address) sponsorByFundKey;
    }

    bytes32 private constant _SPONSOR_FUNDING_STORAGE_LOCATION =
        0x2a467852670f144839bf1fd02ad0393580187791ab471304d92161a3bee88100;

    mapping(bytes32 => FundProposal) private _fundProposals;
    mapping(bytes32 => uint256) private _lastFundingNonceByFundingId;

    /// @notice Seconds an approval stays executable once its delay has passed.
    uint256 public fundApprovalWindow;
    mapping(bytes32 => uint256) public fundExecutableAt;
    mapping(bytes32 => uint256) public fundExpiresAt;

    bytes32[] private _activeApprovedFundKeys;
    mapping(bytes32 => uint256) private _activeApprovedFundKeyIndexPlusOne;

    bool public expiredFundCleanupAuthorized;
    uint256 public expiredFundCleanupCursor;

    /// @notice Seconds between an approval and the first moment it can execute.
    uint256 public executionDelay;
    /// @notice Native wei that may leave per outflow period.
    uint256 public outflowCap;
    /// @notice Outflow period length in seconds.
    uint256 public outflowPeriod;
    uint256 public outflowPeriodStart;
    uint256 public outflowUsed;
    mapping(uint256 => ParameterChange) private _parameterChanges;

    address constant _DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address constant _GAS_SPONSOR = 0x000000000000000000000000000000000000FEeD;

    uint256 private constant _MAX_FUND_NOTE_LENGTH = 280;
    uint256 private constant _MAX_CLEANUP_BATCH_SCAN = 500;
    uint256 public constant MAX_GUARDIANS = 64;
    uint256 public constant MAX_EXECUTION_DELAY = 30 days;
    uint256 public constant DEFAULT_VOTE_WINDOW = 7 days;
    uint256 public constant DEFAULT_APPROVAL_WINDOW = 3 days;
    uint256 private constant _PROBE_GAS = 100000;

    enum VoteType {
        ADD_GUARDIAN,
        REMOVE_GUARDIAN,
        ADD_VOTER,
        REMOVE_VOTER,
        ADD_OTHER_VOTER_CONTRACT,
        REMOVE_OTHER_VOTER_CONTRACT,
        UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
        CLEAR_GUARDIANS,
        BURN_TOKENS,
        FUND_GAS,
        BURN_NATIVE_COIN,
        SET_PARAMETER,
        AUTHORIZE_EXPIRED_FUND_CLEANUP,
        REFRESH_VOTERS,
        SET_VOTER_CONFIGURATION,
        CANCEL_APPROVAL
    }

    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    event VoteTallyReset(VoteType voteType, uint256 target);

    event GasFunded(address indexed to, uint256 amount);
    event TokenBurned(address indexed tokenAddress, uint256 amount);
    event NativeCoinBurned(uint256 amount);
    event GuardianUpdated(address indexed target, bool added);
    event GuardiansCleared(uint256 count);
    event VoterUpdated(address indexed target, bool added);
    event VotersInitialized(address[] voters);
    event OtherVoterContractUpdated(address indexed target, bool added);
    event VoterConfigurationApplied(bytes32 indexed membersHash);
    event VoteTallyBlockThresholdUpdated(uint256 newWindowSeconds);
    event ParameterUpdated(Parameter indexed parameter, uint256 value);
    event ApprovalCancelled(bytes32 indexed key);

    event TokenBurnApproved(address indexed tokenAddress, uint256 amount, bytes32 burnKey, uint256 executableAt, uint256 expiresAt);
    event GasFundApproved(address indexed to, uint256 amount, bytes32 fundKey);
    event CoinBurnApproved(uint256 amount, bytes32 coinBurnKey, uint256 executableAt, uint256 expiresAt);

    event FundApprovalWindowSet(bytes32 indexed fundKey, uint256 executableAt, uint256 expiresAt);
    event FundApprovalCleared(bytes32 indexed fundKey, bool expiredOrInvalid);

    event GasFundProposalCreated(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount,
        bytes32 noteHash,
        string note
    );

    event GasFundProposalApproved(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount,
        bytes32 noteHash,
        uint256 executableAt,
        uint256 expiresAt
    );

    event GasFundProposalExecuted(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount
    );

    event SponsorFundingProposalCreated(bytes32 indexed fundKey, address indexed sponsor, uint256 amount);
    event SponsorFundingProposalApproved(bytes32 indexed fundKey, address indexed sponsor, uint256 executableAt, uint256 expiresAt);
    event SponsorFundingExecuted(bytes32 indexed fundKey, address indexed sponsor, uint256 amount);

    event ExpiredFundCleanupAuthorized(uint256 activeApprovedFundCount);
    event ExpiredFundCleanupExecuted(uint256 scannedCount, uint256 clearedCount, uint256 nextCursor, bool completed);

    modifier onlyVoters() {
        if (!isVoter(msg.sender)) revert GasManagerOnlyVotersCanCallThisFunction();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    // ── Initialization ────────────────────────────────────

    /// @notice One-time setup, passed as the proxy link's init data (X-16). Only a guardian of the
    ///         hosting proxy (a root overlord or proxy guardian) may run it, so an empty-data link can
    ///         never be front-run. Starts with the full voter list (X-4) and the treasury limits.
    /// @param voters          1..64 distinct initial voters.
    /// @param executionDelay_ Seconds between approval and execution (0 allowed, e.g. dev).
    /// @param outflowCap_     Wei that may leave per period (> 0).
    /// @param outflowPeriod_  Period length in seconds (1 hour .. 30 days).
    function initializeWithVoters(
        address[] calldata voters,
        uint256 executionDelay_,
        uint256 outflowCap_,
        uint256 outflowPeriod_
    ) external initializer {
        _requireLinkGuardian();
        __ReentrancyGuard_init();
        _setInitialVoters(voters);
        voteTallyBlockThreshold = DEFAULT_VOTE_WINDOW;
        fundApprovalWindow = DEFAULT_APPROVAL_WINDOW;
        _setParameter(Parameter.EXECUTION_DELAY, executionDelay_);
        _setParameter(Parameter.OUTFLOW_CAP, outflowCap_);
        _setParameter(Parameter.OUTFLOW_PERIOD, outflowPeriod_);
    }

    /// @dev The caller must be a guardian of the proxy this code runs in. On the implementation itself
    ///      initializers are already disabled, so this is only reached through a proxy.
    function _requireLinkGuardian() private view {
        bytes memory input = abi.encodeWithSignature("proxy_isGuardian(address)", msg.sender);
        address host = address(this);
        bool ok;
        uint256 result;
        assembly ("memory-safe") {
            ok := staticcall(_PROBE_GAS, host, add(input, 32), mload(input), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            result := mload(0)
        }
        if (!ok || result != 1) revert InitializerNotLinkGuardian();
    }

    function _setInitialVoters(address[] calldata voters) private {
        if (voters.length == 0) revert GovernanceVotes.NoVoters();
        address[] memory members = GovernanceMembers.collect(voters, new address[](0), bytes4(keccak256("getVoters()")));
        if (members.length != voters.length) revert GovernanceVotes.VoterAlreadyPresent();
        votersArray = voters;
        GovernanceVotes.approveVoters(GovernanceVotes.state(), members);
        emit VotersInitialized(voters);
    }

    // ── Voter Queries ─────────────────────────────────────

    function isVoter(address potentialVoter) public view returns (bool) {
        return GovernanceMembers.contains(getVoters(), potentialVoter);
    }

    function getVoters() public view returns (address[] memory) {
        if (GovernanceVotes.state().votersInitialized) return GovernanceVotes.state().approvedVoters;
        return _readVoters();
    }

    function _readVoters() private view returns (address[] memory) {
        return GovernanceMembers.collect(votersArray, otherVoterContracts, bytes4(keccak256("getVoters()")));
    }

    function previewVoters() external view returns (address[] memory members, bytes32 membersHash) {
        members = _readVoters();
        membersHash = keccak256(abi.encode(members));
    }

    function voteToRefreshVoters(bytes32 expectedHash) external {
        _castVote(VoteType.REFRESH_VOTERS, uint256(expectedHash));
    }

    /// @notice Atomic handover/recovery; approvals bind both configuration and resulting membership.
    function voteToSetVoterConfiguration(address[] calldata local, address[] calldata providers, bytes32 expectedHash) external {
        uint256 target = GovernanceVotes.configure(GovernanceVotes.state(), local, providers, expectedHash);
        _castVote(VoteType.SET_VOTER_CONFIGURATION, target);
    }

    function getVoterCount() public view returns (uint256) {
        return getVoters().length;
    }

    // ── Vote Tally & Thresholds ───────────────────────────

    function getVoteTally(VoteType voteType, uint256 target) public view
        returns (uint256 totalVotes, uint256 startTime, uint256 expiresAt, address[] memory votedAddresses)
    {
        return GovernanceVotes.tally(GovernanceVotes.state(), _voteKey(voteType, target));
    }

    function getProposalSnapshot(VoteType voteType, uint256 target) external view
        returns (uint256 threshold, uint256 expires, uint256 epoch, address[] memory electorate)
    {
        return GovernanceVotes.snapshot(GovernanceVotes.state(), _voteKey(voteType, target));
    }

    function activeVoteCount() public view returns (uint256) { return GovernanceVotes.state().active; }
    function governanceEpoch() external view returns (uint256) { return GovernanceVotes.state().epoch; }
    function openBallots(address proposer) external view returns (uint256 counted, uint256 exempt) {
        return GovernanceVotes.openCount(GovernanceVotes.state(), proposer);
    }
    function hasVoted(VoteType voteType, uint256 target, address voter) external view returns (bool) {
        return GovernanceVotes.voted(GovernanceVotes.state(), _voteKey(voteType, target), voter);
    }

    function getSupermajorityThreshold() public view returns (uint256) {
        uint256 totalVoterCount = getVoterCount();
        if (totalVoterCount == 0) revert GasManagerNoVotersAvailable();
        return (totalVoterCount * 2 + 2) / 3;
    }

    // ── Balance Queries ───────────────────────────────────

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address tokenAddress) public view returns (uint256) {
        return IERC20(tokenAddress).balanceOf(address(this));
    }

    /// @notice Wei that may still leave in the current outflow period.
    function outflowRemaining() public view returns (uint256) {
        if (block.timestamp >= outflowPeriodStart + outflowPeriod) return outflowCap;
        return outflowUsed >= outflowCap ? 0 : outflowCap - outflowUsed;
    }

    // ── Funding Approval Queries ──────────────────────────

    function getFundApprovalStatus(bytes32 fundKey)
        public
        view
        returns (bool approved, uint256 executableAt, uint256 expiresAt, bool expiredOrInvalid, bool inActiveSet)
    {
        approved = approvedFunds[fundKey];
        executableAt = fundExecutableAt[fundKey];
        expiresAt = fundExpiresAt[fundKey];
        expiredOrInvalid = _isFundApprovalExpiredOrInvalid(fundKey);
        inActiveSet = _activeApprovedFundKeyIndexPlusOne[fundKey] != 0;
    }

    /// @notice A burn approval; `valid` is false once expired or after any voter change.
    function getBurnApproval(bytes32 burnKey)
        external
        view
        returns (bool valid, uint256 executableAt, uint256 expiresAt)
    {
        Approval storage a = _burnApprovals[burnKey];
        return (_burnValid(a), a.executableAt, a.expiresAt);
    }

    function getActiveApprovedFundKeyCount() public view returns (uint256) {
        return _activeApprovedFundKeys.length;
    }

    function getActiveApprovedFundKeys(uint256 start, uint256 count) public view returns (bytes32[] memory keys) {
        uint256 len = _activeApprovedFundKeys.length;
        if (!(start < len || len == 0)) revert GasManagerStartOutOfRange();
        if (start >= len) return new bytes32[](0);
        uint256 end = count > len - start ? len : start + count;
        keys = new bytes32[](end - start);
        for (uint256 i = start; i < end; ++i) keys[i - start] = _activeApprovedFundKeys[i];
    }

    function lastFundingNonceByFundingId(string calldata fundingId) public view returns (uint256) {
        return _lastFundingNonceByFundingId[_stringToBytes32(fundingId)];
    }

    function getNextFundingNonce(string calldata fundingId) public view returns (uint256) {
        return _lastFundingNonceByFundingId[_stringToBytes32(fundingId)] + 1;
    }

    function getFundKey(string calldata fundingId, uint256 nonce) public pure returns (bytes32) {
        return _getFundKey(_stringToBytes32(fundingId), nonce);
    }

    function _getFundKey(bytes32 fundingId, uint256 nonce) internal pure returns (bytes32) {
        if (fundingId == bytes32(0)) revert GasManagerFundingIDShouldNotBeZero();
        if (nonce == 0) revert GasManagerNonceMustBeGreaterThanZero();
        return keccak256(abi.encode(fundingId, nonce));
    }

    function getFundProposal(bytes32 fundKey)
        public
        view
        returns (
            bytes32 fundingId,
            uint256 nonce,
            address to,
            uint256 amount,
            bytes32 noteHash,
            bool executed,
            bool exists,
            bool approved,
            uint256 executableAt,
            uint256 expiresAt,
            bool expiredOrInvalid
        )
    {
        FundProposal storage proposal = _fundProposals[fundKey];
        (approved, executableAt, expiresAt, expiredOrInvalid, ) = getFundApprovalStatus(fundKey);
        return (proposal.fundingId, proposal.nonce, proposal.to, proposal.amount, proposal.noteHash,
            proposal.executed, proposal.exists, approved, executableAt, expiresAt, expiredOrInvalid);
    }

    function getFundKeyAndProposal(string calldata fundingId, uint256 nonce)
        external
        view
        returns (bytes32 fundKey, address to, uint256 amount, bool executed, bool exists, bool approved, uint256 executableAt)
    {
        fundKey = _getFundKey(_stringToBytes32(fundingId), nonce);
        FundProposal storage proposal = _fundProposals[fundKey];
        (approved, executableAt, , , ) = getFundApprovalStatus(fundKey);
        return (fundKey, proposal.to, proposal.amount, proposal.executed, proposal.exists, approved, executableAt);
    }

    /// @notice Fixed GasSponsor proxy that receives governed sponsor deposits.
    function gasSponsor() public pure returns (address) {
        return _GAS_SPONSOR;
    }

    function implementationVersion() public pure returns (string memory) {
        return "2.6.0";
    }

    /// @notice ERC-7201 location used for sponsor-funding proposal bindings.
    function sponsorFundingStorageLocation() public pure returns (bytes32) {
        return _SPONSOR_FUNDING_STORAGE_LOCATION;
    }

    /// @notice Returns the immutable sponsor bound to a funding proposal.
    function getSponsorFundingTarget(bytes32 fundKey) public view returns (address sponsor, bool isSponsorFunding) {
        sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        isSponsorFunding = sponsor != address(0);
    }

    // ── Internal Vote Engine ──────────────────────────────

    function _voteKey(VoteType voteType, uint256 target) private pure returns (bytes32) {
        return keccak256(abi.encode(voteType, target));
    }

    function _changesVoters(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.REFRESH_VOTERS || voteType == VoteType.SET_VOTER_CONFIGURATION
            || voteType == VoteType.ADD_VOTER || voteType == VoteType.REMOVE_VOTER
            || voteType == VoteType.ADD_OTHER_VOTER_CONTRACT || voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT;
    }

    /// @dev Defensive ballots stay open-able even when one voter floods the counted caps (X-13).
    function _isExempt(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.REMOVE_VOTER || voteType == VoteType.SET_VOTER_CONFIGURATION
            || voteType == VoteType.REMOVE_GUARDIAN || voteType == VoteType.CLEAR_GUARDIANS
            || voteType == VoteType.CANCEL_APPROVAL;
    }

    function _isGuardianVote(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.ADD_GUARDIAN || voteType == VoteType.REMOVE_GUARDIAN
            || voteType == VoteType.CLEAR_GUARDIANS;
    }

    function _isTreasuryVote(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.FUND_GAS || voteType == VoteType.BURN_TOKENS
            || voteType == VoteType.BURN_NATIVE_COIN || voteType == VoteType.CANCEL_APPROVAL;
    }

    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        GovernanceVotes.State storage s = GovernanceVotes.state();
        address[] memory electorate;
        if (!GovernanceVotes.live(s, key)) electorate = getVoters();
        if (GovernanceVotes.cast(s, key, electorate, voteTallyBlockThreshold, msg.sender, _isExempt(voteType))) {
            if (_changesVoters(voteType)) _applyVoterVote(voteType, target);
            else if (_isGuardianVote(voteType)) _applyGuardianVote(voteType, address(uint160(target)));
            else if (_isTreasuryVote(voteType)) _applyTreasuryVote(voteType, bytes32(target));
            else _applyParameterVote(voteType, target);
            GovernanceVotes.complete(s, key);
            if (_changesVoters(voteType)) GovernanceVotes.invalidate(s);
        }
        emit VoteCast(msg.sender, voteType, target);
    }

    function _applyGuardianVote(VoteType voteType, address target) private {
        if (voteType == VoteType.ADD_GUARDIAN) {
            if (isGuardian[target]) revert GasManagerAlreadyAGuardian();
            if (guardiansArray.length >= MAX_GUARDIANS) revert TooManyGuardians();
            isGuardian[target] = true;
            guardiansArray.push(target);
            emit GuardianUpdated(target, true);
        } else if (voteType == VoteType.REMOVE_GUARDIAN) {
            if (!isGuardian[target]) revert GasManagerNotAGuardian();
            isGuardian[target] = false;
            _removeAddress(guardiansArray, target);
            emit GuardianUpdated(target, false);
        } else {
            uint256 count = guardiansArray.length;
            for (uint256 i = 0; i < count; ++i) isGuardian[guardiansArray[i]] = false;
            delete guardiansArray;
            emit GuardiansCleared(count);
        }
    }

    function _applyTreasuryVote(VoteType voteType, bytes32 key) private {
        if (voteType == VoteType.FUND_GAS) {
            _approveFundKey(key);
        } else if (voteType == VoteType.CANCEL_APPROVAL) {
            if (approvedFunds[key]) _clearFundApproval(key, true);
            delete _burnApprovals[key];
            emit ApprovalCancelled(key);
        } else {
            (uint256 executableAt, uint256 expiresAt) = _approvalWindow();
            _burnApprovals[key] = Approval(executableAt, expiresAt, GovernanceVotes.state().epoch);
        }
    }

    function _applyParameterVote(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
            if (!GovernanceVotes.validWindow(target)) revert GovernanceVotes.InvalidExpiry();
            voteTallyBlockThreshold = target;
            emit VoteTallyBlockThresholdUpdated(target);
        } else if (voteType == VoteType.SET_PARAMETER) {
            ParameterChange memory change = _parameterChanges[target];
            delete _parameterChanges[target];
            _setParameter(change.parameter, change.value);
        } else {
            expiredFundCleanupAuthorized = true;
            expiredFundCleanupCursor = 0;
            emit ExpiredFundCleanupAuthorized(_activeApprovedFundKeys.length);
        }
    }

    function _applyVoterVote(VoteType voteType, uint256 target) private {
        address targetAddress = address(uint160(target));
        if (voteType == VoteType.ADD_VOTER) {
            if (isVoter(targetAddress)) revert GovernanceVotes.VoterAlreadyPresent();
            votersArray.push(targetAddress);
            emit VoterUpdated(targetAddress, true);
        } else if (voteType == VoteType.REMOVE_VOTER) {
            if (!_removeAddress(votersArray, targetAddress)) revert GovernanceVotes.VoterNotFound();
            emit VoterUpdated(targetAddress, false);
        } else if (voteType == VoteType.ADD_OTHER_VOTER_CONTRACT) {
            if (GovernanceMembers.contains(otherVoterContracts, targetAddress)) revert GovernanceVotes.ProviderAlreadyPresent();
            otherVoterContracts.push(targetAddress);
            emit OtherVoterContractUpdated(targetAddress, true);
        } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
            if (!(votersArray.length > 0 || otherVoterContracts.length > 1)) revert GovernanceVotes.EmptyVoterSet();
            if (!_removeAddress(otherVoterContracts, targetAddress)) revert GovernanceVotes.ProviderNotFound();
            emit OtherVoterContractUpdated(targetAddress, false);
        } else if (voteType == VoteType.SET_VOTER_CONFIGURATION) {
            GovernanceVotes.Configuration storage config = GovernanceVotes.state().configurations[target];
            votersArray = config.local;
            otherVoterContracts = config.providers;
        }
        address[] memory members = _readVoters();
        if (members.length == 0) revert GovernanceVotes.EmptyVoterSet();
        bytes32 membersHash = keccak256(abi.encode(members));
        if (voteType == VoteType.REFRESH_VOTERS && membersHash != bytes32(target)) revert GovernanceVotes.MembershipChanged();
        if (voteType == VoteType.SET_VOTER_CONFIGURATION) {
            if (membersHash != GovernanceVotes.state().configurations[target].membersHash) revert GovernanceVotes.MembershipChanged();
            delete GovernanceVotes.state().configurations[target];
            emit VoterConfigurationApplied(membersHash);
        }
        GovernanceVotes.approveVoters(GovernanceVotes.state(), members);
    }

    /// @dev Swap-and-pop removal; arrays here are bounded at 64 entries.
    function _removeAddress(address[] storage list, address target) private returns (bool) {
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ++i) {
            if (list[i] == target) {
                list[i] = list[len - 1];
                list.pop();
                return true;
            }
        }
        return false;
    }

    // ── Voter Management ──────────────────────────────────

    function voteToAddVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.ADD_VOTER, uint256(uint160(voter)));
    }

    function voteToRemoveVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.REMOVE_VOTER, uint256(uint160(voter)));
    }

    function voteToAddOtherVoterContract(address voterContract) external {
        GovernanceMembers.read(voterContract, bytes4(keccak256("getVoters()")));
        _castVote(VoteType.ADD_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    function voteToRemoveOtherVoterContract(address voterContract) external {
        if (voterContract == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.REMOVE_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    // ── Guardian Management ───────────────────────────────

    function voteToAddGuardian(address guardian) external {
        if (guardian == address(0)) revert GasManagerGuardianAddressShouldNotBeZero();
        if (guardiansArray.length >= MAX_GUARDIANS) revert TooManyGuardians();
        _castVote(VoteType.ADD_GUARDIAN, uint256(uint160(guardian)));
    }

    function voteToRemoveGuardian(address guardian) external {
        if (guardian == address(0)) revert GasManagerGuardianAddressShouldNotBeZero();
        _castVote(VoteType.REMOVE_GUARDIAN, uint256(uint160(guardian)));
    }

    function voteToClearGuardians() external {
        if (guardiansArray.length == 0) revert GasManagerNoGuardiansToClear();
        _castVote(VoteType.CLEAR_GUARDIANS, 1);
    }

    function getGuardians() public view returns (address[] memory) {
        return guardiansArray;
    }

    function getGuardianCount() public view returns (uint256) {
        return guardiansArray.length;
    }

    // ── Parameter Governance ──────────────────────────────

    /// @notice Ballot window in seconds (1 hour .. 30 days).
    function voteToUpdateVoteTallyBlockThreshold(uint256 newWindowSeconds) external {
        if (!GovernanceVotes.validWindow(newWindowSeconds)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD, newWindowSeconds);
    }

    /// @notice Treasury parameters: execution delay (0 .. 30 days), approval window (1 hour .. 30 days),
    ///         outflow cap (> 0 wei) and outflow period (1 hour .. 30 days).
    function voteToSetParameter(Parameter parameter, uint256 value) external {
        _checkParameter(parameter, value);
        uint256 target = uint256(keccak256(abi.encode(parameter, value)));
        _parameterChanges[target] = ParameterChange(parameter, value);
        _castVote(VoteType.SET_PARAMETER, target);
    }

    function _checkParameter(Parameter parameter, uint256 value) private pure {
        bool ok;
        if (parameter == Parameter.EXECUTION_DELAY) ok = value <= MAX_EXECUTION_DELAY;
        else if (parameter == Parameter.OUTFLOW_CAP) ok = value > 0;
        else ok = GovernanceVotes.validWindow(value);
        if (!ok) revert InvalidParameter();
    }

    function _setParameter(Parameter parameter, uint256 value) private {
        _checkParameter(parameter, value);
        if (parameter == Parameter.EXECUTION_DELAY) executionDelay = value;
        else if (parameter == Parameter.APPROVAL_WINDOW) fundApprovalWindow = value;
        else if (parameter == Parameter.OUTFLOW_CAP) outflowCap = value;
        else outflowPeriod = value;
        emit ParameterUpdated(parameter, value);
    }

    function voteToAuthorizeExpiredFundCleanup() external {
        if (_activeApprovedFundKeys.length == 0) revert GasManagerNoApprovedFundingsToScan();
        _castVote(VoteType.AUTHORIZE_EXPIRED_FUND_CLEANUP, 1);
    }

    /// @notice Cancel a pending funding or burn approval (for use during its execution delay).
    function voteToCancelApproval(bytes32 key) external {
        if (!approvedFunds[key] && _burnApprovals[key].expiresAt == 0) revert NothingToCancel();
        _castVote(VoteType.CANCEL_APPROVAL, uint256(key));
    }

    // ── Gas Funding ───────────────────────────────────────

    function proposeFundGasV2(string calldata fundingId, address payable to, uint256 amount, string calldata note)
        external
        onlyVoters
        returns (bytes32 fundKey, uint256 nonce)
    {
        return _proposeFundGas(_stringToBytes32(fundingId), to, amount, note, address(0));
    }

    /// @notice Proposes a governed deposit from caFE into a FEeD sponsor ledger.
    /// @dev The sponsor is bound before voting begins. Program sponsors accept credit only from their
    ///      program, so funding one would always revert at execution: it is refused here (X-56).
    function proposeSponsorFunding(string calldata fundingId, address sponsor, uint256 amount, string calldata note)
        external
        onlyVoters
        returns (bytes32 fundKey, uint256 nonce)
    {
        if (sponsor == address(0)) revert InvalidSponsor();
        if (!_isContract(_GAS_SPONSOR)) revert GasSponsorUnavailable();
        if (_isProgramSponsor(sponsor)) revert ProgramSponsorNotFundable(sponsor);
        return _proposeFundGas(_stringToBytes32(fundingId), payable(_GAS_SPONSOR), amount, note, sponsor);
    }

    /// @dev Bounded probe; a GasSponsor without program support (call fails) has no program sponsors.
    function _isProgramSponsor(address sponsor) private view returns (bool) {
        bytes memory input = abi.encodeWithSignature("isProgramSponsor(address)", sponsor);
        address target = _GAS_SPONSOR;
        bool ok;
        uint256 result;
        assembly ("memory-safe") {
            ok := staticcall(_PROBE_GAS, target, add(input, 32), mload(input), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            result := mload(0)
        }
        return ok && result != 0;
    }

    function _proposeFundGas(bytes32 fundingId, address payable to, uint256 amount, string calldata note, address sponsor)
        internal
        returns (bytes32 fundKey, uint256 nonce)
    {
        if (to == address(0)) revert GasManagerInvalidRecipientAddress();
        if (amount == 0) revert GasManagerAmountMustBeGreaterThanZero();
        if (bytes(note).length > _MAX_FUND_NOTE_LENGTH) revert GasManagerNoteTooLong();

        nonce = _lastFundingNonceByFundingId[fundingId] + 1;
        fundKey = _getFundKey(fundingId, nonce);
        if (_fundProposals[fundKey].exists) revert GasManagerFundProposalAlreadyExists();
        _lastFundingNonceByFundingId[fundingId] = nonce;

        bytes32 noteHash = keccak256(bytes(note));
        _fundProposals[fundKey] = FundProposal(fundingId, noteHash, to, amount, nonce, false, true);

        if (sponsor != address(0)) {
            _sponsorFundingStorage().sponsorByFundKey[fundKey] = sponsor;
            emit SponsorFundingProposalCreated(fundKey, sponsor, amount);
        }
        emit GasFundProposalCreated(fundingId, nonce, fundKey, to, amount, noteHash, note);

        _castVote(VoteType.FUND_GAS, uint256(fundKey));
        _emitIfApproved(fundKey);
    }

    function voteToFundGasV2(bytes32 fundKey) external {
        FundProposal storage proposal = _fundProposals[fundKey];
        if (!proposal.exists) revert GasManagerFundProposalNotFound();
        if (proposal.executed) revert GasManagerFundProposalAlreadyExecuted();

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (approvedFunds[fundKey]) revert GasManagerFundAlreadyApproved();

        _castVote(VoteType.FUND_GAS, uint256(fundKey));
        _emitIfApproved(fundKey);
    }

    function _emitIfApproved(bytes32 fundKey) private {
        if (!approvedFunds[fundKey]) return;
        FundProposal storage p = _fundProposals[fundKey];
        uint256 executableAt = fundExecutableAt[fundKey];
        uint256 expiresAt = fundExpiresAt[fundKey];
        emit GasFundApproved(p.to, p.amount, fundKey);
        emit GasFundProposalApproved(p.fundingId, p.nonce, fundKey, p.to, p.amount, p.noteHash, executableAt, expiresAt);
        address sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        if (sponsor != address(0)) emit SponsorFundingProposalApproved(fundKey, sponsor, executableAt, expiresAt);
    }

    /// @notice Execute a funding approval by `fundKey` once its delay has passed.
    function executeFundGasV2(bytes32 fundKey) public nonReentrant {
        FundProposal storage proposal = _fundProposals[fundKey];
        if (!proposal.exists) revert GasManagerFundProposalNotFound();
        if (proposal.executed) revert GasManagerFundProposalAlreadyExecuted();
        if (_sponsorFundingStorage().sponsorByFundKey[fundKey] != address(0)) revert SponsorFundingExecutorRequired();
        if (!(isGuardian[msg.sender] || msg.sender == proposal.to)) revert GasManagerOnlyGuardianOrFundedAddress();

        _consumeExecutableFund(fundKey, proposal.amount);
        proposal.executed = true;

        uint256 balanceBefore = address(this).balance;
        (bool success, ) = proposal.to.call{value: proposal.amount}("");
        if (!success) revert GasManagerTransferFailed();
        if (balanceBefore - address(this).balance != proposal.amount) revert GasManagerExactAmountNotTransferred();

        totalGasFunded += proposal.amount;
        emit GasFunded(proposal.to, proposal.amount);
        emit GasFundProposalExecuted(proposal.fundingId, proposal.nonce, fundKey, proposal.to, proposal.amount);
    }

    /// @notice Executes an approved deposit from caFE into the proposal-bound sponsor ledger held by FEeD.
    function executeSponsorFunding(bytes32 fundKey) public nonReentrant {
        FundProposal storage proposal = _fundProposals[fundKey];
        address sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        if (!proposal.exists) revert GasManagerFundProposalNotFound();
        if (proposal.executed) revert GasManagerFundProposalAlreadyExecuted();
        if (sponsor == address(0) || proposal.to != _GAS_SPONSOR) revert InvalidSponsorFundingProposal();
        if (!isGuardian[msg.sender] && msg.sender != sponsor) revert UnauthorizedSponsorFundingExecutor();
        if (!_isContract(_GAS_SPONSOR)) revert GasSponsorUnavailable();

        _consumeExecutableFund(fundKey, proposal.amount);
        proposal.executed = true;

        uint256 managerBalanceBefore = address(this).balance;
        uint256 gasSponsorBalanceBefore = _GAS_SPONSOR.balance;
        IGasSponsorDepository(_GAS_SPONSOR).depositGasCredit{value: proposal.amount}(sponsor);
        if (managerBalanceBefore - address(this).balance != proposal.amount) revert SponsorFundingTransferMismatch();
        uint256 gasSponsorBalanceAfter = _GAS_SPONSOR.balance;
        if (gasSponsorBalanceAfter < gasSponsorBalanceBefore
            || gasSponsorBalanceAfter - gasSponsorBalanceBefore != proposal.amount) revert SponsorFundingTransferMismatch();

        totalGasFunded += proposal.amount;
        emit GasFunded(_GAS_SPONSOR, proposal.amount);
        emit GasFundProposalExecuted(proposal.fundingId, proposal.nonce, fundKey, _GAS_SPONSOR, proposal.amount);
        emit SponsorFundingExecuted(fundKey, sponsor, proposal.amount);
    }

    /// @dev Checks approval, expiry, delay, balance and the outflow cap, then consumes the approval.
    function _consumeExecutableFund(bytes32 fundKey, uint256 amount) private {
        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (!approvedFunds[fundKey]) revert GasManagerFundNotApproved();
        uint256 executableAt = fundExecutableAt[fundKey];
        if (block.timestamp < executableAt) revert ExecutionDelayActive(executableAt);
        if (address(this).balance < amount) revert GasManagerInsufficientBalance();
        _spendOutflow(amount);
        _clearFundApproval(fundKey, false);
    }

    /// @dev Per-period native outflow cap. Never overflows: compares against the remaining headroom.
    function _spendOutflow(uint256 amount) private {
        if (block.timestamp >= outflowPeriodStart + outflowPeriod) {
            outflowPeriodStart = block.timestamp;
            outflowUsed = 0;
        }
        uint256 cap = outflowCap;
        uint256 used = outflowUsed;
        uint256 remaining = used >= cap ? 0 : cap - used;
        if (amount > remaining) revert OutflowCapExceeded(remaining);
        outflowUsed = used + amount;
    }

    // ── Governed Expired Funding Cleanup ──────────────────

    /// @notice Guardian executes a bounded, cursor-based sweep over active approved fund keys.
    function executeExpiredFundCleanup(uint256 maxScans) external nonReentrant {
        if (!isGuardian[msg.sender]) revert GasManagerOnlyGuardian();
        if (!expiredFundCleanupAuthorized) revert GasManagerExpiredFundCleanupNotAuthorized();
        if (!(maxScans > 0 && maxScans <= _MAX_CLEANUP_BATCH_SCAN)) revert GasManagerInvalidCleanupBatchSize();

        uint256 scannedCount = 0;
        uint256 clearedCount = 0;
        while (expiredFundCleanupCursor < _activeApprovedFundKeys.length && scannedCount < maxScans) {
            bytes32 fundKey = _activeApprovedFundKeys[expiredFundCleanupCursor];
            ++scannedCount;
            if (_isFundApprovalExpiredOrInvalid(fundKey)) {
                _clearFundApproval(fundKey, true);
                ++clearedCount;
            } else {
                ++expiredFundCleanupCursor;
            }
        }

        bool completed = expiredFundCleanupCursor >= _activeApprovedFundKeys.length;
        if (completed) {
            expiredFundCleanupAuthorized = false;
            expiredFundCleanupCursor = 0;
        }
        emit ExpiredFundCleanupExecuted(scannedCount, clearedCount, expiredFundCleanupCursor, completed);
    }

    // ── Token Burns ───────────────────────────────────────

    function voteToBurnTokens(address tokenAddress, uint256 amount) external {
        if (tokenAddress == address(0)) revert GasManagerInvalidTokenAddress();
        if (amount == 0) revert GasManagerAmountMustBeGreaterThanZero();
        bytes32 burnKey = keccak256(abi.encodePacked(tokenAddress, amount));
        _castVote(VoteType.BURN_TOKENS, uint256(burnKey));
        Approval storage a = _burnApprovals[burnKey];
        if (_burnValid(a)) emit TokenBurnApproved(tokenAddress, amount, burnKey, a.executableAt, a.expiresAt);
    }

    function executeTokenBurn(address tokenAddress, uint256 amount) public nonReentrant {
        if (!isGuardian[msg.sender]) revert GasManagerOnlyGuardian();
        _consumeBurn(keccak256(abi.encodePacked(tokenAddress, amount)));
        IERC20 token = IERC20(tokenAddress);
        if (token.balanceOf(address(this)) < amount) revert GasManagerInsufficientBalance();
        if (!token.transfer(_DEAD_ADDRESS, amount)) revert GasManagerTokenBurnFailed();
        emit TokenBurned(tokenAddress, amount);
    }

    // ── Native Coin Burns ─────────────────────────────────

    function voteToBurnNativeCoin(uint256 amount) external {
        if (amount == 0) revert GasManagerAmountMustBeGreaterThanZero();
        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", amount));
        _castVote(VoteType.BURN_NATIVE_COIN, uint256(coinBurnKey));
        Approval storage a = _burnApprovals[coinBurnKey];
        if (_burnValid(a)) emit CoinBurnApproved(amount, coinBurnKey, a.executableAt, a.expiresAt);
    }

    function executeCoinBurn(uint256 amount) public nonReentrant {
        if (!isGuardian[msg.sender]) revert GasManagerOnlyGuardian();
        _consumeBurn(keccak256(abi.encodePacked("nativeBurn", amount)));
        if (address(this).balance < amount) revert GasManagerInsufficientBalance();
        _spendOutflow(amount);
        (bool success, ) = payable(_DEAD_ADDRESS).call{value: amount}("");
        if (!success) revert GasManagerBurnFailed();
        emit NativeCoinBurned(amount);
    }

    function _burnValid(Approval storage a) private view returns (bool) {
        return a.expiresAt != 0 && block.timestamp <= a.expiresAt && a.epoch == GovernanceVotes.state().epoch;
    }

    function _consumeBurn(bytes32 burnKey) private {
        Approval storage a = _burnApprovals[burnKey];
        if (!_burnValid(a)) revert GasManagerBurnNotApproved();
        if (block.timestamp < a.executableAt) revert ExecutionDelayActive(a.executableAt);
        delete _burnApprovals[burnKey];
    }

    // ── Expired Tally Cleanup ─────────────────────────────

    /// @notice Anyone may clear an expired ballot; no membership or approval changes.
    function resetExpiredTally(VoteType voteType, uint256 target) external {
        GovernanceVotes.resetExpired(GovernanceVotes.state(), _voteKey(voteType, target));
        emit VoteTallyReset(voteType, target);
    }

    receive() external payable {}

    // ── Internal Funding Approval Helpers ─────────────────

    function _approvalWindow() private view returns (uint256 executableAt, uint256 expiresAt) {
        executableAt = block.timestamp + executionDelay;
        expiresAt = executableAt + fundApprovalWindow;
    }

    function _approveFundKey(bytes32 fundKey) private {
        (uint256 executableAt, uint256 expiresAt) = _approvalWindow();
        approvedFunds[fundKey] = true;
        fundExecutableAt[fundKey] = executableAt;
        fundExpiresAt[fundKey] = expiresAt;
        if (_activeApprovedFundKeyIndexPlusOne[fundKey] == 0) {
            _activeApprovedFundKeys.push(fundKey);
            _activeApprovedFundKeyIndexPlusOne[fundKey] = _activeApprovedFundKeys.length;
        }
        emit FundApprovalWindowSet(fundKey, executableAt, expiresAt);
    }

    function _clearFundApproval(bytes32 fundKey, bool expiredOrInvalid) private {
        approvedFunds[fundKey] = false;
        fundExecutableAt[fundKey] = 0;
        fundExpiresAt[fundKey] = 0;
        _removeActiveApprovedFundKey(fundKey);
        emit FundApprovalCleared(fundKey, expiredOrInvalid);
    }

    function _clearFundApprovalIfExpiredOrInvalid(bytes32 fundKey) private {
        if (_isFundApprovalExpiredOrInvalid(fundKey)) _clearFundApproval(fundKey, true);
    }

    function _isFundApprovalExpiredOrInvalid(bytes32 fundKey) private view returns (bool) {
        if (!approvedFunds[fundKey]) return false;
        uint256 expiresAt = fundExpiresAt[fundKey];
        return expiresAt == 0 || block.timestamp > expiresAt;
    }

    function _removeActiveApprovedFundKey(bytes32 fundKey) private {
        uint256 indexPlusOne = _activeApprovedFundKeyIndexPlusOne[fundKey];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _activeApprovedFundKeys.length - 1;
        if (index != lastIndex) {
            bytes32 movedKey = _activeApprovedFundKeys[lastIndex];
            _activeApprovedFundKeys[index] = movedKey;
            _activeApprovedFundKeyIndexPlusOne[movedKey] = index + 1;
        }
        _activeApprovedFundKeys.pop();
        delete _activeApprovedFundKeyIndexPlusOne[fundKey];
        if (expiredFundCleanupCursor > _activeApprovedFundKeys.length) {
            expiredFundCleanupCursor = _activeApprovedFundKeys.length;
        }
    }

    // ── Utilities ─────────────────────────────────────────

    function _sponsorFundingStorage() private pure returns (SponsorFundingStorage storage state) {
        bytes32 location = _SPONSOR_FUNDING_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }

    /// @dev Converts a short string (1-32 bytes) to a left-aligned bytes32 (ethers.encodeBytes32String).
    function _stringToBytes32(string calldata str) internal pure returns (bytes32 result) {
        bytes calldata b = bytes(str);
        if (!(b.length > 0 && b.length <= 32)) revert GasManagerStringMustBe132Bytes();
        assembly ("memory-safe") {
            result := calldataload(b.offset)
            let shift := shl(3, sub(32, b.length))
            result := and(result, shl(shift, shr(shift, not(0))))
        }
    }

    function _isContract(address addr) internal view returns (bool) {
        return addr.code.length > 0;
    }
}
