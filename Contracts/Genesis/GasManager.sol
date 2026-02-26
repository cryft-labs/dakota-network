// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   _____          __  ___
  / ___/__ ______/  |/  /__ ____  ___ ____ ____ ____
 / (_ / _ `( -< / /|_/ / _ `/ _ \/ _ `/ _ `/ -_) __/
 \___/\_,_/___//_/  /_/\_,_/_//_/\_,_/\_, /\_ /_/
                                     /___/ By: CryftCreator

  Version 2.0 — Production Gas Manager  [UPGRADEABLE]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  Gas beneficiary — voter-governed funding & burns.   │
  │  2/3 supermajority quorum for all state changes.     │
  │  Voter-pool changes frozen while any tally is active.│
  │  Own voter set with pluggable external voter         │
  │  contracts via otherVoterContracts[].                │
  │                                                      │
  │  Two-phase operations:                               │
  │    vote → approve → execute (guardian-gated).        │
  │    Applies to: gas funding, token burns,             │
  │    native coin burns.                                │
  │                                                      │
  │  Guardian management:                                │
  │    Add/remove individual guardians, or clear all     │
  │    via voteToClearGuardians().  Enumerable via       │
  │    getGuardians() / getGuardianCount().              │
  │                                                      │
  │  Uses .call{value:} for all ETH transfers.           │
  │  ReentrancyGuard on all execute functions.           │
  └──────────────────────────────────────────────────────┘
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.6/contracts/security/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.6/contracts/proxy/utils/Initializable.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IVoterChecker {
    function isVoter(address potentialVoter) external view returns (bool);
    function getVoters() external view returns (address[] memory);
}

