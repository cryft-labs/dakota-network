// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.8.20;

/*
   _____          __  ___
  / ___/__ ______/  |/  /__ ____  ___ ____ ____ ____
 / (_ / _ `(_-< / /|_/ / _ `/ _ \/ _ `/ _ `/ -_) __/
 \___/\_,_/___/ _/  /_/\_,_/_//_/\_,_/\_, /\_ /_/
                                     /___/ By: CryftCreator

  Version 1.0 — Production Gas Manager  [UPGRADEABLE]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                       │
  │  Gas beneficiary — voter-governed funding & burns.     │
  │  Voters derived from ValidatorSmartContractAllowList   │
  │  at genesis address 0x0000...1111.                     │
  │                                                       │
  │  Two-phase token burn:                                 │
  │    voteToBurnTokens → executeBurn (permissionless).    │
  │                                                       │
  │  Uses .call{value:} for all ETH transfers.             │
  └───────────────────────────────────────────────────────┘
*/

import "../OpenZeppelin_openzeppelin-contracts-upgradeable/v4.9.0/contracts/security/ReentrancyGuardUpgradeable.sol";
import "../OpenZeppelin_openzeppelin-contracts-upgradeable/v4.9.0/contracts/proxy/utils/Initializable.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IValidatorVoters {
    function isVoter(address potentialVoter) external view returns (bool);
    function getAllVoters() external view returns (address[] memory);
}

