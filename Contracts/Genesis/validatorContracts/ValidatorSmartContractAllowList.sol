// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// Derived from Hyperledger Besu ValidatorSmartContractAllowList (Apache-2.0, ConsenSys 2021).
pragma solidity >=0.8.19 <0.9.0;

import {GovernanceMembers} from "../Governance/GovernanceMembers.sol";
import {GovernanceVotes} from "../Governance/GovernanceVotes.sol";
import {ValidatorSmartContractInterface} from "./ValidatorSmartContractInterface.sol";

/// @title ValidatorSmartContractAllowList
/// @notice Holds the QBFT validator set, the voters and the roots of the Cryft network, changed only by 2/3 voter
///         ballots.
/// @dev Baked into genesis at 0x…1111; genesis storage sets every field, so there is no initializer. Ballots
///      snapshot their electorate, threshold and window (GovernanceVotes). Besu reads the approved validator set
///      (getValidators), which never changes silently when a provider list changes: provider changes need a
///      hash-bound refresh or configuration ballot.
///      Three management domains can be revoked for good, handing that domain to external provider contracts:
///      roots (no local roots, at least one provider, at least one root), validators (no local validators, at
///      least one provider, at least MIN_VALIDATORS validators) and, last, voters (roots and validators already
///      revoked, no local voters, at least one provider, at least one voter). This is irreversible.
///      The compiler of this contract never changes: solc 0.8.19, EVM London, optimizer 200 runs.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
contract ValidatorSmartContractAllowList is ValidatorSmartContractInterface {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @dev Ballot kinds. Members are stored and hashed by index: never reorder, remove or insert.
    enum VoteType {
        AddValidator,
        RemoveValidator,
        AddVoter,
        RemoveVoter,
        AddOtherValidatorContract,      // unused: provider lists change through voteToSetValidatorConfiguration
        RemoveOtherValidatorContract,   // unused
        AddOtherVoterContract,          // unused: use voteToSetVoterConfiguration
        RemoveOtherVoterContract,       // unused
        SetMaxValidators,
        SetVoteWindow,                  // seconds; the setting lives in voteTallyBlockThreshold
        AddRootOverlord,
        RemoveRootOverlord,
        AddOtherOverlordContract,       // unused: use voteToSetRootConfiguration
        RemoveOtherOverlordContract,    // unused
        RevokeOverlordManagement,
        RevokeValidatorManagement,
        RevokeVoterManagement,
        ReplaceValidator,
        RefreshValidators,
        RefreshVoters,
        SetVoterConfiguration,
        RefreshRoots,
        SetRootConfiguration,
        SetValidatorConfiguration,
        SetUpgradeDelay
    }

    /// @dev Legacy ballot record; only its storage slot remains (voteTallies).
    struct VoteTally {
        uint256 totalVotes;
        uint256 startVoteBlock;
        address[] voters;
    }

    /// @dev A pending validator swap, keyed by its ballot target.
    struct ValidatorReplacement { address previous; address replacement; }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @notice Fewest validators the approved set may hold.
    uint256 public constant MIN_VALIDATORS = 4;
    /// @notice Longest proxy upgrade delay voters may set.
    uint256 public constant MAX_UPGRADE_DELAY = 30 days;

    /// @dev `kind` values of ManagementRevoked.
    uint8 private constant _ROOT_DOMAIN = 0;
    uint8 private constant _VALIDATOR_DOMAIN = 1;
    uint8 private constant _VOTER_DOMAIN = 2;

    // ─── Storage ─────────────────────────────────────────────────────────────────────────────────
    // Genesis storage is derived from this layout (Tools/Genesis/build.py). Never reorder, retype or remove.

    address private __deprecated_guardian;
    address[] public validators;

    address[] public otherValidatorContracts;
    address[] public votersArray;
    address[] public otherVoterContracts;
    address[] public rootOverlords;
    address[] public otherOverlordContracts;

    uint256 public maxValidators;
    /// @notice The ballot window in seconds (one hour to 30 days). The name is kept for its storage slot.
    uint256 public voteTallyBlockThreshold;
    uint256 private __legacyActiveVoteCount; // Slot retained; use activeVoteCount().

    bool public overlordManagementRevoked;
    bool public validatorManagementRevoked;
    bool public voterManagementRevoked;

    mapping(VoteType => mapping(uint256 => VoteTally)) private voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool)))
        private __legacyHasVoted;

    mapping(uint256 => ValidatorReplacement) private _validatorReplacements;
    address[] private _effectiveValidators;
    bool private _validatorCacheInitialized;
    address[] private _effectiveRoots;
    bool private _rootCacheInitialized;
    /// @notice Seconds every genesis proxy waits between scheduling and executing an implementation upgrade.
    ///         Set by genesis storage; changed only by a voter ballot. May be 0 in development.
    uint256 public upgradeDelay;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A validator was added to or removed from the local list.
    event AllowedValidator(address indexed validator, bool added);
    /// @notice A voter voted on a ballot.
    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    /// @notice A ballot passed and its change was applied.
    event StateChanged(VoteType voteType, uint256 newValue);
    /// @notice The validator cap changed.
    event MaxValidatorsUpdated(uint256 newMax);
    /// @notice The ballot window changed (seconds).
    event VoteWindowUpdated(uint256 newWindow);
    /// @notice An expired ballot was cleared.
    event VoteTallyReset(VoteType voteType, uint256 target);
    /// @notice A voter was added to or removed from the local list.
    event VoterUpdated(address indexed target, bool added);
    /// @notice Not emitted; kept in the ABI.
    event OtherVoterContractUpdated(address indexed target, bool added);
    /// @notice A root was added to or removed from the local list.
    event RootOverlordUpdated(address indexed target, bool added);
    /// @notice Root management was revoked for good.
    event OverlordManagementRevoked();
    /// @notice Validator management was revoked for good.
    event ValidatorManagementRevoked();
    /// @notice Voter management was revoked for good.
    event VoterManagementRevoked();
    /// @notice The proxy upgrade delay changed (seconds).
    event UpgradeDelayUpdated(uint256 newDelay);
    /// @notice The approved validator set that Besu reads changed.
    event EffectiveValidatorsUpdated(bytes32 indexed membersHash, uint256 count);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice An address argument is zero.
    error ZeroAddress();
    /// @notice The upgrade delay is over MAX_UPGRADE_DELAY.
    error UpgradeDelayTooLong();
    /// @notice The management domain `kind` (0 roots, 1 validators, 2 voters) is revoked for good.
    error ManagementRevoked(uint8 kind);
    /// @notice Revocation needs the local list of that domain to be empty first.
    error LocalMembersRemain();
    /// @notice Revocation needs at least one provider contract and at least one member from providers.
    error NoProviderListed();
    /// @notice The approved validator set would be under MIN_VALIDATORS or over the validator cap.
    error UnsafeValidatorCount();
    /// @notice Voter management can be revoked only after root and validator management.
    error RevokeOrder();
    /// @notice The address is already a validator.
    error AlreadyValidator();
    /// @notice The address is not in the list.
    error NotFound(address member);
    /// @notice The address is already a root.
    error AlreadyRootOverlord();
    /// @notice The validator cap is zero, under MIN_VALIDATORS or over the member cap.
    error InvalidValidatorMaximum();
    /// @notice A validator replacement names a zero or identical address.
    error InvalidReplacement();
    /// @notice The ballot would leave no root.
    error LastRootOverlord();

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Votes to set the validator cap.
    function voteToSetMaxValidators(uint256 newMax) external {
        if (newMax == 0) revert InvalidValidatorMaximum();
        _castVote(VoteType.SetMaxValidators, newMax);
    }

    /// @notice Votes to add `validator` to the local validator list.
    function voteToAddValidator(address validator) external {
        if (validator == address(0)) revert ZeroAddress();
        _castVote(VoteType.AddValidator, uint256(uint160(validator)));
    }

    /// @notice Votes to remove `validator` from the local validator list.
    function voteToRemoveValidator(address validator) external {
        if (validator == address(0)) revert ZeroAddress();
        _castVote(VoteType.RemoveValidator, uint256(uint160(validator)));
    }

    /// @notice Votes to swap `previous` for `replacement` in the local validator list, keeping the count.
    function voteToReplaceValidator(address previous, address replacement) external {
        if (previous == address(0) || replacement == address(0) || previous == replacement) {
            revert InvalidReplacement();
        }
        uint256 target = uint256(keccak256(abi.encode(previous, replacement)));
        _validatorReplacements[target] = ValidatorReplacement(previous, replacement);
        _castVote(VoteType.ReplaceValidator, target);
    }

    /// @notice Votes to approve the current provider-derived validator set, bound to its hash.
    /// @dev Still possible after local validator management is revoked.
    function voteToRefreshValidators(bytes32 expectedHash) external {
        _castVote(VoteType.RefreshValidators, uint256(expectedHash));
    }

    /// @notice Votes to replace the local validator list and providers, bound to the resulting set's hash.
    function voteToSetValidatorConfiguration(
        address[] calldata local,
        address[] calldata providers,
        bytes32 expectedHash
    ) external {
        uint256 target = GovernanceVotes.configure(GovernanceVotes.state(), local, providers, expectedHash);
        _castVote(VoteType.SetValidatorConfiguration, target);
    }

    /// @notice Votes to add `voter` to the local voter list.
    function voteToAddVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.AddVoter, uint256(uint160(voter)));
    }

    /// @notice Votes to remove `voter` from the local voter list.
    /// @dev Exempt from the ballot caps, so a voter's junk ballots cannot block its own removal.
    function voteToRemoveVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.RemoveVoter, uint256(uint160(voter)));
    }

    /// @notice Votes to approve the current provider-derived voter set, bound to its hash.
    function voteToRefreshVoters(bytes32 expectedHash) external {
        _castVote(VoteType.RefreshVoters, uint256(expectedHash));
    }

    /// @notice Votes to replace the local voter list and providers (handover or recovery), bound to the
    ///         resulting set's hash.
    /// @dev Exempt from the ballot caps.
    function voteToSetVoterConfiguration(
        address[] calldata local,
        address[] calldata providers,
        bytes32 expectedHash
    ) external {
        uint256 target = GovernanceVotes.configure(GovernanceVotes.state(), local, providers, expectedHash);
        _castVote(VoteType.SetVoterConfiguration, target);
    }

    /// @notice Votes to add `overlord` to the local root list.
    function voteToAddRootOverlord(address overlord) external {
        if (overlord == address(0)) revert ZeroAddress();
        _castVote(VoteType.AddRootOverlord, uint256(uint160(overlord)));
    }

    /// @notice Votes to remove `overlord` from the local root list.
    function voteToRemoveRootOverlord(address overlord) external {
        if (overlord == address(0)) revert ZeroAddress();
        _castVote(VoteType.RemoveRootOverlord, uint256(uint160(overlord)));
    }

    /// @notice Votes to approve the current provider-derived root set, bound to its hash.
    function voteToRefreshRoots(bytes32 expectedHash) external {
        _castVote(VoteType.RefreshRoots, uint256(expectedHash));
    }

    /// @notice Votes to replace the local root list and providers, bound to the resulting set's hash.
    function voteToSetRootConfiguration(
        address[] calldata local,
        address[] calldata providers,
        bytes32 expectedHash
    ) external {
        uint256 target = GovernanceVotes.configure(GovernanceVotes.state(), local, providers, expectedHash);
        _castVote(VoteType.SetRootConfiguration, target);
    }

    /// @notice Votes to revoke root management in this contract for good.
    /// @dev Applies only when the local root list is empty and providers supply at least one root. Irreversible.
    function voteToRevokeOverlordManagement() external {
        if (overlordManagementRevoked) revert ManagementRevoked(_ROOT_DOMAIN);
        // Target 1 stands for this ballot, which has no address target.
        _castVote(VoteType.RevokeOverlordManagement, 1);
    }

    /// @notice Votes to revoke validator management in this contract for good.
    /// @dev Applies only when the local validator list is empty and providers supply at least MIN_VALIDATORS
    ///      validators. Irreversible.
    function voteToRevokeValidatorManagement() external {
        if (validatorManagementRevoked) revert ManagementRevoked(_VALIDATOR_DOMAIN);
        _castVote(VoteType.RevokeValidatorManagement, 1);
    }

    /// @notice Votes to revoke voter management in this contract for good; the last revocation.
    /// @dev Applies only after root and validator management are revoked, with no local voters and at least one
    ///      voter from providers. Afterwards every list here is frozen. Irreversible.
    function voteToRevokeVoterManagement() external {
        if (voterManagementRevoked) revert ManagementRevoked(_VOTER_DOMAIN);
        _castVote(VoteType.RevokeVoterManagement, 1);
    }

    /// @notice Votes to set the ballot window in seconds (one hour to 30 days).
    function voteToSetVoteWindow(uint256 newWindowSeconds) external {
        if (!GovernanceVotes.validWindow(newWindowSeconds)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.SetVoteWindow, newWindowSeconds);
    }

    /// @notice Votes to set the proxy upgrade delay in seconds (0 to 30 days), read by every genesis proxy.
    function voteToSetUpgradeDelay(uint256 delaySeconds) external {
        if (delaySeconds > MAX_UPGRADE_DELAY) revert UpgradeDelayTooLong();
        _castVote(VoteType.SetUpgradeDelay, delaySeconds + 1);
    }

    /// @notice Clears an expired ballot. Anyone may call it; it changes no membership and approves nothing.
    function resetExpiredTally(VoteType voteType, uint256 target) external {
        GovernanceVotes.resetExpired(GovernanceVotes.state(), _voteKey(voteType, target));
        emit VoteTallyReset(voteType, target);
    }

    /// @notice Returns the proxy upgrade delay in seconds.
    function getUpgradeDelay() external view returns (uint256) {
        return upgradeDelay;
    }

    /// @notice Returns the open ballots `proposer` holds in the current epoch: (counted, exempt).
    function openBallots(address proposer) external view returns (uint256 counted, uint256 exempt) {
        return GovernanceVotes.openCount(GovernanceVotes.state(), proposer);
    }

    /// @notice Returns a ballot's snapshot: threshold, closing time, epoch and electorate.
    function getProposalSnapshot(VoteType voteType, uint256 target)
        external
        view
        returns (uint256 threshold, uint256 expires, uint256 epoch, address[] memory electorate)
    {
        return GovernanceVotes.snapshot(GovernanceVotes.state(), _voteKey(voteType, target));
    }

    /// @notice Returns the current electorate epoch.
    function governanceEpoch() external view returns (uint256) {
        return GovernanceVotes.state().epoch;
    }

    /// @notice Returns true if `voter` voted on the open ballot.
    function hasVoted(VoteType voteType, uint256 target, address voter) external view returns (bool) {
        return GovernanceVotes.voted(GovernanceVotes.state(), _voteKey(voteType, target), voter);
    }

    /// @notice Returns the voter set that providers and the local list give now, and its hash.
    function previewVoters() external view returns (address[] memory members, bytes32 membersHash) {
        members = _readVoters();
        membersHash = keccak256(abi.encode(members));
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @notice Returns true if `potentialVoter` is an approved voter.
    function isVoter(address potentialVoter) public view override returns (bool) {
        return GovernanceMembers.contains(getVoters(), potentialVoter);
    }

    /// @notice Returns true if `potentialValidator` is in the approved validator set.
    /// @dev Bounded: the set holds at most GovernanceMembers.MAX_MEMBERS addresses.
    function isValidator(address potentialValidator) public view override returns (bool) {
        address[] memory allValidators = getValidators();
        for (uint256 i; i < allValidators.length; ++i) {
            if (allValidators[i] == potentialValidator) return true;
        }
        return false;
    }

    /// @notice Returns a ballot's tally: votes, opening time, closing time and the voters so far.
    function getVoteTally(VoteType voteType, uint256 target)
        public
        view
        returns (
            uint256 totalVotes,
            uint256 startVoteBlock,
            uint256 voteExpirationBlock,
            address[] memory votedAddresses
        )
    {
        return GovernanceVotes.tally(GovernanceVotes.state(), _voteKey(voteType, target));
    }

    /// @notice Returns the counted ballots open in the current epoch.
    function activeVoteCount() public view returns (uint256) {
        return GovernanceVotes.state().active;
    }

    /// @notice Returns the votes a ballot needs with the current voter set: ceil(2/3 of the voters).
    function getSupermajorityThreshold() public view returns (uint256) {
        uint256 totalVoterCount = getVoterCount();
        if (totalVoterCount == 0) revert GovernanceVotes.NoVoters();
        return (totalVoterCount * 2 + 2) / 3;
    }

    /// @notice Returns the approved validator set that Besu reads, independent of provider availability.
    function getValidators() public view override returns (address[] memory) {
        if (_validatorCacheInitialized) return _effectiveValidators;
        // A fresh genesis uses its reviewed local validator list until the first change.
        return validators;
    }

    /// @notice Returns the number of approved validators.
    function getValidatorCount() public view returns (uint256) {
        return getValidators().length;
    }

    /// @notice Returns the validator set that providers and the local list give now, and its hash.
    function previewValidators() public view returns (address[] memory members, bytes32 membersHash) {
        members = GovernanceMembers.collect(
            validators, otherValidatorContracts, bytes4(keccak256("getValidators()"))
        );
        membersHash = keccak256(abi.encode(members));
    }

    /// @notice Returns the approved voter set.
    function getVoters() public view override returns (address[] memory) {
        if (GovernanceVotes.state().votersInitialized) return GovernanceVotes.state().approvedVoters;
        return _readVoters();
    }

    /// @notice Returns the number of approved voters.
    function getVoterCount() public view returns (uint256) {
        return getVoters().length;
    }

    /// @notice Returns the approved root set.
    function getRootOverlords() public view override returns (address[] memory) {
        if (_rootCacheInitialized) return _effectiveRoots;
        return rootOverlords;
    }

    /// @notice Returns the number of approved roots.
    function getRootOverlordCount() public view returns (uint256) {
        return getRootOverlords().length;
    }

    /// @notice Returns true if `potentialOverlord` is an approved root.
    function isRootOverlord(address potentialOverlord) public view override returns (bool) {
        return GovernanceMembers.contains(getRootOverlords(), potentialOverlord);
    }

    /// @notice Returns the root set that providers and the local list give now, and its hash.
    function previewRoots() public view returns (address[] memory members, bytes32 membersHash) {
        members = GovernanceMembers.collect(
            rootOverlords, otherOverlordContracts, bytes4(keccak256("getRootOverlords()"))
        );
        membersHash = keccak256(abi.encode(members));
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @dev Records the caller's vote and, when the ballot passes, applies it. Voter removal and voter-set
    ///      configuration never count toward the ballot caps.
    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        address[] memory electorate;
        if (!GovernanceVotes.live(GovernanceVotes.state(), key)) electorate = getVoters();
        bool exempt = voteType == VoteType.RemoveVoter || voteType == VoteType.SetVoterConfiguration;
        bool approved = GovernanceVotes.cast(
            GovernanceVotes.state(), key, electorate, voteTallyBlockThreshold, msg.sender, exempt
        );
        if (approved) {
            emit StateChanged(voteType, target);
            _applySetting(voteType, target);
            _applyMembership(voteType, address(uint160(target)));
            _validateValidatorChange(voteType, target);
            if (_changesVoters(voteType)) _approveVoterChange(voteType, target);
            GovernanceVotes.complete(GovernanceVotes.state(), key);
            if (_changesVoters(voteType)) GovernanceVotes.invalidate(GovernanceVotes.state());
        }
        emit VoteCast(msg.sender, voteType, target);
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    /// @dev Scalar settings and the one-way management revocations.
    function _applySetting(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.SetMaxValidators) {
            maxValidators = target;
            emit MaxValidatorsUpdated(target);
        } else if (voteType == VoteType.SetVoteWindow) {
            if (!GovernanceVotes.validWindow(target)) revert GovernanceVotes.InvalidExpiry();
            voteTallyBlockThreshold = target;
            emit VoteWindowUpdated(target);
        } else if (voteType == VoteType.SetUpgradeDelay) {
            uint256 delay = target - 1; // target 0 is reserved; the ballot target is delay + 1
            if (delay > MAX_UPGRADE_DELAY) revert UpgradeDelayTooLong();
            upgradeDelay = delay;
            emit UpgradeDelayUpdated(delay);
        } else if (voteType == VoteType.RevokeOverlordManagement) {
            if (overlordManagementRevoked) revert ManagementRevoked(_ROOT_DOMAIN);
            if (rootOverlords.length != 0) revert LocalMembersRemain();
            if (otherOverlordContracts.length == 0) revert NoProviderListed();
            if (getRootOverlordCount() == 0) revert NoProviderListed();
            overlordManagementRevoked = true;
            emit OverlordManagementRevoked();
        } else if (voteType == VoteType.RevokeValidatorManagement) {
            if (validatorManagementRevoked) revert ManagementRevoked(_VALIDATOR_DOMAIN);
            if (validators.length != 0) revert LocalMembersRemain();
            if (otherValidatorContracts.length == 0) revert NoProviderListed();
            if (getValidators().length < MIN_VALIDATORS) revert UnsafeValidatorCount();
            validatorManagementRevoked = true;
            emit ValidatorManagementRevoked();
        } else if (voteType == VoteType.RevokeVoterManagement) {
            if (voterManagementRevoked) revert ManagementRevoked(_VOTER_DOMAIN);
            if (!overlordManagementRevoked) revert RevokeOrder();
            if (!validatorManagementRevoked) revert RevokeOrder();
            if (votersArray.length != 0) revert LocalMembersRemain();
            if (otherVoterContracts.length == 0) revert NoProviderListed();
            if (getVoters().length == 0) revert GovernanceVotes.NoVoters();
            voterManagementRevoked = true;
            emit VoterManagementRevoked();
        }
    }

    /// @dev Single-address membership ballots. Provider lists change only through the hash-bound
    ///      voteToSet*Configuration ballots.
    function _applyMembership(VoteType voteType, address targetAddress) private {
        if (voteType == VoteType.AddValidator) {
            if (validatorManagementRevoked) revert ManagementRevoked(_VALIDATOR_DOMAIN);
            if (isValidator(targetAddress)) revert AlreadyValidator();
            if (validators.length >= GovernanceMembers.MAX_MEMBERS) revert GovernanceMembers.TooManyMembers();
            validators.push(targetAddress);
            emit AllowedValidator(targetAddress, true);
        } else if (voteType == VoteType.RemoveValidator) {
            if (validatorManagementRevoked) revert ManagementRevoked(_VALIDATOR_DOMAIN);
            if (!_removeFrom(validators, targetAddress)) revert NotFound(targetAddress);
            emit AllowedValidator(targetAddress, false);
        } else if (voteType == VoteType.AddVoter) {
            if (voterManagementRevoked) revert ManagementRevoked(_VOTER_DOMAIN);
            if (isVoter(targetAddress)) revert GovernanceVotes.VoterAlreadyPresent();
            if (votersArray.length >= GovernanceMembers.MAX_MEMBERS) revert GovernanceMembers.TooManyMembers();
            votersArray.push(targetAddress);
            emit VoterUpdated(targetAddress, true);
        } else if (voteType == VoteType.RemoveVoter) {
            if (voterManagementRevoked) revert ManagementRevoked(_VOTER_DOMAIN);
            if (!_removeFrom(votersArray, targetAddress)) revert GovernanceVotes.VoterNotFound();
            emit VoterUpdated(targetAddress, false);
        } else if (voteType == VoteType.AddRootOverlord) {
            if (overlordManagementRevoked) revert ManagementRevoked(_ROOT_DOMAIN);
            if (isRootOverlord(targetAddress)) revert AlreadyRootOverlord();
            if (rootOverlords.length >= GovernanceMembers.MAX_MEMBERS) revert GovernanceMembers.TooManyMembers();
            rootOverlords.push(targetAddress);
            emit RootOverlordUpdated(targetAddress, true);
        } else if (voteType == VoteType.RemoveRootOverlord) {
            if (overlordManagementRevoked) revert ManagementRevoked(_ROOT_DOMAIN);
            if (!_removeFrom(rootOverlords, targetAddress)) revert NotFound(targetAddress);
            emit RootOverlordUpdated(targetAddress, false);
        }
    }

    /// @dev Bounded swap-and-pop removal (lists are capped at GovernanceMembers.MAX_MEMBERS).
    function _removeFrom(address[] storage list, address member) private returns (bool) {
        uint256 length = list.length;
        for (uint256 i; i < length; ++i) {
            if (list[i] == member) {
                list[i] = list[length - 1];
                list.pop();
                return true;
            }
        }
        return false;
    }

    /// @dev Applies a voter configuration and approves the resulting voter set.
    function _approveVoterChange(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.SetVoterConfiguration) {
            if (voterManagementRevoked) revert ManagementRevoked(_VOTER_DOMAIN);
            GovernanceVotes.Configuration storage config = GovernanceVotes.state().configurations[target];
            votersArray = config.local;
            otherVoterContracts = config.providers;
        }
        address[] memory members = _readVoters();
        if (members.length == 0) revert GovernanceVotes.EmptyVoterSet();
        bytes32 membersHash = keccak256(abi.encode(members));
        if (voteType == VoteType.RefreshVoters && membersHash != bytes32(target)) {
            revert GovernanceVotes.MembershipChanged();
        }
        if (voteType == VoteType.SetVoterConfiguration) {
            if (membersHash != GovernanceVotes.state().configurations[target].membersHash) {
                revert GovernanceVotes.MembershipChanged();
            }
            delete GovernanceVotes.state().configurations[target];
        }
        GovernanceVotes.approveVoters(GovernanceVotes.state(), members);
    }

    /// @dev Applies validator and root list changes and re-approves the sets Besu and the proxies read.
    function _validateValidatorChange(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.SetValidatorConfiguration || voteType == VoteType.SetRootConfiguration) {
            GovernanceVotes.Configuration storage config = GovernanceVotes.state().configurations[target];
            if (voteType == VoteType.SetValidatorConfiguration) {
                if (validatorManagementRevoked) revert ManagementRevoked(_VALIDATOR_DOMAIN);
                validators = config.local;
                otherValidatorContracts = config.providers;
            } else {
                if (overlordManagementRevoked) revert ManagementRevoked(_ROOT_DOMAIN);
                rootOverlords = config.local;
                otherOverlordContracts = config.providers;
            }
        }
        if (voteType == VoteType.ReplaceValidator) {
            if (validatorManagementRevoked) revert ManagementRevoked(_VALIDATOR_DOMAIN);
            ValidatorReplacement memory replacement = _validatorReplacements[target];
            if (isValidator(replacement.replacement)) revert AlreadyValidator();
            bool found;
            // Bounded: the local list holds at most GovernanceMembers.MAX_MEMBERS addresses.
            for (uint256 i; i < validators.length; ++i) {
                if (validators[i] == replacement.previous) {
                    validators[i] = replacement.replacement;
                    found = true;
                    break;
                }
            }
            if (!found) revert NotFound(replacement.previous);
            emit AllowedValidator(replacement.previous, false);
            emit AllowedValidator(replacement.replacement, true);
            delete _validatorReplacements[target];
        }
        if (
            voteType == VoteType.AddValidator || voteType == VoteType.RemoveValidator
                || voteType == VoteType.SetMaxValidators || voteType == VoteType.RevokeValidatorManagement
                || voteType == VoteType.ReplaceValidator || voteType == VoteType.RefreshValidators
                || voteType == VoteType.SetValidatorConfiguration
        ) {
            (address[] memory members, bytes32 membersHash) = previewValidators();
            if (maxValidators < MIN_VALIDATORS || maxValidators > GovernanceMembers.MAX_MEMBERS) {
                revert InvalidValidatorMaximum();
            }
            if (members.length < MIN_VALIDATORS || members.length > maxValidators) revert UnsafeValidatorCount();
            if (voteType == VoteType.RefreshValidators && membersHash != bytes32(target)) {
                revert GovernanceVotes.MembershipChanged();
            }
            if (voteType == VoteType.SetValidatorConfiguration) {
                if (membersHash != GovernanceVotes.state().configurations[target].membersHash) {
                    revert GovernanceVotes.MembershipChanged();
                }
                delete GovernanceVotes.state().configurations[target];
            }
            _effectiveValidators = members;
            _validatorCacheInitialized = true;
            emit EffectiveValidatorsUpdated(membersHash, members.length);
        }
        if (
            voteType == VoteType.AddRootOverlord || voteType == VoteType.RemoveRootOverlord
                || voteType == VoteType.RefreshRoots || voteType == VoteType.SetRootConfiguration
                || voteType == VoteType.RevokeOverlordManagement
        ) {
            (address[] memory members, bytes32 membersHash) = previewRoots();
            if (members.length == 0) revert LastRootOverlord();
            if (voteType == VoteType.RefreshRoots && membersHash != bytes32(target)) {
                revert GovernanceVotes.MembershipChanged();
            }
            if (voteType == VoteType.SetRootConfiguration) {
                if (membersHash != GovernanceVotes.state().configurations[target].membersHash) {
                    revert GovernanceVotes.MembershipChanged();
                }
                delete GovernanceVotes.state().configurations[target];
            }
            _effectiveRoots = members;
            _rootCacheInitialized = true;
        }
    }

    /// @dev The voter set that the local list and providers give now.
    function _readVoters() private view returns (address[] memory) {
        return GovernanceMembers.collect(votersArray, otherVoterContracts, bytes4(keccak256("getVoters()")));
    }

    /// @dev Ballot key: one ballot per (kind, target).
    function _voteKey(VoteType voteType, uint256 target) private pure returns (bytes32) {
        return keccak256(abi.encode(voteType, target));
    }

    /// @dev Ballot kinds that change the voter set (and so start a new electorate epoch).
    function _changesVoters(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.RefreshVoters || voteType == VoteType.SetVoterConfiguration
            || voteType == VoteType.AddVoter || voteType == VoteType.RemoveVoter
            || voteType == VoteType.RevokeVoterManagement;
    }
}
