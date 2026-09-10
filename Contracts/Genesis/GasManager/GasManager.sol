// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   _____          __  ___
  / ___/__ ______/  |/  /__ ____  ___ ____ ____ ____
 / (_ / _ `( -< / /|_/ / _ `/ _ \/ _ `/ _ `/ -_) __/
 \___/\_,_/___//_/  /_/\_,_/_//_/\_,_/\_, /\_ /_/
                                     /___/ By: CryftCreator

    Version 2.5 — Production Gas Manager  [UPGRADEABLE]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  Gas beneficiary — voter-governed funding & burns.   │
  │  2/3 supermajority quorum for all state changes.     │
  │  Approved voter changes invalidate pending ballots.│
  │  Own voter set with pluggable external voter         │
  │  contracts via otherVoterContracts[].                │
  │                                                      │
  │  Two-phase operations:                               │
  │    vote → approve → execute (guardian-gated).        │
  │    Applies to: gas funding, token burns,             │
  │    native coin burns.                                │
  │                                                      │
  │  Funding V1 (legacy):                                │
  │    fundKey = keccak256(abi.encodePacked(to, amount)) │
  │                                                      │
  │  Funding V2:                                         │
  │    Proposal identity = fundingId + nonce             │
  │    fundKey = keccak256(abi.encode(fundingId, nonce)) │
  │    Clear-text note emitted on proposal creation      │
  │    noteHash stored on-chain                          │
  │                                                      │
  │  Sponsor funding:                                    │
  │    caFE deposits approved funds into FEeD            │
  │    Sponsor address is bound before voting begins     │
  │    Generic transfer execution is blocked             │
  │                                                      │
  │  Shared approval expiry model:                       │
  │    approvalBlock + thresholdAtApproval               │
  │    Threshold changes affect only future approvals    │
  │                                                      │
  │  Expired funding cleanup:                            │
  │    Voter authorizes sweep                            │
  │    Guardian executes bounded cleanup batches         │
  │                                                      │
  │  Guardian management:                                │
  │    Add/remove individual guardians, or clear all     │
  │    via voteToClearGuardians(). Enumerable via        │
  │    getGuardians() / getGuardianCount().              │
  │                                                      │
  │  V2 public API uses string fundingId (≤ 32 bytes).   │
  │    On-chain _stringToBytes32 conversion to bytes32.  │
  │    Matches ethers.encodeBytes32String() encoding.    │
  │    bytes32 fundingId logic is internal only.         │
  │                                                      │
  │  Upgradeability notes:                               │
  │    Existing storage order is preserved.              │
  │    Old storage slots are not reordered.              │
  │    approvedFunds safely serves both V1 and V2 keys.  │
  │                                                      │
  │  Direct funds use .call; sponsor funds use depositFor│
  │  ReentrancyGuard on all execute functions.           │
  └──────────────────────────────────────────────────────┘
*/

import "../Governance/GovernanceMembers.sol";
import "../Governance/GovernanceVotes.sol";

import "../Upgradeable/ReentrancyGuardUpgradeable.sol";
import "../Upgradeable/Initializable.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IVoterChecker {
    function isVoter(address potentialVoter) external view returns (bool);
    function getVoters() external view returns (address[] memory);
}

interface IGasSponsorDepository {
    function depositFor(address sponsor) external payable;
}

