// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity >=0.8.19 <0.9.0;

import {GovernanceMembers} from "./GovernanceMembers.sol";

/// @title GovernanceVotes
/// @notice Snapshot ballots shared by the validator contract (0x…1111), the genesis proxy shell, GasManager and
///         CodeManager.
/// @dev Each caller keeps its ballots in isolated namespaced storage, so its own application layout stays intact.
///      Ballot windows are measured in block.timestamp seconds, never in block counts: block counts can be
///      stuffed for free and their wall-clock length swings with the 1 s / 64 s QBFT cadence.
///      Open ballots are capped per proposer, so one voter cannot fill the global cap with junk ballots and block
///      the ballot that removes it. Exempt ballots (voter removal and voter-set configuration; guardian removal
///      where a caller has guardians) never count toward the global or the per-proposer cap; they have their own
///      small per-proposer cap so they stay bounded. Compiled by the validator contract with solc 0.8.19, so it
///      uses no newer syntax.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
library GovernanceVotes {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @dev One ballot. Field order is storage layout: never change it.
    struct Proposal {
        uint256 epoch;
        uint256 start;     // block.timestamp of the first vote
        uint256 expires;   // last second at which a vote is accepted
        uint256 threshold;
        address[] electorate;
        address[] votes;
        address proposer;
        bool exempt;
    }

    /// @dev The namespaced ballot state of one caller. Field order is storage layout: never change it.
    struct State {
        uint256 epoch;
        uint256 active;
        mapping(bytes32 => Proposal) proposals;
        address[] approvedVoters;
        bool votersInitialized;
        mapping(uint256 => Configuration) configurations;
        // epoch => proposer => open counted ballots; keyed by epoch so invalidate() resets every count.
        mapping(uint256 => mapping(address => uint256)) openBy;
        // epoch => proposer => open exempt ballots.
        mapping(uint256 => mapping(address => uint256)) exemptBy;
    }

    /// @dev A proposed member configuration, bound to the hash of the membership it produces.
    struct Configuration {
        address[] local;
        address[] providers;
        bytes32 membersHash;
    }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @dev Ballot windows: at least one hour, at most 30 days.
    uint256 internal constant MIN_WINDOW = 1 hours;
    uint256 internal constant MAX_WINDOW = 30 days;
    /// @dev Global cap on open non-exempt ballots per electorate epoch.
    uint256 internal constant MAX_ACTIVE = 64;
    /// @dev Exempt ballots each proposer may hold open at once.
    uint256 internal constant MAX_EXEMPT_PER_PROPOSER = 4;
    /// @dev Default namespaced slot (the validator contract and the managers).
    bytes32 private constant _SLOT = keccak256("cryft.governance.snapshot.v1");

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A ballot opened with a snapshot of its electorate, threshold and window.
    event GovernanceProposalStarted(
        bytes32 indexed key,
        uint256 indexed epoch,
        uint256 threshold,
        uint256 expires,
        bytes32 electorateHash
    );
    /// @notice The electorate epoch moved on; every open ballot of the old epoch is void.
    event GovernanceEpochUpdated(uint256 indexed epoch);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is not in the ballot's electorate snapshot.
    error NotSnapshotVoter();
    /// @notice The caller already voted on this ballot.
    error AlreadyVoted();
    /// @notice There are no voters.
    error NoVoters();
    /// @notice A ballot window is outside one hour to 30 days.
    error InvalidExpiry();
    /// @notice The ballot is still open or does not exist.
    error NotExpired();
    /// @notice The ballot target is zero.
    error InvalidVoteTarget();
    /// @notice The address is already a voter.
    error VoterAlreadyPresent();
    /// @notice The address is not a voter.
    error VoterNotFound();
    /// @notice The provider is already listed.
    error ProviderAlreadyPresent();
    /// @notice The provider is not listed.
    error ProviderNotFound();
    /// @notice The resulting voter set would be empty.
    error EmptyVoterSet();
    /// @notice The membership no longer matches the hash the ballot approved.
    error MembershipChanged();
    /// @notice The global cap on open ballots is reached.
    error TooManyActiveProposals();
    /// @notice The proposer holds as many open ballots as allowed.
    error ProposerCapReached();
    /// @notice A configuration lists more members or providers than allowed.
    error ConfigurationTooLarge();

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @dev Counted ballot (subject to the global and per-proposer caps).
    function cast(State storage s, bytes32 key, address[] memory members, uint256 duration, address voter)
        internal
        returns (bool approved)
    {
        return cast(s, key, members, duration, voter, false);
    }

    /// @dev Opens the ballot on the first vote (snapshotting `members`), then records the vote. Returns true once
    ///      the threshold is met.
    function cast(
        State storage s,
        bytes32 key,
        address[] memory members,
        uint256 duration,
        address voter,
        bool exempt
    ) internal returns (bool approved) {
        if (!live(s, key)) {
            _release(s, key);
            delete s.proposals[key];
            if (members.length == 0) revert NoVoters();
            if (!validWindow(duration)) revert InvalidExpiry();
            // Only an electorate member may open a ballot, so caps are charged to real voters.
            if (!GovernanceMembers.contains(members, voter)) revert NotSnapshotVoter();
            if (exempt) {
                if (s.exemptBy[s.epoch][voter] >= MAX_EXEMPT_PER_PROPOSER) revert ProposerCapReached();
                ++s.exemptBy[s.epoch][voter];
            } else {
                if (s.active >= MAX_ACTIVE) revert TooManyActiveProposals();
                if (s.openBy[s.epoch][voter] >= proposerCap(members.length)) revert ProposerCapReached();
                ++s.openBy[s.epoch][voter];
                ++s.active;
            }
            if (!s.votersInitialized) approveVoters(s, members);
            Proposal storage fresh = s.proposals[key];
            fresh.epoch = s.epoch;
            fresh.start = block.timestamp;
            fresh.expires = block.timestamp + duration;
            fresh.threshold = (members.length * 2 + 2) / 3;
            fresh.electorate = members;
            fresh.proposer = voter;
            fresh.exempt = exempt;
            emit GovernanceProposalStarted(
                key, s.epoch, fresh.threshold, fresh.expires, keccak256(abi.encode(members))
            );
        }
        Proposal storage p = s.proposals[key];
        if (!GovernanceMembers.contains(p.electorate, voter)) revert NotSnapshotVoter();
        if (GovernanceMembers.contains(p.votes, voter)) revert AlreadyVoted();
        p.votes.push(voter);
        return p.votes.length >= p.threshold;
    }

    /// @dev Closes a ballot and frees its slot in the caps.
    function complete(State storage s, bytes32 key) internal {
        _release(s, key);
        delete s.proposals[key];
    }

    /// @dev Starts a new electorate epoch, voiding every open ballot.
    function invalidate(State storage s) internal {
        ++s.epoch;
        s.active = 0;
        emit GovernanceEpochUpdated(s.epoch);
    }

    /// @dev Stores the approved voter set.
    function approveVoters(State storage s, address[] memory members) internal {
        if (members.length == 0) revert NoVoters();
        s.approvedVoters = members;
        s.votersInitialized = true;
    }

    /// @dev Stores a proposed configuration and returns its ballot target.
    function configure(State storage s, address[] memory local, address[] memory providers, bytes32 membersHash)
        internal
        returns (uint256 target)
    {
        if (local.length > GovernanceMembers.MAX_MEMBERS || providers.length > GovernanceMembers.MAX_PROVIDERS) {
            revert ConfigurationTooLarge();
        }
        target = uint256(keccak256(abi.encode(local, providers, membersHash)));
        s.configurations[target] = Configuration(local, providers, membersHash);
    }

    /// @dev Permissionless cleanup of an expired ballot; it cannot approve a ballot or change membership.
    function resetExpired(State storage s, bytes32 key) internal {
        if (!current(s, key) || block.timestamp <= proposal(s, key).expires) revert NotExpired();
        complete(s, key);
    }

    /// @dev The ballot stored under `key`.
    function proposal(State storage s, bytes32 key) internal view returns (Proposal storage p) {
        return s.proposals[key];
    }

    /// @dev True when the ballot exists in the current epoch (open or expired).
    function current(State storage s, bytes32 key) internal view returns (bool) {
        Proposal storage p = proposal(s, key);
        return p.start != 0 && p.epoch == s.epoch;
    }

    /// @dev True when the ballot exists in the current epoch and its window is open.
    function live(State storage s, bytes32 key) internal view returns (bool) {
        return current(s, key) && block.timestamp <= proposal(s, key).expires;
    }

    /// @dev True when `voter` voted on the open ballot.
    function voted(State storage s, bytes32 key, address voter) internal view returns (bool) {
        return live(s, key) && GovernanceMembers.contains(proposal(s, key).votes, voter);
    }

    /// @dev Open ballots `proposer` holds in the current epoch: (counted, exempt).
    function openCount(State storage s, address proposer) internal view returns (uint256 counted, uint256 exempt) {
        return (s.openBy[s.epoch][proposer], s.exemptBy[s.epoch][proposer]);
    }

    /// @dev (votes, start, expires, voters) of a current-epoch ballot, zeros otherwise.
    function tally(State storage s, bytes32 key) internal view returns (uint256, uint256, uint256, address[] memory) {
        if (!current(s, key)) return (0, 0, 0, new address[](0));
        Proposal storage p = proposal(s, key);
        return (p.votes.length, p.start, p.expires, p.votes);
    }

    /// @dev (threshold, expires, epoch, electorate) of a current-epoch ballot; otherwise zeros and the epoch.
    function snapshot(State storage s, bytes32 key)
        internal
        view
        returns (uint256, uint256, uint256, address[] memory)
    {
        if (!current(s, key)) return (0, 0, s.epoch, new address[](0));
        Proposal storage p = proposal(s, key);
        return (p.threshold, p.expires, p.epoch, p.electorate);
    }

    /// @dev The default ballot state (the validator contract and the managers).
    function state() internal pure returns (State storage s) {
        return state(_SLOT);
    }

    /// @dev The ballot state at `slot`. Callers that share an address through delegatecall MUST use different
    ///      slots.
    function state(bytes32 slot) internal pure returns (State storage s) {
        assembly ("memory-safe") { s.slot := slot }
    }

    /// @dev True when `duration` is a valid ballot window.
    function validWindow(uint256 duration) internal pure returns (bool) {
        return duration >= MIN_WINDOW && duration <= MAX_WINDOW;
    }

    /// @dev Open counted ballots one proposer may hold: max(1, 64 / electorate size).
    function proposerCap(uint256 electorateSize) internal pure returns (uint256) {
        if (electorateSize == 0) return 1;
        uint256 cap = MAX_ACTIVE / electorateSize;
        return cap == 0 ? 1 : cap;
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    /// @dev Returns a current-epoch ballot's slot in the caps. Counters never underflow (never fatal).
    function _release(State storage s, bytes32 key) private {
        if (!current(s, key)) return;
        Proposal storage p = s.proposals[key];
        if (p.exempt) {
            if (s.exemptBy[p.epoch][p.proposer] > 0) --s.exemptBy[p.epoch][p.proposer];
        } else {
            if (s.active > 0) --s.active;
            if (s.openBy[p.epoch][p.proposer] > 0) --s.openBy[p.epoch][p.proposer];
        }
    }
}
