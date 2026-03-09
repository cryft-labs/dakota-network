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

    Version 2.4 — Production Gas Manager  [UPGRADEABLE]

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
  │  Funding V1 (legacy):                                │
  │    fundKey = keccak256(abi.encodePacked(to, amount)) │
  │                                                      │
  │  Funding V2:                                         │
  │    Proposal identity = fundingId + nonce             │
  │    fundKey = keccak256(abi.encode(fundingId, nonce)) │
  │    Clear-text note emitted on proposal creation      │
  │    noteHash stored on-chain                          │
  │                                                      │
  │  Shared approval expiry model:                       │
  │    approvalBlock + thresholdAtApproval               │
  │    Threshold changes affect only future approvals    │
  │                                                      │
  │  Expired funding cleanup:                            │
  │    Voter authorizes sweep                            │
  │    Guardian executes bounded cleanup batches         │
  │                                                      │
  │  Guardian management:                                │
  │    Add/remove individual guardians, or clear all     │
  │    via voteToClearGuardians(). Enumerable via        │
  │    getGuardians() / getGuardianCount().              │
  │                                                      │
  │  V2 public API uses string fundingId (≤ 32 bytes).   │
  │    On-chain _stringToBytes32 conversion to bytes32.  │
  │    Matches ethers.encodeBytes32String() encoding.    │
  │    bytes32 fundingId logic is internal only.         │
  │                                                      │
  │  Upgradeability notes:                               │
  │    Existing storage order is preserved.              │
  │    Old storage slots are not reordered.              │
  │    approvedFunds safely serves both V1 and V2 keys.  │
  │                                                      │
  │  Uses .call{value:} for all ETH transfers.           │
  │  ReentrancyGuard on all execute functions.           │
  └──────────────────────────────────────────────────────┘
*/