contract GasManager is Initializable, ReentrancyGuardUpgradeable {
    error GasManagerAlreadyAGuardian();
    error GasManagerAmountMustBeGreaterThanZero();
    error GasManagerBurnFailed();
    error GasManagerBurnNotApproved();
    error GasManagerCoinBurnNotApproved();
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

    uint256 public voteTallyBlockThreshold;
    uint256 public totalGasFunded;
    uint256 private __legacyActiveVoteCount; // Slot retained; use activeVoteCount().

    address[] public votersArray;
    address[] public otherVoterContracts;
    address[] public guardiansArray;

    mapping(address => bool) public isGuardian;
    mapping(VoteType => mapping(uint256 => VoteTally)) private _voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool))) private __legacyHasVoted;
    mapping(bytes32 => bool) public approvedBurns;

    // Existing storage slot retained in-place.
    // Expanded safely to represent approval state for BOTH V1 and V2 funding keys.
    mapping(bytes32 => bool) public approvedFunds;

    mapping(bytes32 => bool) public approvedCoinBurns;

    address constant _DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address constant _GAS_SPONSOR = 0x000000000000000000000000000000000000FEeD;

    // ── Appended Storage (safe append-only upgrade) ────────────────────────

    struct FundProposal {
        bytes32 fundingId;
        bytes32 noteHash;
        address payable to;
        uint256 amount;
        uint256 nonce;
        bool executed;
        bool exists;
    }

    /// @custom:storage-location erc7201:dakota.storage.GasManagerSponsorFunding
    struct SponsorFundingStorage {
        mapping(bytes32 => address) sponsorByFundKey;
    }

    bytes32 private constant _SPONSOR_FUNDING_STORAGE_LOCATION =
        0x2a467852670f144839bf1fd02ad0393580187791ab471304d92161a3bee88100;

    // V2 proposals keyed by fundKey = keccak256(abi.encode(fundingId, nonce))
    mapping(bytes32 => FundProposal) private _fundProposals;

    // Last nonce used for each funding id.
    mapping(bytes32 => uint256) private _lastFundingNonceByFundingId;

    // Shared approval expiry model for BOTH V1 and V2
    uint256 public fundApprovalBlockThreshold;
    mapping(bytes32 => uint256) public fundApprovalBlock;
    mapping(bytes32 => uint256) public fundApprovalThresholdAtApproval;

    // Enumerable active approved fund keys for governed stale-expiry sweeps
    bytes32[] private _activeApprovedFundKeys;
    mapping(bytes32 => uint256) private _activeApprovedFundKeyIndexPlusOne;

    // Governed cleanup authorization state
    bool public expiredFundCleanupAuthorized;
    uint256 public expiredFundCleanupCursor;

    uint256 private constant _MAX_FUND_NOTE_LENGTH = 280;
    uint256 private constant _MAX_CLEANUP_BATCH_SCAN = 500;

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
        UPDATE_FUND_APPROVAL_BLOCK_THRESHOLD,
        AUTHORIZE_EXPIRED_FUND_CLEANUP,
        REFRESH_VOTERS,
        SET_VOTER_CONFIGURATION
    }

    struct VoteTally {
        uint256 totalVotes;
        uint256 startVoteBlock;
        address[] voters;
    }

    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    event VoteTallyReset(VoteType voteType, uint256 target);
    event StateChanged(VoteType voteType, uint256 newValue);

    event GasFunded(address indexed to, uint256 amount);
    event TokenBurned(address indexed tokenAddress, uint256 amount);
    event NativeCoinBurned(uint256 amount);
    event GuardianUpdated(address indexed target, bool added);
    event GuardiansCleared(uint256 count);
    event VoterUpdated(address indexed target, bool added);
    event OtherVoterContractUpdated(address indexed target, bool added);
    event VoteTallyBlockThresholdUpdated(uint256 newThreshold);
    event FundApprovalBlockThresholdUpdated(uint256 newThreshold);

    event TokenBurnApproved(address indexed tokenAddress, uint256 amount, bytes32 burnKey);
    event GasFundApproved(address indexed to, uint256 amount, bytes32 fundKey);
    event CoinBurnApproved(uint256 amount, bytes32 coinBurnKey);

    event FundApprovalWindowSet(
        bytes32 indexed fundKey,
        uint256 approvalBlock,
        uint256 thresholdAtApproval
    );

    event FundApprovalCleared(
        bytes32 indexed fundKey,
        bool expiredOrInvalid
    );

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
        uint256 approvalBlock,
        uint256 thresholdAtApproval
    );

    event GasFundProposalExecuted(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount
    );

    event SponsorFundingProposalCreated(
        bytes32 indexed fundKey,
        address indexed sponsor,
        uint256 amount
    );

    event SponsorFundingProposalApproved(
        bytes32 indexed fundKey,
        address indexed sponsor,
        uint256 approvalBlock,
        uint256 thresholdAtApproval
    );

    event SponsorFundingExecuted(
        bytes32 indexed fundKey,
        address indexed sponsor,
        uint256 amount
    );

    event ExpiredFundCleanupAuthorized(uint256 activeApprovedFundCount);
    event ExpiredFundCleanupExecuted(
        uint256 scannedCount,
        uint256 clearedCount,
        uint256 nextCursor,
        bool completed
    );

    modifier onlyVoters() {
        if (!isVoter(msg.sender)) revert GasManagerOnlyVotersCanCallThisFunction();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize() public virtual initializer {
        _initializeVoter(msg.sender);
    }

    /// @notice Atomic proxy/factory setup with an explicit usable governance identity.
    function initializeWithVoter(address initialVoter) external initializer {
        _initializeVoter(initialVoter);
    }

    function _initializeVoter(address initialVoter) private {
        if (initialVoter == address(0) || initialVoter == address(this)
            || initialVoter == 0x0000000000000000000000000000000000FacAdE) revert GovernanceVotes.SelfAdministration();
        __ReentrancyGuard_init();
        votersArray.push(initialVoter);
        voteTallyBlockThreshold = 1000;
        fundApprovalBlockThreshold = 1000;
    }

    /// @notice Upgrade initializer for already-deployed instances upgrading from older versions.
    ///         Safe to call once after upgrade if `fundApprovalBlockThreshold` was never set.
    function initializeV2() public reinitializer(2) {
        if (fundApprovalBlockThreshold == 0) {
            fundApprovalBlockThreshold = 1000;
        }
    }

    // ── Voter Queries ─────────────────────────────────────

    function isVoter(address potentialVoter) public view returns (bool) {
        return GovernanceMembers.contains(getVoters(), potentialVoter);
    }

    function getVoters() public view returns (address[] memory) {
        if (GovernanceVotes.state().votersInitialized) return GovernanceVotes.state().approvedVoters;
        return _readVoters();
    }

    /// @notice Returns the total number of unique voters (local + external).
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
        returns (uint256 totalVotes, uint256 startVoteBlock, uint256 voteExpirationBlock, address[] memory votedAddresses)
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
    function hasVoted(VoteType voteType, uint256 target, address voter) external view returns (bool) {
        return GovernanceVotes.voted(GovernanceVotes.state(), _voteKey(voteType, target), voter);
    }
    function _voteKey(VoteType voteType, uint256 target) private pure returns (bytes32) {
        return keccak256(abi.encode(voteType, target));
    }
    function _changesVoters(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.REFRESH_VOTERS || voteType == VoteType.SET_VOTER_CONFIGURATION
            || voteType == VoteType.ADD_VOTER || voteType == VoteType.REMOVE_VOTER
            || voteType == VoteType.ADD_OTHER_VOTER_CONTRACT || voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT;
    }

    function getSupermajorityThreshold() public view returns (uint256) {
        uint256 totalVoterCount = getVoterCount();
        if (totalVoterCount <= 0) revert GasManagerNoVotersAvailable();
        return (totalVoterCount * 2 + 2) / 3;
    }

    // ── Balance Queries ───────────────────────────────────

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address tokenAddress)
        public
        view
        returns (uint256)
    {
        IERC20 token = IERC20(tokenAddress);
        return token.balanceOf(address(this));
    }

    // ── Shared Funding Approval Queries ───────────────────

    function getFundApprovalStatus(bytes32 fundKey)
        public
        view
        returns (
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid,
            bool inActiveSet
        )
    {
        approved = approvedFunds[fundKey];
        approvalBlockNumber = fundApprovalBlock[fundKey];
        thresholdAtApproval = fundApprovalThresholdAtApproval[fundKey];
        expiredOrInvalid = _isFundApprovalExpiredOrInvalid(fundKey);
        inActiveSet = _activeApprovedFundKeyIndexPlusOne[fundKey] != 0;
    }

    function getActiveApprovedFundKeyCount() public view returns (uint256) {
        return _activeApprovedFundKeys.length;
    }

    function getActiveApprovedFundKeys(uint256 start, uint256 count)
        public
        view
        returns (bytes32[] memory keys)
    {
        if (!(start < _activeApprovedFundKeys.length || _activeApprovedFundKeys.length == 0)) revert GasManagerStartOutOfRange();

        uint256 len = _activeApprovedFundKeys.length;
        if (start >= len) {
            return new bytes32[](0);
        }

        uint256 end = start + count;
        if (end > len) {
            end = len;
        }

        keys = new bytes32[](end - start);
        uint256 out = 0;
        for (uint256 i = start; i < end; i++) {
            keys[out] = _activeApprovedFundKeys[i];
            out++;
        }
    }

    function lastFundingNonceByFundingId(string calldata fundingId) public view returns (uint256) {
        return _lastFundingNonceByFundingId[_stringToBytes32(fundingId)];
    }

    // ── V1 Legacy Funding Queries ─────────────────────────

    function getLegacyFundKey(address to, uint256 amount) public pure returns (bytes32) {
        if (to == address(0)) revert GasManagerInvalidRecipientAddress();
        if (amount <= 0) revert GasManagerAmountMustBeGreaterThanZero();
        return keccak256(abi.encodePacked(to, amount));
    }

    function getLegacyFundApprovalStatus(address to, uint256 amount)
        public
        view
        returns (
            bytes32 fundKey,
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid,
            bool inActiveSet
        )
    {
        fundKey = getLegacyFundKey(to, amount);
        (
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid,
            inActiveSet
        ) = getFundApprovalStatus(fundKey);
    }

    // ── V2 Funding Queries ────────────────────────────────

    function getNextFundingNonce(string calldata fundingId) public view returns (uint256) {
        bytes32 fid = _stringToBytes32(fundingId);
        return _lastFundingNonceByFundingId[fid] + 1;
    }

    function getFundKey(string calldata fundingId, uint256 nonce) public pure returns (bytes32) {
        return _getFundKey(_stringToBytes32(fundingId), nonce);
    }

    function _getFundKey(bytes32 fundingId, uint256 nonce) internal pure returns (bytes32) {
        if (fundingId == bytes32(0)) revert GasManagerFundingIDShouldNotBeZero();
        if (nonce <= 0) revert GasManagerNonceMustBeGreaterThanZero();
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
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid
        )
    {
        FundProposal storage proposal = _fundProposals[fundKey];
        (
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid,
            /* inActiveSet */
        ) = getFundApprovalStatus(fundKey);

        return (
            proposal.fundingId,
            proposal.nonce,
            proposal.to,
            proposal.amount,
            proposal.noteHash,
            proposal.executed,
            proposal.exists,
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid
        );
    }

    function _getFundProposalByFundingId(bytes32 fundingId, uint256 nonce)
        internal
        view
        returns (
            bytes32 fundKey,
            address to,
            uint256 amount,
            bytes32 noteHash,
            bool executed,
            bool exists,
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid
        )
    {
        fundKey = _getFundKey(fundingId, nonce);
        FundProposal storage proposal = _fundProposals[fundKey];
        (
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid,
            /* inActiveSet */
        ) = getFundApprovalStatus(fundKey);

        return (
            fundKey,
            proposal.to,
            proposal.amount,
            proposal.noteHash,
            proposal.executed,
            proposal.exists,
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid
        );
    }

    function getFundProposalByFundingId(string calldata fundingId, uint256 nonce)
        public
        view
        returns (
            bytes32 fundKey,
            address to,
            uint256 amount,
            bytes32 noteHash,
            bool executed,
            bool exists,
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid
        )
    {
        return _getFundProposalByFundingId(_stringToBytes32(fundingId), nonce);
    }

    /// @notice Fixed GasSponsor proxy that receives governed sponsor deposits.
    function gasSponsor() public pure returns (address) {
        return _GAS_SPONSOR;
    }

    function implementationVersion() public pure returns (string memory) {
        return "2.5.0";
    }

    /// @notice ERC-7201 location used for sponsor-funding proposal bindings.
    function sponsorFundingStorageLocation() public pure returns (bytes32) {
        return _SPONSOR_FUNDING_STORAGE_LOCATION;
    }

    /// @notice Returns the immutable sponsor bound to a funding proposal.
    function getSponsorFundingTarget(bytes32 fundKey)
        public
        view
        returns (address sponsor, bool isSponsorFunding)
    {
        sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        isSponsorFunding = sponsor != address(0);
    }

    // ── Internal Vote Engine ──────────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        address[] memory electorate;
        if (!GovernanceVotes.live(GovernanceVotes.state(), key)) electorate = getVoters();
        if (GovernanceVotes.cast(GovernanceVotes.state(), key, electorate, voteTallyBlockThreshold, msg.sender)) {
            emit StateChanged(voteType, target);

            if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                if (!(target > 0 && target <= 100000)) revert GovernanceVotes.InvalidExpiry();
                voteTallyBlockThreshold = target;
                emit VoteTallyBlockThresholdUpdated(target);
            } else if (voteType == VoteType.UPDATE_FUND_APPROVAL_BLOCK_THRESHOLD) {
                if (!(target > 0 && target <= 100000)) revert GovernanceVotes.InvalidExpiry();
                fundApprovalBlockThreshold = target;
                emit FundApprovalBlockThresholdUpdated(target);
            } else if (voteType == VoteType.AUTHORIZE_EXPIRED_FUND_CLEANUP) {
                expiredFundCleanupAuthorized = true;
                expiredFundCleanupCursor = 0;
                emit ExpiredFundCleanupAuthorized(_activeApprovedFundKeys.length);
            } else {
                address targetAddress = address(uint160(target));

                if (voteType == VoteType.ADD_GUARDIAN) {
                    if (isGuardian[targetAddress]) revert GasManagerAlreadyAGuardian();
                    isGuardian[targetAddress] = true;
                    guardiansArray.push(targetAddress);
                    emit GuardianUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_GUARDIAN) {
                    if (!isGuardian[targetAddress]) revert GasManagerNotAGuardian();
                    isGuardian[targetAddress] = false;
                    for (uint256 i = 0; i < guardiansArray.length; i++) {
                        if (guardiansArray[i] == targetAddress) {
                            guardiansArray[i] = guardiansArray[guardiansArray.length - 1];
                            guardiansArray.pop();
                            break;
                        }
                    }
                    emit GuardianUpdated(targetAddress, false);
                } else if (voteType == VoteType.CLEAR_GUARDIANS) {
                    uint256 count = guardiansArray.length;
                    for (uint256 i = 0; i < count; i++) {
                        isGuardian[guardiansArray[i]] = false;
                    }
                    delete guardiansArray;
                    emit GuardiansCleared(count);
                } else if (voteType == VoteType.ADD_VOTER) {
                    if (isVoter(targetAddress)) revert GovernanceVotes.VoterAlreadyPresent();
                    votersArray.push(targetAddress);
                    emit VoterUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_VOTER) {
                    bool found = false;
                    for (uint256 i = 0; i < votersArray.length; i++) {
                        if (votersArray[i] == targetAddress) {
                            votersArray[i] = votersArray[votersArray.length - 1];
                            votersArray.pop();
                            found = true;
                            break;
                        }
                    }
                    if (!found) revert GovernanceVotes.VoterNotFound();
                    emit VoterUpdated(targetAddress, false);
                } else if (voteType == VoteType.ADD_OTHER_VOTER_CONTRACT) {
                    for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                        if (otherVoterContracts[i] == targetAddress) revert GovernanceVotes.ProviderAlreadyPresent();
                    }
                    otherVoterContracts.push(targetAddress);
                    emit OtherVoterContractUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
                    if (!(votersArray.length > 0 || otherVoterContracts.length > 1)) revert GovernanceVotes.EmptyVoterSet();
                    bool found = false;
                    for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                        if (otherVoterContracts[i] == targetAddress) {
                            otherVoterContracts[i] = otherVoterContracts[otherVoterContracts.length - 1];
                            otherVoterContracts.pop();
                            found = true;
                            break;
                        }
                    }
                    if (!found) revert GovernanceVotes.ProviderNotFound();
                    emit OtherVoterContractUpdated(targetAddress, false);
                }
            }

            if (voteType == VoteType.BURN_TOKENS) {
                approvedBurns[bytes32(target)] = true;
            }

            if (voteType == VoteType.FUND_GAS) {
                _approveFundKey(bytes32(target));
            }

            if (voteType == VoteType.BURN_NATIVE_COIN) {
                approvedCoinBurns[bytes32(target)] = true;
            }

            if (_changesVoters(voteType)) {
                if (voteType == VoteType.SET_VOTER_CONFIGURATION) {

                    GovernanceVotes.Configuration storage config = GovernanceVotes.state().configurations[target];
                    votersArray = config.local;
                    otherVoterContracts = config.providers;
                }
                address[] memory members = _readVoters();
                if (members.length <= 0) revert GovernanceVotes.EmptyVoterSet();
                bytes32 membersHash = keccak256(abi.encode(members));
                if (voteType == VoteType.REFRESH_VOTERS) if (membersHash != bytes32(target)) revert GovernanceVotes.MembershipChanged();
                if (voteType == VoteType.SET_VOTER_CONFIGURATION) {
                    if (membersHash != GovernanceVotes.state().configurations[target].membersHash) revert GovernanceVotes.MembershipChanged();
                    delete GovernanceVotes.state().configurations[target];
                }
                GovernanceVotes.approveVoters(GovernanceVotes.state(), members);
            }
            GovernanceVotes.complete(GovernanceVotes.state(), key);
            if (_changesVoters(voteType)) GovernanceVotes.invalidate(GovernanceVotes.state());
        }
        emit VoteCast(msg.sender, voteType, target);
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
        _castVote(VoteType.ADD_GUARDIAN, uint256(uint160(guardian)));
    }

    function voteToRemoveGuardian(address guardian) external {
        if (guardian == address(0)) revert GasManagerGuardianAddressShouldNotBeZero();
        _castVote(VoteType.REMOVE_GUARDIAN, uint256(uint160(guardian)));
    }

    function voteToClearGuardians() external {
        if (guardiansArray.length <= 0) revert GasManagerNoGuardiansToClear();
        _castVote(VoteType.CLEAR_GUARDIANS, 1);
    }

    function getGuardians() public view returns (address[] memory) {
        return guardiansArray;
    }

    function getGuardianCount() public view returns (uint256) {
        return guardiansArray.length;
    }

    // ── Parameter Governance ──────────────────────────────

    function voteToUpdateVoteTallyBlockThreshold(uint256 newThreshold) external {
        if (!(newThreshold > 0 && newThreshold <= 100000)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD, newThreshold);
    }

    function voteToUpdateFundApprovalBlockThreshold(uint256 newThreshold) external {
        if (!(newThreshold > 0 && newThreshold <= 100000)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.UPDATE_FUND_APPROVAL_BLOCK_THRESHOLD, newThreshold);
    }

    function voteToAuthorizeExpiredFundCleanup() external {
        if (_activeApprovedFundKeys.length <= 0) revert GasManagerNoApprovedFundingsToScan();
        _castVote(VoteType.AUTHORIZE_EXPIRED_FUND_CLEANUP, 1);
    }

    // ── Gas Funding V1 (Legacy) ───────────────────────────

    function voteToFundGasV1(address to, uint256 amount) external {
        if (to == address(0)) revert GasManagerInvalidRecipientAddress();
        if (amount <= 0) revert GasManagerAmountMustBeGreaterThanZero();

        bytes32 fundKey = getLegacyFundKey(to, amount);

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (approvedFunds[fundKey]) revert GasManagerFundAlreadyApproved();

        _castVote(VoteType.FUND_GAS, uint256(fundKey));

        if (approvedFunds[fundKey]) {
            emit GasFundApproved(to, amount, fundKey);
        }
    }

    /// @notice Execute a legacy V1 gas funding approval.
    function executeFundGasV1(address payable to, uint256 amount) public nonReentrant {
        if (!(isGuardian[msg.sender] || msg.sender == to)) revert GasManagerOnlyGuardianOrFundedAddress();

        bytes32 fundKey = getLegacyFundKey(to, amount);

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (!approvedFunds[fundKey]) revert GasManagerFundNotApproved();

        _consumeFundApproval(fundKey);

        if (address(this).balance < amount) revert GasManagerInsufficientBalance();
        if (to == address(0)) revert GasManagerInvalidRecipientAddress();

        uint256 balanceBefore = address(this).balance;

        (bool success, ) = to.call{value: amount}("");
        if (!success) revert GasManagerTransferFailed();

        uint256 balanceAfter = address(this).balance;
        if (balanceBefore - balanceAfter != amount) revert GasManagerExactAmountNotTransferred();

        totalGasFunded += amount;

        emit GasFunded(to, amount);
    }

    // ── Gas Funding V2 ────────────────────────────────────

    function proposeFundGasV2(
        string calldata fundingId,
        address payable to,
        uint256 amount,
        string calldata note
    )
        external
        onlyVoters
        returns (bytes32 fundKey, uint256 nonce)
    {
        return _proposeFundGas(
            _stringToBytes32(fundingId),
            to,
            amount,
            note,
            address(0)
        );
    }

    /// @notice Proposes a governed deposit from caFE into a FEeD sponsor ledger.
    /// @dev The sponsor is bound to the proposal before voting begins and cannot
    ///      be replaced by the executor.
    function proposeSponsorFunding(
        string calldata fundingId,
        address sponsor,
        uint256 amount,
        string calldata note
    )
        external
        onlyVoters
        returns (bytes32 fundKey, uint256 nonce)
    {
        if (sponsor == address(0)) revert InvalidSponsor();
        return _proposeFundGas(
            _stringToBytes32(fundingId),
            payable(_GAS_SPONSOR),
            amount,
            note,
            sponsor
        );
    }

    function _proposeFundGas(
        bytes32 fundingId,
        address payable to,
        uint256 amount,
        string calldata note,
        address sponsor
    )
        internal
        returns (bytes32 fundKey, uint256 nonce)
    {
        if (fundingId == bytes32(0)) revert GasManagerFundingIDShouldNotBeZero();
        if (to == address(0)) revert GasManagerInvalidRecipientAddress();
        if (amount <= 0) revert GasManagerAmountMustBeGreaterThanZero();
        if (bytes(note).length > _MAX_FUND_NOTE_LENGTH) revert GasManagerNoteTooLong();

        nonce = _lastFundingNonceByFundingId[fundingId] + 1;
        fundKey = _getFundKey(fundingId, nonce);

        if (_fundProposals[fundKey].exists) revert GasManagerFundProposalAlreadyExists();

        _lastFundingNonceByFundingId[fundingId] = nonce;

        _fundProposals[fundKey] = FundProposal({
            fundingId: fundingId,
            noteHash: keccak256(bytes(note)),
            to: to,
            amount: amount,
            nonce: nonce,
            executed: false,
            exists: true
        });

        if (sponsor != address(0)) {
            if (to != _GAS_SPONSOR) revert InvalidSponsorFundingProposal();
            _sponsorFundingStorage().sponsorByFundKey[fundKey] = sponsor;
            emit SponsorFundingProposalCreated(fundKey, sponsor, amount);
        }

        emit GasFundProposalCreated(
            fundingId,
            nonce,
            fundKey,
            to,
            amount,
            _fundProposals[fundKey].noteHash,
            note
        );

        _castVote(VoteType.FUND_GAS, uint256(fundKey));

        if (approvedFunds[fundKey]) {
            emit GasFundApproved(to, amount, fundKey);
            emit GasFundProposalApproved(
                fundingId,
                nonce,
                fundKey,
                to,
                amount,
                _fundProposals[fundKey].noteHash,
                fundApprovalBlock[fundKey],
                fundApprovalThresholdAtApproval[fundKey]
            );
            _emitSponsorFundingApproved(fundKey);
        }
    }

    function voteToFundGasV2(bytes32 fundKey) external {
        FundProposal storage proposal = _fundProposals[fundKey];

        if (!proposal.exists) revert GasManagerFundProposalNotFound();
        if (proposal.executed) revert GasManagerFundProposalAlreadyExecuted();

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (approvedFunds[fundKey]) revert GasManagerFundAlreadyApproved();

        _castVote(VoteType.FUND_GAS, uint256(fundKey));

        if (approvedFunds[fundKey]) {
            emit GasFundApproved(proposal.to, proposal.amount, fundKey);
            emit GasFundProposalApproved(
                proposal.fundingId,
                proposal.nonce,
                fundKey,
                proposal.to,
                proposal.amount,
                proposal.noteHash,
                fundApprovalBlock[fundKey],
                fundApprovalThresholdAtApproval[fundKey]
            );
            _emitSponsorFundingApproved(fundKey);
        }
    }

    /// @notice Execute a V2 funding approval by `fundKey` only.
    function executeFundGasV2(bytes32 fundKey) public nonReentrant {
        FundProposal storage proposal = _fundProposals[fundKey];

        if (!proposal.exists) revert GasManagerFundProposalNotFound();
        if (proposal.executed) revert GasManagerFundProposalAlreadyExecuted();
        if (_sponsorFundingStorage().sponsorByFundKey[fundKey] != address(0)) {
            revert SponsorFundingExecutorRequired();
        }
        if (!(isGuardian[msg.sender] || msg.sender == proposal.to)) revert GasManagerOnlyGuardianOrFundedAddress();

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (!approvedFunds[fundKey]) revert GasManagerFundNotApproved();

        _consumeFundApproval(fundKey);
        proposal.executed = true;

        if (address(this).balance < proposal.amount) revert GasManagerInsufficientBalance();
        if (proposal.to == address(0)) revert GasManagerInvalidRecipientAddress();

        uint256 balanceBefore = address(this).balance;

        (bool success, ) = proposal.to.call{value: proposal.amount}("");
        if (!success) revert GasManagerTransferFailed();

        uint256 balanceAfter = address(this).balance;
        if (balanceBefore - balanceAfter != proposal.amount) revert GasManagerExactAmountNotTransferred();

        totalGasFunded += proposal.amount;

        emit GasFunded(proposal.to, proposal.amount);
        emit GasFundProposalExecuted(
            proposal.fundingId,
            proposal.nonce,
            fundKey,
            proposal.to,
            proposal.amount
        );
    }

    // ── Governed Expired Funding Cleanup ──────────────────

    /// @notice Executes an approved deposit from caFE into the proposal-bound
    ///         sponsor ledger held by FEeD.
    function executeSponsorFunding(bytes32 fundKey) public nonReentrant {
        FundProposal storage proposal = _fundProposals[fundKey];
        address sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];

        if (!proposal.exists) revert GasManagerFundProposalNotFound();
        if (proposal.executed) revert GasManagerFundProposalAlreadyExecuted();
        if (sponsor == address(0) || proposal.to != _GAS_SPONSOR) {
            revert InvalidSponsorFundingProposal();
        }
        if (!isGuardian[msg.sender] && msg.sender != sponsor) {
            revert UnauthorizedSponsorFundingExecutor();
        }

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (!approvedFunds[fundKey]) revert GasManagerFundNotApproved();
        if (!_isContract(_GAS_SPONSOR)) revert GasSponsorUnavailable();
        if (address(this).balance < proposal.amount) revert GasManagerInsufficientBalance();

        _consumeFundApproval(fundKey);
        proposal.executed = true;

        uint256 managerBalanceBefore = address(this).balance;
        uint256 gasSponsorBalanceBefore = _GAS_SPONSOR.balance;

        IGasSponsorDepository(_GAS_SPONSOR).depositFor{value: proposal.amount}(
            sponsor
        );

        uint256 managerBalanceAfter = address(this).balance;
        uint256 gasSponsorBalanceAfter = _GAS_SPONSOR.balance;
        if (managerBalanceBefore - managerBalanceAfter != proposal.amount) {
            revert SponsorFundingTransferMismatch();
        }
        if (
            gasSponsorBalanceAfter < gasSponsorBalanceBefore ||
            gasSponsorBalanceAfter - gasSponsorBalanceBefore != proposal.amount
        ) revert SponsorFundingTransferMismatch();

        totalGasFunded += proposal.amount;

        emit GasFunded(_GAS_SPONSOR, proposal.amount);
        emit GasFundProposalExecuted(
            proposal.fundingId,
            proposal.nonce,
            fundKey,
            _GAS_SPONSOR,
            proposal.amount
        );
        emit SponsorFundingExecuted(fundKey, sponsor, proposal.amount);
    }

    /// @notice Guardian executes a bounded sweep over active approved fund keys.
    ///         Removes approvals that are expired or invalid.
    ///         Cursor-based so cleanup can be chunked safely.
    function executeExpiredFundCleanup(uint256 maxScans) external nonReentrant {
        if (!isGuardian[msg.sender]) revert GasManagerOnlyGuardian();
        if (!expiredFundCleanupAuthorized) revert GasManagerExpiredFundCleanupNotAuthorized();
        if (!(maxScans > 0 && maxScans <= _MAX_CLEANUP_BATCH_SCAN)) revert GasManagerInvalidCleanupBatchSize();

        uint256 scannedCount = 0;
        uint256 clearedCount = 0;

        while (
            expiredFundCleanupCursor < _activeApprovedFundKeys.length &&
            scannedCount < maxScans
        ) {
            bytes32 fundKey = _activeApprovedFundKeys[expiredFundCleanupCursor];
            scannedCount++;

            if (_isFundApprovalExpiredOrInvalid(fundKey)) {
                _clearFundApproval(fundKey, true);
                clearedCount++;
            } else {
                expiredFundCleanupCursor++;
            }
        }

        bool completed = expiredFundCleanupCursor >= _activeApprovedFundKeys.length;
        if (completed) {
            expiredFundCleanupAuthorized = false;
            expiredFundCleanupCursor = 0;
        }

        emit ExpiredFundCleanupExecuted(
            scannedCount,
            clearedCount,
            expiredFundCleanupCursor,
            completed
        );
    }

    // ── Token Burns ───────────────────────────────────────

    function voteToBurnTokens(address tokenAddress, uint256 amount) external {
        if (tokenAddress == address(0)) revert GasManagerInvalidTokenAddress();
        if (amount <= 0) revert GasManagerAmountMustBeGreaterThanZero();

        bytes32 burnKey = keccak256(abi.encodePacked(tokenAddress, amount));
        _castVote(VoteType.BURN_TOKENS, uint256(burnKey));

        if (approvedBurns[burnKey]) {
            emit TokenBurnApproved(tokenAddress, amount, burnKey);
        }
    }

    function executeTokenBurn(address tokenAddress, uint256 amount) public nonReentrant {
        if (!isGuardian[msg.sender]) revert GasManagerOnlyGuardian();

        bytes32 burnKey = keccak256(abi.encodePacked(tokenAddress, amount));
        if (!approvedBurns[burnKey]) revert GasManagerBurnNotApproved();
        approvedBurns[burnKey] = false;

        IERC20 token = IERC20(tokenAddress);
        if (token.balanceOf(address(this)) < amount) revert GasManagerInsufficientBalance();
        if (!token.transfer(_DEAD_ADDRESS, amount)) revert GasManagerTokenBurnFailed();

        emit TokenBurned(tokenAddress, amount);
    }

    // ── Native Coin Burns ─────────────────────────────────

    function voteToBurnNativeCoin(uint256 amount) external {
        if (amount <= 0) revert GasManagerAmountMustBeGreaterThanZero();

        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", amount));
        _castVote(VoteType.BURN_NATIVE_COIN, uint256(coinBurnKey));

        if (approvedCoinBurns[coinBurnKey]) {
            emit CoinBurnApproved(amount, coinBurnKey);
        }
    }

    function executeCoinBurn(uint256 amount) public nonReentrant {
        if (!isGuardian[msg.sender]) revert GasManagerOnlyGuardian();

        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", amount));
        if (!approvedCoinBurns[coinBurnKey]) revert GasManagerCoinBurnNotApproved();
        approvedCoinBurns[coinBurnKey] = false;

        if (address(this).balance < amount) revert GasManagerInsufficientBalance();

        (bool success, ) = payable(_DEAD_ADDRESS).call{value: amount}("");
        if (!success) revert GasManagerBurnFailed();

        emit NativeCoinBurned(amount);
    }

    // ── Expired Tally Cleanup ─────────────────────────────

    /// @notice Anyone may clear an expired ballot; no membership or approval changes.
    function resetExpiredTally(VoteType voteType, uint256 target) external {
        GovernanceVotes.resetExpired(GovernanceVotes.state(), _voteKey(voteType, target));
        emit VoteTallyReset(voteType, target);
    }

    receive() external payable {}

    // ── Internal Funding Approval Helpers ─────────────────

    function _approveFundKey(bytes32 fundKey) internal {
        approvedFunds[fundKey] = true;
        fundApprovalBlock[fundKey] = block.number;
        fundApprovalThresholdAtApproval[fundKey] = fundApprovalBlockThreshold;

        _addActiveApprovedFundKey(fundKey);

        emit FundApprovalWindowSet(
            fundKey,
            fundApprovalBlock[fundKey],
            fundApprovalThresholdAtApproval[fundKey]
        );
    }

    function _consumeFundApproval(bytes32 fundKey) internal {
        _clearFundApproval(fundKey, false);
    }

    function _clearFundApproval(bytes32 fundKey, bool expiredOrInvalid) internal {
        approvedFunds[fundKey] = false;
        fundApprovalBlock[fundKey] = 0;
        fundApprovalThresholdAtApproval[fundKey] = 0;

        _removeActiveApprovedFundKey(fundKey);

        emit FundApprovalCleared(fundKey, expiredOrInvalid);
    }

    function _clearFundApprovalIfExpiredOrInvalid(bytes32 fundKey) internal {
        if (_isFundApprovalExpiredOrInvalid(fundKey)) {
            _clearFundApproval(fundKey, true);
        }
    }

    function _isFundApprovalExpiredOrInvalid(bytes32 fundKey) internal view returns (bool) {
        if (!approvedFunds[fundKey]) {
            return false;
        }

        uint256 approvalBlockNumber = fundApprovalBlock[fundKey];
        uint256 thresholdAtApproval = fundApprovalThresholdAtApproval[fundKey];

        if (approvalBlockNumber == 0 || thresholdAtApproval == 0) {
            return true;
        }

        return block.number > approvalBlockNumber + thresholdAtApproval;
    }

    function _addActiveApprovedFundKey(bytes32 fundKey) internal {
        if (_activeApprovedFundKeyIndexPlusOne[fundKey] == 0) {
            _activeApprovedFundKeys.push(fundKey);
            _activeApprovedFundKeyIndexPlusOne[fundKey] = _activeApprovedFundKeys.length;
        }
    }

    function _removeActiveApprovedFundKey(bytes32 fundKey) internal {
        uint256 indexPlusOne = _activeApprovedFundKeyIndexPlusOne[fundKey];
        if (indexPlusOne == 0) {
            return;
        }

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

    function _emitSponsorFundingApproved(bytes32 fundKey) internal {
        address sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        if (sponsor != address(0)) {
            emit SponsorFundingProposalApproved(
                fundKey,
                sponsor,
                fundApprovalBlock[fundKey],
                fundApprovalThresholdAtApproval[fundKey]
            );
        }
    }

    function _sponsorFundingStorage()
        private
        pure
        returns (SponsorFundingStorage storage state)
    {
        bytes32 location = _SPONSOR_FUNDING_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }

    function _containsAddress(
        address[] memory addresses,
        uint256 length,
        address target
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (addresses[i] == target) {
                return true;
            }
        }
        return false;
    }

    /// @dev Converts a short string (1-32 bytes) to a left-aligned bytes32.
    ///      Encoding is identical to ethers.encodeBytes32String().
    function _stringToBytes32(string calldata str) internal pure returns (bytes32 result) {
        bytes calldata b = bytes(str);
        if (!(b.length > 0 && b.length <= 32)) revert GasManagerStringMustBe132Bytes();
        // Left-align: copy bytes into the high-order end of a 32-byte word.
        // Unused trailing bytes remain zero — matching ethers.encodeBytes32String().
        assembly ("memory-safe") {
            result := calldataload(b.offset)
            // Mask off any garbage past the string length.
            let shift := shl(3, sub(32, b.length))
            result := and(result, shl(shift, shr(shift, not(0))))
        }
        return result;
    }

    function _isContract(address addr) internal view returns (bool) {
        uint32 size;
        assembly ("memory-safe") {
            size := extcodesize(addr)
        }
        return (size > 0);
    }
}
