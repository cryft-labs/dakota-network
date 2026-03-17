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

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  PUBLIC REGISTRY + PENTE ROUTER                      │
  │                                                      │
  │  Minimal permissionless unique ID registry.          │
  │  Fee-based registration, deterministic IDs via       │
  │  keccak256(address(this), giftContract, chainId)     │
  │  + incrementing counter.                             │
  │                                                      │
  │  2/3 supermajority quorum for all state changes.     │
  │  Voter-pool changes frozen while any tally is active.│
  │  Own voter set with pluggable external voter         │
  │  contracts via otherVoterContracts[].                │
  │                                                      │
  │  PENTE INTEGRATION:                                  │
  │  Authorized Pente privacy groups call router         │
  │  functions (recordRedemption, setUidFrozen) which    │
  │  resolve the UID to its gift                         │
  │  contract and forward via IRedeemable. The gift      │
  │  contract is the SOLE AUTHORITY on per-UID state.    │
  │  CodeManager stores NO per-UID state — it is a       │
  │  thin registry + router only.                        │
  │                                                      │
  │  Patent: U.S. App. Ser. No. 18/930,857               │
  └──────────────────────────────────────────────────────┘
*/

import "../Genesis/Upgradeable/Utils/StringsUpgradeable.sol";
import "../Genesis/Upgradeable/Initializable.sol";
import "../Genesis/Upgradeable/ReentrancyGuardUpgradeable.sol";

import "./Interfaces/ICodeManager.sol";
import "./Interfaces/IRedeemable.sol";

interface IVoterChecker {
    function isVoter(address potentialVoter) external view returns (bool);
    function getVoters() external view returns (address[] memory);
}