import "../Upgradeable/ReentrancyGuardUpgradeable.sol";
import "../Upgradeable/Initializable.sol";

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
    mapping(VoteType => mapping(uint256 => VoteTally)) private _voteTallies;
    mapping(VoteType => mapping(uint256 => mapping(address => bool))) public hasVoted;
    mapping(bytes32 => bool) public approvedBurns;

    // Existing storage slot retained in-place.
    // Expanded safely to represent approval state for BOTH V1 and V2 funding keys.
    mapping(bytes32 => bool) public approvedFunds;

    mapping(bytes32 => bool) public approvedCoinBurns;

    address constant _DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ── Appended Storage (safe append-only upgrade) ────────────────────────

    struct FundProposal {
        bytes32 fundingId;
        bytes32 noteHash;
        address payable to;
        uint256 amount;
        uint256 nonce;
        bool executed;
        bool exists;
    }

    // V2 proposals keyed by fundKey = keccak256(abi.encode(fundingId, nonce))
    mapping(bytes32 => FundProposal) private _fundProposals;

    // Last nonce used for each funding id.
    mapping(bytes32 => uint256) private _lastFundingNonceByFundingId;

    // Shared approval expiry model for BOTH V1 and V2
    uint256 public fundApprovalBlockThreshold;
    mapping(bytes32 => uint256) public fundApprovalBlock;
    mapping(bytes32 => uint256) public fundApprovalThresholdAtApproval;

    // Enumerable active approved fund keys for governed stale-expiry sweeps
    bytes32[] private _activeApprovedFundKeys;
    mapping(bytes32 => uint256) private _activeApprovedFundKeyIndexPlusOne;

    // Governed cleanup authorization state
    bool public expiredFundCleanupAuthorized;
    uint256 public expiredFundCleanupCursor;

    uint256 private constant _MAX_FUND_NOTE_LENGTH = 280;
    uint256 private constant _MAX_CLEANUP_BATCH_SCAN = 500;

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
        BURN_NATIVE_COIN,
        UPDATE_FUND_APPROVAL_BLOCK_THRESHOLD,
        AUTHORIZE_EXPIRED_FUND_CLEANUP
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
    event VoteTallyBlockThresholdUpdated(uint256 newThreshold);
    event FundApprovalBlockThresholdUpdated(uint256 newThreshold);

    event TokenBurnApproved(address indexed tokenAddress, uint256 amount, bytes32 burnKey);
    event GasFundApproved(address indexed to, uint256 amount, bytes32 fundKey);
    event CoinBurnApproved(uint256 amount, bytes32 coinBurnKey);

    event FundApprovalWindowSet(
        bytes32 indexed fundKey,
        uint256 approvalBlock,
        uint256 thresholdAtApproval
    );

    event FundApprovalCleared(
        bytes32 indexed fundKey,
        bool expiredOrInvalid
    );

    event GasFundProposalCreated(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount,
        bytes32 noteHash,
        string note
    );

    event GasFundProposalApproved(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount,
        bytes32 noteHash,
        uint256 approvalBlock,
        uint256 thresholdAtApproval
    );

    event GasFundProposalExecuted(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount
    );

    event ExpiredFundCleanupAuthorized(uint256 activeApprovedFundCount);
    event ExpiredFundCleanupExecuted(
        uint256 scannedCount,
        uint256 clearedCount,
        uint256 nextCursor,
        bool completed
    );

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
        fundApprovalBlockThreshold = 1000;
    }

    /// @notice Upgrade initializer for already-deployed instances upgrading from older versions.
    ///         Safe to call once after upgrade if `fundApprovalBlockThreshold` was never set.
    function initializeV2() public reinitializer(2) {
        if (fundApprovalBlockThreshold == 0) {
            fundApprovalBlockThreshold = 1000;
        }
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
            if (!_containsAddress(allVoters, counter, votersArray[i])) {
                allVoters[counter] = votersArray[i];
                counter++;
            }
        }
        for (uint256 i = 0; i < otherVoterContracts.length; i++) {
            try IVoterChecker(otherVoterContracts[i]).getVoters() returns (address[] memory ext) {
                for (uint256 j = 0; j < ext.length; j++) {
                    if (!_containsAddress(allVoters, counter, ext[j])) {
                        allVoters[counter] = ext[j];
                        counter++;
                    }
                }
            } catch {}
        }

        address[] memory uniqueVoters = new address[](counter);
        for (uint256 i = 0; i < counter; i++) {
            uniqueVoters[i] = allVoters[i];
        }

        return uniqueVoters;
    }

    /// @notice Returns the total number of unique voters (local + external).
    function getVoterCount() public view returns (uint256) {
        return getVoters().length;
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

    // ── Balance Queries ───────────────────────────────────

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address tokenAddress)
        public
        view
        returns (uint256)
    {
        IERC20 token = IERC20(tokenAddress);
        return token.balanceOf(address(this));
    }

    // ── Shared Funding Approval Queries ───────────────────

    function getFundApprovalStatus(bytes32 fundKey)
        public
        view
        returns (
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid,
            bool inActiveSet
        )
    {
        approved = approvedFunds[fundKey];
        approvalBlockNumber = fundApprovalBlock[fundKey];
        thresholdAtApproval = fundApprovalThresholdAtApproval[fundKey];
        expiredOrInvalid = _isFundApprovalExpiredOrInvalid(fundKey);
        inActiveSet = _activeApprovedFundKeyIndexPlusOne[fundKey] != 0;
    }

    function getActiveApprovedFundKeyCount() public view returns (uint256) {
        return _activeApprovedFundKeys.length;
    }

    function getActiveApprovedFundKeys(uint256 start, uint256 count)
        public
        view
        returns (bytes32[] memory keys)
    {
        require(start < _activeApprovedFundKeys.length || _activeApprovedFundKeys.length == 0, "Start out of range");

        uint256 len = _activeApprovedFundKeys.length;
        if (start >= len) {
            return new bytes32[](0);
        }

        uint256 end = start + count;
        if (end > len) {
            end = len;
        }

        keys = new bytes32[](end - start);
        uint256 out = 0;
        for (uint256 i = start; i < end; i++) {
            keys[out] = _activeApprovedFundKeys[i];
            out++;
        }
    }

    function lastFundingNonceByFundingId(string calldata fundingId) public view returns (uint256) {
        return _lastFundingNonceByFundingId[_stringToBytes32(fundingId)];
    }

    // ── V1 Legacy Funding Queries ─────────────────────────

    function getLegacyFundKey(address to, uint256 amount) public pure returns (bytes32) {
        require(to != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than zero");
        return keccak256(abi.encodePacked(to, amount));
    }

    function getLegacyFundApprovalStatus(address to, uint256 amount)
        public
        view
        returns (
            bytes32 fundKey,
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid,
            bool inActiveSet
        )
    {
        fundKey = getLegacyFundKey(to, amount);
        (
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid,
            inActiveSet
        ) = getFundApprovalStatus(fundKey);
    }

    // ── V2 Funding Queries ────────────────────────────────

    function getNextFundingNonce(string calldata fundingId) public view returns (uint256) {
        bytes32 fid = _stringToBytes32(fundingId);
        return _lastFundingNonceByFundingId[fid] + 1;
    }

    function getFundKey(string calldata fundingId, uint256 nonce) public pure returns (bytes32) {
        return _getFundKey(_stringToBytes32(fundingId), nonce);
    }

    function _getFundKey(bytes32 fundingId, uint256 nonce) internal pure returns (bytes32) {
        require(fundingId != bytes32(0), "Funding ID should not be zero");
        require(nonce > 0, "Nonce must be greater than zero");
        return keccak256(abi.encode(fundingId, nonce));
    }

    function getFundProposal(bytes32 fundKey)
        public
        view
        returns (
            bytes32 fundingId,
            uint256 nonce,
            address to,
            uint256 amount,
            bytes32 noteHash,
            bool executed,
            bool exists,
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid
        )
    {
        FundProposal storage proposal = _fundProposals[fundKey];
        (
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid,
            /* inActiveSet */
        ) = getFundApprovalStatus(fundKey);

        return (
            proposal.fundingId,
            proposal.nonce,
            proposal.to,
            proposal.amount,
            proposal.noteHash,
            proposal.executed,
            proposal.exists,
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid
        );
    }

    function _getFundProposalByFundingId(bytes32 fundingId, uint256 nonce)
        internal
        view
        returns (
            bytes32 fundKey,
            address to,
            uint256 amount,
            bytes32 noteHash,
            bool executed,
            bool exists,
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid
        )
    {
        fundKey = _getFundKey(fundingId, nonce);
        FundProposal storage proposal = _fundProposals[fundKey];
        (
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid,
            /* inActiveSet */
        ) = getFundApprovalStatus(fundKey);

        return (
            fundKey,
            proposal.to,
            proposal.amount,
            proposal.noteHash,
            proposal.executed,
            proposal.exists,
            approved,
            approvalBlockNumber,
            thresholdAtApproval,
            expiredOrInvalid
        );
    }

    function getFundProposalByFundingId(string calldata fundingId, uint256 nonce)
        public
        view
        returns (
            bytes32 fundKey,
            address to,
            uint256 amount,
            bytes32 noteHash,
            bool executed,
            bool exists,
            bool approved,
            uint256 approvalBlockNumber,
            uint256 thresholdAtApproval,
            bool expiredOrInvalid
        )
    {
        return _getFundProposalByFundingId(_stringToBytes32(fundingId), nonce);
    }

    // ── Internal Vote Engine ──────────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        require(target != 0, "Target should not be zero");

        VoteTally storage tally = _voteTallies[voteType][target];

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

        require(
            !hasVoted[voteType][target][msg.sender],
            "Voter has already voted for this target"
        );

        if (tally.voters.length == 0) {
            tally.startVoteBlock = block.number;
            activeVoteCount++;
        }

        tally.totalVotes++;
        tally.voters.push(msg.sender);
        hasVoted[voteType][target][msg.sender] = true;

        if (tally.totalVotes >= getSupermajorityThreshold()) {
            emit StateChanged(voteType, target);

            if (voteType == VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD) {
                require(
                    target > 0 && target <= 100000,
                    "Threshold must be 1 to 100000"
                );
                voteTallyBlockThreshold = target;
                emit VoteTallyBlockThresholdUpdated(target);
            } else if (voteType == VoteType.UPDATE_FUND_APPROVAL_BLOCK_THRESHOLD) {
                require(
                    target > 0 && target <= 100000,
                    "Funding approval threshold must be 1 to 100000"
                );
                fundApprovalBlockThreshold = target;
                emit FundApprovalBlockThresholdUpdated(target);
            } else if (voteType == VoteType.AUTHORIZE_EXPIRED_FUND_CLEANUP) {
                expiredFundCleanupAuthorized = true;
                expiredFundCleanupCursor = 0;
                emit ExpiredFundCleanupAuthorized(_activeApprovedFundKeys.length);
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
                        require(
                            otherVoterContracts[i] != targetAddress,
                            "Voter contract already in list"
                        );
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
                _approveFundKey(bytes32(target));
            }

            if (voteType == VoteType.BURN_NATIVE_COIN) {
                approvedCoinBurns[bytes32(target)] = true;
            }

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
        require(activeVoteCount == 0, "Cannot remove voter while votes are active");
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
        _castVote(VoteType.CLEAR_GUARDIANS, 1);
    }

    function getGuardians() public view returns (address[] memory) {
        return guardiansArray;
    }

    function getGuardianCount() public view returns (uint256) {
        return guardiansArray.length;
    }

    // ── Parameter Governance ──────────────────────────────

    function voteToUpdateVoteTallyBlockThreshold(uint256 newThreshold) external onlyVoters {
        require(newThreshold > 0 && newThreshold <= 100000, "Invalid block threshold");
        _castVote(VoteType.UPDATE_VOTE_TALLY_BLOCK_THRESHOLD, newThreshold);
    }

    function voteToUpdateFundApprovalBlockThreshold(uint256 newThreshold) external onlyVoters {
        require(newThreshold > 0 && newThreshold <= 100000, "Invalid funding approval threshold");
        _castVote(VoteType.UPDATE_FUND_APPROVAL_BLOCK_THRESHOLD, newThreshold);
    }

    function voteToAuthorizeExpiredFundCleanup() external onlyVoters {
        require(_activeApprovedFundKeys.length > 0, "No approved fundings to scan");
        _castVote(VoteType.AUTHORIZE_EXPIRED_FUND_CLEANUP, 1);
    }

    // ── Gas Funding V1 (Legacy) ───────────────────────────

    function voteToFundGasV1(address to, uint256 amount) external onlyVoters {
        require(to != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than zero");

        bytes32 fundKey = getLegacyFundKey(to, amount);

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        require(!approvedFunds[fundKey], "Fund already approved");

        _castVote(VoteType.FUND_GAS, uint256(fundKey));

        if (approvedFunds[fundKey]) {
            emit GasFundApproved(to, amount, fundKey);
        }
    }

    /// @notice Execute a legacy V1 gas funding approval.
    function executeFundGasV1(address payable to, uint256 amount) public nonReentrant {
        require(isGuardian[msg.sender] || msg.sender == to, "Only guardian or funded address");

        bytes32 fundKey = getLegacyFundKey(to, amount);

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        require(approvedFunds[fundKey], "Fund not approved");

        _consumeFundApproval(fundKey);

        require(address(this).balance >= amount, "Insufficient balance");
        require(to != address(0), "Invalid recipient address");

        uint256 balanceBefore = address(this).balance;

        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");

        uint256 balanceAfter = address(this).balance;
        require(balanceBefore - balanceAfter == amount, "Exact amount not transferred");

        totalGasFunded += amount;

        emit GasFunded(to, amount);
    }

    // ── Gas Funding V2 ────────────────────────────────────

    function proposeFundGasV2(
        string calldata fundingId,
        address payable to,
        uint256 amount,
        string calldata note
    )
        external
        onlyVoters
        returns (bytes32 fundKey, uint256 nonce)
    {
        return _proposeFundGas(_stringToBytes32(fundingId), to, amount, note);
    }

    function _proposeFundGas(
        bytes32 fundingId,
        address payable to,
        uint256 amount,
        string calldata note
    )
        internal
        returns (bytes32 fundKey, uint256 nonce)
    {
        require(fundingId != bytes32(0), "Funding ID should not be zero");
        require(to != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than zero");
        require(bytes(note).length <= _MAX_FUND_NOTE_LENGTH, "Note too long");

        nonce = _lastFundingNonceByFundingId[fundingId] + 1;
        fundKey = _getFundKey(fundingId, nonce);

        require(!_fundProposals[fundKey].exists, "Fund proposal already exists");

        _lastFundingNonceByFundingId[fundingId] = nonce;

        _fundProposals[fundKey] = FundProposal({
            fundingId: fundingId,
            noteHash: keccak256(bytes(note)),
            to: to,
            amount: amount,
            nonce: nonce,
            executed: false,
            exists: true
        });

        emit GasFundProposalCreated(
            fundingId,
            nonce,
            fundKey,
            to,
            amount,
            _fundProposals[fundKey].noteHash,
            note
        );

        _castVote(VoteType.FUND_GAS, uint256(fundKey));

        if (approvedFunds[fundKey]) {
            emit GasFundApproved(to, amount, fundKey);
            emit GasFundProposalApproved(
                fundingId,
                nonce,
                fundKey,
                to,
                amount,
                _fundProposals[fundKey].noteHash,
                fundApprovalBlock[fundKey],
                fundApprovalThresholdAtApproval[fundKey]
            );
        }
    }

    function voteToFundGasV2(bytes32 fundKey) external onlyVoters {
        FundProposal storage proposal = _fundProposals[fundKey];

        require(proposal.exists, "Fund proposal not found");
        require(!proposal.executed, "Fund proposal already executed");

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        require(!approvedFunds[fundKey], "Fund already approved");

        _castVote(VoteType.FUND_GAS, uint256(fundKey));

        if (approvedFunds[fundKey]) {
            emit GasFundApproved(proposal.to, proposal.amount, fundKey);
            emit GasFundProposalApproved(
                proposal.fundingId,
                proposal.nonce,
                fundKey,
                proposal.to,
                proposal.amount,
                proposal.noteHash,
                fundApprovalBlock[fundKey],
                fundApprovalThresholdAtApproval[fundKey]
            );
        }
    }

    /// @notice Execute a V2 funding approval by `fundKey` only.
    function executeFundGasV2(bytes32 fundKey) public nonReentrant {
        FundProposal storage proposal = _fundProposals[fundKey];

        require(proposal.exists, "Fund proposal not found");
        require(!proposal.executed, "Fund proposal already executed");
        require(
            isGuardian[msg.sender] || msg.sender == proposal.to,
            "Only guardian or funded address"
        );

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        require(approvedFunds[fundKey], "Fund not approved");

        _consumeFundApproval(fundKey);
        proposal.executed = true;

        require(address(this).balance >= proposal.amount, "Insufficient balance");
        require(proposal.to != address(0), "Invalid recipient address");

        uint256 balanceBefore = address(this).balance;

        (bool success, ) = proposal.to.call{value: proposal.amount}("");
        require(success, "Transfer failed");

        uint256 balanceAfter = address(this).balance;
        require(
            balanceBefore - balanceAfter == proposal.amount,
            "Exact amount not transferred"
        );

        totalGasFunded += proposal.amount;

        emit GasFunded(proposal.to, proposal.amount);
        emit GasFundProposalExecuted(
            proposal.fundingId,
            proposal.nonce,
            fundKey,
            proposal.to,
            proposal.amount
        );
    }

    // ── Governed Expired Funding Cleanup ──────────────────

    /// @notice Guardian executes a bounded sweep over active approved fund keys.
    ///         Removes approvals that are expired or invalid.
    ///         Cursor-based so cleanup can be chunked safely.
    function executeExpiredFundCleanup(uint256 maxScans) external nonReentrant {
        require(isGuardian[msg.sender], "Only guardian");
        require(expiredFundCleanupAuthorized, "Expired fund cleanup not authorized");
        require(
            maxScans > 0 && maxScans <= _MAX_CLEANUP_BATCH_SCAN,
            "Invalid cleanup batch size"
        );

        uint256 scannedCount = 0;
        uint256 clearedCount = 0;

        while (
            expiredFundCleanupCursor < _activeApprovedFundKeys.length &&
            scannedCount < maxScans
        ) {
            bytes32 fundKey = _activeApprovedFundKeys[expiredFundCleanupCursor];
            scannedCount++;

            if (_isFundApprovalExpiredOrInvalid(fundKey)) {
                _clearFundApproval(fundKey, true);
                clearedCount++;
            } else {
                expiredFundCleanupCursor++;
            }
        }

        bool completed = expiredFundCleanupCursor >= _activeApprovedFundKeys.length;
        if (completed) {
            expiredFundCleanupAuthorized = false;
            expiredFundCleanupCursor = 0;
        }

        emit ExpiredFundCleanupExecuted(
            scannedCount,
            clearedCount,
            expiredFundCleanupCursor,
            completed
        );
    }

    // ── Token Burns ───────────────────────────────────────

    function voteToBurnTokens(address tokenAddress, uint256 amount) external onlyVoters {
        require(tokenAddress != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than zero");

        bytes32 burnKey = keccak256(abi.encodePacked(tokenAddress, amount));
        _castVote(VoteType.BURN_TOKENS, uint256(burnKey));

        if (approvedBurns[burnKey]) {
            emit TokenBurnApproved(tokenAddress, amount, burnKey);
        }
    }

    function executeTokenBurn(address tokenAddress, uint256 amount) public nonReentrant {
        require(isGuardian[msg.sender], "Only guardian");

        bytes32 burnKey = keccak256(abi.encodePacked(tokenAddress, amount));
        require(approvedBurns[burnKey], "Burn not approved");
        approvedBurns[burnKey] = false;

        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) >= amount, "Insufficient balance");
        require(token.transfer(_DEAD_ADDRESS, amount), "Token burn failed");

        emit TokenBurned(tokenAddress, amount);
    }

    // ── Native Coin Burns ─────────────────────────────────

    function voteToBurnNativeCoin(uint256 amount) external onlyVoters {
        require(amount > 0, "Amount must be greater than zero");

        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", amount));
        _castVote(VoteType.BURN_NATIVE_COIN, uint256(coinBurnKey));

        if (approvedCoinBurns[coinBurnKey]) {
            emit CoinBurnApproved(amount, coinBurnKey);
        }
    }

    function executeCoinBurn(uint256 amount) public nonReentrant {
        require(isGuardian[msg.sender], "Only guardian");

        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", amount));
        require(approvedCoinBurns[coinBurnKey], "Coin burn not approved");
        approvedCoinBurns[coinBurnKey] = false;

        require(address(this).balance >= amount, "Insufficient balance");

        (bool success, ) = payable(_DEAD_ADDRESS).call{value: amount}("");
        require(success, "Burn failed");

        emit NativeCoinBurned(amount);
    }

    // ── Expired Tally Cleanup ─────────────────────────────

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

    receive() external payable {}

    // ── Internal Funding Approval Helpers ─────────────────

    function _approveFundKey(bytes32 fundKey) internal {
        approvedFunds[fundKey] = true;
        fundApprovalBlock[fundKey] = block.number;
        fundApprovalThresholdAtApproval[fundKey] = fundApprovalBlockThreshold;

        _addActiveApprovedFundKey(fundKey);

        emit FundApprovalWindowSet(
            fundKey,
            fundApprovalBlock[fundKey],
            fundApprovalThresholdAtApproval[fundKey]
        );
    }

    function _consumeFundApproval(bytes32 fundKey) internal {
        _clearFundApproval(fundKey, false);
    }

    function _clearFundApproval(bytes32 fundKey, bool expiredOrInvalid) internal {
        approvedFunds[fundKey] = false;
        fundApprovalBlock[fundKey] = 0;
        fundApprovalThresholdAtApproval[fundKey] = 0;

        _removeActiveApprovedFundKey(fundKey);

        emit FundApprovalCleared(fundKey, expiredOrInvalid);
    }

    function _clearFundApprovalIfExpiredOrInvalid(bytes32 fundKey) internal {
        if (_isFundApprovalExpiredOrInvalid(fundKey)) {
            _clearFundApproval(fundKey, true);
        }
    }

    function _isFundApprovalExpiredOrInvalid(bytes32 fundKey) internal view returns (bool) {
        if (!approvedFunds[fundKey]) {
            return false;
        }

        uint256 approvalBlockNumber = fundApprovalBlock[fundKey];
        uint256 thresholdAtApproval = fundApprovalThresholdAtApproval[fundKey];

        if (approvalBlockNumber == 0 || thresholdAtApproval == 0) {
            return true;
        }

        return block.number > approvalBlockNumber + thresholdAtApproval;
    }

    function _addActiveApprovedFundKey(bytes32 fundKey) internal {
        if (_activeApprovedFundKeyIndexPlusOne[fundKey] == 0) {
            _activeApprovedFundKeys.push(fundKey);
            _activeApprovedFundKeyIndexPlusOne[fundKey] = _activeApprovedFundKeys.length;
        }
    }

    function _removeActiveApprovedFundKey(bytes32 fundKey) internal {
        uint256 indexPlusOne = _activeApprovedFundKeyIndexPlusOne[fundKey];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _activeApprovedFundKeys.length - 1;

        if (index != lastIndex) {
            bytes32 movedKey = _activeApprovedFundKeys[lastIndex];
            _activeApprovedFundKeys[index] = movedKey;
            _activeApprovedFundKeyIndexPlusOne[movedKey] = index + 1;
        }

        _activeApprovedFundKeys.pop();
        delete _activeApprovedFundKeyIndexPlusOne[fundKey];

        if (expiredFundCleanupCursor > _activeApprovedFundKeys.length) {
            expiredFundCleanupCursor = _activeApprovedFundKeys.length;
        }
    }

    // ── Utilities ─────────────────────────────────────────

    function _containsAddress(
        address[] memory addresses,
        uint256 length,
        address target
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (addresses[i] == target) {
                return true;
            }
        }
        return false;
    }

    /// @dev Converts a short string (1-32 bytes) to a left-aligned bytes32.
    ///      Encoding is identical to ethers.encodeBytes32String().
    function _stringToBytes32(string calldata str) internal pure returns (bytes32 result) {
        bytes calldata b = bytes(str);
        require(b.length > 0 && b.length <= 32, "String must be 1-32 bytes");
        // Left-align: copy bytes into the high-order end of a 32-byte word.
        // Unused trailing bytes remain zero — matching ethers.encodeBytes32String().
        assembly ("memory-safe") {
            result := calldataload(b.offset)
            // Mask off any garbage past the string length.
            let shift := shl(3, sub(32, b.length))
            result := and(result, shl(shift, shr(shift, not(0))))
        }
        return result;
    }

    function _isContract(address addr) internal view returns (bool) {
        uint32 size;
        assembly ("memory-safe") {
            size := extcodesize(addr)
        }
        return (size > 0);
    }
}
