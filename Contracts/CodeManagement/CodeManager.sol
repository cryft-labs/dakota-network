// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {GovernanceMembers} from "../Genesis/Governance/GovernanceMembers.sol";
import {GovernanceVotes} from "../Genesis/Governance/GovernanceVotes.sol";
import {Initializable} from "../Genesis/Upgradeable/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "../Genesis/Upgradeable/ReentrancyGuardUpgradeable.sol";
import {StringsUpgradeable} from "../Genesis/Upgradeable/Utils/StringsUpgradeable.sol";
import {ICodeManager} from "./Interfaces/ICodeManager.sol";
import {IRedeemable} from "./Interfaces/IRedeemable.sol";
import {CanonicalUid} from "./CanonicalUid.sol";

/// @title CodeManager
/// @notice Registers unique code identifiers for gift contracts and records their redemption.
/// @dev Linked behind the genesis proxy 0x…c0DE. Voters govern it by 2/3 ballots; ballot windows are
///      block.timestamp seconds (default 7 days) and approved voter changes void open ballots. A gift (or a
///      registration operator it names) pays `registrationFee` per code; identifiers are
///      keccak256(address(this), giftContract, chainId) plus an incrementing counter. Authorized Pente privacy
///      groups, each scoped per gift in a per-group epoch, route redemptions and active-state mirrors here.
///      CodeManager stores sparse public status only: a code with no override uses DEFAULT_ACTIVE_STATE, which
///      for privacy-managed codes means "no public override recorded", not proof of the private state. The gift
///      contract stays the authority on what a redemption does. Upgrades are scheduled on the proxy and wait the
///      network upgrade delay. Storage is append-only. Patent: U.S. App. Ser. No. 18/930,857.
/// @custom:version 3.1.0
/// @custom:security-contact security@cryft.cards
contract CodeManager is Initializable, ReentrancyGuardUpgradeable, ICodeManager {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @notice Public status of a code. Values are stored by index: never reorder.
    /// @dev UseDefaultActiveState means no public override is recorded; it resolves to DEFAULT_ACTIVE_STATE.
    enum UniqueIdStatus {
        UseDefaultActiveState,
        Inactive,
        Redeemed
    }

    /// @notice Ballot kinds. Values are part of the ballot key and the ABI: never reorder.
    enum VoteType {
        SetRegistrationFee,
        SetFeeVault,
        AddVoter,
        RemoveVoter,
        AddOtherVoterContract,
        RemoveOtherVoterContract,
        SetVoteWindow,
        DeauthorizePrivacyGroup,
        RefreshVoters,
        SetVoterConfiguration,
        SetPrivacyGroupGift
    }

    /// @dev A privacy-group gift grant waiting for its ballot.
    struct GroupGiftChange { address group; address gift; bool allowed; uint256 epoch; }

    /// @dev The committed recipient of a redeemed code and its delivery state.
    struct Delivery { address recipient; bool delivered; uint256 attempts; }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @notice Active state of every valid code that has no override.
    bool public constant DEFAULT_ACTIVE_STATE = true;
    /// @notice Most codes one status batch may carry.
    uint256 public constant MAX_STATUS_BATCH = 100;
    /// @notice Gas forwarded to a gift contract on delivery.
    uint256 public constant DELIVERY_GAS_LIMIT = 1000000;
    /// @notice Gas a delivery needs on entry: the forwarded limit after the 63/64 rule plus room to record it.
    uint256 public constant MIN_DELIVERY_GAS = DELIVERY_GAS_LIMIT * 64 / 63 + 100000;
    /// @notice Upper bound on the per-code registration fee.
    uint256 public constant MAX_REGISTRATION_FEE = 1 ether;
    /// @notice Ballot window set at initialization.
    uint256 public constant DEFAULT_VOTE_WINDOW = 7 days;

    uint256 private constant _PROBE_GAS = 100000;

    // ─── Storage ─────────────────────────────────────────────────────────────────────────────────

    /// @notice Local voters.
    address[] public votersArray;
    /// @notice Contracts whose `getVoters()` lists are added to the local voters.
    address[] public otherVoterContracts;
    uint256 private __reserved2;

    /// @notice Fee in wei per registered code.
    uint256 public registrationFee;
    /// @notice Ballot window in seconds.
    /// @dev Name kept from the block-count era; slot unchanged.
    uint256 public voteTallyBlockThreshold;
    /// @notice Address that receives registration fees.
    address public feeVault;

    mapping(string => uint256) private _identifierCounter;
    mapping(string => ContractData) private _contractIdentifierToData;
    mapping(bytes32 => UniqueIdStatus) private _uniqueIdStatuses;

    /// @notice Whether a group has held a gift grant in its current epoch; access is always checked per gift.
    mapping(address => bool) public isAuthorizedPrivacyGroup;
    /// @notice Whether a gift lets an operator register codes for it.
    mapping(address => mapping(address => bool)) public registrationOperators;
    /// @notice Bumped on every deauthorization, so earlier gift grants never come back.
    mapping(address => uint256) public privacyGroupEpoch;
    mapping(bytes32 => bool) private _groupGiftGrants;
    mapping(uint256 => GroupGiftChange) private _groupGiftChanges;
    mapping(bytes32 => Delivery) private _deliveries;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A gift allowed or disallowed a registration operator.
    event RegistrationOperatorUpdated(address indexed gift, address indexed operator, bool allowed);
    /// @notice A privacy group's grant for a gift changed.
    event PrivacyGroupGiftUpdated(address indexed group, address indexed gift, bool allowed, uint256 epoch);
    /// @notice A grant ballot passed after its group was deauthorized, so it was not applied.
    event PrivacyGroupGiftChangeStale(address indexed group, address indexed gift, uint256 epoch);
    /// @notice A privacy group lost every grant; its epoch moved on.
    event PrivacyGroupDeauthorized(address indexed group, uint256 newEpoch);
    /// @notice A delivery to the gift contract was attempted.
    event RedemptionDeliveryAttempt(string uniqueId, address indexed recipient, uint256 attempt, bool delivered);
    /// @notice The registration fee changed.
    event RegistrationFeeUpdated(uint256 newFee);
    /// @notice The fee vault changed.
    event FeeVaultUpdated(address indexed newFeeVault);
    /// @notice A voter cast a ballot.
    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    /// @notice An expired ballot was cleared.
    event VoteTallyReset(VoteType voteType, uint256 target);
    /// @notice Codes were registered for a gift contract.
    event UniqueIdsRegistered(address indexed giftContract, string chainId, uint256 quantity);
    /// @notice A local voter was added or removed.
    event VoterUpdated(address indexed target, bool added);
    /// @notice The initial voters were set.
    event VotersInitialized(address[] voters);
    /// @notice A voter-provider contract was added or removed.
    event OtherVoterContractUpdated(address indexed target, bool added);
    /// @notice A voter configuration ballot was applied.
    event VoterConfigurationApplied(bytes32 indexed membersHash);
    /// @notice The ballot window changed.
    event VoteWindowUpdated(uint256 newWindowSeconds);
    /// @notice A redemption reached the gift contract.
    event RedemptionRouted(string uniqueId, address indexed giftContract, address indexed redeemer);
    /// @notice A delivery to the gift contract failed; the code stays redeemed and the delivery can be retried.
    event RedemptionFailed(string uniqueId, address indexed giftContract, address indexed redeemer, string reason);
    /// @notice A redemption failed a precondition; nothing was consumed.
    event RedemptionRejected(string uniqueId, address indexed redeemer, string reason);
    /// @notice A code's public active state changed.
    event UniqueIdActiveStatusUpdated(string uniqueId, bool active, bool usesDefaultState);
    /// @notice A code was marked redeemed.
    event UniqueIdRedeemed(string uniqueId);
    /// @notice One entry of a status batch was skipped.
    event UniqueIdActiveStatusRejected(uint256 index, string uniqueId, string reason);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The chain id is empty.
    error EmptyChainId();
    /// @notice The fee vault rejected the registration fee.
    error FeeTransferFailed();
    /// @notice No fee vault is set.
    error FeeVaultNotSet();
    /// @notice The transaction has too little gas left to deliver.
    error InsufficientDeliveryGas();
    /// @notice The payment is less than `registrationFee * quantity`.
    error InsufficientRegistrationFee();
    /// @notice The initializer caller is not a guardian of the hosting proxy.
    error InitializerNotLinkGuardian();
    /// @notice A batch is empty or carries more than MAX_STATUS_BATCH codes.
    error InvalidBatchSize();
    /// @notice The code's counter is zero or past the registered range.
    error InvalidCounter();
    /// @notice The caller is not a contract, or the operator is the zero address.
    error InvalidGiftOrOperator();
    /// @notice The group is the zero address or the gift has no code.
    error InvalidGroupOrGift();
    /// @notice The code is not registered or its counter is out of range.
    error InvalidUniqueId();
    /// @notice The code is not in `<identifier>-<counter>` form.
    error InvalidUniqueIdFormat();
    /// @notice The two arrays differ in length.
    error LengthMismatch();
    /// @notice The code has no committed redemption to deliver.
    error NoCommittedDelivery();
    /// @notice The caller is not an authorized privacy group.
    error NotAuthorizedPrivacyGroup();
    /// @notice The caller is neither the gift contract nor one of its registration operators.
    error NotRegistrationOperator();
    /// @notice The privacy group has no grant for the code's gift contract.
    error PrivacyGroupScopeMismatch();
    /// @notice The code already has a committed redemption.
    error RedemptionAlreadyCommitted();
    /// @notice A public precondition rejected the strict redemption.
    error RedemptionPreconditionRejected();
    /// @notice The excess payment could not be refunded.
    error RefundFailed();
    /// @notice The registration fee is above MAX_REGISTRATION_FEE.
    error RegistrationFeeTooHigh();
    /// @notice The code is already redeemed.
    error UniqueIdAlreadyRedeemed();
    /// @notice No gift contract is registered for the code's identifier.
    error UniqueIdNotFound();
    /// @notice The address is the zero address.
    error ZeroAddress();
    /// @notice The quantity is zero.
    error ZeroQuantity();

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    modifier onlyAuthorizedPrivacyGroup() {
        if (!isAuthorizedPrivacyGroup[msg.sender]) revert NotAuthorizedPrivacyGroup();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    // ─── Initializers ────────────────────────────────────────────────────────────────────────────

    /// @notice Sets the initial voters (1 to 64 distinct), the fee and the ballot window once, as the proxy link's
    ///         init data.
    /// @dev Only a guardian of the hosting proxy may run it, so an empty-data link cannot be front-run.
    function initializeWithVoters(address[] calldata voters) external initializer {
        _requireLinkGuardian();
        __ReentrancyGuard_init();
        if (voters.length == 0) revert GovernanceVotes.NoVoters();
        address[] memory members =
            GovernanceMembers.collect(voters, new address[](0), bytes4(keccak256("getVoters()")));
        if (members.length != voters.length) revert GovernanceVotes.VoterAlreadyPresent();
        votersArray = voters;
        GovernanceVotes.approveVoters(GovernanceVotes.state(), members);
        registrationFee = 10**15;
        voteTallyBlockThreshold = DEFAULT_VOTE_WINDOW;
        emit VotersInitialized(voters);
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Casts a ballot to adopt the current provider membership, if it still hashes to `expectedHash`.
    function voteToRefreshVoters(bytes32 expectedHash) external {
        _castVote(VoteType.RefreshVoters, uint256(expectedHash));
    }

    /// @notice Casts a ballot to replace the local voters and providers in one step.
    /// @dev The ballot binds both the configuration and the resulting membership hash.
    function voteToSetVoterConfiguration(
        address[] calldata local,
        address[] calldata providers,
        bytes32 expectedHash
    ) external {
        uint256 target = GovernanceVotes.configure(GovernanceVotes.state(), local, providers, expectedHash);
        _castVote(VoteType.SetVoterConfiguration, target);
    }

    /// @notice Casts a ballot to add a local voter.
    function voteToAddVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.AddVoter, uint256(uint160(voter)));
    }

    /// @notice Casts a ballot to remove a local voter.
    function voteToRemoveVoter(address voter) external {
        if (voter == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.RemoveVoter, uint256(uint160(voter)));
    }

    /// @notice Casts a ballot to add a contract whose `getVoters()` list joins the voters.
    function voteToAddOtherVoterContract(address voterContract) external {
        GovernanceMembers.read(voterContract, bytes4(keccak256("getVoters()")));
        _castVote(VoteType.AddOtherVoterContract, uint256(uint160(voterContract)));
    }

    /// @notice Casts a ballot to remove a voter-provider contract.
    function voteToRemoveOtherVoterContract(address voterContract) external {
        if (voterContract == address(0)) revert GovernanceVotes.InvalidVoteTarget();
        _castVote(VoteType.RemoveOtherVoterContract, uint256(uint160(voterContract)));
    }

    /// @notice Casts a ballot to set the per-code registration fee in wei (1 to MAX_REGISTRATION_FEE).
    function voteToSetRegistrationFee(uint256 newFee) external {
        if (newFee > MAX_REGISTRATION_FEE) revert RegistrationFeeTooHigh();
        _castVote(VoteType.SetRegistrationFee, newFee);
    }

    /// @notice Casts a ballot to set the address that receives registration fees.
    function voteToSetFeeVault(address newFeeVault) external {
        if (newFeeVault == address(0)) revert ZeroAddress();
        _castVote(VoteType.SetFeeVault, uint256(uint160(newFeeVault)));
    }

    /// @notice Casts a ballot to set the ballot window in seconds (1 hour to 30 days).
    function voteToSetVoteWindow(uint256 newWindowSeconds) external {
        if (!GovernanceVotes.validWindow(newWindowSeconds)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.SetVoteWindow, newWindowSeconds);
    }

    /// @notice Casts a ballot to revoke every gift grant of a group at once.
    /// @dev The group's epoch advances, so a later grant starts from an empty scope.
    function voteToDeauthorizePrivacyGroup(address privacyGroup) external {
        if (privacyGroup == address(0)) revert ZeroAddress();
        _castVote(VoteType.DeauthorizePrivacyGroup, uint256(uint160(privacyGroup)));
    }

    /// @notice Casts a ballot to grant or revoke a group's access to one gift, in the group's current epoch.
    /// @dev The only way to authorize a group.
    function voteToSetPrivacyGroupGift(address group, address gift, bool allowed) external {
        if (group == address(0) || gift.code.length == 0) revert InvalidGroupOrGift();
        uint256 epoch = privacyGroupEpoch[group];
        uint256 target = uint256(keccak256(abi.encode(group, gift, allowed, epoch)));
        _groupGiftChanges[target] = GroupGiftChange(group, gift, allowed, epoch);
        _castVote(VoteType.SetPrivacyGroupGift, target);
    }

    /// @notice Lets the calling gift contract allow or disallow a separate registration payer.
    /// @dev Paying fees alone never grants authority to advance another gift's code range.
    function setRegistrationOperator(address operator, bool allowed) external {
        if (msg.sender.code.length == 0 || operator == address(0)) revert InvalidGiftOrOperator();
        registrationOperators[msg.sender][operator] = allowed;
        emit RegistrationOperatorUpdated(msg.sender, operator, allowed);
    }

    /// @notice Redeems a code with all-or-nothing preconditions, for private code consumption.
    /// @dev Calls the guarded public `recordRedemption` internally, which keeps msg.sender. A gift delivery failure
    ///      still commits the recipient and can be retried. A public precondition failure reverts, so the enclosing
    ///      Pente transition rolls back.
    function recordRedemptionStrict(string memory uniqueId, address redeemer) external {
        bytes32 uidHash = keccak256(bytes(uniqueId));
        if (_deliveries[uidHash].recipient != address(0)) revert RedemptionAlreadyCommitted();
        recordRedemption(uniqueId, redeemer);
        if (redeemer == address(0) || _deliveries[uidHash].recipient != redeemer) {
            revert RedemptionPreconditionRejected();
        }
    }

    /// @notice Retries delivery of a redeemed code to its committed recipient; anyone may call it.
    /// @dev Repeating a successful delivery is a no-op; a spent code is never reopened.
    function retryRedemptionDelivery(string calldata uniqueId) external nonReentrant {
        bytes32 uidHash = keccak256(bytes(uniqueId));
        Delivery storage delivery = _deliveries[uidHash];
        if (_uniqueIdStatuses[uidHash] != UniqueIdStatus.Redeemed || delivery.recipient == address(0)) {
            revert NoCommittedDelivery();
        }
        if (delivery.delivered) return;
        (, string memory identifier, ) = _trySplitUniqueId(uniqueId);
        _attemptDelivery(uniqueId, _contractIdentifierToData[identifier].giftContract);
    }

    /// @notice Mirrors private active-state changes for up to MAX_STATUS_BATCH codes.
    /// @dev Invalid, out-of-scope or redeemed codes are skipped and reported by event. The default is sparse: an
    ///      `active` equal to DEFAULT_ACTIVE_STATE deletes any stored override.
    function setUniqueIdActiveBatch(
        string[] calldata uniqueIds,
        bool[] calldata activeStates
    ) external onlyAuthorizedPrivacyGroup {
        uint256 len = uniqueIds.length;
        if (len != activeStates.length) revert LengthMismatch();
        if (len == 0 || len > MAX_STATUS_BATCH) revert InvalidBatchSize();

        for (uint256 i = 0; i < len; ++i) {
            if (bytes(uniqueIds[i]).length == 0) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "Empty uniqueId");
                continue;
            }
            if (!validateUniqueId(uniqueIds[i])) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "Invalid uniqueId");
                continue;
            }

            (, string memory identifier, ) = _trySplitUniqueId(uniqueIds[i]);
            if (!canPrivacyGroupAccessGift(msg.sender, _contractIdentifierToData[identifier].giftContract)) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "Privacy group scope mismatch");
                continue;
            }

            bytes32 uidHash = keccak256(bytes(uniqueIds[i]));
            if (_uniqueIdStatuses[uidHash] == UniqueIdStatus.Redeemed) {
                emit UniqueIdActiveStatusRejected(i, uniqueIds[i], "UniqueId already redeemed");
                continue;
            }

            if (activeStates[i] == DEFAULT_ACTIVE_STATE) {
                delete _uniqueIdStatuses[uidHash];
                emit UniqueIdActiveStatusUpdated(uniqueIds[i], activeStates[i], true);
            } else {
                _uniqueIdStatuses[uidHash] = UniqueIdStatus.Inactive;
                emit UniqueIdActiveStatusUpdated(uniqueIds[i], activeStates[i], false);
            }
        }
    }

    /// @notice Registers `quantity` new codes for `giftContract`, paid at `registrationFee` each.
    /// @dev The gift or one of its registration operators pays; the fee goes to `feeVault` and any excess is
    ///      refunded to the caller.
    function registerUniqueIds(
        address giftContract,
        string memory chainId,
        uint256 quantity
    ) external payable nonReentrant {
        if (giftContract == address(0)) revert ZeroAddress();
        if (msg.sender != giftContract && !registrationOperators[giftContract][msg.sender]) {
            revert NotRegistrationOperator();
        }
        if (quantity == 0) revert ZeroQuantity();
        if (bytes(chainId).length == 0) revert EmptyChainId();

        uint256 totalFee = registrationFee * quantity;
        if (msg.value < totalFee) revert InsufficientRegistrationFee();
        address vault = feeVault;
        if (vault == address(0)) revert FeeVaultNotSet();

        _incrementCounter(giftContract, chainId, quantity);
        emit UniqueIdsRegistered(giftContract, chainId, quantity);

        (bool feePaid, ) = payable(vault).call{value: totalFee}("");
        if (!feePaid) revert FeeTransferFailed();

        uint256 refund = msg.value - totalFee;
        if (refund > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: refund}("");
            if (!refunded) revert RefundFailed();
        }
    }

    /// @notice Clears an expired ballot; anyone may call it, and no membership or approval changes.
    function resetExpiredTally(VoteType voteType, uint256 target) external {
        GovernanceVotes.resetExpired(GovernanceVotes.state(), _voteKey(voteType, target));
        emit VoteTallyReset(voteType, target);
    }

    /// @notice Returns the membership a refresh would adopt now, and its hash.
    function previewVoters() external view returns (address[] memory members, bytes32 membersHash) {
        members = _readVoters();
        membersHash = keccak256(abi.encode(members));
    }

    /// @notice Returns a ballot's threshold, closing time, epoch and electorate snapshot.
    function getProposalSnapshot(VoteType voteType, uint256 target)
        external
        view
        returns (uint256 threshold, uint256 expires, uint256 epoch, address[] memory electorate)
    {
        return GovernanceVotes.snapshot(GovernanceVotes.state(), _voteKey(voteType, target));
    }

    /// @notice Returns the electorate epoch; it moves on with every approved voter change.
    function governanceEpoch() external view returns (uint256) {
        return GovernanceVotes.state().epoch;
    }

    /// @notice Returns how many counted and exempt ballots `proposer` holds open.
    function openBallots(address proposer) external view returns (uint256 counted, uint256 exempt) {
        return GovernanceVotes.openCount(GovernanceVotes.state(), proposer);
    }

    /// @notice Returns whether `voter` voted on a ballot.
    function hasVoted(VoteType voteType, uint256 target, address voter) external view returns (bool) {
        return GovernanceVotes.voted(GovernanceVotes.state(), _voteKey(voteType, target), voter);
    }

    /// @notice Returns the committed recipient of a redeemed code.
    function getRedemptionRecipient(string calldata uniqueId) external view returns (address) {
        return _deliveries[keccak256(bytes(uniqueId))].recipient;
    }

    /// @notice Returns a redeemed code's committed recipient, whether delivery succeeded and how often it was tried.
    function getRedemptionDelivery(string calldata uniqueId)
        external
        view
        returns (address recipient, bool delivered, uint256 attempts)
    {
        Delivery storage delivery = _deliveries[keccak256(bytes(uniqueId))];
        return (delivery.recipient, delivery.delivered, delivery.attempts);
    }

    /// @inheritdoc ICodeManager
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool) {
        if (!validateUniqueId(uniqueId)) return false;
        return _uniqueIdStatuses[keccak256(bytes(uniqueId))] == UniqueIdStatus.Redeemed;
    }

    /// @notice Reverts unless every code is registered, in the caller's gift scope and not redeemed.
    function validateUniqueIdsOrRevert(string[] calldata uniqueIds) external view onlyAuthorizedPrivacyGroup {
        uint256 len = uniqueIds.length;
        if (len == 0 || len > MAX_STATUS_BATCH) revert InvalidBatchSize();

        for (uint256 i = 0; i < len; ++i) {
            if (!validateUniqueId(uniqueIds[i])) revert InvalidUniqueId();
            (, string memory identifier, ) = _trySplitUniqueId(uniqueIds[i]);
            if (!canPrivacyGroupAccessGift(msg.sender, _contractIdentifierToData[identifier].giftContract)) {
                revert PrivacyGroupScopeMismatch();
            }
            if (_uniqueIdStatuses[keccak256(bytes(uniqueIds[i]))] == UniqueIdStatus.Redeemed) {
                revert UniqueIdAlreadyRedeemed();
            }
        }
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @notice Marks a code redeemed and delivers it to its gift contract; callable by an authorized privacy group.
    /// @dev Never reverts on a failed precondition (invalid format, unregistered identifier, out-of-scope group,
    ///      out-of-range counter, inactive or redeemed code): it emits RedemptionRejected and returns, keeping the
    ///      best-effort ABI. It does revert when gasleft() is below MIN_DELIVERY_GAS at delivery, so no code is
    ///      consumed. Private code consumption must use `recordRedemptionStrict`. The code is marked Redeemed
    ///      before the gift contract is called; a failing gift emits RedemptionFailed instead of reverting, the
    ///      code stays Redeemed, and `retryRedemptionDelivery` retries the committed recipient.
    function recordRedemption(
        string memory uniqueId,
        address redeemer
    ) public onlyAuthorizedPrivacyGroup nonReentrant {
        (bool splitOk, string memory contractIdentifier, ) = _trySplitUniqueId(uniqueId);
        if (!splitOk) {
            emit RedemptionRejected(uniqueId, redeemer, "Invalid uniqueId format");
            return;
        }

        ContractData memory data = _contractIdentifierToData[contractIdentifier];
        if (data.giftContract == address(0)) {
            emit RedemptionRejected(uniqueId, redeemer, "Unregistered contract identifier");
            return;
        }

        if (redeemer == address(0) || !canPrivacyGroupAccessGift(msg.sender, data.giftContract)) {
            emit RedemptionRejected(uniqueId, redeemer, "Invalid recipient or privacy group scope");
            return;
        }

        if (!validateUniqueId(uniqueId)) {
            emit RedemptionRejected(uniqueId, redeemer, "Invalid or out-of-range uniqueId");
            return;
        }

        if (!isUniqueIdActive(uniqueId)) {
            emit RedemptionRejected(uniqueId, redeemer, "UniqueId is inactive or already redeemed");
            return;
        }

        bytes32 uidHash = keccak256(bytes(uniqueId));
        _uniqueIdStatuses[uidHash] = UniqueIdStatus.Redeemed;
        emit UniqueIdRedeemed(uniqueId);

        _deliveries[uidHash].recipient = redeemer;
        _attemptDelivery(uniqueId, data.giftContract);
    }

    /// @notice Returns whether `potentialVoter` is a voter.
    function isVoter(address potentialVoter) public view returns (bool) {
        return GovernanceMembers.contains(getVoters(), potentialVoter);
    }

    /// @notice Returns the approved voters.
    function getVoters() public view returns (address[] memory) {
        if (GovernanceVotes.state().votersInitialized) return GovernanceVotes.state().approvedVoters;
        return _readVoters();
    }

    /// @notice Returns the number of approved voters.
    function getVoterCount() public view returns (uint256) {
        return getVoters().length;
    }

    /// @notice Returns a ballot's vote count, opening and closing times and the addresses that voted.
    function getVoteTally(VoteType voteType, uint256 target)
        public
        view
        returns (uint256 totalVotes, uint256 startTime, uint256 expiresAt, address[] memory votedAddresses)
    {
        return GovernanceVotes.tally(GovernanceVotes.state(), _voteKey(voteType, target));
    }

    /// @notice Returns the number of open ballots.
    function activeVoteCount() public view returns (uint256) {
        return GovernanceVotes.state().active;
    }

    /// @notice Returns the votes a ballot needs: two thirds of the voters, rounded up.
    function getSupermajorityThreshold() public view returns (uint256) {
        uint256 totalVoterCount = getVoterCount();
        if (totalVoterCount == 0) revert GovernanceVotes.NoVoters();
        return (totalVoterCount * 2 + 2) / 3;
    }

    /// @notice Returns whether `group` holds a grant for `gift` in its current epoch.
    function privacyGroupGifts(address group, address gift) public view returns (bool) {
        return _groupGiftGrants[_grantKey(group, privacyGroupEpoch[group], gift)];
    }

    /// @notice Returns whether `group` is authorized and holds a grant for `gift`.
    function canPrivacyGroupAccessGift(address group, address gift) public view returns (bool) {
        return isAuthorizedPrivacyGroup[group] && privacyGroupGifts(group, gift);
    }

    /// @inheritdoc ICodeManager
    /// @dev A code without an override returns DEFAULT_ACTIVE_STATE. For privacy-managed codes that means no public
    ///      override is recorded; the active or frozen state may be kept privately.
    function isUniqueIdActive(string memory uniqueId) public view returns (bool) {
        if (!validateUniqueId(uniqueId)) return false;
        UniqueIdStatus status = _uniqueIdStatuses[keccak256(bytes(uniqueId))];
        if (status == UniqueIdStatus.Redeemed || status == UniqueIdStatus.Inactive) return false;
        return DEFAULT_ACTIVE_STATE;
    }

    /// @inheritdoc ICodeManager
    function getContractData(string memory contractIdentifier) public view returns (ContractData memory) {
        return _contractIdentifierToData[contractIdentifier];
    }

    /// @inheritdoc ICodeManager
    function getIdentifierCounter(address giftContract, string memory chainId)
        public
        view
        returns (string memory contractIdentifier, uint256 counter)
    {
        bytes32 hash = keccak256(abi.encodePacked(address(this), giftContract, chainId));
        contractIdentifier = StringsUpgradeable.toHexString(uint256(hash), 32);
        counter = _identifierCounter[contractIdentifier];
    }

    /// @inheritdoc ICodeManager
    function getCounterByIdentifier(string memory contractIdentifier) public view returns (uint256) {
        return _identifierCounter[contractIdentifier];
    }

    /// @inheritdoc ICodeManager
    function validateUniqueId(string memory uniqueId) public view returns (bool isValid) {
        (bool ok, string memory contractIdentifier, uint256 extractedCounter) = _trySplitUniqueId(uniqueId);
        if (!ok) return false;
        uint256 registered = _identifierCounter[contractIdentifier];
        if (registered == 0) return false;
        return extractedCounter > 0 && extractedCounter <= registered;
    }

    /// @inheritdoc ICodeManager
    function getUniqueIdDetails(string memory uniqueId)
        public
        view
        returns (address giftContract, string memory chainId, uint256 counter)
    {
        (bool ok, string memory contractIdentifier, uint256 extractedCounter) = _trySplitUniqueId(uniqueId);
        if (!ok) revert InvalidUniqueIdFormat();
        ContractData memory data = getContractData(contractIdentifier);
        if (data.giftContract == address(0)) revert UniqueIdNotFound();
        uint256 currentCounter = _identifierCounter[contractIdentifier];
        if (extractedCounter == 0 || extractedCounter > currentCounter) revert InvalidCounter();
        return (data.giftContract, data.chainId, extractedCounter);
    }

    /// @notice Returns this implementation's version.
    function implementationVersion() public pure returns (string memory) {
        return "3.1.0";
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        GovernanceVotes.State storage s = GovernanceVotes.state();
        address[] memory electorate;
        if (!GovernanceVotes.live(s, key)) electorate = getVoters();
        if (GovernanceVotes.cast(s, key, electorate, voteTallyBlockThreshold, msg.sender, _isExempt(voteType))) {
            if (_changesVoters(voteType)) {
                _applyVoterVote(voteType, target);
            } else if (voteType == VoteType.SetPrivacyGroupGift || voteType == VoteType.DeauthorizePrivacyGroup) {
                _applyGroupVote(voteType, target);
            } else {
                _applyParameterVote(voteType, target);
            }
            GovernanceVotes.complete(s, key);
            if (_changesVoters(voteType)) GovernanceVotes.invalidate(s);
        }
        emit VoteCast(msg.sender, voteType, target);
    }

    function _incrementCounter(address giftContract, string memory chainId, uint256 quantity) internal {
        bytes32 hash = keccak256(abi.encodePacked(address(this), giftContract, chainId));
        string memory contractIdentifier = StringsUpgradeable.toHexString(uint256(hash), 32);
        if (_identifierCounter[contractIdentifier] == 0) {
            _contractIdentifierToData[contractIdentifier] = ContractData(giftContract, chainId);
        }
        _identifierCounter[contractIdentifier] += quantity;
    }

    function _trySplitUniqueId(string memory uniqueId)
        internal
        pure
        returns (bool ok, string memory contractIdentifier, uint256 counter)
    {
        return CanonicalUid.split(uniqueId);
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    function _applyParameterVote(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.SetRegistrationFee) {
            if (target > MAX_REGISTRATION_FEE) revert RegistrationFeeTooHigh();
            registrationFee = target;
            emit RegistrationFeeUpdated(target);
        } else if (voteType == VoteType.SetFeeVault) {
            feeVault = address(uint160(target));
            emit FeeVaultUpdated(feeVault);
        } else {
            if (!GovernanceVotes.validWindow(target)) revert GovernanceVotes.InvalidExpiry();
            voteTallyBlockThreshold = target;
            emit VoteWindowUpdated(target);
        }
    }

    function _applyGroupVote(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.DeauthorizePrivacyGroup) {
            address group = address(uint160(target));
            isAuthorizedPrivacyGroup[group] = false;
            uint256 epoch = ++privacyGroupEpoch[group];
            emit PrivacyGroupDeauthorized(group, epoch);
            return;
        }
        GroupGiftChange memory change = _groupGiftChanges[target];
        delete _groupGiftChanges[target];
        if (change.epoch != privacyGroupEpoch[change.group]) {
            // The group was deauthorized while this ballot was open: never apply it to the new epoch.
            emit PrivacyGroupGiftChangeStale(change.group, change.gift, change.epoch);
            return;
        }
        _groupGiftGrants[_grantKey(change.group, change.epoch, change.gift)] = change.allowed;
        if (change.allowed) isAuthorizedPrivacyGroup[change.group] = true;
        emit PrivacyGroupGiftUpdated(change.group, change.gift, change.allowed, change.epoch);
    }

    function _applyVoterVote(VoteType voteType, uint256 target) private {
        address targetAddress = address(uint160(target));
        GovernanceVotes.State storage s = GovernanceVotes.state();
        if (voteType == VoteType.AddVoter) {
            if (isVoter(targetAddress)) revert GovernanceVotes.VoterAlreadyPresent();
            votersArray.push(targetAddress);
            emit VoterUpdated(targetAddress, true);
        } else if (voteType == VoteType.RemoveVoter) {
            if (!_removeAddress(votersArray, targetAddress)) revert GovernanceVotes.VoterNotFound();
            emit VoterUpdated(targetAddress, false);
        } else if (voteType == VoteType.AddOtherVoterContract) {
            if (GovernanceMembers.contains(otherVoterContracts, targetAddress)) {
                revert GovernanceVotes.ProviderAlreadyPresent();
            }
            otherVoterContracts.push(targetAddress);
            emit OtherVoterContractUpdated(targetAddress, true);
        } else if (voteType == VoteType.RemoveOtherVoterContract) {
            if (votersArray.length == 0 && otherVoterContracts.length <= 1) revert GovernanceVotes.EmptyVoterSet();
            if (!_removeAddress(otherVoterContracts, targetAddress)) revert GovernanceVotes.ProviderNotFound();
            emit OtherVoterContractUpdated(targetAddress, false);
        } else if (voteType == VoteType.SetVoterConfiguration) {
            GovernanceVotes.Configuration storage config = s.configurations[target];
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
            if (membersHash != s.configurations[target].membersHash) revert GovernanceVotes.MembershipChanged();
            delete s.configurations[target];
            emit VoterConfigurationApplied(membersHash);
        }
        GovernanceVotes.approveVoters(s, members);
    }

    /// @dev Swap-and-pop removal; voter and provider arrays are bounded at 64 / 16 entries.
    function _removeAddress(address[] storage list, address target) private returns (bool) {
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ++i) {
            if (list[i] == target) {
                list[i] = list[len - 1];
                list.pop();
                return true;
            }
        }
        return false;
    }

    /// @dev Callers hold the reentrancy guard. The caller cannot choose the gift's gas: a starved call reverts the
    ///      whole transaction instead of being recorded as a failed attempt, and the gift always gets exactly
    ///      DELIVERY_GAS_LIMIT.
    function _attemptDelivery(string memory uniqueId, address gift) private {
        Delivery storage delivery = _deliveries[keccak256(bytes(uniqueId))];
        bytes memory input = abi.encodeCall(IRedeemable.recordRedemption, (uniqueId, delivery.recipient));
        if (gasleft() < MIN_DELIVERY_GAS) revert InsufficientDeliveryGas();
        uint256 limit = DELIVERY_GAS_LIMIT;
        bool success;
        if (gift.code.length != 0) {
            assembly ("memory-safe") {
                success := call(limit, gift, 0, add(input, 32), mload(input), 0, 0)
            }
        }
        ++delivery.attempts;
        delivery.delivered = success;
        if (success) {
            emit RedemptionRouted(uniqueId, gift, delivery.recipient);
        } else {
            emit RedemptionFailed(
                uniqueId,
                gift,
                delivery.recipient,
                "Gift delivery failed; retry committed recipient"
            );
        }
        emit RedemptionDeliveryAttempt(uniqueId, delivery.recipient, delivery.attempts, success);
    }

    /// @dev The caller must be a guardian of the proxy this code runs in.
    function _requireLinkGuardian() private view {
        bytes memory input = abi.encodeWithSignature("proxy_isGuardian(address)", msg.sender);
        address host = address(this);
        bool ok;
        uint256 result;
        assembly ("memory-safe") {
            ok := staticcall(_PROBE_GAS, host, add(input, 32), mload(input), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            result := mload(0)
        }
        if (!ok || result != 1) revert InitializerNotLinkGuardian();
    }

    function _readVoters() private view returns (address[] memory) {
        return GovernanceMembers.collect(votersArray, otherVoterContracts, bytes4(keccak256("getVoters()")));
    }

    function _voteKey(VoteType voteType, uint256 target) private pure returns (bytes32) {
        return keccak256(abi.encode(voteType, target));
    }

    function _changesVoters(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.RefreshVoters || voteType == VoteType.SetVoterConfiguration
            || voteType == VoteType.AddVoter || voteType == VoteType.RemoveVoter
            || voteType == VoteType.AddOtherVoterContract || voteType == VoteType.RemoveOtherVoterContract;
    }

    /// @dev Defensive ballots stay open-able even when one voter floods the counted caps.
    function _isExempt(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.RemoveVoter || voteType == VoteType.SetVoterConfiguration
            || voteType == VoteType.DeauthorizePrivacyGroup;
    }

    function _grantKey(address group, uint256 epoch, address gift) private pure returns (bytes32) {
        return keccak256(abi.encode(group, epoch, gift));
    }
}
