// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity 0.8.37;

/*
   _____        __    __  ___
  / ___/__  ___/ /__ /  |/  /__ ____  ___ ____ ____ ____
 / /__/ _ \/ _  / -_) /|_/ / _ `/ _ \/ _ `/ _ `/ -_) __/
 \___/\___/\_,_/\__/_/  /_/\_,_/_//_/\_,_/\_, /\__/_/
                                         /___/ By: CryftCreator

  Version 3.1 — Production Code Manager  [UPGRADEABLE]

  ┌──────────────── Contract Architecture ──────────────────────────┐
  │                                                                 │
  │  PUBLIC REGISTRY + PENTE ROUTER                                 │
  │                                                                 │
  │  Gift-authorized canonical unique ID registry.                     │
  │  Fee-based registration, deterministic IDs via                  │
  │  keccak256(address(this), giftContract, chainId)                │
  │  + incrementing counter.                                        │
  │                                                                 │
  │  2/3 supermajority quorum for all state changes.                │
  │  Ballot windows in block.timestamp seconds (default 7 days).    │
  │  Privacy groups are authorized per gift only, in a per-group    │
  │  epoch; deauthorizing a group voids all of its grants.          │
  │  Deliveries require MIN_DELIVERY_GAS and forward exactly        │
  │  DELIVERY_GAS_LIMIT. Setup only through the proxy link.         │
  │  Approved voter changes invalidate pending ballots.           │
  │  Own voter set with pluggable external voter                    │
  │  contracts via otherVoterContracts[].                           │
  │                                                                 │
  │  PENTE INTEGRATION:                                             │
  │  Authorized Pente privacy groups call the                       │
  │  router functions, which resolve UIDs to gift                   │
  │  contracts and forward via IRedeemable:                         │
  │    • recordRedemption(uid, redeemer)                            │
  │      Marks UID terminally redeemed then routes to gift          │
  │      contract via try/catch. Gift contract failures             │
  │      emit RedemptionFailed — no Pente rollback.                 │
  │    • setUniqueIdActiveBatch(uids, states)                       │
  │      Mirrors private active-state changes publicly.             │
  │      Only UIDs whose mirror is enabled in ComboStorage          │
  │      reach this function.                                       │
  │    • validateUniqueIdsOrRevert(uids)                            │
  │      Confirms UIDs are registered before private storage.       │
  │                                                                 │
  │  CodeManager stores sparse public UID status only.              │
  │  Newly registered UIDs inherit DEFAULT_ACTIVE_STATE             │
  │  with no per-UID write at registration time.                    │
  │  Only deviations from that default consume storage.             │
  │  A missing override (USE_DEFAULT_ACTIVE_STATE) means            │
  │  no public deviation is recorded — for privacy-managed          │
  │  redeemables, the active/frozen state may be managed            │
  │  privately by PrivateComboStorage with mirroring                │
  │  disabled, so absence of public state does not imply            │
  │  the UID is active on the private execution side.               │
  │                                                                 │
  │  The gift contract remains the authority on                     │
  │  redemption finality (already redeemed, vault                   │
  │  ownership transfer, etc.).                                     │
  │                                                                 │
  │  Patent: U.S. App. Ser. No. 18/930,857                          │
  └─────────────────────────────────────────────────────────────────┘
*/

import "../Genesis/Governance/GovernanceMembers.sol";
import "../Genesis/Governance/GovernanceVotes.sol";

import "../Genesis/Upgradeable/Utils/StringsUpgradeable.sol";
import "../Genesis/Upgradeable/Initializable.sol";
import "../Genesis/Upgradeable/ReentrancyGuardUpgradeable.sol";

import "./Interfaces/ICodeManager.sol";
import "./CanonicalUid.sol";
import "./Interfaces/IRedeemable.sol";

