// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   _____        __    __  ___
  / ___/__  ___/ /__ /  |/  /__ ____  ___ ____ ____ ____
 / /__/ _ \/ _  / -_) /|_/ / _ `/ _ \/ _ `/ _ `/ -_) __/
 \___/\___/\_,_/\__/_/  /_/\_,_/_//_/\_,_/\_, /\__/_/
                                         /___/ By: CryftCreator

  Version 3.0 — Production Code Manager  [UPGRADEABLE]

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

interface IVoterChecker {
    function isVoter(address potentialVoter) external view returns (bool);
    function getVoters() external view returns (address[] memory);
}

contract CodeManager is Initializable, ReentrancyGuardUpgradeable, ICodeManager {
    using StringsUpgradeable for uint256;

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
        ADD_WHITELISTED_ADDRESS,
        REMOVE_WHITELISTED_ADDRESS,
        UPDATE_REGISTRATION_FEE,
        UPDATE_FEE_VAULT,
        ADD_VOTER,
        REMOVE_VOTER,
        ADD_OTHER_VOTER_CONTRACT,
        REMOVE_OTHER_VOTER_CONTRACT,
        UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
        AUTHORIZE_PRIVACY_GROUP,
        DEAUTHORIZE_PRIVACY_GROUP,
        REFRESH_VOTERS,
        SET_VOTER_CONFIGURATION,
        SET_PRIVACY_GROUP_GIFT
    }

    struct VoteTally {
        uint256 totalVotes;
        uint256 startVoteBlock;
        address[] voters;
    }

    address[] public votersArray;
    address[] public otherVoterContracts;
    uint256 private __legacyActiveVoteCount; // Slot retained; use activeVoteCount().

    uint256 public registrationFee;
    uint256 public voteTallyBlockThreshold;
    address public feeVault;

    /// @dev Default active state applied to every valid UID unless an override exists.
    bool public constant DEFAULT_ACTIVE_STATE = true;

    mapping(address => bool) public isWhitelistedAddress;
    mapping(string => uint256) private _identifierCounter;
    mapping(string => ContractData) private _contractIdentifierToData;
    mapping(bytes32 => UniqueIdStatus) private _uniqueIdStatuses;
    mapping(VoteType => mapping(uint256 => VoteTally)) private _voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool))) private __legacyHasVoted;

    /// @dev Authorized Pente privacy groups that can call router functions.
    mapping(address => bool) public isAuthorizedPrivacyGroup;

    // Append-only release state. Legacy explicit global group authorization
    // remains available; new tenant groups use the scoped governance entry.
    mapping(address => mapping(address => bool)) public registrationOperators;
    mapping(address => bool) public isScopedPrivacyGroup;
    mapping(address => mapping(address => bool)) public privacyGroupGifts;
    struct GroupGiftChange { address group; address gift; bool allowed; }
    mapping(uint256 => GroupGiftChange) private _groupGiftChanges;
    struct Delivery { address recipient; bool delivered; uint256 attempts; }
    mapping(bytes32 => Delivery) private _deliveries;
    uint256 public constant MAX_STATUS_BATCH = 100;
    uint256 public constant DELIVERY_GAS_LIMIT = 1000000;
    event RegistrationOperatorUpdated(address indexed gift, address indexed operator, bool allowed);
    event PrivacyGroupGiftUpdated(address indexed group, address indexed gift, bool allowed);
    event RedemptionDeliveryAttempt(string uniqueId, address indexed recipient, uint256 attempt, bool delivered);


    event RegistrationFeeUpdated(uint256 newFee);
    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    event StateChanged(VoteType voteType, uint256 newValue);
    event VoteTallyReset(VoteType voteType, uint256 target);
    event UniqueIdsRegistered(address indexed giftContract, string chainId, uint256 quantity);
    event VoterUpdated(address indexed target, bool added);
    event OtherVoterContractUpdated(address indexed target, bool added);
    event VoteTallyBlockThresholdUpdated(uint256 newThreshold);
    event PrivacyGroupAuthorized(address indexed privacyGroup, bool authorized);
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
        require(
            isAuthorizedPrivacyGroup[msg.sender],
            "Caller is not an authorized privacy group"
        );
        _;
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
        registrationFee = 10**15;
        voteTallyBlockThreshold = 1000;
    }

    // ── Voter Queries ─────────────────────────────────────

    function isVoter(address potentialVoter) public view returns (bool) {
        return GovernanceMembers.contains(getVoters(), potentialVoter);
    }

    function getVoters() public view returns (address[] memory) {
        if (GovernanceVotes.state().votersInitialized) return GovernanceVotes.state().approvedVoters;
        return _readVoters();
    }
    /// @notice Returns the total number of voters (local + external).
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
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount * 2 + 2) / 3;
    }

    // ── Internal Vote Engine ──────────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        address[] memory electorate;
        if (!GovernanceVotes.live(GovernanceVotes.state(), key)) electorate = getVoters();
        if (GovernanceVotes.cast(GovernanceVotes.state(), key, electorate, voteTallyBlockThreshold, msg.sender)) {
            emit StateChanged(voteType, target);

            if (voteType == VoteType.ADD_WHITELISTED_ADDRESS) {
                isWhitelistedAddress[address(uint160(target))] = true;
            } else if (voteType == VoteType.REMOVE_WHITELISTED_ADDRESS) {
                isWhitelistedAddress[address(uint160(target))] = false;
            } else if (voteType == VoteType.UPDATE_REGISTRATION_FEE) {
                registrationFee = target;
                emit RegistrationFeeUpdated(registrationFee);
            } else if (voteType == VoteType.UPDATE_FEE_VAULT) {
                feeVault = address(uint160(target));
            } else if (voteType == VoteType.ADD_VOTER) {
                if (isVoter(address(uint160(target)))) revert GovernanceVotes.VoterAlreadyPresent();
                votersArray.push(address(uint160(target)));
                emit VoterUpdated(address(uint160(target)), true);
            } else if (voteType == VoteType.REMOVE_VOTER) {
                address targetAddress = address(uint160(target));
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
                address targetAddress = address(uint160(target));
                for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                    if (otherVoterContracts[i] == targetAddress) revert GovernanceVotes.ProviderAlreadyPresent();
                }
                otherVoterContracts.push(targetAddress);
                emit OtherVoterContractUpdated(targetAddress, true);
            } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
                address targetAddress = address(uint160(target));
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
            } else if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                if (!(target > 0 && target <= 100000)) revert GovernanceVotes.InvalidExpiry();
                voteTallyBlockThreshold = target;
                emit VoteTallyBlockThresholdUpdated(target);
            } else if (voteType == VoteType.AUTHORIZE_PRIVACY_GROUP) {
                address targetAddress = address(uint160(target));
                isAuthorizedPrivacyGroup[targetAddress] = true;
                emit PrivacyGroupAuthorized(targetAddress, true);
            } else if (voteType == VoteType.DEAUTHORIZE_PRIVACY_GROUP) {
                address targetAddress = address(uint160(target));
                isAuthorizedPrivacyGroup[targetAddress] = false;
                emit PrivacyGroupAuthorized(targetAddress, false);
            }
            if (voteType == VoteType.SET_PRIVACY_GROUP_GIFT) {
                GroupGiftChange memory change = _groupGiftChanges[target];
                isScopedPrivacyGroup[change.group] = true;
                privacyGroupGifts[change.group][change.gift] = change.allowed;
                if (change.allowed) isAuthorizedPrivacyGroup[change.group] = true;
                delete _groupGiftChanges[target];
                emit PrivacyGroupGiftUpdated(change.group, change.gift, change.allowed);
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

    // ── Governance Entry Points ───────────────────────────

    function voteToAddWhitelistedAddress(address newAddress) external {
        require(newAddress != address(0), "Address should not be zero");
        _castVote(VoteType.ADD_WHITELISTED_ADDRESS, uint256(uint160(newAddress)));
    }

    function voteToRemoveWhitelistedAddress(address removeAddress) external {
        require(removeAddress != address(0), "Address should not be zero");
        _castVote(VoteType.REMOVE_WHITELISTED_ADDRESS, uint256(uint160(removeAddress)));
    }

    function voteToUpdateRegistrationFee(uint256 newFee) external {
        _castVote(VoteType.UPDATE_REGISTRATION_FEE, newFee);
    }

    function voteToUpdateFeeVault(address newFeeVault) external {
        require(newFeeVault != address(0), "Fee vault address should not be zero");
        _castVote(VoteType.UPDATE_FEE_VAULT, uint256(uint160(newFeeVault)));
    }

    function voteToUpdateVoteTallyBlockThreshold(uint256 newThreshold) external {
        if (!(newThreshold > 0 && newThreshold <= 100000)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD, newThreshold);
    }

    /// @notice Vote to authorize (or de-authorize) a Pente privacy group address.
    ///         Authorized privacy groups can call router functions.
    function voteToAuthorizePrivacyGroup(address privacyGroup) external {
        require(privacyGroup != address(0), "Privacy group address cannot be zero");
        _castVote(VoteType.AUTHORIZE_PRIVACY_GROUP, uint256(uint160(privacyGroup)));
    }

    /// @notice Vote to de-authorize a Pente privacy group address.
    function voteToDeauthorizePrivacyGroup(address privacyGroup) external {
        require(privacyGroup != address(0), "Privacy group address cannot be zero");
        _castVote(VoteType.DEAUTHORIZE_PRIVACY_GROUP, uint256(uint160(privacyGroup)));
    }

    /// @notice Authorize a tenant group for one gift, without a global-access
    /// window. First use makes this group scoped; subsequent grants are additive.
    function voteToSetPrivacyGroupGift(address group, address gift, bool allowed) external {
        require(group != address(0) && gift.code.length != 0, "Invalid group or gift");
        uint256 target = uint256(keccak256(abi.encode(group, gift, allowed)));
        _groupGiftChanges[target] = GroupGiftChange(group, gift, allowed);
        _castVote(VoteType.SET_PRIVACY_GROUP_GIFT, target);
    }

    function canPrivacyGroupAccessGift(address group, address gift) public view returns (bool) {
        return isAuthorizedPrivacyGroup[group] && (!isScopedPrivacyGroup[group] || privacyGroupGifts[group][gift]);
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
    ///         This function NEVER reverts on precondition failures. Invalid UIDs,
    ///         unregistered identifiers, out-of-range counters, and inactive/redeemed
    ///         UIDs emit a RedemptionRejected event and return gracefully. This
    ///         guarantees that every PenteExternalCall from redeemCodeBatch succeeds
    ///         from Pente's perspective — private state changes (hash deletion,
    ///         local REDEEMED marking) are never rolled back by a public-chain
    ///         precondition failure.
    ///
    ///         CodeManager marks the UID as REDEEMED before calling the gift contract.
    ///         If the gift contract reverts, CodeManager catches the error and emits
    ///         a RedemptionFailed event instead of propagating the revert.
    ///
    ///         The UID remains terminally REDEEMED in CodeManager regardless of
    ///         gift contract outcome. Admin monitoring should watch for
    ///         RedemptionFailed events and resolve the gift-contract side effect
    ///         (e.g., manual NFT transfer) separately.
    function recordRedemption(string memory uniqueId, address redeemer) external onlyAuthorizedPrivacyGroup nonReentrant {
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
        // Leave room to persist the outcome even if the gift exhausts its gas.
        uint256 available = gasleft();
        uint256 budget = available > 100000 ? available - 100000 : 0;
        if (budget > DELIVERY_GAS_LIMIT) budget = DELIVERY_GAS_LIMIT;
        bool success;
        if (budget != 0 && gift.code.length != 0) {
            assembly ("memory-safe") { success := call(budget, gift, 0, add(input, 32), mload(input), 0, 0) }
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

    function _tryParseUint(string memory s) internal pure returns (bool ok, uint256 value) {
        return CanonicalUid.parseCounter(s);
    }

    function _substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
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

    function _isContract(address addr) internal view returns (bool) {
        uint32 size;
        assembly ("memory-safe") {
            size := extcodesize(addr)
        }
        return (size > 0);
    }

    function _incrementCounter(address giftContract, string memory chainId, uint256 quantity) internal {
        bytes32 hash = keccak256(abi.encodePacked(address(this), giftContract, chainId));
        string memory contractIdentifier = StringsUpgradeable.toHexString(uint256(hash), 32);

        if (_identifierCounter[contractIdentifier] == 0) {
            _contractIdentifierToData[contractIdentifier] = ContractData(giftContract, chainId);
        }

        _identifierCounter[contractIdentifier] += quantity;
    }

}
