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

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  QBFT validator and voter governance.                │
  │  Majority-vote quorum for all state changes.         │
  │  Deployed at genesis address 0x0000...1111.          │
  │                                                      │
  │  Manages: validators, voters,                        │
  │  gas beneficiary, and max-validator cap.             │
  └──────────────────────────────────────────────────────┘
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

    enum VoteType {
        ADD_VALIDATOR,
        REMOVE_VALIDATOR,
        ADD_VOTER,
        REMOVE_VOTER,
        ADD_CONTRACT,
        REMOVE_CONTRACT,
        ADD_OTHER_VOTER_CONTRACT,
        REMOVE_OTHER_VOTER_CONTRACT,
        CHANGE_MAX_VALIDATORS,
        UPDATE_VOTE_TALLY_BLOCK_THRESHOLD
    }

    struct VoteTally {
        uint256 totalVotes;
        uint256 startVoteBlock;
        address[] voters;
    }

    address[] public validators;
    address[] public otherValidatorContracts;

    address[] public votersArray;
    address[] public otherVotersArray;

    uint32 public MAX_VALIDATORS;
    uint32 public voteTallyBlockThreshold;

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
            tally.voters.length > 0 &&
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
                require(!isVoter(target), "Voter already in the list");
                votersArray.push(target);
                emit VoterUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_VOTER) {
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
            } else if (voteType == VoteType.ADD_CONTRACT) {
                for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
                    require(
                        otherValidatorContracts[i] != target,
                        "Contract already in list"
                    );
                }
                otherValidatorContracts.push(target);
                emit OtherValidatorContractUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_CONTRACT) {
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
                for (uint256 i = 0; i < otherVotersArray.length; i++) {
                    require(
                        otherVotersArray[i] != target,
                        "Voter contract already in list"
                    );
                }
                otherVotersArray.push(target);
                emit OtherVoterContractUpdated(target, true);
            } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
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

        _castVote(VoteType.ADD_CONTRACT, contractAddress);
    }

    function voteToRemoveOtherValidatorContract(
        address contractAddress
    ) external onlyVoters {
        require(
            contractAddress != address(0),
            "Contract address should not be zero"
        );
        _castVote(VoteType.REMOVE_CONTRACT, contractAddress);
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
            try ValidatorSmartContractInterface(
                    otherValidatorContracts[i]
                ).getValidators() returns (address[] memory ext) {
                totalLength += ext.length;
            } catch {}
        }

        address[] memory allValidators = new address[](totalLength);

        uint256 counter = 0;

        for (uint256 i = 0; i < validators.length; i++) {
            allValidators[counter] = validators[i];
            counter++;
        }

        for (uint256 i = 0; i < otherValidatorContracts.length; i++) {
            try ValidatorSmartContractInterface(
                    otherValidatorContracts[i]
                ).getValidators() returns (address[] memory externalValidators) {
                for (uint256 j = 0; j < externalValidators.length; j++) {
                    allValidators[counter] = externalValidators[j];
                    counter++;
                }
            } catch {}
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

    // ── Utilities ─────────────────────────────────────

    function isContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }
}