// SPDX-License-Identifier: Apache-2.0
//
// Original work Copyright 2021 ConsenSys.
// Derivative work Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// NOTICE: This file has been modified from the original Consensys/Besu
// ValidatorSmartContractAllowList. Changes include overlord/guardian
// governance with threshold voting. Do not assume it is stock or
// unmodified — review all changes before use.

pragma solidity >=0.8.2 <0.8.20;

/*
  _   __     ___    __     __             ___   ____         __ _      __
 | | / /__ _/ (_)__/ /__ _/ /____  ____  / _ | / / /__ _    / / (_)__ / /_
 | |/ / _ `/ / / _  / _ `/ __/ _ \/ __/ / __ |/ / / _ \ |/|/ / / (_-</ __/
 |___/\_,_/_/_/\_,_/\_,_/\__/\___/_/   /_/ |_/_/_/\___/__,__/_/_/___/\__/
                                                         By: CryftCreator

  Pre-genesis review — Validator Allow List  [GENESIS]

  ┌──────────────── Contract Architecture ──────────────────────┐
  │                                                             │
  │  QBFT validator, voter, and root overlord governance.       │
  │  2/3 supermajority quorum for all state changes.            │
  │  Proposal electorates/thresholds/expiry are snapshotted.   │
  │  Deployed at genesis address 0x0000...1111.                 │
  │                                                             │
  │  Manages: validators, voters, root overlords,               │
  │  external delegation contracts, and max-validator cap.      │
  │                                                             │
  │  ── Permanent Management Revocation ──────────────────────  │
  │                                                             │
  │  Three independent management domains can be permanently    │
  │  revoked via voter supermajority vote, delegating all       │
  │  governance to external contracts. IRREVERSIBLE.            │
  │                                                             │
  │  1. Overlord management revocation                          │
  │     Pre-conditions:                                         │
  │       - rootOverlords[] must be empty                       │
  │       - otherOverlordContracts[] must have ≥1 entry         │
  │                                                             │
  │  2. Validator management revocation                         │
  │     Pre-conditions:                                         │
  │       - validators[] must be empty                          │
  │       - otherValidatorContracts[] must have ≥1 entry        │
  │       - getValidators() must return ≥4 addresses            │
  │                                                             │
  │  3. Voter management revocation (LAST — final switch)       │
  │     Pre-conditions:                                         │
  │       - Overlord management must already be revoked         │
  │       - Validator management must already be revoked        │
  │       - votersArray[] must be empty                         │
  │       - otherVoterContracts[] must have ≥1 entry            │
  │       - getVoters() must return ≥1 address                  │
  │                                                             │
  │  Once all three are revoked, this contract's lists are      │
  │  frozen. Upstream changes require explicit refresh votes.  │
  │  Approved cached lists remain available during outages.    │
  └─────────────────────────────────────────────────────────────┘
*/

import "../Governance/GovernanceMembers.sol";
import "../Governance/GovernanceVotes.sol";

import "./ValidatorSmartContractInterface.sol";