contract CodeManager is Initializable, ReentrancyGuardUpgradeable, ICodeManager {
    using StringsUpgradeable for uint256;

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
        DEAUTHORIZE_PRIVACY_GROUP
    }

    struct VoteTally {
        uint256 totalVotes;
        uint256 startVoteBlock;
        address[] voters;
    }

    address[] public votersArray;
    address[] public otherVoterContracts;
    uint256 public activeVoteCount;

    uint256 public registrationFee;
    uint256 public voteTallyBlockThreshold;
    address public feeVault;

    mapping(address => bool) public isWhitelistedAddress;
    mapping(string => uint256) private _identifierCounter;
    mapping(string => ContractData) private _contractIdentifierToData;
    mapping(VoteType => mapping(uint256 => VoteTally)) private _voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool))) public hasVoted;

    /// @dev Authorized Pente privacy groups that can call router functions.
    mapping(address => bool) public isAuthorizedPrivacyGroup;

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
    event FrozenStatusRouted(string uniqueId, address indexed giftContract, bool frozen);


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
        __ReentrancyGuard_init();
        votersArray.push(msg.sender);
        registrationFee = 10**15;
        voteTallyBlockThreshold = 1000;
    }

    // ── Voter Queries ─────────────────────────────────────

    function isVoter(address potentialVoter) public view returns (bool) {
        for (uint256 i = 0; i < votersArray.length; i++) {
            if (votersArray[i] == potentialVoter) {
                return true;
            }
        }
        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try IVoterChecker(otherVoterContracts[i]).isVoter(potentialVoter) returns (bool result) {
                if (result) return true;
            } catch {}
        }
        return false;
    }

    function getVoters() public view returns (address[] memory) {
        uint256 maxLen = votersArray.length;
        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try IVoterChecker(otherVoterContracts[i]).getVoters() returns (address[] memory ext) {
                maxLen += ext.length;
            } catch {}
        }

        address[] memory temp = new address[](maxLen);
        uint256 count = 0;

        for (uint256 i = 0; i < votersArray.length; i++) {
            temp[count] = votersArray[i];
            count++;
        }

        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try IVoterChecker(otherVoterContracts[i]).getVoters() returns (address[] memory ext) {
                for (uint256 j = 0; j < ext.length; j++) {
                    bool dup = false;
                    for (uint256 k = 0; k < count; k++) {
                        if (temp[k] == ext[j]) { dup = true; break; }
                    }
                    if (!dup) {
                        temp[count] = ext[j];
                        count++;
                    }
                }
            } catch {}
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }
    /// @notice Returns the total number of voters (local + external).
    function getVoterCount() public view returns (uint256) {
        return getVoters().length;
    }
    // ── Vote Tally & Thresholds ───────────────────────────

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
        VoteTally memory tally = _voteTallies[voteType][target];
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
        uint256 totalVoterCount = getVoterCount();
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount * 2 + 2) / 3;
    }

    // ── Internal Vote Engine ──────────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        require(target != 0 || voteType == VoteType.UPDATE_REGISTRATION_FEE, "Target should not be zero");
        // Caller validation is enforced by the onlyVoters modifier on all public entry points

        VoteTally storage tally = _voteTallies[voteType][target];

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

        require(!hasVoted[voteType][target][msg.sender], "Voter has already voted for this target");

        // record vote
        if (tally.voters.length == 0) {
            tally.startVoteBlock = block.number;
            activeVoteCount++;
        }
        tally.totalVotes++;
        tally.voters.push(msg.sender);
        hasVoted[voteType][target][msg.sender] = true;

        // check for supermajority (2/3)
        if (tally.totalVotes >= getSupermajorityThreshold()) {
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
                require(!isVoter(address(uint160(target))), "Voter already in the list");
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
                require(found, "Voter not found");
                emit VoterUpdated(targetAddress, false);
            } else if (voteType == VoteType.ADD_OTHER_VOTER_CONTRACT) {
                address targetAddress = address(uint160(target));
                for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                    require(otherVoterContracts[i] != targetAddress, "Voter contract already in list");
                }
                otherVoterContracts.push(targetAddress);
                emit OtherVoterContractUpdated(targetAddress, true);
            } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
                address targetAddress = address(uint160(target));
                require(
                    votersArray.length > 0 || otherVoterContracts.length > 1,
                    "Cannot remove: would leave no voters in the system"
                );
                bool found = false;
                for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                    if (otherVoterContracts[i] == targetAddress) {
                        otherVoterContracts[i] = otherVoterContracts[otherVoterContracts.length - 1];
                        otherVoterContracts.pop();
                        found = true;
                        break;
                    }
                }
                require(found, "Voter contract not found");
                emit OtherVoterContractUpdated(targetAddress, false);
            } else if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                require(
                    target > 0 && target <= 100000,
                    "Threshold must be 1 to 100000"
                );
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

            // clear votes
            for (uint256 i = 0; i < tally.voters.length; i++) {
                hasVoted[voteType][target][tally.voters[i]] = false;
            }
            delete _voteTallies[voteType][target];
            activeVoteCount--;
        }

        emit VoteCast(msg.sender, voteType, target);
    }

    // ── Voter Management ──────────────────────────────────

    function voteToAddVoter(address voter) external onlyVoters {
        require(voter != address(0), "Voter address should not be zero");
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        _castVote(VoteType.ADD_VOTER, uint256(uint160(voter)));
    }

    function voteToRemoveVoter(address voter) external onlyVoters {
        require(voter != address(0), "Voter address should not be zero");
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        require(getVoters().length > 1, "Cannot remove the last voter");
        _castVote(VoteType.REMOVE_VOTER, uint256(uint160(voter)));
    }

    function voteToAddOtherVoterContract(address voterContract) external onlyVoters {
        require(voterContract != address(0), "Voter contract address should not be zero");
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        require(_isContract(voterContract), "Provided address does not point to a valid contract");
        try IVoterChecker(voterContract).getVoters() {} catch {
            revert("Contract does not implement required getVoters function");
        }
        try IVoterChecker(voterContract).isVoter(msg.sender) {} catch {
            revert("Contract does not implement required isVoter function");
        }
        _castVote(VoteType.ADD_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    function voteToRemoveOtherVoterContract(address voterContract) external onlyVoters {
        require(voterContract != address(0), "Voter contract address should not be zero");
        require(activeVoteCount == 0, "Cannot modify voter pool while votes are active");
        _castVote(VoteType.REMOVE_OTHER_VOTER_CONTRACT, uint256(uint160(voterContract)));
    }

    // ── Governance Entry Points ───────────────────────────

    function voteToAddWhitelistedAddress(address newAddress) external onlyVoters {
        require(newAddress != address(0), "Address should not be zero");
        _castVote(VoteType.ADD_WHITELISTED_ADDRESS, uint256(uint160(newAddress)));
    }

    function voteToRemoveWhitelistedAddress(address removeAddress) external onlyVoters {
        require(removeAddress != address(0), "Address should not be zero");
        _castVote(VoteType.REMOVE_WHITELISTED_ADDRESS, uint256(uint160(removeAddress)));
    }

    function voteToUpdateRegistrationFee(uint256 newFee) external onlyVoters {
        _castVote(VoteType.UPDATE_REGISTRATION_FEE, newFee);
    }

    function voteToUpdateFeeVault(address newFeeVault) external onlyVoters {
        require(newFeeVault != address(0), "Fee vault address should not be zero");
        _castVote(VoteType.UPDATE_FEE_VAULT, uint256(uint160(newFeeVault)));
    }

    function voteToUpdateVoteTallyBlockThreshold(uint256 newThreshold) external onlyVoters {
        require(newThreshold > 0 && newThreshold <= 100000, "Invalid block threshold");
        _castVote(VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD, newThreshold);
    }

    /// @notice Vote to authorize (or de-authorize) a Pente privacy group address.
    ///         Authorized privacy groups can call router functions.
    function voteToAuthorizePrivacyGroup(address privacyGroup) external onlyVoters {
        require(privacyGroup != address(0), "Privacy group address cannot be zero");
        _castVote(VoteType.AUTHORIZE_PRIVACY_GROUP, uint256(uint160(privacyGroup)));
    }

    /// @notice Vote to de-authorize a Pente privacy group address.
    function voteToDeauthorizePrivacyGroup(address privacyGroup) external onlyVoters {
        require(privacyGroup != address(0), "Privacy group address cannot be zero");
        _castVote(VoteType.DEAUTHORIZE_PRIVACY_GROUP, uint256(uint160(privacyGroup)));
    }

    // ── Pente Router Functions ────────────────────────────
    //
    //    Called by authorized Pente privacy groups via PenteExternalCall.
    //    Each function resolves the UID → gift contract and forwards the
    //    call via IRedeemable. CodeManager stores NO per-UID state.
    //    The gift contract is the SOLE AUTHORITY on all per-UID state.
    //
    /// @notice Route a redemption from the Pente privacy group to the gift contract.
    ///         The gift contract decides how to handle the redemption — single-use,
    ///         multi-use, NFT mint, etc. If the gift contract reverts, the entire
    ///         Pente transition rolls back atomically.
    function recordRedemption(string memory uniqueId, address redeemer) external onlyAuthorizedPrivacyGroup {
        (address giftContract, , ) = getUniqueIdDetails(uniqueId);
        IRedeemable(giftContract).recordRedemption(uniqueId, redeemer);
        emit RedemptionRouted(uniqueId, giftContract, redeemer);
    }

    /// @notice Route a freeze/unfreeze from the Pente privacy group to the gift contract.
    function setUidFrozen(string memory uniqueId, bool frozen) external onlyAuthorizedPrivacyGroup {
        (address giftContract, , ) = getUniqueIdDetails(uniqueId);
        IRedeemable(giftContract).setFrozen(uniqueId, frozen);
        emit FrozenStatusRouted(uniqueId, giftContract, frozen);
    }

    // ── UID View Functions (read from gift contract) ──────
    //
    //    These read per-UID state from the gift contract via IRedeemable.
    //    CodeManager is a pass-through — it stores no per-UID state.

    /// @notice Returns whether a UID is frozen, as reported by its gift contract.
    function isUniqueIdFrozen(string memory uniqueId) external view returns (bool) {
        (address giftContract, , ) = getUniqueIdDetails(uniqueId);
        return IRedeemable(giftContract).isUniqueIdFrozen(uniqueId);
    }

    /// @notice Returns whether a UID has been redeemed, as reported by its gift contract.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool) {
        (address giftContract, , ) = getUniqueIdDetails(uniqueId);
        return IRedeemable(giftContract).isUniqueIdRedeemed(uniqueId);
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

    function validateUniqueId(string memory uniqueId) public view returns (bool isValid) {
        (string memory contractIdentifier, uint256 extractedCounter) = _splitUniqueId(uniqueId);

        if (_identifierCounter[contractIdentifier] == 0) {
            return false;
        }

        return extractedCounter > 0 && extractedCounter <= _identifierCounter[contractIdentifier];
    }

    function validateUniqueIdsOrRevert(
        string[] calldata uniqueIds
    ) external view onlyAuthorizedPrivacyGroup {
        uint256 len = uniqueIds.length;
        require(len > 0, "No uniqueIds provided");

        for (uint256 i = 0; i < len; ) {
            require(
                validateUniqueId(uniqueIds[i]),
                "Invalid uniqueId in batch"
            );
            unchecked { ++i; }
        }
    }

    function getUniqueIdDetails(string memory uniqueId) public view returns (address giftContract, string memory chainId, uint256 counter) {
        (string memory contractIdentifier, uint256 extractedCounter) = _splitUniqueId(uniqueId);
        ContractData memory data = getContractData(contractIdentifier);

        require(data.giftContract != address(0), "No matching uniqueId found.");

        uint256 currentCounter = _identifierCounter[contractIdentifier];
        require(extractedCounter > 0 && extractedCounter <= currentCounter, "Invalid counter value");

        return (data.giftContract, data.chainId, extractedCounter);
    }

    function _splitUniqueId(string memory uniqueId) internal pure returns (string memory contractIdentifier, uint256 counter) {
        uint256 delimiterIndex = bytes(uniqueId).length;
        for (uint256 i = 0; i < bytes(uniqueId).length; i++) {
            if (bytes(uniqueId)[i] == "-") {
                delimiterIndex = i;
                break;
            }
        }
        require(delimiterIndex != bytes(uniqueId).length, "Invalid uniqueId format");

        contractIdentifier = _substring(uniqueId, 0, delimiterIndex);
        counter = _parseUint(_substring(uniqueId, delimiterIndex + 1, bytes(uniqueId).length));
    }

    function _parseUint(string memory s) internal pure returns (uint256) {
        uint256 res = 0;
        for (uint256 i = 0; i < bytes(s).length; i++) {
            require(bytes(s)[i] >= "0" && bytes(s)[i] <= "9", "Non-numeric character");
            res = res * 10 + (uint256(uint8(bytes(s)[i])) - 48);
        }
        return res;
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
    ///         Permissionless — anyone can call as long as they pay `registrationFee * quantity`.
    ///         Works for both direct EOA calls and calls from external contracts.
    ///         Payment is forwarded to the feeVault.
    function registerUniqueIds(address giftContract, string memory chainId, uint256 quantity) external payable nonReentrant {
        require(giftContract != address(0), "Gift contract address cannot be zero");
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

    /// @notice Voter-only function to reset an expired tally and decrement the active vote counter.
    ///         Call this to clean up stale tallies that would otherwise block voter-pool changes.
    function resetExpiredTally(VoteType voteType, uint256 target) external onlyVoters {
        VoteTally storage tally = _voteTallies[voteType][target];
        require(tally.startVoteBlock != 0, "No active tally for this target");
        require(
            block.number > tally.startVoteBlock + voteTallyBlockThreshold,
            "Tally has not expired yet"
        );
        for (uint256 i = 0; i < tally.voters.length; i++) {
            hasVoted[voteType][target][tally.voters[i]] = false;
        }
        delete _voteTallies[voteType][target];
        activeVoteCount--;
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