contract GasManager is Initializable, ReentrancyGuardUpgradeable {
    IValidatorVoters constant VALIDATOR_CONTRACT = IValidatorVoters(0x0000000000000000000000000000000000001111);

    uint256 public voteTallyBlockThreshold;
    uint256 public maxContractBalance;
    uint256 public totalGasFunded;

    uint256 public period;
    uint256 public limit;

    mapping(address => bool) public whitelist;

    mapping(VoteType => mapping(uint256 => VoteTally)) private voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool))) public hasVoted;

    mapping(address => uint256) private addressSpecificCurrentPeriodEnd;
    mapping(address => uint256) private addressSpecificCurrentPeriodAmount;

    enum VoteType {
        WHITELIST_ADD,
        WHITELIST_REMOVE,
        LIMIT,
        VOTE_TALLY_BLOCK_THRESHOLD,
        PERIOD,
        MAX_CONTRACT_BALANCE,
        BURN_TOKENS
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
    event MaxContractBalanceChanged(uint256 newMaxBalance);
    event ExcessBurned(uint256 amount);
    event WhitelistUpdated(address indexed target, bool added);
    event TokenBurnApproved(address indexed tokenAddress, uint256 amount, bytes32 burnKey);

    // Approved token burns: keccak256(tokenAddress, amount) => true
    mapping(bytes32 => bool) public approvedBurns;

    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    modifier onlyVoters() {
        require(VALIDATOR_CONTRACT.isVoter(msg.sender), "Only voters can call this function");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize() public virtual initializer {
        __ReentrancyGuard_init();
        voteTallyBlockThreshold = 1000;
        maxContractBalance = 100 ether;
        period = 1000;
        limit = 1 ether;
    }

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

    function getMajorityThreshold() public view returns (uint256) {
        uint256 totalVoterCount = VALIDATOR_CONTRACT.getAllVoters().length;
        require(totalVoterCount > 0, "No voters available");
        return (totalVoterCount / 2) + 1;
    }

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

    function updatePeriod(address _address) internal {
        if (addressSpecificCurrentPeriodEnd[_address] < block.number) {
            addressSpecificCurrentPeriodEnd[_address] = block.number + period;
            addressSpecificCurrentPeriodAmount[_address] = 0;
        }
    }

    function getFundingDetails(address _address)
        public
        view
        returns (uint256 fundedAmount, uint256 periodEnd)
    {
        require(whitelist[_address], "Not whitelisted");
        fundedAmount = addressSpecificCurrentPeriodAmount[_address];
        periodEnd = addressSpecificCurrentPeriodEnd[_address];
    }

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
            emit VoteTallyReset(voteType, target);
        }

        require(
            !hasVoted[voteType][target][msg.sender],
            "Voter has already voted for this target"
        );

        // record the vote
        if (tally.voters.length == 0) {
            tally.startVoteBlock = block.number;
        }
        tally.totalVotes++;
        tally.voters.push(msg.sender);
        hasVoted[voteType][target][msg.sender] = true;

        // check for majority
        if (tally.totalVotes >= getMajorityThreshold()) {
            emit StateChanged(voteType, target);

            if (voteType == VoteType.LIMIT) {
                limit = target;
            } else if (voteType == VoteType.VOTE_TALLY_BLOCK_THRESHOLD) {
                voteTallyBlockThreshold = target;
            } else if (voteType == VoteType.PERIOD) {
                period = target;
            } else if (voteType == VoteType.MAX_CONTRACT_BALANCE) {
                maxContractBalance = target;
                emit MaxContractBalanceChanged(target);
            } else {
                address targetAddress = address(uint160(target));
                if (voteType == VoteType.WHITELIST_ADD) {
                    require(!whitelist[targetAddress], "Already whitelisted");
                    whitelist[targetAddress] = true;
                    emit WhitelistUpdated(targetAddress, true);
                } else if (voteType == VoteType.WHITELIST_REMOVE) {
                    require(whitelist[targetAddress], "Not in whitelist");
                    whitelist[targetAddress] = false;
                    emit WhitelistUpdated(targetAddress, false);
                }
            }

            if (voteType == VoteType.BURN_TOKENS) {
                approvedBurns[bytes32(target)] = true;
            }

            // clear votes
            for (uint256 i = 0; i < tally.voters.length; i++) {
                hasVoted[voteType][target][tally.voters[i]] = false;
            }
            delete voteTallies[voteType][target];
        }

        emit VoteCast(msg.sender, voteType, target);
    }

    function fundGas(address payable _to, uint256 _amount) public nonReentrant {
        require(address(this).balance >= _amount, "Insufficient balance");
        require(whitelist[msg.sender], "Not whitelisted");
        require(_to != address(0), "Invalid recipient address");

        updatePeriod(msg.sender);

        uint256 totalAmount = addressSpecificCurrentPeriodAmount[msg.sender] +
            _amount;
        require(totalAmount <= limit, "exceeds period limit");

        addressSpecificCurrentPeriodAmount[msg.sender] += _amount;

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

        burnExcessGas();
    }

    function burnExcessGas() internal {
        if (address(this).balance > maxContractBalance) {
            uint256 excess = address(this).balance - maxContractBalance;
            (bool success, ) = payable(DEAD_ADDRESS).call{value: excess}("");
            if (success) {
                emit ExcessBurned(excess);
            }
        }
    }

    function setMaxContractBalance(uint256 _newMaxBalance) public onlyVoters {
        require(_newMaxBalance > 0, "Invalid max balance");
        _castVote(VoteType.MAX_CONTRACT_BALANCE, _newMaxBalance);
    }

    function setMaxGasAmount(uint256 _amount) public onlyVoters {
        require(_amount > 0 && _amount <= 1000 ether, "Invalid gas amount");
        _castVote(VoteType.LIMIT, _amount);
    }

    function setVoteTallyBlockThreshold(uint256 _blocks) public onlyVoters {
        require(_blocks > 0 && _blocks <= 100000, "Invalid block threshold");
        _castVote(VoteType.VOTE_TALLY_BLOCK_THRESHOLD, _blocks);
    }

    function setFundingBlockThreshold(uint256 _blocks) public onlyVoters {
        require(_blocks > 0 && _blocks <= 100000, "Invalid block threshold");
        _castVote(VoteType.PERIOD, _blocks);
    }

    function addWhitelist(address target) public onlyVoters {
        require(target != address(0), "Invalid address");
        _castVote(VoteType.WHITELIST_ADD, uint256(uint160(target)));
    }

    function removeWhitelist(address target) public onlyVoters {
        require(target != address(0), "Invalid address");
        _castVote(VoteType.WHITELIST_REMOVE, uint256(uint160(target)));
    }

    function voteToBurnTokens(address _tokenAddress, uint256 _amount) public onlyVoters {
        require(_tokenAddress != address(0), "Invalid token address");
        require(_amount > 0, "Amount must be greater than zero");
        bytes32 burnKey = keccak256(abi.encodePacked(_tokenAddress, _amount));
        uint256 target = uint256(burnKey);
        _castVote(VoteType.BURN_TOKENS, target);
        // Emit approval event if vote passed (burn was approved)
        if (approvedBurns[bytes32(target)]) {
            emit TokenBurnApproved(_tokenAddress, _amount, burnKey);
        }
    }

    /// @notice Execute a previously approved token burn. Callable by anyone to
    ///         avoid burdening the final voter with the transfer gas cost.
    function executeBurn(address _tokenAddress, uint256 _amount) public {
        bytes32 burnKey = keccak256(abi.encodePacked(_tokenAddress, _amount));
        require(approvedBurns[burnKey], "Burn not approved");
        approvedBurns[burnKey] = false;

        IERC20 token = IERC20(_tokenAddress);
        require(token.balanceOf(address(this)) >= _amount, "Insufficient balance");
        require(token.transfer(DEAD_ADDRESS, _amount), "Token burn failed");
        emit TokenBurned(_tokenAddress, _amount);
    }

    function manualBurnExcessBalance() public onlyVoters {
        if (address(this).balance > maxContractBalance) {
            uint256 excess = address(this).balance - maxContractBalance;
            (bool success, ) = payable(DEAD_ADDRESS).call{value: excess}("");
            require(success, "Burn failed");
            emit ExcessBurned(excess);
        }
    }

    receive() external payable {
        if (address(this).balance > maxContractBalance) {
            uint256 excess = address(this).balance - maxContractBalance;
            (bool success, ) = payable(DEAD_ADDRESS).call{value: excess}("");
            if (success) {
                emit ExcessBurned(excess);
            }
        }
    }

    /**
     * @dev Reserved storage gap for future upgrades.
     */
    uint256[50] private __gap;
}