contract ValidatorSmartContractAllowList is ValidatorSmartContractInterface {
    event AllowedValidator(address indexed validator, bool added);
    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    event StateChanged(VoteType voteType, uint256 newValue);
    event MaxValidatorsChanged(uint256 newMax);
    event VoteTallyBlockThresholdUpdated(uint256 newThreshold);
    event VoteTallyReset(VoteType voteType, uint256 target);
    event VoterUpdated(address indexed target, bool added);
    event OtherValidatorContractUpdated(address indexed target, bool added);
    event OtherVoterContractUpdated(address indexed target, bool added);
    event RootOverlordUpdated(address indexed target, bool added);
    event OtherOverlordContractUpdated(address indexed target, bool added);
    event OverlordManagementRevoked();
    event ValidatorManagementRevoked();
    event VoterManagementRevoked();

    enum VoteType {
        ADD_VALIDATOR,
        REMOVE_VALIDATOR,
        ADD_VOTER,
        REMOVE_VOTER,
        ADD_OTHER_VALIDATOR_CONTRACT,
        REMOVE_OTHER_VALIDATOR_CONTRACT,
        ADD_OTHER_VOTER_CONTRACT,
        REMOVE_OTHER_VOTER_CONTRACT,
        UPDATE_MAX_VALIDATORS,
        UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
        ADD_ROOT_OVERLORD,
        REMOVE_ROOT_OVERLORD,
        ADD_OTHER_OVERLORD_CONTRACT,
        REMOVE_OTHER_OVERLORD_CONTRACT,
        REVOKE_OVERLORD_MANAGEMENT,
        REVOKE_VALIDATOR_MANAGEMENT,
        REVOKE_VOTER_MANAGEMENT,
        REPLACE_VALIDATOR,
        REFRESH_VALIDATORS,
        REFRESH_VOTERS,
        SET_VOTER_CONFIGURATION,
        REFRESH_ROOTS,
        SET_ROOT_CONFIGURATION,
        SET_VALIDATOR_CONFIGURATION
    }

    struct VoteTally {
        uint256 totalVotes;
        uint256 startVoteBlock;
        address[] voters;
    }

    address private __deprecated_guardian;
    address[] public validators;

    address[] public otherValidatorContracts;
    address[] public votersArray;
    address[] public otherVoterContracts;
    address[] public rootOverlords;
    address[] public otherOverlordContracts;

    uint256 public maxValidators;
    uint256 public voteTallyBlockThreshold;
    uint256 private __legacyActiveVoteCount; // Slot retained; use activeVoteCount().

    bool public overlordManagementRevoked;
    bool public validatorManagementRevoked;
    bool public voterManagementRevoked;

    mapping(VoteType => mapping(uint256 => VoteTally)) private voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool)))
        private __legacyHasVoted;

    struct ValidatorReplacement { address previous; address replacement; }
    mapping(uint256 => ValidatorReplacement) private _validatorReplacements;
    address[] private _effectiveValidators;
    bool private _validatorCacheInitialized;
    address[] private _effectiveRoots;
    bool private _rootCacheInitialized;
    uint256 public constant MIN_VALIDATORS = 4;
    event EffectiveValidatorsUpdated(bytes32 indexed membersHash, uint256 count);

    modifier onlyVoters() {
        address[] memory allVoters = getVoters();
        bool isCallerVoter = false;

        for (uint256 i = 0; i < allVoters.length; i++) {
            if (allVoters[i] == msg.sender) {
                isCallerVoter = true;
                break;
            }
        }

        require(isCallerVoter, "Only voters can call this function");
        _;
    }

    function initialize() public {
        require(votersArray.length == 0, "Contract already initialized");
        votersArray.push(msg.sender);

        voteTallyBlockThreshold = 1000;
        maxValidators = 11;
    }

    // ── Voter & Validator Queries ─────────────────────

    function isVoter(address potentialVoter) public view override returns (bool) {
        return GovernanceMembers.contains(getVoters(), potentialVoter);
    }

    function isValidator(
        address potentialValidator
    ) public view override returns (bool) {
        address[] memory allValidators = getValidators();
        for (uint256 i = 0; i < allValidators.length; i++) {
            if (allValidators[i] == potentialValidator) {
                return true;
            }
        }
        return false;
    }

    // ── Internal Vote Engine ──────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        address[] memory electorate;
        if (!GovernanceVotes.live(GovernanceVotes.state(), key)) electorate = getVoters();
        if (GovernanceVotes.cast(GovernanceVotes.state(), key, electorate, voteTallyBlockThreshold, msg.sender)) {
            emit StateChanged(voteType, target);

            if (voteType == VoteType.UPDATE_MAX_VALIDATORS) {
                maxValidators = target;
                emit MaxValidatorsChanged(target);
            } else if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                if (!(target > 0 && target <= 100000)) revert GovernanceVotes.InvalidExpiry();
                voteTallyBlockThreshold = target;
                emit VoteTallyBlockThresholdUpdated(target);
            } else if (voteType == VoteType.REVOKE_OVERLORD_MANAGEMENT) {
                require(!overlordManagementRevoked, "Overlord management already revoked");
                require(
                    rootOverlords.length == 0,
                    "Cannot revoke: local root overlords still exist, remove them first"
                );
                require(
                    otherOverlordContracts.length > 0,
                    "Cannot revoke: at least one other overlord contract must be listed"
                );
                require(getRootOverlordCount() > 0, "No external root overlords");
                overlordManagementRevoked = true;
                emit OverlordManagementRevoked();
            } else if (voteType == VoteType.REVOKE_VALIDATOR_MANAGEMENT) {
                require(!validatorManagementRevoked, "Validator management already revoked");
                require(
                    validators.length == 0,
                    "Cannot revoke: local validators still exist, remove them first"
                );
                require(
                    otherValidatorContracts.length > 0,
                    "Cannot revoke: at least one other validator contract must be listed"
                );
                require(
                    getValidators().length >= 4,
                    "Cannot revoke: aggregated validator count must be at least 4"
                );
                validatorManagementRevoked = true;
                emit ValidatorManagementRevoked();
            } else if (voteType == VoteType.REVOKE_VOTER_MANAGEMENT) {
                require(!voterManagementRevoked, "Voter management already revoked");
                require(
                    overlordManagementRevoked,
                    "Cannot revoke: overlord management must be revoked first"
                );
                require(
                    validatorManagementRevoked,
                    "Cannot revoke: validator management must be revoked first"
                );
                require(
                    votersArray.length == 0,
                    "Cannot revoke: local voters still exist, remove them first"
                );
                require(
                    otherVoterContracts.length > 0,
                    "Cannot revoke: at least one other voter contract must be listed"
                );
                require(
                    getVoters().length >= 1,
                    "Cannot revoke: aggregated voter count must be at least 1"
                );
                voterManagementRevoked = true;
                emit VoterManagementRevoked();
            } else {
                address targetAddress = address(uint160(target));

                if (voteType == VoteType.ADD_VALIDATOR) {
                    require(!validatorManagementRevoked, "Validator management permanently revoked");
                    require(
                        !isValidator(targetAddress),
                        "Validator already in list"
                    );
                    require(
                        validators.length < GovernanceMembers.MAX_MEMBERS,
                        "Reached max validators"
                    );
                    validators.push(targetAddress);
                    emit AllowedValidator(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_VALIDATOR) {
                    require(!validatorManagementRevoked, "Validator management permanently revoked");
                    bool found = false;
                    for (uint256 i = 0; i < validators.length; i++) {
                        if (validators[i] == targetAddress) {
                            validators[i] = validators[validators.length - 1];
                            validators.pop();
                            emit AllowedValidator(targetAddress, false);
                            found = true;
                            break;
                        }
                    }
                    require(found, "Validator not found");
                } else if (voteType == VoteType.ADD_VOTER) {
                    require(!voterManagementRevoked, "Voter management permanently revoked");
                    if (isVoter(targetAddress)) revert GovernanceVotes.VoterAlreadyPresent();
                    votersArray.push(targetAddress);
                    emit VoterUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_VOTER) {
                    require(!voterManagementRevoked, "Voter management permanently revoked");
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
                } else if (voteType == VoteType.ADD_OTHER_VALIDATOR_CONTRACT) {
                    require(!validatorManagementRevoked, "Validator management permanently revoked");
                    for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
                        require(
                            otherValidatorContracts[i] != targetAddress,
                            "Contract already in list"
                        );
                    }
                    otherValidatorContracts.push(targetAddress);
                    emit OtherValidatorContractUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_OTHER_VALIDATOR_CONTRACT) {
                    require(!validatorManagementRevoked, "Validator management permanently revoked");
                    bool found = false;
                    for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
                        if (otherValidatorContracts[i] == targetAddress) {
                            otherValidatorContracts[i] = otherValidatorContracts[
                                otherValidatorContracts.length - 1
                            ];
                            otherValidatorContracts.pop();
                            found = true;
                            break;
                        }
                    }
                    require(found, "Validator contract not found");
                    emit OtherValidatorContractUpdated(targetAddress, false);
                } else if (voteType == VoteType.ADD_OTHER_VOTER_CONTRACT) {
                    require(!voterManagementRevoked, "Voter management permanently revoked");
                    for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                        if (otherVoterContracts[i] == targetAddress) revert GovernanceVotes.ProviderAlreadyPresent();
                    }
                    otherVoterContracts.push(targetAddress);
                    emit OtherVoterContractUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
                    require(!voterManagementRevoked, "Voter management permanently revoked");
                    if (!(votersArray.length > 0 || otherVoterContracts.length > 1)) revert GovernanceVotes.EmptyVoterSet();
                    bool found = false;
                    for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                        if (otherVoterContracts[i] == targetAddress) {
                            otherVoterContracts[i] = otherVoterContracts[
                                otherVoterContracts.length - 1
                            ];
                            otherVoterContracts.pop();
                            found = true;
                            break;
                        }
                    }
                    if (!found) revert GovernanceVotes.ProviderNotFound();
                    emit OtherVoterContractUpdated(targetAddress, false);
                } else if (voteType == VoteType.ADD_ROOT_OVERLORD) {
                    require(!overlordManagementRevoked, "Overlord management permanently revoked");
                    require(!isRootOverlord(targetAddress), "Already a root overlord");
                    rootOverlords.push(targetAddress);
                    emit RootOverlordUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_ROOT_OVERLORD) {
                    require(!overlordManagementRevoked, "Overlord management permanently revoked");
                    bool found = false;
                    for (uint256 i = 0; i < rootOverlords.length; i++) {
                        if (rootOverlords[i] == targetAddress) {
                            rootOverlords[i] = rootOverlords[rootOverlords.length - 1];
                            rootOverlords.pop();
                            found = true;
                            break;
                        }
                    }
                    require(found, "Root overlord not found");
                    emit RootOverlordUpdated(targetAddress, false);
                } else if (voteType == VoteType.ADD_OTHER_OVERLORD_CONTRACT) {
                    require(!overlordManagementRevoked, "Overlord management permanently revoked");
                    for (uint256 i = 0; i < otherOverlordContracts.length; i++) {
                        require(
                            otherOverlordContracts[i] != targetAddress,
                            "Overlord contract already in list"
                        );
                    }
                    otherOverlordContracts.push(targetAddress);
                    emit OtherOverlordContractUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_OTHER_OVERLORD_CONTRACT) {
                    require(!overlordManagementRevoked, "Overlord management permanently revoked");
                    bool found = false;
                    for (uint256 i = 0; i < otherOverlordContracts.length; i++) {
                        if (otherOverlordContracts[i] == targetAddress) {
                            otherOverlordContracts[i] = otherOverlordContracts[
                                otherOverlordContracts.length - 1
                            ];
                            otherOverlordContracts.pop();
                            found = true;
                            break;
                        }
                    }
                    require(found, "Overlord contract not found");
                    emit OtherOverlordContractUpdated(targetAddress, false);
                }
            }
            _validateValidatorChange(voteType, target);
            if (_changesVoters(voteType)) {
                if (voteType == VoteType.SET_VOTER_CONFIGURATION) {
                    require(!voterManagementRevoked, "Voter management permanently revoked");
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

    // ── Validator Governance ──────────────────────────

    function voteToUpdateMaxValidators(uint256 newMax) external {
        require(
            newMax > 0,
            "New max validators must be greater than zero"
        );
        _castVote(VoteType.UPDATE_MAX_VALIDATORS, newMax);
    }

    function voteToAddValidator(address validator) external {
        require(
            validator != address(0),
            "Validator address should not be zero"
        );
        _castVote(VoteType.ADD_VALIDATOR, uint256(uint160(validator)));
    }

    function voteToRemoveValidator(address validator) external {
        require(
            validator != address(0),
            "Validator address should not be zero"
        );
        _castVote(VoteType.REMOVE_VALIDATOR, uint256(uint160(validator)));
    }

    // ── Voter Management ──────────────────────────────

    function voteToAddVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.ADD_VOTER, uint256(uint160(voter)));
    }

    function voteToRemoveVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.REMOVE_VOTER, uint256(uint160(voter)));
    }

    // ── External Contract Management ──────────────────

    function voteToAddOtherValidatorContract(address contractAddress) external {
        GovernanceMembers.read(contractAddress, bytes4(keccak256("getValidators()")));
        _castVote(VoteType.ADD_OTHER_VALIDATOR_CONTRACT, uint256(uint160(contractAddress)));
    }

    function voteToRemoveOtherValidatorContract(
        address contractAddress
    ) external {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );
        _castVote(VoteType.REMOVE_OTHER_VALIDATOR_CONTRACT, uint256(uint160(contractAddress)));
    }

    function voteToAddOtherVoterContract(address voterContract) external {
        GovernanceMembers.read(voterContract, bytes4(keccak256("getVoters()")));
        _castVote(VoteType.ADD_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    function voteToRemoveOtherVoterContract(
        address voterContract
    ) external {
        if (voterContract == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.REMOVE_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    // ── Root Overlord Management ──────────────────────

    function voteToAddRootOverlord(address overlord) external {
        require(
            overlord != address(0),
            "Root overlord address should not be zero"
        );
        _castVote(VoteType.ADD_ROOT_OVERLORD, uint256(uint160(overlord)));
    }

    function voteToRemoveRootOverlord(address overlord) external {
        require(
            overlord != address(0),
            "Root overlord address should not be zero"
        );
        _castVote(VoteType.REMOVE_ROOT_OVERLORD, uint256(uint160(overlord)));
    }

    function voteToAddOtherOverlordContract(address contractAddress) external {
        GovernanceMembers.read(contractAddress, bytes4(keccak256("getRootOverlords()")));
        _castVote(VoteType.ADD_OTHER_OVERLORD_CONTRACT, uint256(uint160(contractAddress)));
    }

    function voteToRemoveOtherOverlordContract(
        address contractAddress
    ) external {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );
        _castVote(VoteType.REMOVE_OTHER_OVERLORD_CONTRACT, uint256(uint160(contractAddress)));
    }

    // ── Overlord Management Revocation ────────────────

    /**
     * @dev Voters can permanently revoke the ability to add/remove root overlords
     *      and other overlord contracts from THIS contract.
     *      Pre-conditions:
     *        - No locally stored root overlords (rootOverlords must be empty)
     *        - At least one external overlord contract must be listed
     *      Once revoked, all overlord management is permanently delegated
     *      to the listed external contract(s). This action is IRREVERSIBLE.
     */
    function voteToRevokeOverlordManagement() external {
        require(!overlordManagementRevoked, "Overlord management already revoked");
        // Use 1 as a sentinel for this non-targeted vote
        _castVote(VoteType.REVOKE_OVERLORD_MANAGEMENT, 1);
    }

    /**
     * @dev Voters can permanently revoke the ability to add/remove validators
     *      and other validator contracts from THIS contract.
     *      Pre-conditions:
     *        - At least one external validator contract must be listed
     *      Once revoked, all validator management is permanently delegated
     *      to the listed external contract(s). This action is IRREVERSIBLE.
     */
    function voteToRevokeValidatorManagement() external {
        require(!validatorManagementRevoked, "Validator management already revoked");
        _castVote(VoteType.REVOKE_VALIDATOR_MANAGEMENT, 1);
    }

    /**
     * @dev Voters can permanently revoke the ability to add/remove voters
     *      and other voter contracts from THIS contract.
     *      Pre-conditions (enforced to prevent lockout):
     *        - Overlord management must already be revoked
     *        - Validator management must already be revoked
     *        - At least one external voter contract must be listed
     *      This is the LAST management revocation — once done, this contract's
     *      lists are completely frozen. All governance is permanently delegated
     *      to external contracts. This action is IRREVERSIBLE.
     */
    function voteToRevokeVoterManagement() external {
        require(!voterManagementRevoked, "Voter management already revoked");
        _castVote(VoteType.REVOKE_VOTER_MANAGEMENT, 1);
    }

    // ── Vote Threshold Governance ─────────────────────

    function voteToUpdateVoteTallyBlockThreshold(
        uint256 newThreshold
    ) external {
        if (!(newThreshold > 0 && newThreshold <= 100000)) revert GovernanceVotes.InvalidExpiry();
        _castVote(
            VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
            newThreshold
        );
    }

    // ── Vote Tally & Thresholds ───────────────────────

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
            || voteType == VoteType.ADD_OTHER_VOTER_CONTRACT || voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT || voteType == VoteType.REVOKE_VOTER_MANAGEMENT;
    }

    function getSupermajorityThreshold() public view returns (uint256) {
        uint256 totalVoterCount = getVoterCount();
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount * 2 + 2) / 3;
    }

    // ── Aggregation Queries ───────────────────────────

    /// @notice Besu reads the approved set, independent of provider availability.
    function getValidators() public view override returns (address[] memory) {
        if (_validatorCacheInitialized) return _effectiveValidators;
        // Fresh genesis uses its reviewed local validator allocation before the first change.
        return validators;
    }

    /// @notice Returns the total number of validators (local + external).
    function getValidatorCount() public view returns (uint256) { return getValidators().length; }

    function getVoters() public view override returns (address[] memory) {
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

    // ── Root Overlord Queries ─────────────────────────

    function getRootOverlords() public view override returns (address[] memory) {
        if (_rootCacheInitialized) return _effectiveRoots;
        return rootOverlords;
    }

    /// @notice Returns the total number of root overlords (local + external).
    function getRootOverlordCount() public view returns (uint256) { return getRootOverlords().length; }

    function isRootOverlord(address potentialOverlord) public view override returns (bool) {
        return GovernanceMembers.contains(getRootOverlords(), potentialOverlord);
    }

    // ── Expired Tally Cleanup ─────────────────────────

    /// @notice Anyone may clear an expired ballot; no membership or approval changes.
    function resetExpiredTally(VoteType voteType, uint256 target) external {
        GovernanceVotes.resetExpired(GovernanceVotes.state(), _voteKey(voteType, target));
        emit VoteTallyReset(voteType, target);
    }

    // ── Utilities ─────────────────────────────────────

    /// @notice Propose an atomic local validator replacement, retaining the count.
    function voteToReplaceValidator(address previous, address replacement) external {
        require(previous != address(0) && replacement != address(0) && previous != replacement, "Invalid replacement");
        uint256 target = uint256(keccak256(abi.encode(previous, replacement)));
        _validatorReplacements[target] = ValidatorReplacement(previous, replacement);
        _castVote(VoteType.REPLACE_VALIDATOR, target);
    }

    /// @notice Preview provider changes before approving their exact effective-set hash.
    function previewValidators() public view returns (address[] memory members, bytes32 membersHash) {
        members = GovernanceMembers.collect(validators, otherValidatorContracts, bytes4(keccak256("getValidators()")));
        membersHash = keccak256(abi.encode(members));
    }

    /// @notice Provider list changes never silently alter Besu's active validator set.
    ///         Refresh remains possible after local management is delegated/revoked.
    function voteToRefreshValidators(bytes32 expectedHash) external {
        _castVote(VoteType.REFRESH_VALIDATORS, uint256(expectedHash));
    }

    function previewRoots() public view returns (address[] memory members, bytes32 membersHash) {
        members = GovernanceMembers.collect(rootOverlords, otherOverlordContracts, bytes4(keccak256("getRootOverlords()")));
        membersHash = keccak256(abi.encode(members));
    }
    function voteToRefreshRoots(bytes32 expectedHash) external { _castVote(VoteType.REFRESH_ROOTS, uint256(expectedHash)); }
    function voteToSetRootConfiguration(address[] calldata local, address[] calldata providers, bytes32 expectedHash) external {
        _castVote(VoteType.SET_ROOT_CONFIGURATION, GovernanceVotes.configure(GovernanceVotes.state(), local, providers, expectedHash));
    }
    function voteToSetValidatorConfiguration(address[] calldata local, address[] calldata providers, bytes32 expectedHash) external {
        _castVote(VoteType.SET_VALIDATOR_CONFIGURATION, GovernanceVotes.configure(GovernanceVotes.state(), local, providers, expectedHash));
    }

    function _validateValidatorChange(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.SET_VALIDATOR_CONFIGURATION || voteType == VoteType.SET_ROOT_CONFIGURATION) {
            GovernanceVotes.Configuration storage config = GovernanceVotes.state().configurations[target];
            if (voteType == VoteType.SET_VALIDATOR_CONFIGURATION) {
                require(!validatorManagementRevoked, "Validator management permanently revoked");
                validators = config.local;
                otherValidatorContracts = config.providers;
            } else {
                require(!overlordManagementRevoked, "Overlord management permanently revoked");
                rootOverlords = config.local;
                otherOverlordContracts = config.providers;
            }
        }
        if (voteType == VoteType.REPLACE_VALIDATOR) {
            require(!validatorManagementRevoked, "Validator management permanently revoked");
            ValidatorReplacement memory replacement = _validatorReplacements[target];
            require(!isValidator(replacement.replacement), "Validator already in list");
            bool found;
            for (uint256 i; i < validators.length; ++i) {
                if (validators[i] == replacement.previous) { validators[i] = replacement.replacement; found = true; break; }
            }
            require(found, "Validator not found");
            emit AllowedValidator(replacement.previous, false);
            emit AllowedValidator(replacement.replacement, true);
            delete _validatorReplacements[target];
        }
        if (voteType == VoteType.ADD_VALIDATOR || voteType == VoteType.REMOVE_VALIDATOR
            || voteType == VoteType.ADD_OTHER_VALIDATOR_CONTRACT || voteType == VoteType.REMOVE_OTHER_VALIDATOR_CONTRACT
            || voteType == VoteType.UPDATE_MAX_VALIDATORS || voteType == VoteType.REVOKE_VALIDATOR_MANAGEMENT
            || voteType == VoteType.REPLACE_VALIDATOR || voteType == VoteType.REFRESH_VALIDATORS
            || voteType == VoteType.SET_VALIDATOR_CONFIGURATION)
        {
            (address[] memory members, bytes32 membersHash) = previewValidators();
            require(maxValidators >= MIN_VALIDATORS && maxValidators <= GovernanceMembers.MAX_MEMBERS, "Invalid validator maximum");
            require(members.length >= MIN_VALIDATORS && members.length <= maxValidators, "Unsafe validator count");
            if (voteType == VoteType.REFRESH_VALIDATORS) require(membersHash == bytes32(target), "Validator set changed");
            if (voteType == VoteType.SET_VALIDATOR_CONFIGURATION) {
                require(membersHash == GovernanceVotes.state().configurations[target].membersHash, "Validator set changed");
                delete GovernanceVotes.state().configurations[target];
            }
            _effectiveValidators = members;
            _validatorCacheInitialized = true;
            emit EffectiveValidatorsUpdated(membersHash, members.length);
        }
        if (voteType == VoteType.ADD_ROOT_OVERLORD || voteType == VoteType.REMOVE_ROOT_OVERLORD
            || voteType == VoteType.ADD_OTHER_OVERLORD_CONTRACT || voteType == VoteType.REMOVE_OTHER_OVERLORD_CONTRACT
            || voteType == VoteType.REFRESH_ROOTS || voteType == VoteType.SET_ROOT_CONFIGURATION
            || voteType == VoteType.REVOKE_OVERLORD_MANAGEMENT)
        {
            (address[] memory members, bytes32 membersHash) = previewRoots();
            require(members.length > 0, "Cannot remove the last root overlord");
            if (voteType == VoteType.REFRESH_ROOTS) require(membersHash == bytes32(target), "Root set changed");
            if (voteType == VoteType.SET_ROOT_CONFIGURATION) {
                require(membersHash == GovernanceVotes.state().configurations[target].membersHash, "Root set changed");
                delete GovernanceVotes.state().configurations[target];
            }
            _effectiveRoots = members;
            _rootCacheInitialized = true;
        }
    }

    function _isContract(address addr) internal view returns (bool) {
        uint32 size;
        /// @solidity memory-safe-assembly
        assembly {
            size := extcodesize(addr)
        }
        return (size > 0);
    }
}