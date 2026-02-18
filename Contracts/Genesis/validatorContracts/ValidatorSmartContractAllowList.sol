// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.8.20;

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
  │  Majority-vote quorum for all state changes.                │
  │  Deployed at genesis address 0x0000...1111.                 │
  │                                                             │
  │  Manages: validators, voters, root overlords,               │
  │  external delegation contracts, and max-validator cap.      │
  │                                                             │
  │  ── Permanent Management Revocation ──────────────────────  │
  │                                                             │
  │  Three independent management domains can be permanently    │
  │  revoked via voter majority vote, delegating all future     │
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
  │       - otherVotersArray[] must have ≥1 entry               │
  │       - getAllVoters() must return ≥1 address               │
  │                                                             │
  │  Once all three are revoked, this contract's lists are      │
  │  permanently frozen. All governance is delegated to the     │
  │  listed external contracts.                                 │
  └─────────────────────────────────────────────────────────────┘
*/

import "./ValidatorSmartContractInterface.sol";

contract ValidatorSmartContractAllowList is ValidatorSmartContractInterface {
    event AllowedValidator(address indexed validator, bool added);
    event VoteCast(address indexed voter, VoteType voteType, address target);
    event StateChanged(VoteType voteType, address newValue);
    event MaxValidatorsChanged(uint32 newMax);
    event VoteTallyBlockThresholdUpdated(uint32 newThreshold);
    event VoteTallyReset(VoteType voteType, address target);
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

    address private __deprecated_guardian; // slot 0 — preserved for genesis storage compatibility

    address[] public validators;
    address[] public otherValidatorContracts;

    address[] public votersArray;
    address[] public otherVotersArray;

    uint32 public MAX_VALIDATORS;
    uint32 public voteTallyBlockThreshold;

    address[] public rootOverlords;
    address[] public otherOverlordContracts;

    bool public overlordManagementRevoked;
    bool public validatorManagementRevoked;
    bool public voterManagementRevoked;

    mapping(VoteType => mapping(address => VoteTally)) private voteTallies;
    mapping(VoteType => mapping(address => mapping(address => bool)))
        public hasVoted;

    modifier onlyVoters() {
        address[] memory allVoters = getAllVoters();
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
        address[] memory allVoters = getAllVoters();
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

    function _castVote(VoteType voteType, address target) internal {
        require(target != address(0), "Target should not be zero");
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
        }
        tally.totalVotes++;
        tally.voters.push(msg.sender);
        hasVoted[voteType][target][msg.sender] = true;

        // check for quorum
        // NOTE: threshold is computed dynamically — adding/removing voters during
        // an active tally will shift the required quorum for in-flight votes.
        uint256 threshold = (getAllVoters().length / 2) + 1;
        if (tally.totalVotes >= threshold) {
            emit StateChanged(voteType, target);

            if (voteType == VoteType.ADD_VALIDATOR) {
                require(!validatorManagementRevoked, "Validator management permanently revoked");
                require(
                    !isValidator(target),
                    "Validator already in list"
                );
                require(
                    validators.length < MAX_VALIDATORS,
                    "Reached max validators"
                );
                validators.push(target);
                emit AllowedValidator(target, true);
            } else if (voteType == VoteType.REMOVE_VALIDATOR) {
                require(!validatorManagementRevoked, "Validator management permanently revoked");
                bool found = false;
                for (uint256 i = 0; i < validators.length; i++) {
                    if (validators[i] == target) {
                        validators[i] = validators[validators.length - 1];
                        validators.pop();
                        emit AllowedValidator(target, false);
                        found = true;
                        break;
                    }
                }
                require(found, "Validator not found");
            } else if (voteType == VoteType.ADD_VOTER) {
                require(!voterManagementRevoked, "Voter management permanently revoked");
                require(!isVoter(target), "Voter already in the list");
                votersArray.push(target);
                emit VoterUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_VOTER) {
                require(!voterManagementRevoked, "Voter management permanently revoked");
                bool found = false;
                for (uint256 i = 0; i < votersArray.length; i++) {
                    if (votersArray[i] == target) {
                        votersArray[i] = votersArray[votersArray.length - 1];
                        votersArray.pop();
                        found = true;
                        break;
                    }
                }
                require(found, "Voter not found");
                emit VoterUpdated(target, false);
            } else if (voteType == VoteType.ADD_OTHER_VALIDATOR_CONTRACT) {
                require(!validatorManagementRevoked, "Validator management permanently revoked");
                for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
                    require(
                        otherValidatorContracts[i] != target,
                        "Contract already in list"
                    );
                }
                otherValidatorContracts.push(target);
                emit OtherValidatorContractUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_OTHER_VALIDATOR_CONTRACT) {
                require(!validatorManagementRevoked, "Validator management permanently revoked");
                bool found = false;
                for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
                    if (otherValidatorContracts[i] == target) {
                        otherValidatorContracts[i] = otherValidatorContracts[
                            otherValidatorContracts.length - 1
                        ];
                        otherValidatorContracts.pop();
                        found = true;
                        break;
                    }
                }
                require(found, "Contract not found");
                emit OtherValidatorContractUpdated(target, false);
            } else if (voteType == VoteType.CHANGE_MAX_VALIDATORS) {
                uint32 newMax = uint32(uint160(target));
                MAX_VALIDATORS = newMax;
                emit MaxValidatorsChanged(newMax);
            } else if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                uint32 newThreshold = uint32(uint160(target));
                require(
                    newThreshold > 0 && newThreshold <= 100000,
                    "Threshold must be 1 to 100000"
                );
                voteTallyBlockThreshold = newThreshold;
                emit VoteTallyBlockThresholdUpdated(newThreshold);
            } else if (voteType == VoteType.ADD_OTHER_VOTER_CONTRACT) {
                require(!voterManagementRevoked, "Voter management permanently revoked");
                for (uint256 i = 0; i < otherVotersArray.length; i++) {
                    require(
                        otherVotersArray[i] != target,
                        "Voter contract already in list"
                    );
                }
                otherVotersArray.push(target);
                emit OtherVoterContractUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
                require(!voterManagementRevoked, "Voter management permanently revoked");
                require(
                    votersArray.length > 0 || otherVotersArray.length > 1,
                    "Cannot remove: would leave no voters in the system"
                );
                bool found = false;
                for (uint256 i = 0; i < otherVotersArray.length; i++) {
                    if (otherVotersArray[i] == target) {
                        otherVotersArray[i] = otherVotersArray[
                            otherVotersArray.length - 1
                        ];
                        otherVotersArray.pop();
                        found = true;
                        break;
                    }
                }
                require(found, "Voter contract not found");
                emit OtherVoterContractUpdated(target, false);
            } else if (voteType == VoteType.ADD_ROOT_OVERLORD) {
                require(!overlordManagementRevoked, "Overlord management permanently revoked");
                require(target != address(0), "Root overlord cannot be zero address");
                require(!isRootOverlord(target), "Already a root overlord");
                rootOverlords.push(target);
                emit RootOverlordUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_ROOT_OVERLORD) {
                require(!overlordManagementRevoked, "Overlord management permanently revoked");
                bool found = false;
                for (uint256 i = 0; i < rootOverlords.length; i++) {
                    if (rootOverlords[i] == target) {
                        rootOverlords[i] = rootOverlords[rootOverlords.length - 1];
                        rootOverlords.pop();
                        found = true;
                        break;
                    }
                }
                require(found, "Root overlord not found");
                emit RootOverlordUpdated(target, false);
            } else if (voteType == VoteType.ADD_OTHER_OVERLORD_CONTRACT) {
                require(!overlordManagementRevoked, "Overlord management permanently revoked");
                for (uint256 i = 0; i < otherOverlordContracts.length; i++) {
                    require(
                        otherOverlordContracts[i] != target,
                        "Overlord contract already in list"
                    );
                }
                otherOverlordContracts.push(target);
                emit OtherOverlordContractUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_OTHER_OVERLORD_CONTRACT) {
                require(!overlordManagementRevoked, "Overlord management permanently revoked");
                bool found = false;
                for (uint256 i = 0; i < otherOverlordContracts.length; i++) {
                    if (otherOverlordContracts[i] == target) {
                        otherOverlordContracts[i] = otherOverlordContracts[
                            otherOverlordContracts.length - 1
                        ];
                        otherOverlordContracts.pop();
                        found = true;
                        break;
                    }
                }
                require(found, "Overlord contract not found");
                emit OtherOverlordContractUpdated(target, false);
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
                    otherVotersArray.length > 0,
                    "Cannot revoke: at least one other voter contract must be listed"
                );
                require(
                    getAllVoters().length >= 1,
                    "Cannot revoke: aggregated voter count must be at least 1"
                );
                voterManagementRevoked = true;
                emit VoterManagementRevoked();
            }

            // clear votes for this target
            for (uint256 i = 0; i < tally.voters.length; i++) {
                hasVoted[voteType][target][tally.voters[i]] = false;
            }
            delete voteTallies[voteType][target];
        }

        emit VoteCast(msg.sender, voteType, target);
    }

    // ── Validator Governance ──────────────────────────

    function voteToChangeMaxValidators(uint32 newMax) external onlyVoters {
        require(
            newMax > 0 && newMax <= type(uint32).max,
            "New max validators must be within valid range"
        );
        _castVote(VoteType.CHANGE_MAX_VALIDATORS, address(uint160(newMax)));
    }

    function voteToAddValidator(address validator) external onlyVoters {
        require(
            validator != address(0),
            "Validator address should not be zero"
        );
        _castVote(VoteType.ADD_VALIDATOR, validator);
    }

    function voteToRemoveValidator(address validator) external onlyVoters {
        require(
            validator != address(0),
            "Validator address should not be zero"
        );
        _castVote(VoteType.REMOVE_VALIDATOR, validator);
    }

    // ── Voter Management ──────────────────────────────

    function voteToAddVoter(address voter) external onlyVoters {
        require(voter != address(0), "Voter address should not be zero");
        _castVote(VoteType.ADD_VOTER, voter);
    }

    function voteToRemoveVoter(address voter) external onlyVoters {
        require(voter != address(0), "Voter address should not be zero");
        require(
            getAllVoters().length > 1,
            "Cannot remove the last voter"
        );
        _castVote(VoteType.REMOVE_VOTER, voter);
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

        _castVote(VoteType.ADD_OTHER_VALIDATOR_CONTRACT, contractAddress);
    }

    function voteToRemoveOtherValidatorContract(
        address contractAddress
    ) external onlyVoters {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );
        _castVote(VoteType.REMOVE_OTHER_VALIDATOR_CONTRACT, contractAddress);
    }

    function voteToAddOtherVoterContract(
        address voterContract
    ) external onlyVoters {
        require(
            voterContract != address(0),
            "Voter contract address should not be zero"
        );

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
        try candidateContract.getAllVoters() {} catch {
            revert(
                "Provided contract does not implement the required getAllVoters function"
            );
        }

        try candidateContract.isVoter(msg.sender) {} catch {
            revert(
                "Provided contract does not implement the required isVoter function"
            );
        }

        _castVote(VoteType.ADD_OTHER_VOTER_CONTRACT, voterContract);
    }

    function voteToRemoveOtherVoterContract(
        address voterContract
    ) external onlyVoters {
        require(
            voterContract != address(0),
            "Voter contract address should not be zero"
        );
        _castVote(VoteType.REMOVE_OTHER_VOTER_CONTRACT, voterContract);
    }

    // ── Root Overlord Management ──────────────────────

    function voteToAddRootOverlord(address overlord) external onlyVoters {
        require(
            overlord != address(0),
            "Root overlord address should not be zero"
        );
        _castVote(VoteType.ADD_ROOT_OVERLORD, overlord);
    }

    function voteToRemoveRootOverlord(address overlord) external onlyVoters {
        require(
            overlord != address(0),
            "Root overlord address should not be zero"
        );
        _castVote(VoteType.REMOVE_ROOT_OVERLORD, overlord);
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

        _castVote(VoteType.ADD_OTHER_OVERLORD_CONTRACT, contractAddress);
    }

    function voteToRemoveOtherOverlordContract(
        address contractAddress
    ) external onlyVoters {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );
        _castVote(VoteType.REMOVE_OTHER_OVERLORD_CONTRACT, contractAddress);
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
        // Use address(1) as a sentinel for this non-targeted vote
        _castVote(VoteType.REVOKE_OVERLORD_MANAGEMENT, address(1));
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
        _castVote(VoteType.REVOKE_VALIDATOR_MANAGEMENT, address(1));
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
        _castVote(VoteType.REVOKE_VOTER_MANAGEMENT, address(1));
    }

    // ── Vote Threshold Governance ─────────────────────

    function voteToUpdateVoteTallyBlockThreshold(
        uint32 newThreshold
    ) external onlyVoters {
        require(
            newThreshold > 0 && newThreshold <= 100000,
            "New threshold must be greater than zero and less than or equal to 100,000"
        );
        _castVote(
            VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
            address(uint160(newThreshold))
        );
    }

    // ── Vote Tally & Thresholds ───────────────────────

    function getVoteTally(
        VoteType voteType,
        address target
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

    function getMajorityThreshold() public view returns (uint256) {
        address[] memory allVoters = getAllVoters();
        uint256 totalVoterCount = allVoters.length;
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount / 2) + 1;
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

    function getAllVoters() public view override returns (address[] memory) {
        uint256 totalVoterCount = votersArray.length;

        for (uint256 i = 0; i < otherVotersArray.length; i++) {
            try ValidatorSmartContractInterface(
                    otherVotersArray[i]
                ).getAllVoters() returns (address[] memory ext) {
                totalVoterCount += ext.length;
            } catch {}
        }

        address[] memory allVoters = new address[](totalVoterCount);
        uint256 counter = 0;

        for (uint256 i = 0; i < votersArray.length; i++) {
            allVoters[counter] = votersArray[i];
            counter++;
        }

        for (uint256 i = 0; i < otherVotersArray.length; i++) {
            try ValidatorSmartContractInterface(
                    otherVotersArray[i]
                ).getAllVoters() returns (address[] memory externalVoters) {
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

    // ── Utilities ─────────────────────────────────────

    function isContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }
}