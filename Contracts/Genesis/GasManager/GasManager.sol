// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {GovernanceMembers} from "../Governance/GovernanceMembers.sol";
import {GovernanceVotes} from "../Governance/GovernanceVotes.sol";
import {Initializable} from "../Upgradeable/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "../Upgradeable/ReentrancyGuardUpgradeable.sol";

/// @title IERC20
/// @notice The two ERC-20 calls GasManager makes when it burns tokens it holds.
interface IERC20 {
    /// @notice Returns the token balance of `account`.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Moves `amount` tokens from the caller to `recipient`.
    function transfer(address recipient, uint256 amount) external returns (bool);
}

/// @title IGasSponsorDepository
/// @notice The GasSponsor (0x…FEeD) call GasManager makes to fund a sponsor's gas credit.
interface IGasSponsorDepository {
    /// @notice Adds the sent value to `sponsor`'s gas credit.
    function depositGasCredit(address sponsor) external payable;
}

/// @title GasManager
/// @notice Holds the network's gas beneficiary balance and pays it out, or burns it, by voter ballot.
/// @dev Linked behind the genesis proxy 0x…cafE. Every state change needs a 2/3 ballot of the voters; an approved
///      voter change voids every open ballot and every pending burn approval. Treasury operations run in two
///      phases: a ballot approves, then a guardian or the recipient executes once `executionDelay` seconds have
///      passed and before `fundApprovalWindow` more seconds run out. Native outflows (funding, sponsor funding,
///      coin burns) share a cap of `outflowCap` wei per `outflowPeriod` seconds. Voters may cancel any pending
///      approval. All windows are block.timestamp seconds. A funding key is keccak256(abi.encode(fundingId,
///      nonce)); recipient, amount and note hash are bound when the funding is proposed. Upgrades are scheduled
///      on the proxy and wait the network upgrade delay. Storage is append-only.
/// @custom:version 2.6.0
/// @custom:security-contact security@cryft.cards
contract GasManager is Initializable, ReentrancyGuardUpgradeable {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @dev A pending burn approval. Field order is storage layout: never change it.
    struct Approval {
        uint256 executableAt;
        uint256 expiresAt;
        uint256 epoch;      // governance epoch at approval; a voter change voids the approval
    }

    /// @dev A funding proposal. Field order is storage layout: never change it.
    struct FundProposal {
        bytes32 fundingId;
        bytes32 noteHash;
        address payable to;
        uint256 amount;
        uint256 nonce;
        bool executed;
        bool exists;
    }

    /// @dev A treasury parameter change waiting for its ballot.
    struct ParameterChange { Parameter parameter; uint256 value; }

    /// @custom:storage-location erc7201:cryft.storage.GasManagerSponsorFunding
    struct SponsorFundingStorage {
        mapping(bytes32 => address) sponsorByFundKey;
    }

    /// @notice Treasury parameters a ballot can set. Values are stored by index: never reorder.
    enum Parameter { ExecutionDelay, ApprovalWindow, OutflowCap, OutflowPeriod }

    /// @notice Ballot kinds. Values are part of the ballot key and the ABI: never reorder.
    enum VoteType {
        AddGuardian,
        RemoveGuardian,
        AddVoter,
        RemoveVoter,
        AddOtherVoterContract,
        RemoveOtherVoterContract,
        SetVoteWindow,
        ClearGuardians,
        BurnTokens,
        FundGas,
        BurnNativeCoin,
        SetParameter,
        AuthorizeExpiredFundCleanup,
        RefreshVoters,
        SetVoterConfiguration,
        CancelApproval
    }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    /// @notice Most guardians GasManager keeps.
    uint256 public constant MAX_GUARDIANS = 64;
    /// @notice Longest execution delay a ballot can set.
    uint256 public constant MAX_EXECUTION_DELAY = 30 days;
    /// @notice Ballot window set at initialization.
    uint256 public constant DEFAULT_VOTE_WINDOW = 7 days;
    /// @notice Approval window set at initialization.
    uint256 public constant DEFAULT_APPROVAL_WINDOW = 3 days;

    address private constant _DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address private constant _GAS_SPONSOR = 0x000000000000000000000000000000000000FEeD;
    bytes32 private constant _SPONSOR_FUNDING_STORAGE_LOCATION =
        0x2a467852670f144839bf1fd02ad0393580187791ab471304d92161a3bee88100;
    uint256 private constant _MAX_FUND_NOTE_LENGTH = 280;
    uint256 private constant _MAX_CLEANUP_BATCH_SCAN = 500;
    uint256 private constant _MAX_PAGE = 100;
    uint256 private constant _PROBE_GAS = 100000;

    // ─── Storage ─────────────────────────────────────────────────────────────────────────────────

    /// @notice Ballot window in seconds.
    /// @dev Name kept from the block-count era; slot unchanged.
    uint256 public voteTallyBlockThreshold;
    /// @notice Total wei paid out by executed fundings.
    uint256 public totalGasFunded;
    uint256 private __reserved53;

    /// @notice Local voters.
    address[] public votersArray;
    /// @notice Contracts whose `getVoters()` lists are added to the local voters.
    address[] public otherVoterContracts;
    /// @notice Guardians, who execute approved burns and fundings and run cleanups.
    address[] public guardiansArray;

    /// @notice Whether an address is a guardian.
    mapping(address => bool) public isGuardian;
    uint256 private __reserved58;
    uint256 private __reserved59;
    /// @dev Token and native-coin burn approvals (keys never collide: coin keys are prefixed "nativeBurn").
    mapping(bytes32 => Approval) private _burnApprovals;
    /// @notice Whether a funding key holds a live approval.
    mapping(bytes32 => bool) public approvedFunds;
    uint256 private __reserved62;

    mapping(bytes32 => FundProposal) private _fundProposals;
    mapping(bytes32 => uint256) private _lastFundingNonceByFundingId;

    /// @notice Seconds an approval stays executable once its delay has passed.
    uint256 public fundApprovalWindow;
    /// @notice First second at which an approved funding may execute.
    mapping(bytes32 => uint256) public fundExecutableAt;
    /// @notice Last second at which an approved funding may execute.
    mapping(bytes32 => uint256) public fundExpiresAt;

    bytes32[] private _activeApprovedFundKeys;
    mapping(bytes32 => uint256) private _activeApprovedFundKeyIndexPlusOne;

    /// @notice Whether a ballot has authorized a guardian sweep of expired funding approvals.
    bool public expiredFundCleanupAuthorized;
    /// @notice Position of the next key the sweep looks at.
    uint256 public expiredFundCleanupCursor;

    /// @notice Seconds between an approval and the first time it can execute.
    uint256 public executionDelay;
    /// @notice Native wei that may leave per outflow period.
    uint256 public outflowCap;
    /// @notice Outflow period length in seconds.
    uint256 public outflowPeriod;
    /// @notice Start of the current outflow period.
    uint256 public outflowPeriodStart;
    /// @notice Wei spent in the current outflow period.
    uint256 public outflowUsed;
    mapping(uint256 => ParameterChange) private _parameterChanges;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice A voter cast a ballot.
    event VoteCast(address indexed voter, VoteType voteType, uint256 target);
    /// @notice An expired ballot was cleared.
    event VoteTallyReset(VoteType voteType, uint256 target);
    /// @notice Wei left GasManager for an executed funding.
    event GasFunded(address indexed to, uint256 amount);
    /// @notice Tokens were burned.
    event TokenBurned(address indexed tokenAddress, uint256 amount);
    /// @notice Native coin was burned.
    event NativeCoinBurned(uint256 amount);
    /// @notice A guardian was added or removed.
    event GuardianUpdated(address indexed target, bool added);
    /// @notice Every guardian was removed.
    event GuardiansCleared(uint256 count);
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
    /// @notice A treasury parameter changed.
    event ParameterUpdated(Parameter indexed parameter, uint256 value);
    /// @notice A pending funding or burn approval was cancelled.
    event ApprovalCancelled(bytes32 indexed key);
    /// @notice A token burn was approved.
    event TokenBurnApproved(
        address indexed tokenAddress,
        uint256 amount,
        bytes32 burnKey,
        uint256 executableAt,
        uint256 expiresAt
    );
    /// @notice A funding was approved.
    event GasFundApproved(address indexed to, uint256 amount, bytes32 fundKey);
    /// @notice A native-coin burn was approved.
    event CoinBurnApproved(uint256 amount, bytes32 coinBurnKey, uint256 executableAt, uint256 expiresAt);
    /// @notice A funding approval's execution window was set.
    event FundApprovalWindowUpdated(bytes32 indexed fundKey, uint256 executableAt, uint256 expiresAt);
    /// @notice A funding approval was consumed, cancelled or cleared as expired.
    event FundApprovalCleared(bytes32 indexed fundKey, bool expiredOrInvalid);
    /// @notice A funding was proposed.
    event GasFundProposalCreated(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount,
        bytes32 noteHash,
        string note
    );
    /// @notice A funding proposal was approved.
    event GasFundProposalApproved(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount,
        bytes32 noteHash,
        uint256 executableAt,
        uint256 expiresAt
    );
    /// @notice A funding proposal was executed.
    event GasFundProposalExecuted(
        bytes32 indexed fundingId,
        uint256 indexed nonce,
        bytes32 indexed fundKey,
        address to,
        uint256 amount
    );
    /// @notice A sponsor funding was proposed.
    event SponsorFundingProposalCreated(bytes32 indexed fundKey, address indexed sponsor, uint256 amount);
    /// @notice A sponsor funding was approved.
    event SponsorFundingProposalApproved(
        bytes32 indexed fundKey,
        address indexed sponsor,
        uint256 executableAt,
        uint256 expiresAt
    );
    /// @notice A sponsor funding was deposited into the sponsor's gas credit.
    event SponsorFundingExecuted(bytes32 indexed fundKey, address indexed sponsor, uint256 amount);
    /// @notice A ballot authorized the expired-approval sweep.
    event ExpiredFundCleanupAuthorized(uint256 activeApprovedFundCount);
    /// @notice A guardian ran one batch of the expired-approval sweep.
    event ExpiredFundCleanupExecuted(uint256 scannedCount, uint256 clearedCount, uint256 nextCursor, bool completed);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The address is already a guardian.
    error AlreadyGuardian();
    /// @notice The native-coin burn transfer failed.
    error BurnFailed();
    /// @notice The burn has no live approval.
    error BurnNotApproved();
    /// @notice No ballot has authorized the expired-approval sweep.
    error CleanupNotAuthorized();
    /// @notice The approval's execution delay has not passed.
    error ExecutionDelayActive(uint256 executableAt);
    /// @notice The funding already holds a live approval.
    error FundAlreadyApproved();
    /// @notice The funding has no live approval.
    error FundNotApproved();
    /// @notice The funding proposal was already executed.
    error FundProposalAlreadyExecuted();
    /// @notice A funding proposal with this key already exists.
    error FundProposalExists();
    /// @notice No funding proposal has this key.
    error FundProposalNotFound();
    /// @notice The GasSponsor proxy has no code.
    error GasSponsorUnavailable();
    /// @notice The initializer caller is not a guardian of the hosting proxy.
    error InitializerNotLinkGuardian();
    /// @notice GasManager holds less than the amount.
    error InsufficientBalance();
    /// @notice The sweep batch size is outside 1 to 500.
    error InvalidBatchSize();
    /// @notice A funding id is not 1 to 32 bytes long.
    error InvalidFundingIdLength();
    /// @notice A treasury parameter value is out of range.
    error InvalidParameter();
    /// @notice The funding recipient is the zero address.
    error InvalidRecipient();
    /// @notice The sponsor is the zero address.
    error InvalidSponsor();
    /// @notice The proposal is not a sponsor funding.
    error InvalidSponsorFundingProposal();
    /// @notice The token is the zero address.
    error InvalidToken();
    /// @notice There are no active funding approvals to sweep.
    error NoApprovedFunds();
    /// @notice There are no guardians to clear.
    error NoGuardians();
    /// @notice The address is not a guardian.
    error NotAGuardian(address account);
    /// @notice The caller is not a guardian.
    error NotGuardian();
    /// @notice The caller is neither a guardian nor the funding recipient.
    error NotGuardianOrRecipient();
    /// @notice The key holds no pending funding or burn approval.
    error NothingToCancel();
    /// @notice The caller is not a voter.
    error NotVoter();
    /// @notice The funding note is longer than 280 bytes.
    error NoteTooLong();
    /// @notice The amount is more than the outflow cap still allows this period.
    error OutflowCapExceeded(uint256 remaining);
    /// @notice Program sponsors accept credit only from their program.
    error ProgramSponsorNotFundable(address sponsor);
    /// @notice A sponsor funding must run through `executeSponsorFunding`.
    error SponsorFundingExecutorRequired();
    /// @notice The sponsor deposit moved a different amount than approved.
    error SponsorFundingTransferMismatch();
    /// @notice The page start is past the end of the list.
    error StartOutOfRange();
    /// @notice The token transfer to the burn address failed.
    error TokenBurnFailed();
    /// @notice GasManager already has the most guardians it keeps.
    error TooManyGuardians();
    /// @notice The funding moved a different amount than approved.
    error TransferAmountMismatch();
    /// @notice The funding transfer failed.
    error TransferFailed();
    /// @notice The caller is neither a guardian nor the bound sponsor.
    error UnauthorizedSponsorFundingExecutor();
    /// @notice The address is the zero address.
    error ZeroAddress();
    /// @notice The amount is zero.
    error ZeroAmount();
    /// @notice The funding id is zero.
    error ZeroFundingId();
    /// @notice The funding nonce is zero.
    error ZeroNonce();

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    modifier onlyVoters() {
        if (!isVoter(msg.sender)) revert NotVoter();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    // ─── Initializers ────────────────────────────────────────────────────────────────────────────

    /// @notice Sets the initial voters and treasury limits once, as the proxy link's init data.
    /// @dev Only a guardian of the hosting proxy (a root or proxy guardian) may run it, so an empty-data link can
    ///      never be front-run.
    /// @param voters          1 to 64 distinct initial voters.
    /// @param executionDelay_ Seconds between approval and execution (0 allowed, e.g. dev).
    /// @param outflowCap_     Wei that may leave per period (> 0).
    /// @param outflowPeriod_  Period length in seconds (1 hour to 30 days).
    function initializeWithVoters(
        address[] calldata voters,
        uint256 executionDelay_,
        uint256 outflowCap_,
        uint256 outflowPeriod_
    ) external initializer {
        _requireLinkGuardian();
        __ReentrancyGuard_init();
        _setInitialVoters(voters);
        voteTallyBlockThreshold = DEFAULT_VOTE_WINDOW;
        fundApprovalWindow = DEFAULT_APPROVAL_WINDOW;
        _setParameter(Parameter.ExecutionDelay, executionDelay_);
        _setParameter(Parameter.OutflowCap, outflowCap_);
        _setParameter(Parameter.OutflowPeriod, outflowPeriod_);
    }

    // ─── receive / fallback ──────────────────────────────────────────────────────────────────────

    /// @notice Accepts native coin (the gas beneficiary payouts).
    receive() external payable {}

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

    /// @notice Casts a ballot to add a guardian.
    function voteToAddGuardian(address guardian) external {
        if (guardian == address(0)) revert ZeroAddress();
        if (guardiansArray.length >= MAX_GUARDIANS) revert TooManyGuardians();
        _castVote(VoteType.AddGuardian, uint256(uint160(guardian)));
    }

    /// @notice Casts a ballot to remove a guardian.
    function voteToRemoveGuardian(address guardian) external {
        if (guardian == address(0)) revert ZeroAddress();
        _castVote(VoteType.RemoveGuardian, uint256(uint160(guardian)));
    }

    /// @notice Casts a ballot to remove every guardian.
    function voteToClearGuardians() external {
        if (guardiansArray.length == 0) revert NoGuardians();
        _castVote(VoteType.ClearGuardians, 1);
    }

    /// @notice Casts a ballot to set the ballot window in seconds (1 hour to 30 days).
    function voteToSetVoteWindow(uint256 newWindowSeconds) external {
        if (!GovernanceVotes.validWindow(newWindowSeconds)) revert GovernanceVotes.InvalidExpiry();
        _castVote(VoteType.SetVoteWindow, newWindowSeconds);
    }

    /// @notice Casts a ballot to set a treasury parameter.
    /// @dev Ranges: execution delay 0 to 30 days, approval window 1 hour to 30 days, outflow cap > 0 wei, outflow
    ///      period 1 hour to 30 days.
    function voteToSetParameter(Parameter parameter, uint256 value) external {
        _checkParameter(parameter, value);
        uint256 target = uint256(keccak256(abi.encode(parameter, value)));
        _parameterChanges[target] = ParameterChange(parameter, value);
        _castVote(VoteType.SetParameter, target);
    }

    /// @notice Casts a ballot to let guardians sweep expired funding approvals.
    function voteToAuthorizeExpiredFundCleanup() external {
        if (_activeApprovedFundKeys.length == 0) revert NoApprovedFunds();
        _castVote(VoteType.AuthorizeExpiredFundCleanup, 1);
    }

    /// @notice Casts a ballot to cancel a pending funding or burn approval (for use during its execution delay).
    function voteToCancelApproval(bytes32 key) external {
        if (!approvedFunds[key] && _burnApprovals[key].expiresAt == 0) revert NothingToCancel();
        _castVote(VoteType.CancelApproval, uint256(key));
    }

    /// @notice Proposes paying `amount` wei to `to` and casts the caller's ballot for it.
    /// @dev "Propose" here creates a funding request; the recipient, amount and note hash are bound now.
    function proposeGasFunding(string calldata fundingId, address payable to, uint256 amount, string calldata note)
        external
        onlyVoters
        returns (bytes32 fundKey, uint256 nonce)
    {
        return _proposeFundGas(_stringToBytes32(fundingId), to, amount, note, address(0));
    }

    /// @notice Proposes a deposit from GasManager into a GasSponsor (0x…FEeD) sponsor's gas credit.
    /// @dev The sponsor is bound before voting begins. Program sponsors accept credit only from their program, so
    ///      funding one would always revert at execution: it is refused here.
    function proposeSponsorFunding(string calldata fundingId, address sponsor, uint256 amount, string calldata note)
        external
        onlyVoters
        returns (bytes32 fundKey, uint256 nonce)
    {
        if (sponsor == address(0)) revert InvalidSponsor();
        if (!_isContract(_GAS_SPONSOR)) revert GasSponsorUnavailable();
        if (_isProgramSponsor(sponsor)) revert ProgramSponsorNotFundable(sponsor);
        return _proposeFundGas(_stringToBytes32(fundingId), payable(_GAS_SPONSOR), amount, note, sponsor);
    }

    /// @notice Casts a ballot for an existing funding proposal.
    function voteToFundGas(bytes32 fundKey) external {
        FundProposal storage proposal = _fundProposals[fundKey];
        if (!proposal.exists) revert FundProposalNotFound();
        if (proposal.executed) revert FundProposalAlreadyExecuted();

        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (approvedFunds[fundKey]) revert FundAlreadyApproved();

        _castVote(VoteType.FundGas, uint256(fundKey));
        _emitIfApproved(fundKey);
    }

    /// @notice Clears up to `maxScans` expired funding approvals; callable by a guardian after a ballot allows it.
    /// @dev Cursor-based, so a long list is swept over several calls.
    function executeExpiredFundCleanup(uint256 maxScans) external nonReentrant {
        if (!isGuardian[msg.sender]) revert NotGuardian();
        if (!expiredFundCleanupAuthorized) revert CleanupNotAuthorized();
        if (maxScans == 0 || maxScans > _MAX_CLEANUP_BATCH_SCAN) revert InvalidBatchSize();

        uint256 scannedCount = 0;
        uint256 clearedCount = 0;
        while (expiredFundCleanupCursor < _activeApprovedFundKeys.length && scannedCount < maxScans) {
            bytes32 fundKey = _activeApprovedFundKeys[expiredFundCleanupCursor];
            ++scannedCount;
            if (_isFundApprovalExpiredOrInvalid(fundKey)) {
                _clearFundApproval(fundKey, true);
                ++clearedCount;
            } else {
                ++expiredFundCleanupCursor;
            }
        }

        bool completed = expiredFundCleanupCursor >= _activeApprovedFundKeys.length;
        if (completed) {
            expiredFundCleanupAuthorized = false;
            expiredFundCleanupCursor = 0;
        }
        emit ExpiredFundCleanupExecuted(scannedCount, clearedCount, expiredFundCleanupCursor, completed);
    }

    /// @notice Casts a ballot to burn `amount` of a token GasManager holds.
    function voteToBurnTokens(address tokenAddress, uint256 amount) external {
        if (tokenAddress == address(0)) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        bytes32 burnKey = keccak256(abi.encodePacked(tokenAddress, amount));
        _castVote(VoteType.BurnTokens, uint256(burnKey));
        Approval storage a = _burnApprovals[burnKey];
        if (_burnValid(a)) emit TokenBurnApproved(tokenAddress, amount, burnKey, a.executableAt, a.expiresAt);
    }

    /// @notice Casts a ballot to burn `amount` wei of native coin.
    function voteToBurnNativeCoin(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        bytes32 coinBurnKey = keccak256(abi.encodePacked("nativeBurn", amount));
        _castVote(VoteType.BurnNativeCoin, uint256(coinBurnKey));
        Approval storage a = _burnApprovals[coinBurnKey];
        if (_burnValid(a)) emit CoinBurnApproved(amount, coinBurnKey, a.executableAt, a.expiresAt);
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

    /// @notice Returns a burn approval; `valid` is false once expired or after any voter change.
    function getBurnApproval(bytes32 burnKey)
        external
        view
        returns (bool valid, uint256 executableAt, uint256 expiresAt)
    {
        Approval storage a = _burnApprovals[burnKey];
        return (_burnValid(a), a.executableAt, a.expiresAt);
    }

    /// @notice Returns the key of a funding and the main fields of its proposal.
    function getFundKeyAndProposal(string calldata fundingId, uint256 nonce)
        external
        view
        returns (
            bytes32 fundKey,
            address to,
            uint256 amount,
            bool executed,
            bool exists,
            bool approved,
            uint256 executableAt
        )
    {
        fundKey = _getFundKey(_stringToBytes32(fundingId), nonce);
        FundProposal storage proposal = _fundProposals[fundKey];
        (approved, executableAt, , , ) = getFundApprovalStatus(fundKey);
        return (fundKey, proposal.to, proposal.amount, proposal.executed, proposal.exists, approved, executableAt);
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @notice Pays an approved funding once its delay has passed; callable by a guardian or the recipient.
    function executeGasFunding(bytes32 fundKey) public nonReentrant {
        FundProposal storage proposal = _fundProposals[fundKey];
        if (!proposal.exists) revert FundProposalNotFound();
        if (proposal.executed) revert FundProposalAlreadyExecuted();
        if (_sponsorFundingStorage().sponsorByFundKey[fundKey] != address(0)) revert SponsorFundingExecutorRequired();
        if (!isGuardian[msg.sender] && msg.sender != proposal.to) revert NotGuardianOrRecipient();

        uint256 amount = proposal.amount;
        _consumeExecutableFund(fundKey, amount);
        proposal.executed = true;
        totalGasFunded += amount;

        uint256 balanceBefore = address(this).balance;
        (bool success, ) = proposal.to.call{value: amount}("");
        if (!success) revert TransferFailed();
        if (balanceBefore - address(this).balance != amount) revert TransferAmountMismatch();

        emit GasFunded(proposal.to, amount);
        emit GasFundProposalExecuted(proposal.fundingId, proposal.nonce, fundKey, proposal.to, amount);
    }

    /// @notice Deposits an approved sponsor funding into the bound sponsor's gas credit at GasSponsor (0x…FEeD).
    function executeSponsorFunding(bytes32 fundKey) public nonReentrant {
        FundProposal storage proposal = _fundProposals[fundKey];
        address sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        if (!proposal.exists) revert FundProposalNotFound();
        if (proposal.executed) revert FundProposalAlreadyExecuted();
        if (sponsor == address(0) || proposal.to != _GAS_SPONSOR) revert InvalidSponsorFundingProposal();
        if (!isGuardian[msg.sender] && msg.sender != sponsor) revert UnauthorizedSponsorFundingExecutor();
        if (!_isContract(_GAS_SPONSOR)) revert GasSponsorUnavailable();

        uint256 amount = proposal.amount;
        _consumeExecutableFund(fundKey, amount);
        proposal.executed = true;
        totalGasFunded += amount;

        uint256 managerBalanceBefore = address(this).balance;
        uint256 gasSponsorBalanceBefore = _GAS_SPONSOR.balance;
        IGasSponsorDepository(_GAS_SPONSOR).depositGasCredit{value: amount}(sponsor);
        if (managerBalanceBefore - address(this).balance != amount) revert SponsorFundingTransferMismatch();
        uint256 gasSponsorBalanceAfter = _GAS_SPONSOR.balance;
        if (
            gasSponsorBalanceAfter < gasSponsorBalanceBefore
                || gasSponsorBalanceAfter - gasSponsorBalanceBefore != amount
        ) revert SponsorFundingTransferMismatch();

        emit GasFunded(_GAS_SPONSOR, amount);
        emit GasFundProposalExecuted(proposal.fundingId, proposal.nonce, fundKey, _GAS_SPONSOR, amount);
        emit SponsorFundingExecuted(fundKey, sponsor, amount);
    }

    /// @notice Sends an approved token burn to the burn address; callable by a guardian after the delay.
    function executeTokenBurn(address tokenAddress, uint256 amount) public nonReentrant {
        if (!isGuardian[msg.sender]) revert NotGuardian();
        _consumeBurn(keccak256(abi.encodePacked(tokenAddress, amount)));
        IERC20 token = IERC20(tokenAddress);
        if (token.balanceOf(address(this)) < amount) revert InsufficientBalance();
        if (!token.transfer(_DEAD_ADDRESS, amount)) revert TokenBurnFailed();
        emit TokenBurned(tokenAddress, amount);
    }

    /// @notice Sends an approved native-coin burn to the burn address; callable by a guardian after the delay.
    function executeCoinBurn(uint256 amount) public nonReentrant {
        if (!isGuardian[msg.sender]) revert NotGuardian();
        _consumeBurn(keccak256(abi.encodePacked("nativeBurn", amount)));
        if (address(this).balance < amount) revert InsufficientBalance();
        _spendOutflow(amount);
        (bool success, ) = payable(_DEAD_ADDRESS).call{value: amount}("");
        if (!success) revert BurnFailed();
        emit NativeCoinBurned(amount);
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

    /// @notice Returns GasManager's native balance in wei.
    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns GasManager's balance of a token.
    function getTokenBalance(address tokenAddress) public view returns (uint256) {
        return IERC20(tokenAddress).balanceOf(address(this));
    }

    /// @notice Returns the wei that may still leave in the current outflow period.
    function outflowRemaining() public view returns (uint256) {
        if (block.timestamp >= outflowPeriodStart + outflowPeriod) return outflowCap;
        return outflowUsed >= outflowCap ? 0 : outflowCap - outflowUsed;
    }

    /// @notice Returns a funding approval's state and whether its key is in the active list.
    function getFundApprovalStatus(bytes32 fundKey)
        public
        view
        returns (bool approved, uint256 executableAt, uint256 expiresAt, bool expiredOrInvalid, bool inActiveSet)
    {
        approved = approvedFunds[fundKey];
        executableAt = fundExecutableAt[fundKey];
        expiresAt = fundExpiresAt[fundKey];
        expiredOrInvalid = _isFundApprovalExpiredOrInvalid(fundKey);
        inActiveSet = _activeApprovedFundKeyIndexPlusOne[fundKey] != 0;
    }

    /// @notice Returns the number of active funding approvals.
    function getActiveApprovedFundKeyCount() public view returns (uint256) {
        return _activeApprovedFundKeys.length;
    }

    /// @notice Returns up to `count` active funding keys from `start`, at most 100 per call.
    function getActiveApprovedFundKeys(uint256 start, uint256 count) public view returns (bytes32[] memory keys) {
        uint256 len = _activeApprovedFundKeys.length;
        if (start >= len && len != 0) revert StartOutOfRange();
        if (start >= len) return new bytes32[](0);
        if (count > _MAX_PAGE) count = _MAX_PAGE;
        uint256 end = count > len - start ? len : start + count;
        keys = new bytes32[](end - start);
        for (uint256 i = start; i < end; ++i) keys[i - start] = _activeApprovedFundKeys[i];
    }

    /// @notice Returns the last nonce used for `fundingId`.
    function lastFundingNonceByFundingId(string calldata fundingId) public view returns (uint256) {
        return _lastFundingNonceByFundingId[_stringToBytes32(fundingId)];
    }

    /// @notice Returns the nonce the next proposal for `fundingId` will use.
    function getNextFundingNonce(string calldata fundingId) public view returns (uint256) {
        return _lastFundingNonceByFundingId[_stringToBytes32(fundingId)] + 1;
    }

    /// @notice Returns a funding proposal with its approval state.
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
            uint256 executableAt,
            uint256 expiresAt,
            bool expiredOrInvalid
        )
    {
        FundProposal storage proposal = _fundProposals[fundKey];
        (approved, executableAt, expiresAt, expiredOrInvalid, ) = getFundApprovalStatus(fundKey);
        return (
            proposal.fundingId,
            proposal.nonce,
            proposal.to,
            proposal.amount,
            proposal.noteHash,
            proposal.executed,
            proposal.exists,
            approved,
            executableAt,
            expiresAt,
            expiredOrInvalid
        );
    }

    /// @notice Returns the sponsor bound to a funding proposal, if it is a sponsor funding.
    function getSponsorFundingTarget(bytes32 fundKey) public view returns (address sponsor, bool isSponsorFunding) {
        sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        isSponsorFunding = sponsor != address(0);
    }

    /// @notice Returns the guardians.
    function getGuardians() public view returns (address[] memory) {
        return guardiansArray;
    }

    /// @notice Returns the number of guardians.
    function getGuardianCount() public view returns (uint256) {
        return guardiansArray.length;
    }

    /// @notice Returns the funding key for a funding id and nonce.
    function getFundKey(string calldata fundingId, uint256 nonce) public pure returns (bytes32) {
        return _getFundKey(_stringToBytes32(fundingId), nonce);
    }

    /// @notice Returns the GasSponsor proxy (0x…FEeD) that receives sponsor fundings.
    function gasSponsor() public pure returns (address) {
        return _GAS_SPONSOR;
    }

    /// @notice Returns this implementation's version.
    function implementationVersion() public pure returns (string memory) {
        return "2.6.0";
    }

    /// @notice Returns the ERC-7201 location of the sponsor-funding bindings.
    function sponsorFundingStorageLocation() public pure returns (bytes32) {
        return _SPONSOR_FUNDING_STORAGE_LOCATION;
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    function _castVote(VoteType voteType, uint256 target) internal {
        if (target == 0) revert GovernanceVotes.InvalidVoteTarget();
        bytes32 key = _voteKey(voteType, target);
        GovernanceVotes.State storage s = GovernanceVotes.state();
        address[] memory electorate;
        if (!GovernanceVotes.live(s, key)) electorate = getVoters();
        if (GovernanceVotes.cast(s, key, electorate, voteTallyBlockThreshold, msg.sender, _isExempt(voteType))) {
            if (_changesVoters(voteType)) _applyVoterVote(voteType, target);
            else if (_isGuardianVote(voteType)) _applyGuardianVote(voteType, address(uint160(target)));
            else if (_isTreasuryVote(voteType)) _applyTreasuryVote(voteType, bytes32(target));
            else _applyParameterVote(voteType, target);
            GovernanceVotes.complete(s, key);
            if (_changesVoters(voteType)) GovernanceVotes.invalidate(s);
        }
        emit VoteCast(msg.sender, voteType, target);
    }

    function _proposeFundGas(
        bytes32 fundingId,
        address payable to,
        uint256 amount,
        string calldata note,
        address sponsor
    ) internal returns (bytes32 fundKey, uint256 nonce) {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (bytes(note).length > _MAX_FUND_NOTE_LENGTH) revert NoteTooLong();

        nonce = _lastFundingNonceByFundingId[fundingId] + 1;
        fundKey = _getFundKey(fundingId, nonce);
        if (_fundProposals[fundKey].exists) revert FundProposalExists();
        _lastFundingNonceByFundingId[fundingId] = nonce;

        bytes32 noteHash = keccak256(bytes(note));
        _fundProposals[fundKey] = FundProposal(fundingId, noteHash, to, amount, nonce, false, true);

        if (sponsor != address(0)) {
            _sponsorFundingStorage().sponsorByFundKey[fundKey] = sponsor;
            emit SponsorFundingProposalCreated(fundKey, sponsor, amount);
        }
        emit GasFundProposalCreated(fundingId, nonce, fundKey, to, amount, noteHash, note);

        _castVote(VoteType.FundGas, uint256(fundKey));
        _emitIfApproved(fundKey);
    }

    function _isContract(address addr) internal view returns (bool) {
        return addr.code.length > 0;
    }

    function _getFundKey(bytes32 fundingId, uint256 nonce) internal pure returns (bytes32) {
        if (fundingId == bytes32(0)) revert ZeroFundingId();
        if (nonce == 0) revert ZeroNonce();
        return keccak256(abi.encode(fundingId, nonce));
    }

    /// @dev Converts a short string (1-32 bytes) to a left-aligned bytes32 (ethers.encodeBytes32String).
    function _stringToBytes32(string calldata str) internal pure returns (bytes32 result) {
        bytes calldata b = bytes(str);
        if (b.length == 0 || b.length > 32) revert InvalidFundingIdLength();
        assembly ("memory-safe") {
            result := calldataload(b.offset)
            let shift := shl(3, sub(32, b.length))
            result := and(result, shl(shift, shr(shift, not(0))))
        }
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    function _setInitialVoters(address[] calldata voters) private {
        if (voters.length == 0) revert GovernanceVotes.NoVoters();
        address[] memory members =
            GovernanceMembers.collect(voters, new address[](0), bytes4(keccak256("getVoters()")));
        if (members.length != voters.length) revert GovernanceVotes.VoterAlreadyPresent();
        votersArray = voters;
        GovernanceVotes.approveVoters(GovernanceVotes.state(), members);
        emit VotersInitialized(voters);
    }

    /// @dev The guardian loop is bounded by MAX_GUARDIANS.
    function _applyGuardianVote(VoteType voteType, address target) private {
        if (voteType == VoteType.AddGuardian) {
            if (isGuardian[target]) revert AlreadyGuardian();
            if (guardiansArray.length >= MAX_GUARDIANS) revert TooManyGuardians();
            isGuardian[target] = true;
            guardiansArray.push(target);
            emit GuardianUpdated(target, true);
        } else if (voteType == VoteType.RemoveGuardian) {
            if (!isGuardian[target]) revert NotAGuardian(target);
            isGuardian[target] = false;
            _removeAddress(guardiansArray, target);
            emit GuardianUpdated(target, false);
        } else {
            uint256 count = guardiansArray.length;
            for (uint256 i = 0; i < count; ++i) isGuardian[guardiansArray[i]] = false;
            delete guardiansArray;
            emit GuardiansCleared(count);
        }
    }

    function _applyTreasuryVote(VoteType voteType, bytes32 key) private {
        if (voteType == VoteType.FundGas) {
            _approveFundKey(key);
        } else if (voteType == VoteType.CancelApproval) {
            if (approvedFunds[key]) _clearFundApproval(key, true);
            delete _burnApprovals[key];
            emit ApprovalCancelled(key);
        } else {
            (uint256 executableAt, uint256 expiresAt) = _approvalWindow();
            _burnApprovals[key] = Approval(executableAt, expiresAt, GovernanceVotes.state().epoch);
        }
    }

    function _applyParameterVote(VoteType voteType, uint256 target) private {
        if (voteType == VoteType.SetVoteWindow) {
            if (!GovernanceVotes.validWindow(target)) revert GovernanceVotes.InvalidExpiry();
            voteTallyBlockThreshold = target;
            emit VoteWindowUpdated(target);
        } else if (voteType == VoteType.SetParameter) {
            ParameterChange memory change = _parameterChanges[target];
            delete _parameterChanges[target];
            _setParameter(change.parameter, change.value);
        } else {
            expiredFundCleanupAuthorized = true;
            expiredFundCleanupCursor = 0;
            emit ExpiredFundCleanupAuthorized(_activeApprovedFundKeys.length);
        }
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

    /// @dev Swap-and-pop removal; the voter and guardian arrays are bounded at 64 entries, providers at 16.
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

    function _setParameter(Parameter parameter, uint256 value) private {
        _checkParameter(parameter, value);
        if (parameter == Parameter.ExecutionDelay) executionDelay = value;
        else if (parameter == Parameter.ApprovalWindow) fundApprovalWindow = value;
        else if (parameter == Parameter.OutflowCap) outflowCap = value;
        else outflowPeriod = value;
        emit ParameterUpdated(parameter, value);
    }

    function _emitIfApproved(bytes32 fundKey) private {
        if (!approvedFunds[fundKey]) return;
        FundProposal storage p = _fundProposals[fundKey];
        uint256 executableAt = fundExecutableAt[fundKey];
        uint256 expiresAt = fundExpiresAt[fundKey];
        emit GasFundApproved(p.to, p.amount, fundKey);
        emit GasFundProposalApproved(
            p.fundingId,
            p.nonce,
            fundKey,
            p.to,
            p.amount,
            p.noteHash,
            executableAt,
            expiresAt
        );
        address sponsor = _sponsorFundingStorage().sponsorByFundKey[fundKey];
        if (sponsor != address(0)) emit SponsorFundingProposalApproved(fundKey, sponsor, executableAt, expiresAt);
    }

    /// @dev Checks approval, expiry, delay, balance and the outflow cap, then consumes the approval.
    function _consumeExecutableFund(bytes32 fundKey, uint256 amount) private {
        _clearFundApprovalIfExpiredOrInvalid(fundKey);
        if (!approvedFunds[fundKey]) revert FundNotApproved();
        uint256 executableAt = fundExecutableAt[fundKey];
        if (block.timestamp < executableAt) revert ExecutionDelayActive(executableAt);
        if (address(this).balance < amount) revert InsufficientBalance();
        _spendOutflow(amount);
        _clearFundApproval(fundKey, false);
    }

    /// @dev Per-period native outflow cap. Never overflows: compares against the remaining headroom.
    function _spendOutflow(uint256 amount) private {
        if (block.timestamp >= outflowPeriodStart + outflowPeriod) {
            outflowPeriodStart = block.timestamp;
            outflowUsed = 0;
        }
        uint256 cap = outflowCap;
        uint256 used = outflowUsed;
        uint256 remaining = used >= cap ? 0 : cap - used;
        if (amount > remaining) revert OutflowCapExceeded(remaining);
        outflowUsed = used + amount;
    }

    function _consumeBurn(bytes32 burnKey) private {
        Approval storage a = _burnApprovals[burnKey];
        if (!_burnValid(a)) revert BurnNotApproved();
        if (block.timestamp < a.executableAt) revert ExecutionDelayActive(a.executableAt);
        delete _burnApprovals[burnKey];
    }

    function _approveFundKey(bytes32 fundKey) private {
        (uint256 executableAt, uint256 expiresAt) = _approvalWindow();
        approvedFunds[fundKey] = true;
        fundExecutableAt[fundKey] = executableAt;
        fundExpiresAt[fundKey] = expiresAt;
        if (_activeApprovedFundKeyIndexPlusOne[fundKey] == 0) {
            _activeApprovedFundKeys.push(fundKey);
            _activeApprovedFundKeyIndexPlusOne[fundKey] = _activeApprovedFundKeys.length;
        }
        emit FundApprovalWindowUpdated(fundKey, executableAt, expiresAt);
    }

    function _clearFundApproval(bytes32 fundKey, bool expiredOrInvalid) private {
        approvedFunds[fundKey] = false;
        fundExecutableAt[fundKey] = 0;
        fundExpiresAt[fundKey] = 0;
        _removeActiveApprovedFundKey(fundKey);
        emit FundApprovalCleared(fundKey, expiredOrInvalid);
    }

    function _clearFundApprovalIfExpiredOrInvalid(bytes32 fundKey) private {
        if (_isFundApprovalExpiredOrInvalid(fundKey)) _clearFundApproval(fundKey, true);
    }

    function _removeActiveApprovedFundKey(bytes32 fundKey) private {
        uint256 indexPlusOne = _activeApprovedFundKeyIndexPlusOne[fundKey];
        if (indexPlusOne == 0) return;
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

    /// @dev The caller must be a guardian of the proxy this code runs in. On the implementation itself the
    ///      initializers are already disabled, so this is only reached through a proxy.
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

    /// @dev Bounded probe; a GasSponsor without program support (call fails) has no program sponsors.
    function _isProgramSponsor(address sponsor) private view returns (bool) {
        bytes memory input = abi.encodeWithSignature("isProgramSponsor(address)", sponsor);
        address target = _GAS_SPONSOR;
        bool ok;
        uint256 result;
        assembly ("memory-safe") {
            ok := staticcall(_PROBE_GAS, target, add(input, 32), mload(input), 0, 32)
            if iszero(eq(returndatasize(), 32)) { ok := 0 }
            result := mload(0)
        }
        return ok && result != 0;
    }

    function _burnValid(Approval storage a) private view returns (bool) {
        return a.expiresAt != 0 && block.timestamp <= a.expiresAt && a.epoch == GovernanceVotes.state().epoch;
    }

    function _approvalWindow() private view returns (uint256 executableAt, uint256 expiresAt) {
        executableAt = block.timestamp + executionDelay;
        expiresAt = executableAt + fundApprovalWindow;
    }

    function _isFundApprovalExpiredOrInvalid(bytes32 fundKey) private view returns (bool) {
        if (!approvedFunds[fundKey]) return false;
        uint256 expiresAt = fundExpiresAt[fundKey];
        return expiresAt == 0 || block.timestamp > expiresAt;
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
            || voteType == VoteType.RemoveGuardian || voteType == VoteType.ClearGuardians
            || voteType == VoteType.CancelApproval;
    }

    function _isGuardianVote(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.AddGuardian || voteType == VoteType.RemoveGuardian
            || voteType == VoteType.ClearGuardians;
    }

    function _isTreasuryVote(VoteType voteType) private pure returns (bool) {
        return voteType == VoteType.FundGas || voteType == VoteType.BurnTokens
            || voteType == VoteType.BurnNativeCoin || voteType == VoteType.CancelApproval;
    }

    function _checkParameter(Parameter parameter, uint256 value) private pure {
        bool ok;
        if (parameter == Parameter.ExecutionDelay) ok = value <= MAX_EXECUTION_DELAY;
        else if (parameter == Parameter.OutflowCap) ok = value > 0;
        else ok = GovernanceVotes.validWindow(value);
        if (!ok) revert InvalidParameter();
    }

    function _sponsorFundingStorage() private pure returns (SponsorFundingStorage storage state) {
        bytes32 location = _SPONSOR_FUNDING_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }
}