contract CodeManager is Initializable, ReentrancyGuardUpgradeable, ICodeManager {
    // No explicit public override stored for this UID. This currently resolves
    // to DEFAULT_ACTIVE_STATE in CodeManager. For privacy-managed redeemables,
    // callers should interpret that absence of public state as "no public
    // override recorded" rather than proof that no private active/frozen rules
    // exist off-chain or inside the private contract flow.
    enum UniqueIdStatus {
        USE_DEFAULT_ACTIVE_STATE,
        INACTIVE,
        REDEEMED
    }

    enum VoteType {
        UPDATE_REGISTRATION_FEE,
        UPDATE_FEE_VAULT,
        ADD_VOTER,
        REMOVE_VOTER,
        ADD_OTHER_VOTER_CONTRACT,
        REMOVE_OTHER_VOTER_CONTRACT,
        UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
        DEAUTHORIZE_PRIVACY_GROUP,
        REFRESH_VOTERS,
        SET_VOTER_CONFIGURATION,
        SET_PRIVACY_GROUP_GIFT
    }

    struct GroupGiftChange { address group; address gift; bool allowed; uint256 epoch; }
    struct Delivery { address recipient; bool delivered; uint256 attempts; }

    error InsufficientDeliveryGas();
    error RegistrationFeeTooHigh();
    error InitializerNotLinkGuardian();

    address[] public votersArray;
    address[] public otherVoterContracts;
    uint256 private __reserved2;

    uint256 public registrationFee;
    /// @dev Ballot window in SECONDS (name kept from the block-count era; slot unchanged).
    uint256 public voteTallyBlockThreshold;
    address public feeVault;

    /// @dev Default active state applied to every valid UID unless an override exists.
    bool public constant DEFAULT_ACTIVE_STATE = true;

    mapping(string => uint256) private _identifierCounter;
    mapping(string => ContractData) private _contractIdentifierToData;
    mapping(bytes32 => UniqueIdStatus) private _uniqueIdStatuses;

    /// @dev A group with at least one gift grant in its current epoch; access is always per gift.
    mapping(address => bool) public isAuthorizedPrivacyGroup;
    mapping(address => mapping(address => bool)) public registrationOperators;
    /// @notice Bumped on every deauthorization, so earlier gift grants never come back (X-21).
    mapping(address => uint256) public privacyGroupEpoch;
    mapping(bytes32 => bool) private _groupGiftGrants;
    mapping(uint256 => GroupGiftChange) private _groupGiftChanges;
    mapping(bytes32 => Delivery) private _deliveries;

    uint256 public constant MAX_STATUS_BATCH = 100;
    uint256 public constant DELIVERY_GAS_LIMIT = 1000000;
    /// @notice Gas a delivery needs on entry: the forwarded limit after the 63/64 rule plus room to record it (X-22).
    uint256 public constant MIN_DELIVERY_GAS = DELIVERY_GAS_LIMIT * 64 / 63 + 100000;
    /// @notice Upper bound on the per-code registration fee (X-64).
    uint256 public constant MAX_REGISTRATION_FEE = 1 ether;
    uint256 public constant DEFAULT_VOTE_WINDOW = 7 days;
    uint256 private constant _PROBE_GAS = 100000;

    event RegistrationOperatorUpdated(address indexed gift, address indexed operator, bool allowed);
    event PrivacyGroupGiftUpdated(address indexed group, address indexed gift, bool allowed, uint256 epoch);
    event PrivacyGroupGiftChangeStale(address indexed group, address indexed gift, uint256 epoch);
    event PrivacyGroupDeauthorized(address indexed group, uint256 newEpoch);
    event RedemptionDeliveryAttempt(string uniqueId, address indexed recipient, uint256 attempt, bool delivered);
    event RegistrationFeeUpdated(uint256 newFee);
    event FeeVaultUpdated(address indexed newFeeVault);
    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    event VoteTallyReset(VoteType voteType, uint256 target);
    event UniqueIdsRegistered(address indexed giftContract, string chainId, uint256 quantity);
    event VoterUpdated(address indexed target, bool added);
    event VotersInitialized(address[] voters);
    event OtherVoterContractUpdated(address indexed target, bool added);
    event VoterConfigurationApplied(bytes32 indexed membersHash);
    event VoteTallyBlockThresholdUpdated(uint256 newWindowSeconds);
    event RedemptionRouted(string uniqueId, address indexed giftContract, address indexed redeemer);
    event RedemptionFailed(string uniqueId, address indexed giftContract, address indexed redeemer, string reason);
    event RedemptionRejected(string uniqueId, address indexed redeemer, string reason);
    event UniqueIdActiveStatusUpdated(string uniqueId, bool active, bool usesDefaultState);
    event UniqueIdRedeemed(string uniqueId);
    event UniqueIdActiveStatusRejected(uint256 index, string uniqueId, string reason);

    constructor() {
        _disableInitializers();
    }

    modifier onlyVoters() {
        require(isVoter(msg.sender), "Only voters can call this function");
        _;
    }

    modifier onlyAuthorizedPrivacyGroup() {
        require(isAuthorizedPrivacyGroup[msg.sender], "Caller is not an authorized privacy group");
        _;
    }

    // ── Initialization ────────────────────────────────────

    /// @notice One-time setup, passed as the proxy link's init data (X-16). Only a guardian of the
    ///         hosting proxy may run it, so an empty-data link cannot be front-run. Takes the full
    ///         initial voter list (1..64 distinct voters, X-5).
    function initializeWithVoters(address[] calldata voters) external initializer {
        _requireLinkGuardian();
        __ReentrancyGuard_init();
        if (voters.length == 0) revert GovernanceVotes.NoVoters();
        address[] memory members = GovernanceMembers.collect(voters, new address[](0), bytes4(keccak256("getVoters()")));
        if (members.length != voters.length) revert GovernanceVotes.VoterAlreadyPresent();
        votersArray = voters;
        GovernanceVotes.approveVoters(GovernanceVotes.state(), members);
        registrationFee = 10**15;
        voteTallyBlockThreshold = DEFAULT_VOTE_WINDOW;
        emit VotersInitialized(voters);
    }

    /// @dev The caller must be a guardian of the proxy this code runs in.
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
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount * 2 + 2) / 3;
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
            || voteType == VoteType.DEAUTHORIZE_PRIVACY_GROUP;
    }

    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        GovernanceVotes.State storage s = GovernanceVotes.state();
        address[] memory electorate;
        if (!GovernanceVotes.live(s, key)) electorate = getVoters();
        if (GovernanceVotes.cast(s, key, electorate, voteTallyBlockThreshold, msg.sender, _isExempt(voteType))) {
            if (_changesVoters(voteType)) _applyVoterVote(voteType, target);
            else if (voteType == VoteType.SET_PRIVACY_GROUP_GIFT || voteType == VoteType.DEAUTHORIZE_PRIVACY_GROUP)
                _applyGroupVote(voteType, target);
            else _applyParameterVote(voteType, target);
            GovernanceVotes.complete(s, key);
            if (_changesVoters(voteType)) GovernanceVotes.invalidate(s);
        }
        emit VoteCast(msg.sender, voteType, target);
    }

    function _applyParameterVote(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.UPDATE_REGISTRATION_FEE) {
            if (target > MAX_REGISTRATION_FEE) revert RegistrationFeeTooHigh();
            registrationFee = target;
            emit RegistrationFeeUpdated(target);
        } else if (voteType == VoteType.UPDATE_FEE_VAULT) {
            feeVault = address(uint160(target));
            emit FeeVaultUpdated(feeVault);
        } else {
            if (!GovernanceVotes.validWindow(target)) revert GovernanceVotes.InvalidExpiry();
            voteTallyBlockThreshold = target;
            emit VoteTallyBlockThresholdUpdated(target);
        }
    }

    function _applyGroupVote(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.DEAUTHORIZE_PRIVACY_GROUP) {
            address group = address(uint160(target));
            isAuthorizedPrivacyGroup[group] = false;
            uint256 epoch = ++privacyGroupEpoch[group];
            emit PrivacyGroupDeauthorized(group, epoch);
            return;
        }
        GroupGiftChange memory change = _groupGiftChanges[target];
        delete _groupGiftChanges[target];
        if (change.epoch != privacyGroupEpoch[change.group]) {
            // The group was deauthorized while this ballot was open: never apply it to the new epoch.
            emit PrivacyGroupGiftChangeStale(change.group, change.gift, change.epoch);
            return;
        }
        _groupGiftGrants[_grantKey(change.group, change.epoch, change.gift)] = change.allowed;
        if (change.allowed) isAuthorizedPrivacyGroup[change.group] = true;
        emit PrivacyGroupGiftUpdated(change.group, change.gift, change.allowed, change.epoch);
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

    /// @dev Swap-and-pop removal; voter and provider arrays are bounded at 64 / 16 entries.
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

    // ── Governance Entry Points ───────────────────────────

    /// @notice Per-code registration fee in wei (1 .. MAX_REGISTRATION_FEE).
    function voteToUpdateRegistrationFee(uint256 newFee) external {
        if (newFee > MAX_REGISTRATION_FEE) revert RegistrationFeeTooHigh();
        _castVote(VoteType.UPDATE_REGISTRATION_FEE, newFee);
    }

    function voteToUpdateFeeVault(address newFeeVault) external {
        require(newFeeVault != address(0), "Fee vault address should not be zero");
        _castVote(VoteType.UPDATE_FEE_VAULT, uint256(uint160(newFeeVault)));
    }

    /// @notice Ballot window in seconds (1 hour .. 30 days).
    function voteToUpdateVoteTallyBlockThreshold(uint256 newWindowSeconds) external {
        if (!GovernanceVotes.validWindow(newWindowSeconds)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD, newWindowSeconds);
    }

    /// @notice Revoke every gift grant of a group at once: its epoch advances, so a later grant
    ///         starts from an empty scope.
    function voteToDeauthorizePrivacyGroup(address privacyGroup) external {
        require(privacyGroup != address(0), "Privacy group address cannot be zero");
        _castVote(VoteType.DEAUTHORIZE_PRIVACY_GROUP, uint256(uint160(privacyGroup)));
    }

    /// @notice The only way to authorize a group: one gift at a time, in the group's current epoch.
    function voteToSetPrivacyGroupGift(address group, address gift, bool allowed) external {
        require(group != address(0) && gift.code.length != 0, "Invalid group or gift");
        uint256 epoch = privacyGroupEpoch[group];
        uint256 target = uint256(keccak256(abi.encode(group, gift, allowed, epoch)));
        _groupGiftChanges[target] = GroupGiftChange(group, gift, allowed, epoch);
        _castVote(VoteType.SET_PRIVACY_GROUP_GIFT, target);
    }

    function _grantKey(address group, uint256 epoch, address gift) private pure returns (bytes32) {
        return keccak256(abi.encode(group, epoch, gift));
    }

    /// @notice Whether `group` holds a grant for `gift` in its current epoch.
    function privacyGroupGifts(address group, address gift) public view returns (bool) {
        return _groupGiftGrants[_grantKey(group, privacyGroupEpoch[group], gift)];
    }

    function canPrivacyGroupAccessGift(address group, address gift) public view returns (bool) {
        return isAuthorizedPrivacyGroup[group] && privacyGroupGifts(group, gift);
    }

    /// @notice A gift explicitly authorizes separate registration payers. Paying
    /// fees alone never grants authority to advance another gift's UID range.
    function setRegistrationOperator(address operator, bool allowed) external {
        require(msg.sender.code.length != 0 && operator != address(0), "Invalid gift or operator");
        registrationOperators[msg.sender][operator] = allowed;
        emit RegistrationOperatorUpdated(msg.sender, operator, allowed);
    }

    // ── Pente Router Functions ────────────────────────────
    //
    //    Called by authorized Pente privacy groups via PenteExternalCall.
    //    CodeManager owns sparse per-UID active state and routes valid
    //    redemptions to the gift contract.
    //
    /// @notice Route a redemption from the Pente privacy group to the gift contract.
    ///         The gift contract decides how to handle the redemption — single-use,
    ///         multi-use, NFT mint, etc.
    ///
    ///         This function NEVER reverts on precondition failures (it does revert when
    ///         gasleft() is below MIN_DELIVERY_GAS at delivery, so no code is consumed). Invalid UIDs,
    ///         unregistered identifiers, out-of-range counters, and inactive/redeemed
    ///         UIDs emit a RedemptionRejected event and return gracefully. This
    ///         preserves the legacy best-effort ABI. Private code consumption must
    ///         use recordRedemptionStrict so a rejected public precondition rolls
    ///         back the Pente transition rather than consuming an undeliverable code.
    ///
    ///         CodeManager marks the UID as REDEEMED before calling the gift contract.
    ///         If the gift contract reverts, CodeManager catches the error and emits
    ///         a RedemptionFailed event instead of propagating the revert.
    ///
    ///         The UID remains terminally REDEEMED in CodeManager regardless of
    ///         gift contract outcome. Monitor RedemptionFailed and repair the
    ///         delivery target before calling retryRedemptionDelivery. The retry
    ///         retains the committed recipient and never reopens the spent code.
    function recordRedemption(string memory uniqueId, address redeemer) public onlyAuthorizedPrivacyGroup nonReentrant {
        // ── Precondition checks (graceful skip, never revert) ──
        (bool splitOk, string memory contractIdentifier, ) = _trySplitUniqueId(uniqueId);
        if (!splitOk) {
            emit RedemptionRejected(uniqueId, redeemer, "Invalid uniqueId format");
            return;
        }

        ContractData memory data = _contractIdentifierToData[contractIdentifier];
        if (data.giftContract == address(0)) {
            emit RedemptionRejected(uniqueId, redeemer, "Unregistered contract identifier");
            return;
        }

        if (redeemer == address(0) || !canPrivacyGroupAccessGift(msg.sender, data.giftContract)) {
            emit RedemptionRejected(uniqueId, redeemer, "Invalid recipient or privacy group scope");
            return;
        }

        if (!validateUniqueId(uniqueId)) {
            emit RedemptionRejected(uniqueId, redeemer, "Invalid or out-of-range uniqueId");
            return;
        }

        if (!isUniqueIdActive(uniqueId)) {
            emit RedemptionRejected(uniqueId, redeemer, "UniqueId is inactive or already redeemed");
            return;
        }

        // ── Commit: mark terminally REDEEMED ──
        _uniqueIdStatuses[keccak256(bytes(uniqueId))] = UniqueIdStatus.REDEEMED;
        emit UniqueIdRedeemed(uniqueId);

        _deliveries[keccak256(bytes(uniqueId))].recipient = redeemer;
        _attemptDelivery(uniqueId, data.giftContract);
    }

    /// @notice Atomic private/public boundary: reject without consuming private state.
    /// @dev The guarded public function is called internally, preserving msg.sender.
    ///      A gift delivery failure still commits the recipient and supports retry.
    ///      A public precondition failure reverts the entire enclosing Pente transition.
    function recordRedemptionStrict(string memory uniqueId, address redeemer) external {
        bytes32 uidHash = keccak256(bytes(uniqueId));
        require(_deliveries[uidHash].recipient == address(0), "Redemption already committed");
        recordRedemption(uniqueId, redeemer);
        require(redeemer != address(0) && _deliveries[uidHash].recipient == redeemer,
            "Public redemption precondition rejected");
    }

    function getRedemptionRecipient(string calldata uniqueId) external view returns (address) {
        return _deliveries[keccak256(bytes(uniqueId))].recipient;
    }

    function getRedemptionDelivery(string calldata uniqueId) external view returns (address recipient, bool delivered, uint256 attempts) {
        Delivery storage delivery = _deliveries[keccak256(bytes(uniqueId))];
        return (delivery.recipient, delivery.delivered, delivery.attempts);
    }

    /// @notice Permissionless repair of only the already committed recipient.
    /// Repeating a successful delivery is a no-op; a spent code is never reopened.
    function retryRedemptionDelivery(string calldata uniqueId) external nonReentrant {
        bytes32 uidHash = keccak256(bytes(uniqueId));
        Delivery storage delivery = _deliveries[uidHash];
        require(_uniqueIdStatuses[uidHash] == UniqueIdStatus.REDEEMED && delivery.recipient != address(0), "No committed delivery");
        if (delivery.delivered) return;
        (, string memory identifier,) = _trySplitUniqueId(uniqueId);
        _attemptDelivery(uniqueId, _contractIdentifierToData[identifier].giftContract);
    }

    function _attemptDelivery(string memory uniqueId, address gift) private {
        Delivery storage delivery = _deliveries[keccak256(bytes(uniqueId))];
        bytes memory input = abi.encodeCall(IRedeemable.recordRedemption, (uniqueId, delivery.recipient));
        // The caller cannot choose the gift's gas (X-22): a starved call reverts the whole transaction
        // instead of being recorded as a failed attempt, and the gift always gets exactly the limit.
        if (gasleft() < MIN_DELIVERY_GAS) revert InsufficientDeliveryGas();
        uint256 limit = DELIVERY_GAS_LIMIT;
        bool success;
        if (gift.code.length != 0) {
            assembly ("memory-safe") { success := call(limit, gift, 0, add(input, 32), mload(input), 0, 0) }
        }
        ++delivery.attempts;
        delivery.delivered = success;
        if (success) emit RedemptionRouted(uniqueId, gift, delivery.recipient);
        else emit RedemptionFailed(uniqueId, gift, delivery.recipient, "Gift delivery failed; retry committed recipient");
        emit RedemptionDeliveryAttempt(uniqueId, delivery.recipient, delivery.attempts, success);
    }

    /// @notice Update active state overrides for one or more UIDs.
    ///         Invalid or unregistered UIDs are skipped and reported via events.
    ///         The default state is sparse: when `active == DEFAULT_ACTIVE_STATE`,
    ///         any stored override is deleted instead of persisting a redundant value.
    function setUniqueIdActiveBatch(
        string[] calldata uniqueIds,
        bool[] calldata activeStates
    ) external onlyAuthorizedPrivacyGroup {
        uint256 len = uniqueIds.length;
        require(len == activeStates.length, "Array length mismatch");
        require(len > 0 && len <= MAX_STATUS_BATCH, "Batch size must be 1-100");

        for (uint256 i = 0; i < len; ) {
            if (bytes(uniqueIds[i]).length == 0) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "Empty uniqueId");
                unchecked { ++i; }
                continue;
            }
            if (!validateUniqueId(uniqueIds[i])) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "Invalid uniqueId");
                unchecked { ++i; }
                continue;
            }

            (, string memory identifier,) = _trySplitUniqueId(uniqueIds[i]);
            if (!canPrivacyGroupAccessGift(msg.sender, _contractIdentifierToData[identifier].giftContract)) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "Privacy group scope mismatch");
                unchecked { ++i; }
                continue;
            }

            bytes32 uidHash = keccak256(bytes(uniqueIds[i]));
            if (_uniqueIdStatuses[uidHash] == UniqueIdStatus.REDEEMED) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "UniqueId already redeemed");
                unchecked { ++i; }
                continue;
            }

            if (activeStates[i] == DEFAULT_ACTIVE_STATE) {
                delete _uniqueIdStatuses[uidHash];
                emit UniqueIdActiveStatusUpdated(uniqueIds[i], activeStates[i], true);
            } else {
                _uniqueIdStatuses[uidHash] = UniqueIdStatus.INACTIVE;
                emit UniqueIdActiveStatusUpdated(uniqueIds[i], activeStates[i], false);
            }

            unchecked { ++i; }
        }
    }

    // ── UID View Functions (read from gift contract) ──────
    //
    //    CodeManager owns active state directly and reads redemption state
    //    from the gift contract via IRedeemable.

    /// @notice Returns CodeManager's public view of whether a UID is active.
    ///         Invalid or unregistered UIDs return false.
    ///         When the status is USE_DEFAULT_ACTIVE_STATE, this means there is
    ///         no public override recorded in CodeManager. For privacy-managed
    ///         redeemables, callers may infer that active/frozen control is
    ///         being handled privately rather than mirrored publicly.
    function isUniqueIdActive(string memory uniqueId) public view returns (bool) {
        if (!validateUniqueId(uniqueId)) {
            return false;
        }

        UniqueIdStatus status = _uniqueIdStatuses[keccak256(bytes(uniqueId))];
        if (status == UniqueIdStatus.REDEEMED) {
            return false;
        }
        if (status == UniqueIdStatus.INACTIVE) {
            return false;
        }
        return DEFAULT_ACTIVE_STATE;
    }

    /// @notice Returns whether a UID has been redeemed.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool) {
        if (!validateUniqueId(uniqueId)) {
            return false;
        }
        return _uniqueIdStatuses[keccak256(bytes(uniqueId))] == UniqueIdStatus.REDEEMED;
    }

    // ── Unique ID Queries ─────────────────────────────────

    function getContractData(string memory contractIdentifier) public view returns (ContractData memory) {
        return _contractIdentifierToData[contractIdentifier];
    }

    /// @notice Get the counter for a given giftContract + chainId, computed on the fly.
    function getIdentifierCounter(address giftContract, string memory chainId) public view returns (string memory contractIdentifier, uint256 counter) {
        bytes32 hash = keccak256(abi.encodePacked(address(this), giftContract, chainId));
        contractIdentifier = StringsUpgradeable.toHexString(uint256(hash), 32);
        counter = _identifierCounter[contractIdentifier];
    }

    /// @notice Get the registered counter for a contract identifier directly.
    function getCounterByIdentifier(string memory contractIdentifier) public view returns (uint256) {
        return _identifierCounter[contractIdentifier];
    }

    function validateUniqueId(string memory uniqueId) public view returns (bool isValid) {
        (bool ok, string memory contractIdentifier, uint256 extractedCounter) = _trySplitUniqueId(uniqueId);

        if (!ok) {
            return false;
        }

        if (_identifierCounter[contractIdentifier] == 0) {
            return false;
        }

        return extractedCounter > 0 && extractedCounter <= _identifierCounter[contractIdentifier];
    }

    function validateUniqueIdsOrRevert(
        string[] calldata uniqueIds
    ) external view onlyAuthorizedPrivacyGroup {
        uint256 len = uniqueIds.length;
        require(len > 0 && len <= MAX_STATUS_BATCH, "Batch size must be 1-100");

        for (uint256 i = 0; i < len; ) {
            require(validateUniqueId(uniqueIds[i]), "Invalid uniqueId");
            (, string memory identifier,) = _trySplitUniqueId(uniqueIds[i]);
            require(canPrivacyGroupAccessGift(msg.sender, _contractIdentifierToData[identifier].giftContract), "Privacy group scope mismatch");
            require(
                _uniqueIdStatuses[keccak256(bytes(uniqueIds[i]))] != UniqueIdStatus.REDEEMED,
                "UniqueId already redeemed"
            );
            unchecked { ++i; }
        }
    }

    function getUniqueIdDetails(string memory uniqueId) public view returns (address giftContract, string memory chainId, uint256 counter) {
        (bool ok, string memory contractIdentifier, uint256 extractedCounter) = _trySplitUniqueId(uniqueId);
        require(ok, "Invalid uniqueId format");
        ContractData memory data = getContractData(contractIdentifier);

        require(data.giftContract != address(0), "No matching uniqueId found.");

        uint256 currentCounter = _identifierCounter[contractIdentifier];
        require(extractedCounter > 0 && extractedCounter <= currentCounter, "Invalid counter value");

        return (data.giftContract, data.chainId, extractedCounter);
    }

    function _trySplitUniqueId(string memory uniqueId) internal pure returns (bool ok, string memory contractIdentifier, uint256 counter) {
        return CanonicalUid.split(uniqueId);
    }

    /// @notice Register a single or batch of unique IDs by incrementing the counter range.
    ///         The gift or its explicitly authorized registrar pays `registrationFee * quantity`.
    ///         Works for both direct EOA calls and calls from external contracts.
    ///         Payment is forwarded to the feeVault.
    function registerUniqueIds(address giftContract, string memory chainId, uint256 quantity) external payable nonReentrant {
        require(giftContract != address(0), "Gift contract address cannot be zero");
        require(msg.sender == giftContract || registrationOperators[giftContract][msg.sender], "Unauthorized registration operator");
        require(quantity > 0, "Quantity must be greater than zero");
        require(bytes(chainId).length > 0, "Chain ID cannot be empty");

        uint256 totalFee = registrationFee * quantity;
        require(msg.value >= totalFee, "Insufficient registration fee");
        require(feeVault != address(0), "Fee vault not set");

        // Forward fee to fee vault
        (bool feePaid, ) = payable(feeVault).call{value: totalFee}("");
        require(feePaid, "Fee transfer failed");

        _incrementCounter(giftContract, chainId, quantity);

        emit UniqueIdsRegistered(giftContract, chainId, quantity);

        // Refund excess payment
        uint256 refund = msg.value - totalFee;
        if (refund > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: refund}("");
            require(refunded, "Refund failed");
        }
    }

    // ── Expired Tally Cleanup ─────────────────────────────

    /// @notice Anyone may clear an expired ballot; no membership or approval changes.
    function resetExpiredTally(VoteType voteType, uint256 target) external {
        GovernanceVotes.resetExpired(GovernanceVotes.state(), _voteKey(voteType, target));
        emit VoteTallyReset(voteType, target);
    }

    // ── Utilities ─────────────────────────────────────

    function _incrementCounter(address giftContract, string memory chainId, uint256 quantity) internal {
        bytes32 hash = keccak256(abi.encodePacked(address(this), giftContract, chainId));
        string memory contractIdentifier = StringsUpgradeable.toHexString(uint256(hash), 32);

        if (_identifierCounter[contractIdentifier] == 0) {
            _contractIdentifierToData[contractIdentifier] = ContractData(giftContract, chainId);
        }

        _identifierCounter[contractIdentifier] += quantity;
    }

}
