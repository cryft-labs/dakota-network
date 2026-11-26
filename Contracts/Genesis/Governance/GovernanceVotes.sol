// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.19 <0.9.0;

import "./GovernanceMembers.sol";

/// @dev Snapshot ballots shared by the validator contract (0x1111), the genesis proxy shell,
///      GasManager and CodeManager. Isolated storage keeps each caller's application layout intact.
///
///      Windows are measured in block.timestamp seconds, never in block counts: block counts can be
///      stuffed for free and their wall-clock length swings with the 1 s / 64 s QBFT cadence (audit X-14).
///
///      Open ballots are capped per proposer (audit X-13): one voter can no longer fill the global cap
///      with junk ballots and so block the ballot that removes it. Exempt ballots (voter removal and
///      voter-set configuration; guardian removal where a caller has guardians) never count toward the
///      global or the per-proposer cap; they have their own small per-proposer cap so they stay bounded.
library GovernanceVotes {
    bytes32 private constant SLOT = keccak256("cryft.governance.snapshot.v1");
    /// @dev Ballot windows: at least one hour, at most 30 days.
    uint256 internal constant MIN_WINDOW = 1 hours;
    uint256 internal constant MAX_WINDOW = 30 days;
    /// @dev Global cap on open non-exempt ballots per electorate epoch.
    uint256 internal constant MAX_ACTIVE = 64;
    /// @dev Exempt ballots each proposer may hold open at once.
    uint256 internal constant MAX_EXEMPT_PER_PROPOSER = 4;

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
    struct Configuration { address[] local; address[] providers; bytes32 membersHash; }
    event GovernanceProposalStarted(bytes32 indexed key, uint256 indexed epoch, uint256 threshold, uint256 expires, bytes32 electorateHash);
    event GovernanceEpochChanged(uint256 indexed epoch);
    error NotSnapshotVoter();
    error AlreadyVoted();
    error NoVoters();
    error InvalidExpiry();
    error NotExpired();
    error InvalidVoteTarget();
    error VoterAlreadyPresent();
    error VoterNotFound();
    error ProviderAlreadyPresent();
    error ProviderNotFound();
    error EmptyVoterSet();
    error MembershipChanged();
    error SelfAdministration();
    error TooManyActiveProposals();
    error ProposerCapReached();

    function state() internal pure returns (State storage s) {
        return state(SLOT);
    }

    /// @dev Callers sharing an address through delegatecall MUST use different slots.
    function state(bytes32 slot) internal pure returns (State storage s) {
        assembly ("memory-safe") { s.slot := slot }
    }

    function validWindow(uint256 duration) internal pure returns (bool) {
        return duration >= MIN_WINDOW && duration <= MAX_WINDOW;
    }

    /// @dev Open counted ballots one proposer may hold: max(1, 64 / electorate size).
    function proposerCap(uint256 electorateSize) internal pure returns (uint256) {
        if (electorateSize == 0) return 1;
        uint256 cap = MAX_ACTIVE / electorateSize;
        return cap == 0 ? 1 : cap;
    }

    function proposal(State storage s, bytes32 key) internal view returns (Proposal storage p) { return s.proposals[key]; }
    function current(State storage s, bytes32 key) internal view returns (bool) {
        Proposal storage p = proposal(s, key);
        return p.start != 0 && p.epoch == s.epoch;
    }
    function live(State storage s, bytes32 key) internal view returns (bool) {
        return current(s, key) && block.timestamp <= proposal(s, key).expires;
    }

    /// @dev Counted ballot (subject to the global and per-proposer caps).
    function cast(State storage s, bytes32 key, address[] memory members, uint256 duration, address voter)
        internal returns (bool approved)
    {
        return cast(s, key, members, duration, voter, false);
    }

    function cast(State storage s, bytes32 key, address[] memory members, uint256 duration, address voter, bool exempt)
        internal returns (bool approved)
    {
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
            emit GovernanceProposalStarted(key, s.epoch, fresh.threshold, fresh.expires, keccak256(abi.encode(members)));
        }
        Proposal storage p = s.proposals[key];
        if (!GovernanceMembers.contains(p.electorate, voter)) revert NotSnapshotVoter();
        if (GovernanceMembers.contains(p.votes, voter)) revert AlreadyVoted();
        p.votes.push(voter);
        return p.votes.length >= p.threshold;
    }

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

    function complete(State storage s, bytes32 key) internal {
        _release(s, key);
        delete s.proposals[key];
    }
    function invalidate(State storage s) internal {
        ++s.epoch;
        s.active = 0;
        emit GovernanceEpochChanged(s.epoch);
    }
    function approveVoters(State storage s, address[] memory members) internal {
        if (members.length == 0) revert NoVoters();
        s.approvedVoters = members;
        s.votersInitialized = true;
    }
    function configure(State storage s, address[] memory local, address[] memory providers, bytes32 membersHash)
        internal returns (uint256 target)
    {
        require(local.length <= 64 && providers.length <= 16, "Configuration too large");
        target = uint256(keccak256(abi.encode(local, providers, membersHash)));
        s.configurations[target] = Configuration(local, providers, membersHash);
    }
    /// @dev Permissionless cleanup cannot approve a proposal or change membership.
    function resetExpired(State storage s, bytes32 key) internal {
        if (!current(s, key) || block.timestamp <= proposal(s, key).expires) revert NotExpired();
        complete(s, key);
    }
    function voted(State storage s, bytes32 key, address voter) internal view returns (bool) {
        return live(s, key) && GovernanceMembers.contains(proposal(s, key).votes, voter);
    }
    function openCount(State storage s, address proposer) internal view returns (uint256 counted, uint256 exempt) {
        return (s.openBy[s.epoch][proposer], s.exemptBy[s.epoch][proposer]);
    }
    function tally(State storage s, bytes32 key) internal view returns (uint256, uint256, uint256, address[] memory) {
        if (!current(s, key)) return (0, 0, 0, new address[](0));
        Proposal storage p = proposal(s, key);
        return (p.votes.length, p.start, p.expires, p.votes);
    }
    function snapshot(State storage s, bytes32 key) internal view returns (uint256, uint256, uint256, address[] memory) {
        if (!current(s, key)) return (0, 0, s.epoch, new address[](0));
        Proposal storage p = proposal(s, key);
        return (p.threshold, p.expires, p.epoch, p.electorate);
    }
}
