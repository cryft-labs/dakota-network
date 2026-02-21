// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
  _   __     ___    __     __             ___   ____         __ _      __
 | | / /__ _/ (_)__/ /__ _/ /____  ____  / _ | / / /__ _    / / (_)__ / /_
 | |/ / _ `/ / / _  / _ `/ __/ _ \/ __/ / __ |/ / / _ \ |/|/ / / (_-</ __/
 |___/\_,_/_/_/\_,_/\_,_/\__/\___/_/   /_/ |_/_/_/\___/__,__/_/_/___/\__/
                                                         By: CryftCreator

  Version 1.0 — Production Validator Allow List  [GENESIS]

  ┌──────────────── Contract Architecture ──────────────────────┐
  │                                                             │
  │  QBFT validator, voter, and root overlord governance.       │
  │  2/3 supermajority quorum for all state changes.            │
  │  Voter-pool changes are frozen while any tally is active.   │
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
  │  permanently frozen. All governance is delegated to the     │
  │  listed external contracts.                                 │
  └─────────────────────────────────────────────────────────────┘
*/

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
        CHANGE_MAX_VALIDATORS,
        UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
        ADD_ROOT_OVERLORD,
        REMOVE_ROOT_OVERLORD,
        ADD_OTHER_OVERLORD_CONTRACT,
        REMOVE_OTHER_OVERLORD_CONTRACT,
        REVOKE_OVERLORD_MANAGEMENT,
        REVOKE_VALIDATOR_MANAGEMENT,
        REVOKE_VOTER_MANAGEMENT
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

    uint256 public MAX_VALIDATORS;
    uint256 public voteTallyBlockThreshold;
    uint256 public activeVoteCount;

    bool public overlordManagementRevoked;
    bool public validatorManagementRevoked;
    bool public voterManagementRevoked;

    mapping(VoteType => mapping(uint256 => VoteTally)) private voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool)))
        public hasVoted;

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
        MAX_VALIDATORS = 11;
    }

    // ── Voter & Validator Queries ─────────────────────

    function isVoter(
        address potentialVoter
    ) public view override returns (bool) {
        address[] memory allVoters = getVoters();
        for (uint256 i = 0; i < allVoters.length; i++) {
            if (allVoters[i] == potentialVoter) {
                return true;
            }
        }
        return false;
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
        require(target != 0, "Target should not be zero");
        // Caller validation is enforced by the onlyVoters modifier on all public entry points

        VoteTally storage tally = voteTallies[voteType][target];

        // reset expired tallies based on startVoteBlock
        if (
            tally.startVoteBlock != 0 &&
            block.number > tally.startVoteBlock + voteTallyBlockThreshold
        ) {
            for (uint256 i = 0; i < tally.voters.length; i++) {
                hasVoted[voteType][target][tally.voters[i]] = false;
            }
            tally.totalVotes = 0;
            tally.voters = new address[](0);
            tally.startVoteBlock = 0;
            activeVoteCount--;
            emit VoteTallyReset(voteType, target);
        }

        // ensure not already voted
        require(
            !hasVoted[voteType][target][msg.sender],
            "Voter has already voted for this target"
        );

        // record vote
        if (tally.voters.length == 0) {
            // first vote sets the window start
            tally.startVoteBlock = block.number;
            activeVoteCount++;
        }
        tally.totalVotes++;
        tally.voters.push(msg.sender);
        hasVoted[voteType][target][msg.sender] = true;

        // check for quorum (2/3 supermajority)
        // NOTE: voter-pool changes are blocked while any tally is active
        // (activeVoteCount > 0), so the threshold is stable for in-flight votes.
        if (tally.totalVotes >= getSupermajorityThreshold()) {
            emit StateChanged(voteType, target);

            if (voteType == VoteType.CHANGE_MAX_VALIDATORS) {
                MAX_VALIDATORS = target;
                emit MaxValidatorsChanged(target);
            } else if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                require(
                    target > 0 && target <= 100000,
                    "Threshold must be 1 to 100000"
                );
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
                        validators.length < MAX_VALIDATORS,
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
                    require(!isVoter(targetAddress), "Voter already in the list");
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
                    require(found, "Voter not found");
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
                    require(found, "Contract not found");
                    emit OtherValidatorContractUpdated(targetAddress, false);
                } else if (voteType == VoteType.ADD_OTHER_VOTER_CONTRACT) {
                    require(!voterManagementRevoked, "Voter management permanently revoked");
                    for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                        require(
                            otherVoterContracts[i] != targetAddress,
                            "Voter contract already in list"
                        );
                    }
                    otherVoterContracts.push(targetAddress);
                    emit OtherVoterContractUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
                    require(!voterManagementRevoked, "Voter management permanently revoked");
                    require(
                        votersArray.length > 0 || otherVoterContracts.length > 1,
                        "Cannot remove: would leave no voters in the system"
                    );
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
                    require(found, "Voter contract not found");
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

            // clear votes for this target
            for (uint256 i = 0; i < tally.voters.length; i++) {
                hasVoted[voteType][target][tally.voters[i]] = false;
            }
            delete voteTallies[voteType][target];
            activeVoteCount--;
        }

        emit VoteCast(msg.sender, voteType, target);
    }

    // ── Validator Governance ──────────────────────────

    function voteToChangeMaxValidators(uint256 newMax) external onlyVoters {
        require(
            newMax > 0,
            "New max validators must be within valid range"
        );
        _castVote(VoteType.CHANGE_MAX_VALIDATORS, newMax);
    }

    function voteToAddValidator(address validator) external onlyVoters {
        require(
            validator != address(0),
            "Validator address should not be zero"
        );
        _castVote(VoteType.ADD_VALIDATOR, uint256(uint160(validator)));
    }

    function voteToRemoveValidator(address validator) external onlyVoters {
        require(
            validator != address(0),
            "Validator address should not be zero"
        );
        _castVote(VoteType.REMOVE_VALIDATOR, uint256(uint160(validator)));
    }

    // ── Voter Management ──────────────────────────────

    function voteToAddVoter(address voter) external onlyVoters {
        require(voter != address(0), "Voter address should not be zero");
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        _castVote(VoteType.ADD_VOTER, uint256(uint160(voter)));
    }

    function voteToRemoveVoter(address voter) external onlyVoters {
        require(voter != address(0), "Voter address should not be zero");
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        require(
            getVoters().length > 1,
            "Cannot remove the last voter"
        );
        _castVote(VoteType.REMOVE_VOTER, uint256(uint160(voter)));
    }

    // ── External Contract Management ──────────────────

    function voteToAddOtherValidatorContract(
        address contractAddress
    ) external onlyVoters {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );

        // Check if provided address points to a contract
        require(
            isContract(contractAddress),
            "Provided address does not point to a valid contract"
        );

        // Attempt to create an instance of the ValidatorSmartContractInterface
        ValidatorSmartContractInterface candidateContract = ValidatorSmartContractInterface(
                contractAddress
            );

        // Check if the functions exist and can be called
        try candidateContract.getValidators() {} catch {
            revert(
                "Provided contract does not implement the required getValidators function"
            );
        }

        try candidateContract.isValidator(msg.sender) {} catch {
            revert(
                "Provided contract does not implement the required isValidator function"
            );
        }

        _castVote(VoteType.ADD_OTHER_VALIDATOR_CONTRACT, uint256(uint160(contractAddress)));
    }

    function voteToRemoveOtherValidatorContract(
        address contractAddress
    ) external onlyVoters {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );
        _castVote(VoteType.REMOVE_OTHER_VALIDATOR_CONTRACT, uint256(uint160(contractAddress)));
    }

    function voteToAddOtherVoterContract(
        address voterContract
    ) external onlyVoters {
        require(
            voterContract != address(0),
            "Voter contract address should not be zero"
        );
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");

        // Check if provided address points to a contract
        require(
            isContract(voterContract),
            "Provided address does not point to a valid contract"
        );

        // Attempt to create an instance of the ValidatorSmartContractInterface
        ValidatorSmartContractInterface candidateContract = ValidatorSmartContractInterface(
                voterContract
            );

        // Check if the functions exist and can be called
        try candidateContract.getVoters() {} catch {
            revert(
                "Provided contract does not implement the required getVoters function"
            );
        }

        try candidateContract.isVoter(msg.sender) {} catch {
            revert(
                "Provided contract does not implement the required isVoter function"
            );
        }

        _castVote(VoteType.ADD_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    function voteToRemoveOtherVoterContract(
        address voterContract
    ) external onlyVoters {
        require(
            voterContract != address(0),
            "Voter contract address should not be zero"
        );
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        _castVote(VoteType.REMOVE_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    // ── Root Overlord Management ──────────────────────

    function voteToAddRootOverlord(address overlord) external onlyVoters {
        require(
            overlord != address(0),
            "Root overlord address should not be zero"
        );
        _castVote(VoteType.ADD_ROOT_OVERLORD, uint256(uint160(overlord)));
    }

    function voteToRemoveRootOverlord(address overlord) external onlyVoters {
        require(
            overlord != address(0),
            "Root overlord address should not be zero"
        );
        _castVote(VoteType.REMOVE_ROOT_OVERLORD, uint256(uint160(overlord)));
    }

    function voteToAddOtherOverlordContract(
        address contractAddress
    ) external onlyVoters {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );

        // Check if provided address points to a contract
        require(
            isContract(contractAddress),
            "Provided address does not point to a valid contract"
        );

        // Attempt to verify the contract implements the required interface
        ValidatorSmartContractInterface candidateContract = ValidatorSmartContractInterface(
                contractAddress
            );

        // Check if the functions exist and can be called
        try candidateContract.getRootOverlords() {} catch {
            revert(
                "Provided contract does not implement the required getRootOverlords function"
            );
        }

        try candidateContract.isRootOverlord(msg.sender) {} catch {
            revert(
                "Provided contract does not implement the required isRootOverlord function"
            );
        }

        _castVote(VoteType.ADD_OTHER_OVERLORD_CONTRACT, uint256(uint160(contractAddress)));
    }

    function voteToRemoveOtherOverlordContract(
        address contractAddress
    ) external onlyVoters {
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
    function voteToRevokeOverlordManagement() external onlyVoters {
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
    function voteToRevokeValidatorManagement() external onlyVoters {
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
    function voteToRevokeVoterManagement() external onlyVoters {
        require(!voterManagementRevoked, "Voter management already revoked");
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        _castVote(VoteType.REVOKE_VOTER_MANAGEMENT, 1);
    }

    // ── Vote Threshold Governance ─────────────────────

    function voteToUpdateVoteTallyBlockThreshold(
        uint256 newThreshold
    ) external onlyVoters {
        require(
            newThreshold > 0 && newThreshold <= 100000,
            "Invalid block threshold"
        );
        _castVote(
            VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
            newThreshold
        );
    }

    // ── Vote Tally & Thresholds ───────────────────────

    function getVoteTally(
        VoteType voteType,
        uint256 target
    )
        public
        view
        returns (
            uint256 totalVotes,
            uint256 startVoteBlock,
            uint256 voteExpirationBlock,
            address[] memory votedAddresses
        )
    {
        VoteTally memory tally = voteTallies[voteType][target];
        totalVotes = tally.totalVotes;
        startVoteBlock = tally.startVoteBlock;
        if (startVoteBlock != 0) {
            voteExpirationBlock = startVoteBlock + voteTallyBlockThreshold;
        } else {
            voteExpirationBlock = 0;
        }
        votedAddresses = tally.voters;
    }

    function getSupermajorityThreshold() public view returns (uint256) {
        address[] memory allVoters = getVoters();
        uint256 totalVoterCount = allVoters.length;
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount * 2 + 2) / 3;
    }

    // ── Aggregation Queries ───────────────────────────

    function getValidators() public view override returns (address[] memory) {
        uint256 totalLength = validators.length;

        for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
            ValidatorSmartContractInterface otherContract = ValidatorSmartContractInterface(
                    otherValidatorContracts[i]
                );
            totalLength += otherContract.getValidators().length;
        }

        address[] memory allValidators = new address[](totalLength);

        uint256 counter = 0;

        for (uint256 i = 0; i < validators.length; i++) {
            allValidators[counter] = validators[i];
            counter++;
        }

        for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
            ValidatorSmartContractInterface otherContract = ValidatorSmartContractInterface(
                    otherValidatorContracts[i]
                );
            address[] memory externalValidators = otherContract.getValidators();

            for (uint256 j = 0; j < externalValidators.length; j++) {
                allValidators[counter] = externalValidators[j];
                counter++;
            }
        }

        return allValidators;
    }

    function getVoters() public view override returns (address[] memory) {
        uint256 totalVoterCount = votersArray.length;

        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try ValidatorSmartContractInterface(
                    otherVoterContracts[i]
                ).getVoters() returns (address[] memory ext) {
                totalVoterCount += ext.length;
            } catch {}
        }

        address[] memory allVoters = new address[](totalVoterCount);
        uint256 counter = 0;

        for (uint256 i = 0; i < votersArray.length; i++) {
            allVoters[counter] = votersArray[i];
            counter++;
        }

        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try ValidatorSmartContractInterface(
                    otherVoterContracts[i]
                ).getVoters() returns (address[] memory externalVoters) {
                for (uint256 j = 0; j < externalVoters.length; j++) {
                    allVoters[counter] = externalVoters[j];
                    counter++;
                }
            } catch {}
        }

        return allVoters;
    }

    // ── Root Overlord Queries ─────────────────────────

    function getRootOverlords() public view override returns (address[] memory) {
        uint256 totalLength = rootOverlords.length;

        for (uint256 i = 0; i < otherOverlordContracts.length; i++) {
            try ValidatorSmartContractInterface(
                    otherOverlordContracts[i]
                ).getRootOverlords() returns (address[] memory ext) {
                totalLength += ext.length;
            } catch {}
        }

        address[] memory allOverlords = new address[](totalLength);
        uint256 counter = 0;

        for (uint256 i = 0; i < rootOverlords.length; i++) {
            allOverlords[counter] = rootOverlords[i];
            counter++;
        }

        for (uint256 i = 0; i < otherOverlordContracts.length; i++) {
            try ValidatorSmartContractInterface(
                    otherOverlordContracts[i]
                ).getRootOverlords() returns (address[] memory externalOverlords) {
                for (uint256 j = 0; j < externalOverlords.length; j++) {
                    allOverlords[counter] = externalOverlords[j];
                    counter++;
                }
            } catch {}
        }

        return allOverlords;
    }

    function isRootOverlord(
        address potentialOverlord
    ) public view override returns (bool) {
        if (potentialOverlord == address(0)) return false;

        for (uint256 i = 0; i < rootOverlords.length; i++) {
            if (rootOverlords[i] == potentialOverlord) return true;
        }

        for (uint256 i = 0; i < otherOverlordContracts.length; i++) {
            try ValidatorSmartContractInterface(
                    otherOverlordContracts[i]
                ).isRootOverlord(potentialOverlord) returns (bool result) {
                if (result) return true;
            } catch {}
        }

        return false;
    }

    // ── Expired Tally Cleanup ─────────────────────────

    /// @notice Voter-only function to reset an expired tally and decrement the active vote counter.
    ///         Call this to clean up stale tallies that would otherwise block voter-pool changes.
    function resetExpiredTally(VoteType voteType, uint256 target) external onlyVoters {
        VoteTally storage tally = voteTallies[voteType][target];
        require(tally.startVoteBlock != 0, "No active tally for this target");
        require(
            block.number > tally.startVoteBlock + voteTallyBlockThreshold,
            "Tally has not expired yet"
        );
        for (uint256 i = 0; i < tally.voters.length; i++) {
            hasVoted[voteType][target][tally.voters[i]] = false;
        }
        delete voteTallies[voteType][target];
        activeVoteCount--;
        emit VoteTallyReset(voteType, target);
    }

    // ── Utilities ─────────────────────────────────────

    function isContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }
}