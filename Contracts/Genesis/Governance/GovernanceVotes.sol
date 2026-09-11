// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.19 <0.9.0;

import "./GovernanceMembers.sol";

/// @dev Isolated storage preserves the legacy contracts' application storage layout.
///      Pending legacy ballots are deliberately not imported into the new engine.
library GovernanceVotes {
    bytes32 private constant SLOT = keccak256("cryft.governance.snapshot.v1");
    struct Proposal {
        uint256 epoch;
        uint256 start;
        uint256 expires;
        uint256 threshold;
        address[] electorate;
        address[] votes;
    }
    struct State {
        uint256 epoch;
        uint256 active;
        mapping(bytes32 => Proposal) proposals;
        address[] approvedVoters;
        bool votersInitialized;
        mapping(uint256 => Configuration) configurations;
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

    function state() internal pure returns (State storage s) {
        return state(SLOT);
    }

    /// @dev Callers sharing an address through delegatecall MUST use different slots.
    function state(bytes32 slot) internal pure returns (State storage s) {
        assembly ("memory-safe") { s.slot := slot }
    }

    function proposal(State storage s, bytes32 key) internal view returns (Proposal storage p) { return s.proposals[key]; }
    function current(State storage s, bytes32 key) internal view returns (bool) {
        Proposal storage p = proposal(s, key);
        return p.start != 0 && p.epoch == s.epoch;
    }
    function live(State storage s, bytes32 key) internal view returns (bool) {
        return current(s, key) && block.number <= proposal(s, key).expires;
    }

    function cast(State storage s, bytes32 key, address[] memory members, uint256 duration, address voter)
        internal returns (bool approved)
    {
        if (!live(s, key)) {
            if (current(s, key)) --s.active;
            delete s.proposals[key];
            if (members.length == 0) revert NoVoters();
            if (duration == 0 || duration > 100000) revert InvalidExpiry();
            require(s.active < 64, "Too many active proposals");
            if (!s.votersInitialized) approveVoters(s, members);
            Proposal storage fresh = s.proposals[key];
            fresh.epoch = s.epoch;
            fresh.start = block.number;
            fresh.expires = block.number + duration;
            fresh.threshold = (members.length * 2 + 2) / 3;
            fresh.electorate = members;
            ++s.active;
            emit GovernanceProposalStarted(key, s.epoch, fresh.threshold, fresh.expires, keccak256(abi.encode(members)));
        }
        Proposal storage p = s.proposals[key];
        if (!GovernanceMembers.contains(p.electorate, voter)) revert NotSnapshotVoter();
        if (GovernanceMembers.contains(p.votes, voter)) revert AlreadyVoted();
        p.votes.push(voter);
        return p.votes.length >= p.threshold;
    }

    function complete(State storage s, bytes32 key) internal {
        if (current(s, key)) --s.active;
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
        if (!current(s, key) || block.number <= proposal(s, key).expires) revert NotExpired();
        complete(s, key);
    }
    function voted(State storage s, bytes32 key, address voter) internal view returns (bool) {
        return live(s, key) && GovernanceMembers.contains(proposal(s, key).votes, voter);
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