contract GasManager is Initializable, ReentrancyGuardUpgradeable {
    uint256 public voteTallyBlockThreshold;
    uint256 public totalGasFunded;
    uint256 public activeVoteCount;

    address[] public votersArray;
    address[] public otherVoterContracts;
    address[] public guardiansArray;

    mapping(address => bool) public isGuardian;
    mapping(VoteType => mapping(uint256 => VoteTally)) private voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool))) public hasVoted;
    mapping(bytes32 => bool) public approvedBurns;
    mapping(bytes32 => bool) public approvedFunds;
    mapping(bytes32 => bool) public approvedCoinBurns;

    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    enum VoteType {
        ADD_GUARDIAN,
        REMOVE_GUARDIAN,
        ADD_VOTER,
        REMOVE_VOTER,
        ADD_OTHER_VOTER_CONTRACT,
        REMOVE_OTHER_VOTER_CONTRACT,
        UPDATE_VOTE_TALLY_BLOCK_THRESHOLD,
        CLEAR_GUARDIANS,
        BURN_TOKENS,
        FUND_GAS,
        BURN_NATIVE_COIN
    }

    struct VoteTally {
        uint256 totalVotes;
        uint256 startVoteBlock;
        address[] voters;
    }

    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    event VoteTallyReset(VoteType voteType, uint256 target);
    event StateChanged(VoteType voteType, uint256 newValue);
    event GasFunded(address indexed to, uint256 amount);
    event TokenBurned(address indexed tokenAddress, uint256 amount);
    event NativeCoinBurned(uint256 amount);
    event GuardianUpdated(address indexed target, bool added);
    event GuardiansCleared(uint256 count);
    event VoterUpdated(address indexed target, bool added);
    event OtherVoterContractUpdated(address indexed target, bool added);
    event TokenBurnApproved(address indexed tokenAddress, uint256 amount, bytes32 burnKey);
    event GasFundApproved(address indexed to, uint256 amount, bytes32 fundKey);
    event CoinBurnApproved(uint256 amount, bytes32 coinBurnKey);

    modifier onlyVoters() {
        require(isVoter(msg.sender), "Only voters can call this function");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize() public virtual initializer {
        __ReentrancyGuard_init();
        votersArray.push(msg.sender);
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
        uint256 totalLen = votersArray.length;
        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try IVoterChecker(otherVoterContracts[i]).getVoters() returns (address[] memory ext) {
                totalLen += ext.length;
            } catch {}
        }

        address[] memory allVoters = new address[](totalLen);
        uint256 counter = 0;
        for (uint256 i = 0; i < votersArray.length; i++) {
            allVoters[counter] = votersArray[i];
            counter++;
        }
        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try IVoterChecker(otherVoterContracts[i]).getVoters() returns (address[] memory ext) {
                for (uint256 j = 0; j < ext.length; j++) {
                    allVoters[counter] = ext[j];
                    counter++;
                }
            } catch {}
        }
        return allVoters;
    }

    // ── Vote Tally & Thresholds ───────────────────────────

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
        uint256 totalVoterCount = getVoters().length;
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount * 2 + 2) / 3;
    }

    // ── Balance Queries ───────────────────────────────────

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address _tokenAddress)
        public
        view
        returns (uint256)
    {
        IERC20 token = IERC20(_tokenAddress);
        return token.balanceOf(address(this));
    }

    // ── Internal Vote Engine ──────────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        require(target != 0, "Target should not be zero");

        VoteTally storage tally = voteTallies[voteType][target];

        // reset expired tallies
        if (
            tally.startVoteBlock != 0 &&
            block.number > tally.startVoteBlock + voteTallyBlockThreshold
        ) {
            // clear hasVoted flags
            for (uint256 i = 0; i < tally.voters.length; i++) {
                hasVoted[voteType][target][tally.voters[i]] = false;
            }
            // clear the tally
            tally.totalVotes = 0;
            tally.voters = new address[](0);
            tally.startVoteBlock = 0;
            activeVoteCount--;
            emit VoteTallyReset(voteType, target);
        }

        require(
            !hasVoted[voteType][target][msg.sender],
            "Voter has already voted for this target"
        );

        // record the vote
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

            if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                voteTallyBlockThreshold = target;
            } else {
                address targetAddress = address(uint160(target));
                if (voteType == VoteType.ADD_GUARDIAN) {
                    require(!isGuardian[targetAddress], "Already a guardian");
                    isGuardian[targetAddress] = true;
                    guardiansArray.push(targetAddress);
                    emit GuardianUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_GUARDIAN) {
                    require(isGuardian[targetAddress], "Not a guardian");
                    isGuardian[targetAddress] = false;
                    for (uint256 i = 0; i < guardiansArray.length; i++) {
                        if (guardiansArray[i] == targetAddress) {
                            guardiansArray[i] = guardiansArray[guardiansArray.length - 1];
                            guardiansArray.pop();
                            break;
                        }
                    }
                    emit GuardianUpdated(targetAddress, false);
                } else if (voteType == VoteType.CLEAR_GUARDIANS) {
                    uint256 count = guardiansArray.length;
                    for (uint256 i = 0; i < count; i++) {
                        isGuardian[guardiansArray[i]] = false;
                    }
                    delete guardiansArray;
                    emit GuardiansCleared(count);
                } else if (voteType == VoteType.ADD_VOTER) {
                    require(!isVoter(targetAddress), "Voter already in the list");
                    votersArray.push(targetAddress);
                    emit VoterUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_VOTER) {
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
                    for (uint256 i = 0; i < otherVoterContracts.length; i++) {
                        require(otherVoterContracts[i] != targetAddress, "Voter contract already in list");
                    }
                    otherVoterContracts.push(targetAddress);
                    emit OtherVoterContractUpdated(targetAddress, true);
                } else if (voteType == VoteType.REMOVE_OTHER_VOTER_CONTRACT) {
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
                }
            }

            if (voteType == VoteType.BURN_TOKENS) {
                approvedBurns[bytes32(target)] = true;
            }
            if (voteType == VoteType.FUND_GAS) {
                approvedFunds[bytes32(target)] = true;
            }
            if (voteType == VoteType.BURN_NATIVE_COIN) {
                approvedCoinBurns[bytes32(target)] = true;
            }

            // clear votes
            for (uint256 i = 0; i < tally.voters.length; i++) {
                hasVoted[voteType][target][tally.voters[i]] = false;
            }
            delete voteTallies[voteType][target];
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
        require(isContract(voterContract), "Provided address does not point to a valid contract");
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

    // ── Guardian Management ───────────────────────────────

    function voteToAddGuardian(address guardian) external onlyVoters {
        require(guardian != address(0), "Guardian address should not be zero");
        _castVote(VoteType.ADD_GUARDIAN, uint256(uint160(guardian)));
    }

    function voteToRemoveGuardian(address guardian) external onlyVoters {
        require(guardian != address(0), "Guardian address should not be zero");
        _castVote(VoteType.REMOVE_GUARDIAN, uint256(uint160(guardian)));
    }

    function voteToClearGuardians() external onlyVoters {
        require(guardiansArray.length > 0, "No guardians to clear");
        // Use 1 as sentinel for this non-targeted vote
        _castVote(VoteType.CLEAR_GUARDIANS, 1);
    }

    function getGuardians() public view returns (address[] memory) {
        return guardiansArray;
    }

    function getGuardianCount() public view returns (uint256) {
        return guardiansArray.length;
    }

    // ── Parameter Governance ──────────────────────────────

    function voteToUpdateVoteTallyBlockThreshold(uint256 _blocks) external onlyVoters {
        require(_blocks > 0 && _blocks <= 100000, "Invalid block threshold");
        _castVote(VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD, _blocks);
    }

    // ── Gas Funding ───────────────────────────────────────

    function voteToFundGas(address _to, uint256 _amount) external onlyVoters {
        require(_to != address(0), "Invalid recipient address");
        require(_amount > 0, "Amount must be greater than zero");
        bytes32 fundKey = keccak256(abi.encodePacked(_to, _amount));
        uint256 target = uint256(fundKey);
        _castVote(VoteType.FUND_GAS, target);
        if (approvedFunds[bytes32(target)]) {
            emit GasFundApproved(_to, _amount, fundKey);
        }
    }

    /// @notice Execute a previously approved gas fund. Only callable by a guardian or the funded address.
    function executeFundGas(address payable _to, uint256 _amount) public nonReentrant {
        require(isGuardian[msg.sender] || msg.sender == _to, "Only guardian or funded address");
        bytes32 fundKey = keccak256(abi.encodePacked(_to, _amount));
        require(approvedFunds[fundKey], "Fund not approved");
        approvedFunds[fundKey] = false;

        require(address(this).balance >= _amount, "Insufficient balance");
        require(_to != address(0), "Invalid recipient address");

        uint256 balanceBefore = address(this).balance;

        (bool success, ) = _to.call{value: _amount}("");
        require(success, "Transfer failed");

        uint256 balanceAfter = address(this).balance;
        require(
            balanceBefore - balanceAfter == _amount,
            "Exact amount not transferred"
        );

        totalGasFunded += _amount;

        emit GasFunded(_to, _amount);
    }

    // ── Token Burns ───────────────────────────────────────

    function voteToBurnTokens(address _tokenAddress, uint256 _amount) external onlyVoters {
        require(_tokenAddress != address(0), "Invalid token address");
        require(_amount > 0, "Amount must be greater than zero");
        bytes32 burnKey = keccak256(abi.encodePacked(_tokenAddress, _amount));
        uint256 target = uint256(burnKey);
        _castVote(VoteType.BURN_TOKENS, target);
        if (approvedBurns[bytes32(target)]) {
            emit TokenBurnApproved(_tokenAddress, _amount, burnKey);
        }
    }

    /// @notice Execute a previously approved token burn. Only callable by a guardian.
    function executeTokenBurn(address _tokenAddress, uint256 _amount) public nonReentrant {
        require(isGuardian[msg.sender], "Only guardian");
        bytes32 burnKey = keccak256(abi.encodePacked(_tokenAddress, _amount));
        require(approvedBurns[burnKey], "Burn not approved");
        approvedBurns[burnKey] = false;

        IERC20 token = IERC20(_tokenAddress);
        require(token.balanceOf(address(this)) >= _amount, "Insufficient balance");
        require(token.transfer(DEAD_ADDRESS, _amount), "Token burn failed");
        emit TokenBurned(_tokenAddress, _amount);
    }

    // ── Native Coin Burns ─────────────────────────────────

    function voteToBurnNativeCoin(uint256 _amount) external onlyVoters {
        require(_amount > 0, "Amount must be greater than zero");
        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", _amount));
        uint256 target = uint256(coinBurnKey);
        _castVote(VoteType.BURN_NATIVE_COIN, target);
        if (approvedCoinBurns[bytes32(target)]) {
            emit CoinBurnApproved(_amount, coinBurnKey);
        }
    }

    /// @notice Execute a previously approved native coin burn. Only callable by a guardian.
    function executeCoinBurn(uint256 _amount) public nonReentrant {
        require(isGuardian[msg.sender], "Only guardian");
        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", _amount));
        require(approvedCoinBurns[coinBurnKey], "Coin burn not approved");
        approvedCoinBurns[coinBurnKey] = false;

        require(address(this).balance >= _amount, "Insufficient balance");
        (bool success, ) = payable(DEAD_ADDRESS).call{value: _amount}("");
        require(success, "Burn failed");
        emit NativeCoinBurned(_amount);
    }

    // ── Expired Tally Cleanup ─────────────────────────────

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

    receive() external payable {}

    // ── Utilities ─────────────────────────────────────

    function isContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }
}
