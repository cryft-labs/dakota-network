// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.8.20;

/*
   _____        __    __  ___
  / ___/__  ___/ /__ /  |/  /__ ____  ___ ____ ____ ____
 / /__/ _ \/ _  / -_) /|_/ / _ `/ _ \/ _ `/ _ `/ -_) __/
 \___/\___/\_,_/\__/_/  /_/\_,_/_//_/\_,_/\_, /\__/_/
                                         /___/ By: CryftCreator

  Version 1.0 — Production Code Manager  [UPGRADEABLE]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  Minimal permissionless unique ID registry.          │
  │  Fee-based registration, deterministic IDs via       │
  │  keccak256(address(this), giftContract, chainId)     │
  │  + incrementing counter.                             │
  │                                                      │
  │  Voter governance derived from                       │
  │  ValidatorSmartContractAllowList at 0x...1111.       │
  │                                                      │
  │  No cross-contract state writes.                     │
  └──────────────────────────────────────────────────────┘
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/utils/StringsUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/proxy/utils/Initializable.sol";

import "./interfaces/ICodeManager.sol";

interface IVoterChecker {
    function isVoter(address potentialVoter) external view returns (bool);
    function getAllVoters() external view returns (address[] memory);
}

contract CodeManager is Initializable, ICodeManager {
    using StringsUpgradeable for uint256;

    modifier onlyWhitelisted() {
        require(isWhitelistedAddress[msg.sender], "Caller is not whitelisted");
        _;
    }

    enum VoteType {
        ADD_WHITELISTED_ADDRESS,
        REMOVE_WHITELISTED_ADDRESS,
        UPDATE_REGISTRATION_FEE,
        UPDATE_FEE_VAULT
    }

    struct VoteTally {
        uint256 totalVotes;
        uint256 lastVoteBlock;
    }

    IVoterChecker public validatorContract;
    uint256 public registrationFee;
    uint32 public voteTallyBlockThreshold;
    address public feeVault;

    mapping(address => bool) public isWhitelistedAddress;
    mapping(string => uint256) private identifierCounter;
    mapping(string => ContractData) private contractIdentifierToData;
    mapping(VoteType => mapping(address => VoteTally)) private voteTallies;
    mapping(VoteType => mapping(address => mapping(address => bool))) private hasVoted;

    event registrationFeeUpdated(uint256 newFee);
    event VoteCast(address indexed voter, VoteType voteType, address target);
    event StateChanged(VoteType voteType, address newValue);
    event UniqueIdsRegistered(address indexed giftContract, string chainId, uint256 quantity);

    constructor() {
        _disableInitializers();
    }

    modifier onlyVoters() {
        require(validatorContract.isVoter(msg.sender), "Caller is not a voter");
        _;
    }

    function initialize() public virtual initializer {
        validatorContract = IVoterChecker(0x0000000000000000000000000000000000001111);
        registrationFee = 10**15;
        voteTallyBlockThreshold = 10000;
    }

    function _castVote(VoteType voteType, address target) internal {
        require(target != address(0), "Target address should not be zero");
        require(validatorContract.isVoter(msg.sender), "Only voters can vote");

        VoteTally storage tally = voteTallies[voteType][target];

        if (block.number > tally.lastVoteBlock + voteTallyBlockThreshold) {
            tally.totalVotes = 0;
            address[] memory allVoters = validatorContract.getAllVoters();
            for (uint256 i = 0; i < allVoters.length; i++) {
                hasVoted[voteType][target][allVoters[i]] = false;
            }
        }

        require(!hasVoted[voteType][target][msg.sender], "Voter has already voted for this target");

        tally.totalVotes++;
        tally.lastVoteBlock = block.number;
        hasVoted[voteType][target][msg.sender] = true;

        if (tally.totalVotes >= (validatorContract.getAllVoters().length / 2) + 1) {
            emit StateChanged(voteType, target);
            if (voteType == VoteType.ADD_WHITELISTED_ADDRESS) {
                isWhitelistedAddress[target] = true;
            } else if (voteType == VoteType.REMOVE_WHITELISTED_ADDRESS) {
                isWhitelistedAddress[target] = false;
            } else if (voteType == VoteType.UPDATE_REGISTRATION_FEE) {
                registrationFee = uint256(uint160(target));
                emit registrationFeeUpdated(registrationFee);
            } else if (voteType == VoteType.UPDATE_FEE_VAULT) {
                feeVault = target;
            }
            delete voteTallies[voteType][target];
            address[] memory allVoters = validatorContract.getAllVoters();
            for (uint256 i = 0; i < allVoters.length; i++) {
                hasVoted[voteType][target][allVoters[i]] = false;
            }
        }

        emit VoteCast(msg.sender, voteType, target);
    }

    function voteToAddWhitelistedAddress(address newAddress) public onlyVoters {
        _castVote(VoteType.ADD_WHITELISTED_ADDRESS, newAddress);
    }

    function voteToRemoveWhitelistedAddress(address removeAddress) public onlyVoters {
        _castVote(VoteType.REMOVE_WHITELISTED_ADDRESS, removeAddress);
    }

    function voteToUpdateRegistrationFee(uint256 newFee) public onlyVoters {
        _castVote(VoteType.UPDATE_REGISTRATION_FEE, address(uint160(newFee)));
    }

    function voteToUpdateFeeVault(address newFeeVault) public onlyVoters {
        _castVote(VoteType.UPDATE_FEE_VAULT, newFeeVault);
    }

    function getVoteTally(VoteType voteType, address target) external view returns (uint256, uint256) {
        VoteTally storage tally = voteTallies[voteType][target];
        return (tally.lastVoteBlock, tally.totalVotes);
    }

    function getContractData(string memory contractIdentifier) public view returns (ContractData memory) {
        return contractIdentifierToData[contractIdentifier];
    }

    /// @notice Get the counter for a given giftContract + chainId, computed on the fly.
    function getIdentifierCounter(address giftContract, string memory chainId) public view returns (string memory contractIdentifier, uint256 counter) {
        bytes32 hash = keccak256(abi.encodePacked(address(this), giftContract, chainId));
        contractIdentifier = StringsUpgradeable.toHexString(uint256(hash), 32);
        counter = identifierCounter[contractIdentifier];
    }

    function validateUniqueId(string memory uniqueId) public view returns (bool isValid) {
        (string memory contractIdentifier, uint256 extractedCounter) = splitUniqueId(uniqueId);

        if (identifierCounter[contractIdentifier] == 0) {
            return false;
        }

        return extractedCounter > 0 && extractedCounter <= identifierCounter[contractIdentifier];
    }

    function getUniqueIdDetails(string memory uniqueId) public view returns (address giftContract, string memory chainId, uint256 counter) {
        (string memory contractIdentifier, uint256 extractedCounter) = splitUniqueId(uniqueId);
        ContractData memory data = getContractData(contractIdentifier);

        require(data.giftContract != address(0), "No matching uniqueId found.");

        uint256 currentCounter = identifierCounter[contractIdentifier];
        require(extractedCounter > 0 && extractedCounter <= currentCounter, "Invalid counter value");

        return (data.giftContract, data.chainId, extractedCounter);
    }

    function splitUniqueId(string memory uniqueId) internal pure returns (string memory contractIdentifier, uint256 counter) {
        uint256 delimiterIndex = bytes(uniqueId).length;
        for (uint256 i = 0; i < bytes(uniqueId).length; i++) {
            if (bytes(uniqueId)[i] == "-") {
                delimiterIndex = i;
                break;
            }
        }
        require(delimiterIndex != bytes(uniqueId).length, "Invalid uniqueId format");

        contractIdentifier = substring(uniqueId, 0, delimiterIndex);
        counter = parseUint(substring(uniqueId, delimiterIndex + 1, bytes(uniqueId).length));
    }

    function parseUint(string memory s) internal pure returns (uint256) {
        uint256 res = 0;
        for (uint256 i = 0; i < bytes(s).length; i++) {
            require(bytes(s)[i] >= "0" && bytes(s)[i] <= "9", "Non-numeric character");
            res = res * 10 + (uint256(uint8(bytes(s)[i])) - 48);
        }
        return res;
    }

    function substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    /// @notice Register a single or batch of unique IDs by incrementing the counter range.
    ///         Permissionless — anyone can call as long as they pay `registrationFee * quantity`.
    ///         Works for both direct EOA calls and calls from external contracts.
    ///         Payment is forwarded to the feeVault.
    function registerUniqueIds(address giftContract, string memory chainId, uint256 quantity) external payable {
        require(giftContract != address(0), "Gift contract address cannot be zero");
        require(quantity > 0, "Quantity must be greater than zero");
        require(bytes(chainId).length > 0, "Chain ID cannot be empty");

        uint256 totalFee = registrationFee * quantity;
        require(msg.value >= totalFee, "Insufficient registration fee");

        // Forward fee to fee vault
        payable(feeVault).transfer(totalFee);

        incrementCounter(giftContract, chainId, quantity);

        emit UniqueIdsRegistered(giftContract, chainId, quantity);

        // Refund excess payment
        uint256 refund = msg.value - totalFee;
        if (refund > 0) {
            payable(msg.sender).transfer(refund);
        }
    }

    function incrementCounter(address giftContract, string memory chainId, uint256 quantity) internal {
        bytes32 hash = keccak256(abi.encodePacked(address(this), giftContract, chainId));
        string memory contractIdentifier = StringsUpgradeable.toHexString(uint256(hash), 32);

        if (identifierCounter[contractIdentifier] == 0) {
            contractIdentifierToData[contractIdentifier] = ContractData(giftContract, chainId);
        }

        identifierCounter[contractIdentifier] += quantity;
    }

}