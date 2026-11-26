// SPDX-License-Identifier: MIT
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// Derived from OpenZeppelin Contracts v4.9.0 (proxy/transparent/TransparentUpgradeableProxy.sol), MIT.
pragma solidity 0.8.37;

import {GovernanceMembers} from "../../../Governance/GovernanceMembers.sol";
import {GovernanceVotes} from "../../../Governance/GovernanceVotes.sol";
import {IERC1967} from "../../Interfaces/IERC1967.sol";
import {ERC1967Proxy} from "../ERC1967/ERC1967Proxy.sol";

/// @title ITransparentUpgradeableProxy
/// @notice The admin-only functions of {TransparentUpgradeableProxy}, reached through its internal dispatch.
/// @dev The proxy does not inherit this interface: the compiler cannot see the dispatched functions, so callers
///      (the ProxyAdmin) use this interface.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
interface ITransparentUpgradeableProxy is IERC1967 {
    /// @notice Returns the proxy admin (the ProxyAdmin at 0x…FacAdE).
    function admin() external view returns (address);

    /// @notice Returns the current implementation.
    function implementation() external view returns (address);

    /// @notice Upgrades to a scheduled implementation with no call.
    function upgradeTo(address) external;

    /// @notice Upgrades to a scheduled implementation and calls it with the scheduled data.
    function upgradeToAndCall(address, bytes memory) external payable;
}

/// @title IValidatorRootOverlord
/// @notice The root reads the proxy makes on the validator contract (0x…1111).
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
interface IValidatorRootOverlord {
    /// @notice Returns the approved root set.
    function getRootOverlords() external view returns (address[] memory);

    /// @notice Returns true if `addr` is an approved root.
    function isRootOverlord(address addr) external view returns (bool);
}

/// @title TransparentUpgradeableProxy
/// @notice The genesis proxy shell: an ERC-1967 transparent proxy governed by roots, overlords and guardians.
/// @dev Baked into genesis behind every system proxy address. The admin is the constant ProxyAdmin (0x…FacAdE);
///      admin calls are dispatched here and never reach the implementation, every other caller is forwarded.
///      Roles: a root (listed in 0x…1111) adds or removes overlords directly; overlords cast 2/3 ballots on
///      overlords, guardians, the ballot window and root revocation; guardians (roots count as guardians) link
///      the implementation and schedule upgrades, which run through the ProxyAdmin after the network upgrade
///      delay. One counted ballot is open at a time; removal ballots are exempt so a rogue controller cannot
///      delay its own removal. All proxy state lives in namespaced slots, apart from implementation storage.
///      Do not add external functions without checking selector clashes with the dispatched admin functions.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
contract TransparentUpgradeableProxy is ERC1967Proxy {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @dev Local overlords and the governance context of the open ballot session. Never reorder.
    struct ProxyGovernanceStorage {
        address[] localOverlords;
        bytes32 sessionContext;
    }

    /// @dev Roots that gave up their powers on this proxy. Never reorder.
    struct RootRenounceStorage {
        address[] renounced;
        mapping(address => bool) isRenounced;
    }

    /// @dev Scheduled upgrades. Never reorder.
    struct UpgradeStorage {
        mapping(bytes32 => uint256) scheduledAt;
        mapping(bytes32 => address) proposerOf;
        mapping(address => bytes32) scheduleOf;
    }

    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    address private constant _PROXY_ADMIN = 0x0000000000000000000000000000000000FacAdE;
    address private constant _PROXY_VALIDATOR_CONTRACT = 0x0000000000000000000000000000000000001111;

    bytes32 private constant _PROXY_IS_INIT_SLOT =
        keccak256("TransparentUpgradeableProxy.isInit");
    bytes32 private constant _PROXY_GUARDIAN_MAP_SLOT =
        keccak256("TransparentUpgradeableProxy.guardianMap");
    bytes32 private constant _PROXY_GUARDIAN_COUNT_SLOT =
        keccak256("TransparentUpgradeableProxy.guardianCount");
    bytes32 private constant _PROXY_GUARDIAN_ARRAY_SLOT =
        keccak256("TransparentUpgradeableProxy.guardianArray");
    bytes32 private constant _PROXY_GUARDIAN_ARRAY_INDEX_SLOT =
        keccak256("TransparentUpgradeableProxy.guardianArrayIndex");
    bytes32 private constant _PROXY_OVERLORD_MAP_SLOT =
        keccak256("TransparentUpgradeableProxy.overlordMap");
    bytes32 private constant _PROXY_OVERLORD_COUNT_SLOT =
        keccak256("TransparentUpgradeableProxy.overlordCount");
    bytes32 private constant _PROXY_ROOT_REVOKED_SLOT =
        keccak256("TransparentUpgradeableProxy.rootRevoked");
    bytes32 private constant _PROXY_VOTE_EPOCH_SLOT =
        keccak256("TransparentUpgradeableProxy.voteEpoch");
    bytes32 private constant _PROXY_PROPOSAL_ROUND_SLOT =
        keccak256("TransparentUpgradeableProxy.proposalRound");
    bytes32 private constant _PROXY_VOTE_EXPIRY_SLOT =
        keccak256("TransparentUpgradeableProxy.voteExpiry");
    bytes32 private constant _PROXY_ACTIVE_PROPOSAL_SLOT =
        keccak256("TransparentUpgradeableProxy.activeProposal");
    bytes32 private constant _PROXY_ACTIVE_PROPOSAL_START_SLOT =
        keccak256("TransparentUpgradeableProxy.activeProposalStart");
    // Retired slots, never to be reused (ballot counts, voters and start times now live in GovernanceVotes):
    //   keccak256("TransparentUpgradeableProxy.proposalVoteCount")
    //   keccak256("TransparentUpgradeableProxy.proposalVoter")
    //   keccak256("TransparentUpgradeableProxy.proposalStartBlock")

    /// @dev Ballot window used until overlords set one (seconds, never block counts).
    uint256 private constant _DEFAULT_VOTE_EXPIRY = 7 days;
    uint256 private constant _MAX_GUARDIANS = 10;
    /// @dev A ready upgrade must run within this time or be scheduled again.
    uint256 private constant _UPGRADE_GRACE = 14 days;
    uint256 private constant _MAX_UPGRADE_DELAY = 30 days;

    // ─── Storage ─────────────────────────────────────────────────────────────────────────────────
    // No state variables: every value lives at a namespaced slot, apart from the implementation's storage.

    function _proxyGovernanceStorage() private pure returns (ProxyGovernanceStorage storage s) {
        bytes32 slot = keccak256("cryft.proxy.governance.snapshot.v1");
        assembly ("memory-safe") { s.slot := slot }
    }

    function _rootRenounceStorage() private pure returns (RootRenounceStorage storage r) {
        bytes32 slot = keccak256("cryft.proxy.root.renounced.v1");
        assembly ("memory-safe") { r.slot := slot }
    }

    function _upgradeStorage() private pure returns (UpgradeStorage storage u) {
        bytes32 slot = keccak256("cryft.proxy.upgrade.schedule.v1");
        assembly ("memory-safe") { u.slot := slot }
    }

    /// @dev Proxy ballots never share the delegated application's ballot storage.
    function _proxyVotes() private pure returns (GovernanceVotes.State storage) {
        return GovernanceVotes.state(keccak256("cryft.proxy.governance.votes.v1"));
    }

    // ─── Events ──────────────────────────────────────────────────────────────────────────────────

    /// @notice An overlord was added.
    event OverlordAdded(address indexed overlord);
    /// @notice An overlord was removed.
    event OverlordRemoved(address indexed overlord);
    /// @notice A guardian was added.
    event GuardianAdded(address indexed guardian);
    /// @notice A guardian was removed.
    event GuardianRemoved(address indexed guardian);
    /// @notice Every root lost its powers on this proxy by an overlord ballot.
    event RootOverlordRevoked();
    /// @notice Root powers on this proxy were restored by an overlord ballot.
    event RootOverlordRestored(address indexed restoredBy);
    /// @notice A vote was cast on an overlord ballot.
    event OverlordChangeProposed(
        address indexed voter, address indexed target, bool isAdd, uint256 currentVotes, uint256 threshold
    );
    /// @notice A vote was cast on a ballot-window ballot.
    event ExpiryChangeProposed(address indexed voter, uint256 newExpiry, uint256 currentVotes, uint256 threshold);
    /// @notice The ballot window changed (seconds).
    event VoteExpiryUpdated(uint256 oldExpiry, uint256 newExpiry);
    /// @notice Every guardian was removed.
    event GuardiansCleared(uint256 count);
    /// @notice A vote was cast on the clear-guardians ballot.
    event ClearGuardiansProposed(address indexed voter, uint256 currentVotes, uint256 threshold);
    /// @notice A vote was cast on a guardian ballot.
    event GuardianChangeProposed(
        address indexed voter, address indexed target, bool isAdd, uint256 currentVotes, uint256 threshold
    );
    /// @notice A vote was cast on the restore-root ballot.
    event RestoreRootProposed(address indexed voter, uint256 currentVotes, uint256 threshold);
    /// @notice A vote was cast on the revoke-root ballot.
    event RevokeRootProposed(address indexed voter, uint256 currentVotes, uint256 threshold);
    /// @notice A ballot's window closed, so its next vote opens a new round.
    event ProposalRoundExpired(bytes32 indexed proposalKey, uint256 newRound);
    /// @notice A root gave up its own powers on this proxy.
    event RootOverlordRenounced(address indexed root);
    /// @notice An upgrade was scheduled; it may run from `readyAt`.
    event UpgradeScheduled(
        bytes32 indexed id, address indexed implementation, bytes data, address indexed proposer, uint256 readyAt
    );
    /// @notice A scheduled upgrade was cancelled.
    event UpgradeCancelled(bytes32 indexed id, address indexed cancelledBy);
    /// @notice A scheduled upgrade ran.
    event UpgradeExecuted(bytes32 indexed id, address indexed implementation);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The caller is not an overlord (or an active root).
    error NotOverlord();
    /// @notice The caller is not an active root.
    error NotRootOverlord();
    /// @notice The caller is not a guardian (or an active root).
    error NotGuardian();
    /// @notice The caller is not a guardian, an overlord or an active root.
    error NotGuardianOrOverlord();
    /// @notice Root powers on this proxy are already revoked.
    error RootAlreadyRevoked();
    /// @notice Root powers on this proxy are not revoked.
    error RootNotRevoked();
    /// @notice The renounce list is full.
    error RenounceLimit();
    /// @notice The change would leave the proxy without a controller.
    error LastController();
    /// @notice The change would remove the last local overlord while no root is active.
    error LastOverlord();
    /// @notice An address argument is zero.
    error ZeroAddress();
    /// @notice The local overlord list is full.
    error TooManyOverlords();
    /// @notice The address is already a root.
    error AlreadyRootOverlord();
    /// @notice The address is already an overlord.
    error AlreadyOverlord();
    /// @notice The address is not an overlord.
    error NotAnOverlord(address account);
    /// @notice A guardian cannot also be an overlord.
    error GuardianCannotBeOverlord();
    /// @notice An overlord or root cannot also be a guardian.
    error OverlordCannotBeGuardian();
    /// @notice The address is already a guardian.
    error AlreadyGuardian();
    /// @notice The address is not a guardian.
    error NotAGuardian(address account);
    /// @notice The guardian list is full.
    error TooManyGuardians();
    /// @notice There are no guardians to clear.
    error NoGuardians();
    /// @notice Roots are managed in the validator contract, not on the proxy.
    error RootManagedByValidator();
    /// @notice Another ballot is open; wait for it to pass or close.
    error BallotActive();
    /// @notice The value is already set.
    error SameValue();
    /// @notice The validator contract did not return the upgrade delay.
    error UpgradeDelayUnavailable();
    /// @notice The proxy has no implementation linked.
    error NotLinked();
    /// @notice The proxy is already linked.
    error AlreadyLinked();
    /// @notice The implementation address has no code.
    error AddressHasNoCode();
    /// @notice Initialization data is required.
    error EmptyInitData();
    /// @notice The proposer already holds a live schedule.
    error ProposerHasScheduledUpgrade();
    /// @notice This upgrade is already scheduled.
    error UpgradeAlreadyScheduled();
    /// @notice This upgrade is not scheduled.
    error UpgradeNotScheduled();
    /// @notice The upgrade delay has not passed.
    error UpgradeNotReady();
    /// @notice The schedule's grace period has passed; schedule it again.
    error UpgradeExpired();
    /// @notice The admin can call only the dispatched admin functions.
    error AdminCannotFallback();

    // ─── Modifiers ───────────────────────────────────────────────────────────────────────────────

    modifier onlyOverlord() {
        if (!((_isRootOverlordAddress(msg.sender) && !_isRootRevoked()) || _isOverlord(msg.sender))) {
            revert NotOverlord();
        }
        _;
    }

    modifier onlyRootOverlord() {
        if (!(_isRootOverlordAddress(msg.sender) && !_isRootRevoked())) revert NotRootOverlord();
        _;
    }

    modifier onlyGuardian() {
        if (!((_isRootOverlordAddress(msg.sender) && !_isRootRevoked()) || _isGuardian(msg.sender))) {
            revert NotGuardian();
        }
        _;
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Gives up the caller's own root powers on this proxy only.
    /// @dev One root cannot lock the other roots out; revoking every root needs an overlord ballot
    ///      (proxy_proposeRevokeRootOverlord). A restore-root ballot clears all renounces. Never leaves the proxy
    ///      without a controller.
    function proxy_revokeRootOverlord() external {
        if (_isRootRevoked()) revert RootAlreadyRevoked();
        if (!_isRootOverlordAddress(msg.sender)) revert NotRootOverlord();
        RootRenounceStorage storage r = _rootRenounceStorage();
        if (r.renounced.length >= GovernanceMembers.MAX_MEMBERS) revert RenounceLimit();
        r.renounced.push(msg.sender);
        r.isRenounced[msg.sender] = true;
        if (_governanceMembers().length == 0) revert LastController();
        _clearActiveProposal();
        _incrementVoteEpoch();
        emit RootOverlordRenounced(msg.sender);
    }

    /// @notice Adds a local overlord (roots only). Voids every open ballot.
    function proxy_addOverlord(address newOverlord) external onlyRootOverlord {
        if (newOverlord == address(0)) revert ZeroAddress();
        if (_isRootOverlordAddress(newOverlord)) revert AlreadyRootOverlord();
        if (_isOverlord(newOverlord)) revert AlreadyOverlord();
        if (_isGuardian(newOverlord)) revert GuardianCannotBeOverlord();
        _setOverlord(newOverlord, true);
        _setOverlordCount(_rawOverlordCount() + 1);
        _clearActiveProposal();
        _incrementVoteEpoch();
        emit OverlordAdded(newOverlord);
    }

    /// @notice Removes a local overlord (roots only). Voids every open ballot.
    function proxy_removeOverlord(address overlordToRemove) external onlyRootOverlord {
        if (!_isOverlord(overlordToRemove)) revert NotAnOverlord(overlordToRemove);
        if (!(_rawOverlordCount() > 1 || (_getRootOverlordCount() > 0 && !_isRootRevoked()))) revert LastOverlord();
        _setOverlord(overlordToRemove, false);
        _setOverlordCount(_rawOverlordCount() - 1);
        _clearActiveProposal();
        _incrementVoteEpoch();
        emit OverlordRemoved(overlordToRemove);
    }

    /// @notice Votes to add or remove a local overlord; applies at 2/3 and voids every open ballot.
    /// @dev Works without roots, so overlords can govern themselves. Removal ballots are exempt.
    function proxy_proposeOverlordChange(address target, bool isAdd) external onlyOverlord {
        if (target == address(0)) revert ZeroAddress();
        if (_isRootOverlordAddress(target)) revert RootManagedByValidator();
        if (proxy_getOverlordCount() == 0) revert GovernanceVotes.NoVoters();

        if (isAdd) {
            if (_isOverlord(target)) revert AlreadyOverlord();
            if (_isGuardian(target)) revert GuardianCannotBeOverlord();
        } else {
            if (!_isOverlord(target)) revert NotAnOverlord(target);
            if (!(_rawOverlordCount() > 1 || (_getRootOverlordCount() > 0 && !_isRootRevoked()))) {
                revert LastOverlord();
            }
        }

        bytes32 proposalKey = _getProposalKey(isAdd, target);
        bytes32 proposalId = _getProposalId(isAdd, target);

        // A closed round starts a new one.
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.timestamp > GovernanceVotes.proposal(_proxyVotes(), proposalId).expires) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        (uint256 newVoteCount, uint256 threshold) = _castProxyVote(proposalId, !isAdd);
        emit OverlordChangeProposed(msg.sender, target, isAdd, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            if (isAdd) {
                _setOverlord(target, true);
                _setOverlordCount(_rawOverlordCount() + 1);
                emit OverlordAdded(target);
            } else {
                _setOverlord(target, false);
                _setOverlordCount(_rawOverlordCount() - 1);
                emit OverlordRemoved(target);
            }
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /// @notice Votes to set the ballot window in seconds (one hour to 30 days); applies at 2/3.
    function proxy_proposeExpiryChange(uint256 newExpiry) external onlyOverlord {
        if (!GovernanceVotes.validWindow(newExpiry)) revert GovernanceVotes.InvalidExpiry();
        if (newExpiry == proxy_getVoteExpiry()) revert SameValue();
        if (proxy_getOverlordCount() == 0) revert GovernanceVotes.NoVoters();

        bytes32 proposalKey = _getExpiryProposalKey(newExpiry);
        bytes32 proposalId = _getExpiryProposalId(newExpiry);

        // A closed round starts a new one.
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.timestamp > GovernanceVotes.proposal(_proxyVotes(), proposalId).expires) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        (uint256 newVoteCount, uint256 threshold) = _castProxyVote(proposalId);
        emit ExpiryChangeProposed(msg.sender, newExpiry, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            uint256 oldExpiry = proxy_getVoteExpiry();
            _setVoteExpiry(newExpiry);
            emit VoteExpiryUpdated(oldExpiry, newExpiry);
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /// @notice Votes to remove every guardian at once; applies at 2/3.
    /// @dev Guardians are temporary: add them for setup, clear them when done. Exempt ballot.
    function proxy_proposeClearGuardians() external onlyOverlord {
        if (proxy_getGuardianCount() == 0) revert NoGuardians();
        if (proxy_getOverlordCount() == 0) revert GovernanceVotes.NoVoters();

        bytes32 proposalKey = _getClearGuardiansProposalKey();
        bytes32 proposalId = _getClearGuardiansProposalId();

        // A closed round starts a new one.
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.timestamp > GovernanceVotes.proposal(_proxyVotes(), proposalId).expires) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        (uint256 newVoteCount, uint256 threshold) = _castProxyVote(proposalId, true);
        emit ClearGuardiansProposed(msg.sender, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            _clearAllGuardians();
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /// @notice Votes to add or remove a guardian; applies at 2/3. Removal ballots are exempt.
    function proxy_proposeGuardianChange(address target, bool isAdd) external onlyOverlord {
        if (target == address(0)) revert ZeroAddress();
        if (target == _PROXY_VALIDATOR_CONTRACT) revert RootManagedByValidator();
        if (proxy_getOverlordCount() == 0) revert GovernanceVotes.NoVoters();

        if (isAdd) {
            if (_isGuardian(target)) revert AlreadyGuardian();
            if (proxy_getGuardianCount() >= _MAX_GUARDIANS) revert TooManyGuardians();
            if (_isOverlord(target) || _isRootOverlordAddress(target)) revert OverlordCannotBeGuardian();
        } else {
            if (!_isGuardian(target)) revert NotAGuardian(target);
        }

        bytes32 proposalKey = _getGuardianProposalKey(isAdd, target);
        bytes32 proposalId = _getGuardianProposalId(isAdd, target);

        // A closed round starts a new one.
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.timestamp > GovernanceVotes.proposal(_proxyVotes(), proposalId).expires) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        (uint256 newVoteCount, uint256 threshold) = _castProxyVote(proposalId, !isAdd);
        emit GuardianChangeProposed(msg.sender, target, isAdd, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            if (isAdd) {
                _addGuardian(target);
            } else {
                _removeGuardian(target);
            }
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /// @notice Votes to restore root powers on this proxy and clear every renounce; applies at 2/3.
    /// @dev Every member of the ballot's electorate may vote: local overlords, plus the roots still active here
    ///      when only some roots renounced (after a full revoke no root is active, so only local overlords vote).
    function proxy_proposeRestoreRootOverlord() external {
        if (!((_isRootOverlordAddress(msg.sender) && !_isRootRevoked()) || _isOverlord(msg.sender))) {
            revert NotOverlord();
        }
        if (!_isRootRevoked() && _rootRenounceStorage().renounced.length == 0) revert RootNotRevoked();
        if (proxy_getOverlordCount() == 0) revert GovernanceVotes.NoVoters();

        bytes32 proposalKey = _getRestoreRootProposalKey();
        bytes32 proposalId = _getRestoreRootProposalId();

        // A closed round starts a new one.
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.timestamp > GovernanceVotes.proposal(_proxyVotes(), proposalId).expires) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        (uint256 newVoteCount, uint256 threshold) = _castProxyVote(proposalId);
        emit RestoreRootProposed(msg.sender, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            _restoreRootOverlord();
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /// @notice Votes to revoke every root's powers on this proxy; applies at 2/3.
    /// @dev Unlike proxy_revokeRootOverlord (one root renouncing itself), this removes all roots. Active roots
    ///      may vote.
    function proxy_proposeRevokeRootOverlord() external onlyOverlord {
        if (_isRootRevoked()) revert RootAlreadyRevoked();
        if (_rawOverlordCount() == 0) revert LastController();
        if (proxy_getOverlordCount() == 0) revert GovernanceVotes.NoVoters();

        bytes32 proposalKey = _getRevokeRootProposalKey();
        bytes32 proposalId = _getRevokeRootProposalId();

        // A closed round starts a new one.
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.timestamp > GovernanceVotes.proposal(_proxyVotes(), proposalId).expires) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        (uint256 newVoteCount, uint256 threshold) = _castProxyVote(proposalId);
        emit RevokeRootProposed(msg.sender, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            _setRootRevoked(true);
            emit RootOverlordRevoked();
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /// @notice Schedules an upgrade to `implementation` with call `data`; it may run through the ProxyAdmin
    ///         after the network upgrade delay and within the grace period.
    /// @dev Guardians only (roots count as guardians). Each proposer holds at most one live schedule per proxy.
    function proxy_scheduleUpgrade(address implementation, bytes calldata data)
        external
        onlyGuardian
        returns (bytes32 id)
    {
        if (!proxy_getIsInit()) revert NotLinked();
        if (implementation.code.length == 0) revert AddressHasNoCode();
        UpgradeStorage storage u = _upgradeStorage();
        bytes32 previous = u.scheduleOf[msg.sender];
        if (previous != bytes32(0)) {
            if (block.timestamp <= u.scheduledAt[previous] + proxy_getUpgradeDelay() + _UPGRADE_GRACE) {
                revert ProposerHasScheduledUpgrade();
            }
            _clearSchedule(previous);
        }
        id = proxy_upgradeId(implementation, data);
        if (u.scheduledAt[id] != 0) revert UpgradeAlreadyScheduled();
        u.scheduledAt[id] = block.timestamp;
        u.proposerOf[id] = msg.sender;
        u.scheduleOf[msg.sender] = id;
        emit UpgradeScheduled(id, implementation, data, msg.sender, block.timestamp + proxy_getUpgradeDelay());
    }

    /// @notice Cancels a scheduled upgrade (any guardian, overlord or active root).
    function proxy_cancelUpgrade(bytes32 id) external {
        if (
            !((_isRootOverlordAddress(msg.sender) && !_isRootRevoked()) || _isGuardian(msg.sender)
                || _isOverlord(msg.sender))
        ) revert NotGuardianOrOverlord();
        if (_upgradeStorage().scheduledAt[id] == 0) revert UpgradeNotScheduled();
        _clearSchedule(id);
        emit UpgradeCancelled(id, msg.sender);
    }

    /// @notice Links the first implementation and initializes it in the same transaction (guardians only).
    /// @dev Linking and initializing together stops anyone front-running an open initializer.
    function proxy_linkLogicAdmin(address logic, bytes memory initData) external payable onlyGuardian {
        if (proxy_getIsInit()) revert AlreadyLinked();
        if (logic == address(0)) revert ZeroAddress();
        if (initData.length == 0) revert EmptyInitData();
        _setIsInit(true);
        _initializeProxy(logic, initData);
    }

    /// @notice Returns the roots that gave up their powers on this proxy.
    function proxy_getRenouncedRoots() external view returns (address[] memory) {
        return _rootRenounceStorage().renounced;
    }

    /// @notice Returns the ballot electorate now: local overlords plus the roots active here.
    function proxy_getGovernanceMembers() external view returns (address[] memory) {
        return _governanceMembers();
    }

    /// @notice Returns the open counted ballot's threshold, closing time and electorate (zeros if none).
    function proxy_getActiveVoteSnapshot()
        external
        view
        returns (uint256 threshold, uint256 expires, address[] memory electorate)
    {
        if (!_isSessionActive()) return (0, 0, new address[](0));
        GovernanceVotes.Proposal storage p = GovernanceVotes.proposal(_proxyVotes(), _getActiveProposal());
        return (p.threshold, p.expires, p.electorate);
    }

    /// @notice Returns the roots the validator contract (0x…1111) reports, or none if it cannot answer.
    function proxy_getRootOverlords() external view returns (address[] memory) {
        try IValidatorRootOverlord(_PROXY_VALIDATOR_CONTRACT).getRootOverlords() returns (address[] memory overlords) {
            return overlords;
        } catch {
            return new address[](0);
        }
    }

    /// @notice Returns true if every root's powers on this proxy are revoked.
    function proxy_isRootOverlordRevoked() external view returns (bool) {
        return _isRootRevoked();
    }

    /// @notice Returns true if `addr` is a guardian or an active root.
    function proxy_isGuardian(address addr) external view returns (bool) {
        return (_isRootOverlordAddress(addr) && !_isRootRevoked()) || _isGuardian(addr);
    }

    /// @notice Returns every guardian.
    /// @dev Bounded: at most _MAX_GUARDIANS guardians.
    function proxy_getGuardians() external view returns (address[] memory) {
        uint256 count = proxy_getGuardianCount();
        address[] memory result = new address[](count);
        for (uint256 i; i < count; ++i) {
            result[i] = _getGuardianAt(i);
        }
        return result;
    }

    /// @notice Returns true if `addr` is a local overlord or an active root.
    function proxy_isOverlord(address addr) external view returns (bool) {
        return (_isRootOverlordAddress(addr) && !_isRootRevoked()) || _isOverlord(addr);
    }

    /// @notice Returns true if a counted ballot is open.
    function proxy_isVotingSessionActive() external view returns (bool) {
        return _isSessionActive();
    }

    /// @notice Returns the votes on an overlord ballot in this round.
    function proxy_getProposalVotes(address target, bool isAdd) external view returns (uint256) {
        return _getProposalVoteCount(_getProposalId(isAdd, target));
    }

    /// @notice Returns true if `voter` voted on an overlord ballot in this round.
    function proxy_hasVotedOnProposal(address voter, address target, bool isAdd) external view returns (bool) {
        return _hasVoted(_getProposalId(isAdd, target), voter);
    }

    /// @notice Returns when (block.timestamp) the current round of an overlord ballot opened, 0 if none.
    function proxy_getProposalStartBlock(address target, bool isAdd) external view returns (uint256) {
        return _getProposalStartBlock(_getProposalId(isAdd, target));
    }

    /// @notice Returns the votes on a ballot-window ballot.
    function proxy_getExpiryProposalVotes(uint256 newExpiry) external view returns (uint256) {
        return _getProposalVoteCount(_getExpiryProposalId(newExpiry));
    }

    /// @notice Returns true if `voter` voted on a ballot-window ballot.
    function proxy_hasVotedOnExpiryProposal(address voter, uint256 newExpiry) external view returns (bool) {
        return _hasVoted(_getExpiryProposalId(newExpiry), voter);
    }

    /// @notice Returns the votes on the clear-guardians ballot.
    function proxy_getClearGuardiansProposalVotes() external view returns (uint256) {
        return _getProposalVoteCount(_getClearGuardiansProposalId());
    }

    /// @notice Returns true if `voter` voted on the clear-guardians ballot.
    function proxy_hasVotedOnClearGuardians(address voter) external view returns (bool) {
        return _hasVoted(_getClearGuardiansProposalId(), voter);
    }

    /// @notice Returns the votes on a guardian ballot.
    function proxy_getGuardianProposalVotes(address target, bool isAdd) external view returns (uint256) {
        return _getProposalVoteCount(_getGuardianProposalId(isAdd, target));
    }

    /// @notice Returns true if `voter` voted on a guardian ballot.
    function proxy_hasVotedOnGuardianProposal(address voter, address target, bool isAdd)
        external
        view
        returns (bool)
    {
        return _hasVoted(_getGuardianProposalId(isAdd, target), voter);
    }

    /// @notice Returns the votes on the restore-root ballot.
    function proxy_getRestoreRootProposalVotes() external view returns (uint256) {
        return _getProposalVoteCount(_getRestoreRootProposalId());
    }

    /// @notice Returns true if `voter` voted on the restore-root ballot.
    function proxy_hasVotedOnRestoreRoot(address voter) external view returns (bool) {
        return _hasVoted(_getRestoreRootProposalId(), voter);
    }

    /// @notice Returns the votes on the revoke-root ballot.
    function proxy_getRevokeRootProposalVotes() external view returns (uint256) {
        return _getProposalVoteCount(_getRevokeRootProposalId());
    }

    /// @notice Returns true if `voter` voted on the revoke-root ballot.
    function proxy_hasVotedOnRevokeRoot(address voter) external view returns (bool) {
        return _hasVoted(_getRevokeRootProposalId(), voter);
    }

    /// @notice Returns the open counted ballot, when it opened (block.timestamp) and whether its window closed.
    ///         Returns bytes32(0) when none is open.
    function proxy_getActiveProposal() external view returns (bytes32 proposalId, uint256 startBlock, bool expired) {
        proposalId = _getActiveProposal();
        startBlock = _getActiveProposalStart();
        if (proposalId != bytes32(0) && startBlock > 0) {
            expired = block.timestamp > GovernanceVotes.proposal(_proxyVotes(), proposalId).expires;
        }
    }

    /// @notice Returns the vote epoch (moves on with every applied ballot or direct overlord change).
    function proxy_getVoteEpoch() external view returns (uint256) {
        return _getVoteEpoch();
    }

    /// @notice Returns a schedule: when it was made, when it is ready, when it expires and who proposed it.
    function proxy_getScheduledUpgrade(bytes32 id)
        external
        view
        returns (uint256 scheduledAt, uint256 readyAt, uint256 expiresAt, address proposer)
    {
        UpgradeStorage storage u = _upgradeStorage();
        scheduledAt = u.scheduledAt[id];
        proposer = u.proposerOf[id];
        if (scheduledAt != 0) {
            readyAt = scheduledAt + proxy_getUpgradeDelay();
            expiresAt = readyAt + _UPGRADE_GRACE;
        }
    }

    /// @notice Returns the validator contract address (0x…1111).
    function proxy_getValidatorContract() external pure returns (address) {
        return _PROXY_VALIDATOR_CONTRACT;
    }

    // ─── Public functions ────────────────────────────────────────────────────────────────────────

    /// @notice Returns true once an implementation is linked.
    function proxy_getIsInit() public view returns (bool) {
        bool isInit;
        bytes32 slot = _PROXY_IS_INIT_SLOT;
        assembly ("memory-safe") {
            isInit := sload(slot)
        }
        return isInit;
    }

    /// @notice Returns the number of guardians.
    function proxy_getGuardianCount() public view returns (uint256) {
        uint256 count;
        bytes32 slot = _PROXY_GUARDIAN_COUNT_SLOT;
        assembly ("memory-safe") {
            count := sload(slot)
        }
        return count;
    }

    /// @notice Returns the size of the ballot electorate (local overlords plus the roots active here).
    function proxy_getOverlordCount() public view returns (uint256) {
        return _governanceMembers().length;
    }

    /// @notice Returns the ballot window in seconds.
    function proxy_getVoteExpiry() public view returns (uint256) {
        uint256 expiry;
        bytes32 slot = _PROXY_VOTE_EXPIRY_SLOT;
        assembly ("memory-safe") {
            expiry := sload(slot)
        }
        return expiry == 0 ? _DEFAULT_VOTE_EXPIRY : expiry;
    }

    /// @notice Returns the votes a ballot needs now: ceil(2/3 of the electorate), e.g. 1→1, 2→2, 3→2, 4→3.
    function proxy_getOverlordThreshold() public view returns (uint256) {
        uint256 count = proxy_getOverlordCount();
        return (count * 2 + 2) / 3;
    }

    /// @notice Returns the network upgrade delay from 0x…1111, capped at 30 days.
    /// @dev Fails closed: if 0x…1111 cannot answer, nothing can be upgraded.
    function proxy_getUpgradeDelay() public view returns (uint256 delay) {
        (bool ok, bytes memory out) = _PROXY_VALIDATOR_CONTRACT.staticcall{gas: 100000}(
            abi.encodeWithSelector(bytes4(keccak256("getUpgradeDelay()")))
        );
        if (!ok || out.length != 32) revert UpgradeDelayUnavailable();
        delay = abi.decode(out, (uint256));
        if (delay > _MAX_UPGRADE_DELAY) delay = _MAX_UPGRADE_DELAY;
    }

    /// @notice Returns the schedule id of an upgrade to `implementation` with call `data`.
    function proxy_upgradeId(address implementation, bytes memory data) public pure returns (bytes32) {
        return keccak256(abi.encode(implementation, data));
    }

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @dev Admin calls are dispatched here; every other caller is forwarded to the implementation.
    function _fallback() internal virtual override {
        if (msg.sender == _PROXY_ADMIN) {
            bytes memory ret;
            bytes4 selector = msg.sig;
            if (selector == ITransparentUpgradeableProxy.upgradeTo.selector) {
                ret = _dispatchUpgradeTo();
            } else if (selector == ITransparentUpgradeableProxy.upgradeToAndCall.selector) {
                ret = _dispatchUpgradeToAndCall();
            } else if (selector == ITransparentUpgradeableProxy.admin.selector) {
                ret = _dispatchAdmin();
            } else if (selector == ITransparentUpgradeableProxy.implementation.selector) {
                ret = _dispatchImplementation();
            } else {
                revert AdminCannotFallback();
            }
            assembly ("memory-safe") {
                return(add(ret, 0x20), mload(ret))
            }
        } else {
            // An unlinked proxy accepts no calls and no coin. Block rewards to 0x…cafE are balance credits, not
            // calls, so they still arrive before the link.
            if (_implementation() == address(0)) revert NotLinked();
            super._fallback();
        }
    }

    function _setIsInit(bool value) internal {
        bytes32 slot = _PROXY_IS_INIT_SLOT;
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    function _setRootRevoked(bool status) internal {
        bytes32 slot = _PROXY_ROOT_REVOKED_SLOT;
        assembly ("memory-safe") {
            sstore(slot, status)
        }
    }

    /// @dev Applies a passed restore-root ballot.
    function _restoreRootOverlord() internal {
        _setRootRevoked(false);
        _clearRootRenounces();
        emit RootOverlordRestored(msg.sender);
    }

    function _setGuardian(address addr, bool status) internal {
        bytes32 slot = _guardianSlot(addr);
        assembly ("memory-safe") {
            sstore(slot, status)
        }
    }

    function _setGuardianCount(uint256 count) internal {
        bytes32 slot = _PROXY_GUARDIAN_COUNT_SLOT;
        assembly ("memory-safe") {
            sstore(slot, count)
        }
    }

    function _setGuardianAt(uint256 index, address addr) internal {
        bytes32 slot = _guardianArrayElement(index);
        assembly ("memory-safe") {
            sstore(slot, addr)
        }
    }

    function _setGuardianIndex(address addr, uint256 indexPlusOne) internal {
        bytes32 slot = _guardianIndexSlot(addr);
        assembly ("memory-safe") {
            sstore(slot, indexPlusOne)
        }
    }

    function _pushGuardian(address addr) internal {
        uint256 count = proxy_getGuardianCount();
        _setGuardianAt(count, addr);
        _setGuardianIndex(addr, count + 1); // index + 1, so 0 means absent
    }

    function _removeGuardianFromArray(address addr) internal {
        uint256 indexPlusOne = _getGuardianIndex(addr);
        if (indexPlusOne == 0) return; // not in the array
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = proxy_getGuardianCount() - 1;

        if (index != lastIndex) {
            address lastAddr = _getGuardianAt(lastIndex);
            _setGuardianAt(index, lastAddr);
            _setGuardianIndex(lastAddr, index + 1);
        }
        _setGuardianAt(lastIndex, address(0));
        _setGuardianIndex(addr, 0);
    }

    function _addGuardian(address newGuardian) internal {
        _setGuardian(newGuardian, true);
        _pushGuardian(newGuardian);
        _setGuardianCount(proxy_getGuardianCount() + 1);
        emit GuardianAdded(newGuardian);
    }

    function _removeGuardian(address guardianToRemove) internal {
        _setGuardian(guardianToRemove, false);
        _removeGuardianFromArray(guardianToRemove);
        _setGuardianCount(proxy_getGuardianCount() - 1);
        emit GuardianRemoved(guardianToRemove);
    }

    /// @dev Bounded: at most _MAX_GUARDIANS guardians.
    function _clearAllGuardians() internal {
        uint256 count = proxy_getGuardianCount();
        for (uint256 i; i < count; ++i) {
            address addr = _getGuardianAt(i);
            _setGuardian(addr, false);
            _setGuardianIndex(addr, 0);
            _setGuardianAt(i, address(0));
        }
        _setGuardianCount(0);
        emit GuardiansCleared(count);
    }

    /// @dev Adds or removes a local overlord. Bounded: the list holds at most GovernanceMembers.MAX_MEMBERS.
    function _setOverlord(address addr, bool status) internal {
        if (addr == address(0)) revert ZeroAddress();
        ProxyGovernanceStorage storage s = _proxyGovernanceStorage();
        if (status && !_isOverlord(addr)) {
            if (s.localOverlords.length >= GovernanceMembers.MAX_MEMBERS) revert TooManyOverlords();
            s.localOverlords.push(addr);
        } else if (!status && _isOverlord(addr)) {
            for (uint256 i; i < s.localOverlords.length; ++i) {
                if (s.localOverlords[i] == addr) {
                    s.localOverlords[i] = s.localOverlords[s.localOverlords.length - 1];
                    s.localOverlords.pop();
                    break;
                }
            }
        }
        bytes32 slot = _overlordSlot(addr);
        assembly ("memory-safe") { sstore(slot, status) }
        if (_governanceMembers().length == 0) revert LastController();
    }

    function _setOverlordCount(uint256 count) internal {
        bytes32 slot = _PROXY_OVERLORD_COUNT_SLOT;
        assembly ("memory-safe") {
            sstore(slot, count)
        }
    }

    /// @dev Starts a new vote epoch, voiding every open ballot.
    function _incrementVoteEpoch() internal {
        GovernanceVotes.invalidate(_proxyVotes());
        bytes32 slot = _PROXY_VOTE_EPOCH_SLOT;
        uint256 epoch;
        assembly ("memory-safe") {
            epoch := sload(slot)
            epoch := add(epoch, 1)
            sstore(slot, epoch)
        }
    }

    /// @dev Moves a ballot to its next round after its window closed, voiding the old votes.
    function _incrementProposalRound(bytes32 proposalKey) internal {
        bytes32 slot = _proposalRoundKey(proposalKey);
        uint256 round;
        assembly ("memory-safe") {
            round := sload(slot)
            round := add(round, 1)
            sstore(slot, round)
        }
    }

    function _setVoteExpiry(uint256 newExpiry) internal {
        bytes32 slot = _PROXY_VOTE_EXPIRY_SLOT;
        assembly ("memory-safe") {
            sstore(slot, newExpiry)
        }
    }

    function _setActiveProposal(bytes32 proposalId) internal {
        bytes32 slot = _PROXY_ACTIVE_PROPOSAL_SLOT;
        assembly ("memory-safe") {
            sstore(slot, proposalId)
        }
    }

    function _setActiveProposalStart(uint256 startTime) internal {
        bytes32 slot = _PROXY_ACTIVE_PROPOSAL_START_SLOT;
        assembly ("memory-safe") {
            sstore(slot, startTime)
        }
    }

    function _clearActiveProposal() internal {
        _setActiveProposal(bytes32(0));
        _setActiveProposalStart(0);
    }

    /// @dev Single-session rule: a different counted ballot cannot open while one is open; a closed one is
    ///      cleared so the new ballot can open.
    function _enforceSession(bytes32 proposalId) internal {
        _refreshSessionContext();
        bytes32 active = _getActiveProposal();
        if (active == proposalId) return;
        if (GovernanceVotes.live(_proxyVotes(), active)) revert BallotActive();
        if (active != bytes32(0)) GovernanceVotes.complete(_proxyVotes(), active);
        _setActiveProposal(proposalId);
        _setActiveProposalStart(block.timestamp);
    }

    /// @dev True if `addr` is a root in 0x…1111 that has not renounced here (false if 0x…1111 cannot answer).
    function _isRootOverlordAddress(address addr) internal view returns (bool) {
        if (addr == address(0) || _rootRenounceStorage().isRenounced[addr]) return false;
        try IValidatorRootOverlord(_PROXY_VALIDATOR_CONTRACT).isRootOverlord(addr) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    /// @dev Roots that still hold power here (excludes self-renounced roots; 0 while all are revoked).
    function _getRootOverlordCount() internal view returns (uint256) {
        return _activeRoots().length;
    }

    function _isRootRevoked() internal view returns (bool) {
        bool revoked;
        bytes32 slot = _PROXY_ROOT_REVOKED_SLOT;
        assembly ("memory-safe") {
            revoked := sload(slot)
        }
        return revoked;
    }

    function _isGuardian(address addr) internal view returns (bool) {
        bytes32 slot = _guardianSlot(addr);
        bool result;
        assembly ("memory-safe") {
            result := sload(slot)
        }
        return result;
    }

    function _getGuardianAt(uint256 index) internal view returns (address) {
        bytes32 slot = _guardianArrayElement(index);
        address addr;
        assembly ("memory-safe") {
            addr := sload(slot)
        }
        return addr;
    }

    /// @dev Returns the stored index + 1 (0 means not in the array).
    function _getGuardianIndex(address addr) internal view returns (uint256) {
        bytes32 slot = _guardianIndexSlot(addr);
        uint256 idx;
        assembly ("memory-safe") {
            idx := sload(slot)
        }
        return idx;
    }

    function _isOverlord(address addr) internal view returns (bool) {
        bytes32 slot = _overlordSlot(addr);
        bool result;
        assembly ("memory-safe") {
            result := sload(slot)
        }
        return result;
    }

    /// @dev The stored local overlord count (roots excluded).
    function _rawOverlordCount() internal view returns (uint256) {
        uint256 count;
        bytes32 slot = _PROXY_OVERLORD_COUNT_SLOT;
        assembly ("memory-safe") {
            count := sload(slot)
        }
        return count;
    }

    function _getVoteEpoch() internal view returns (uint256) {
        uint256 epoch;
        bytes32 slot = _PROXY_VOTE_EPOCH_SLOT;
        assembly ("memory-safe") {
            epoch := sload(slot)
        }
        return epoch;
    }

    /// @dev Overlord ballot id: the ballot key plus its round.
    function _getProposalId(bool isAdd, address target) internal view returns (bytes32) {
        bytes32 proposalKey = keccak256(abi.encodePacked(_governanceContext(), isAdd, target));
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Overlord ballot key (without the round), used to track rounds.
    function _getProposalKey(bool isAdd, address target) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_governanceContext(), isAdd, target));
    }

    /// @dev Ballot-window ballot key.
    function _getExpiryProposalKey(uint256 newExpiry) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_governanceContext(), "expiry", newExpiry));
    }

    function _getExpiryProposalId(uint256 newExpiry) internal view returns (bytes32) {
        bytes32 proposalKey = _getExpiryProposalKey(newExpiry);
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Clear-guardians ballot key.
    function _getClearGuardiansProposalKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_governanceContext(), "clearGuardians"));
    }

    function _getClearGuardiansProposalId() internal view returns (bytes32) {
        bytes32 proposalKey = _getClearGuardiansProposalKey();
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Guardian ballot key.
    function _getGuardianProposalKey(bool isAdd, address target) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_governanceContext(), "guardian", isAdd, target));
    }

    function _getGuardianProposalId(bool isAdd, address target) internal view returns (bytes32) {
        bytes32 proposalKey = _getGuardianProposalKey(isAdd, target);
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Restore-root ballot key.
    function _getRestoreRootProposalKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_governanceContext(), "restoreRoot"));
    }

    function _getRestoreRootProposalId() internal view returns (bytes32) {
        bytes32 proposalKey = _getRestoreRootProposalKey();
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Revoke-root ballot key.
    function _getRevokeRootProposalKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_governanceContext(), "revokeRoot"));
    }

    function _getRevokeRootProposalId() internal view returns (bytes32) {
        bytes32 proposalKey = _getRevokeRootProposalKey();
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    function _getProposalVoteCount(bytes32 proposalId) internal view returns (uint256) {
        if (!GovernanceVotes.current(_proxyVotes(), proposalId)) return 0;
        return GovernanceVotes.proposal(_proxyVotes(), proposalId).votes.length;
    }

    function _hasVoted(bytes32 proposalId, address voter) internal view returns (bool) {
        return GovernanceVotes.voted(_proxyVotes(), proposalId, voter);
    }

    /// @dev When (block.timestamp) a ballot's current round opened, from GovernanceVotes; 0 if none.
    function _getProposalStartBlock(bytes32 proposalId) internal view returns (uint256) {
        if (!GovernanceVotes.current(_proxyVotes(), proposalId)) return 0;
        return GovernanceVotes.proposal(_proxyVotes(), proposalId).start;
    }

    function _getProposalRound(bytes32 proposalKey) internal view returns (uint256) {
        bytes32 slot = _proposalRoundKey(proposalKey);
        uint256 round;
        assembly ("memory-safe") {
            round := sload(slot)
        }
        return round;
    }

    function _getActiveProposal() internal view returns (bytes32) {
        bytes32 result;
        bytes32 slot = _PROXY_ACTIVE_PROPOSAL_SLOT;
        assembly ("memory-safe") {
            result := sload(slot)
        }
        return result;
    }

    function _getActiveProposalStart() internal view returns (uint256) {
        uint256 startTime;
        bytes32 slot = _PROXY_ACTIVE_PROPOSAL_START_SLOT;
        assembly ("memory-safe") {
            startTime := sload(slot)
        }
        return startTime;
    }

    /// @dev True if a counted ballot is open in the current governance context.
    function _isSessionActive() internal view returns (bool) {
        return _proxyGovernanceStorage().sessionContext == _governanceContext()
            && GovernanceVotes.live(_proxyVotes(), _getActiveProposal());
    }

    // ─── Private functions ───────────────────────────────────────────────────────────────────────

    /// @dev Bounded: the renounce list holds at most GovernanceMembers.MAX_MEMBERS roots.
    function _clearRootRenounces() private {
        RootRenounceStorage storage r = _rootRenounceStorage();
        uint256 length = r.renounced.length;
        for (uint256 i; i < length; ++i) r.isRenounced[r.renounced[i]] = false;
        delete r.renounced;
    }

    /// @dev Counted ballot.
    function _castProxyVote(bytes32 proposalId) private returns (uint256 votes, uint256 threshold) {
        return _castProxyVote(proposalId, false);
    }

    /// @dev Removal ballots (an overlord or guardian out, or clear all guardians) are exempt from the
    ///      single-session rule and the ballot caps: a rogue controller holding the session with a junk ballot
    ///      can never delay its own removal.
    function _castProxyVote(bytes32 proposalId, bool exempt) private returns (uint256 votes, uint256 threshold) {
        if (exempt) _refreshSessionContext();
        else _enforceSession(proposalId);
        address[] memory members;
        if (!GovernanceVotes.live(_proxyVotes(), proposalId)) members = _governanceMembers();
        GovernanceVotes.cast(_proxyVotes(), proposalId, members, proxy_getVoteExpiry(), msg.sender, exempt);
        GovernanceVotes.Proposal storage p = GovernanceVotes.proposal(_proxyVotes(), proposalId);
        return (p.votes.length, p.threshold);
    }

    /// @dev A changed governance context (epoch, root revocation or electorate) voids the open session.
    function _refreshSessionContext() private {
        bytes32 context = _governanceContext();
        ProxyGovernanceStorage storage s = _proxyGovernanceStorage();
        if (s.sessionContext != context) {
            GovernanceVotes.invalidate(_proxyVotes());
            _clearActiveProposal();
            s.sessionContext = context;
        }
    }

    function _clearSchedule(bytes32 id) private {
        UpgradeStorage storage u = _upgradeStorage();
        address proposer = u.proposerOf[id];
        if (u.scheduleOf[proposer] == id) delete u.scheduleOf[proposer];
        delete u.scheduledAt[id];
        delete u.proposerOf[id];
    }

    /// @dev Consumes a ready schedule for exactly (implementation, data).
    function _consumeUpgrade(address implementation, bytes memory data) private {
        if (!proxy_getIsInit()) revert NotLinked();
        bytes32 id = proxy_upgradeId(implementation, data);
        uint256 scheduledAt = _upgradeStorage().scheduledAt[id];
        if (scheduledAt == 0) revert UpgradeNotScheduled();
        uint256 readyAt = scheduledAt + proxy_getUpgradeDelay();
        if (block.timestamp < readyAt) revert UpgradeNotReady();
        if (block.timestamp > readyAt + _UPGRADE_GRACE) revert UpgradeExpired();
        _clearSchedule(id);
        emit UpgradeExecuted(id, implementation);
    }

    /// @dev Returns the admin. Clients can also read the EIP-1967 admin slot
    ///      0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 with eth_getStorageAt.
    function _dispatchAdmin() private returns (bytes memory) {
        _requireZeroValue();

        address admin = _PROXY_ADMIN;
        return abi.encode(admin);
    }

    /// @dev Returns the implementation. Clients can also read the EIP-1967 implementation slot
    ///      0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc with eth_getStorageAt.
    function _dispatchImplementation() private returns (bytes memory) {
        _requireZeroValue();

        address implementation = _implementation();
        return abi.encode(implementation);
    }

    /// @dev Upgrades to a scheduled implementation with no call.
    function _dispatchUpgradeTo() private returns (bytes memory) {
        _requireZeroValue();

        address newImplementation = abi.decode(msg.data[4:], (address));
        _consumeUpgrade(newImplementation, bytes(""));
        _upgradeToAndCall(newImplementation, bytes(""), false);

        return "";
    }

    /// @dev Upgrades to a scheduled implementation and calls it with the scheduled data.
    function _dispatchUpgradeToAndCall() private returns (bytes memory) {
        (address newImplementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));
        // An empty call would still run the new logic's fallback; use upgradeTo instead.
        if (data.length == 0) revert EmptyInitData();
        _consumeUpgrade(newImplementation, data);
        _upgradeToAndCall(newImplementation, data, false);

        return "";
    }

    /// @dev Admin functions are payable for transparency; this keeps the non-payable ones value-free.
    function _requireZeroValue() private {
        require(msg.value == 0);
    }

    /// @dev Ballot electorate: local overlords plus the roots active here.
    function _governanceMembers() private view returns (address[] memory) {
        return GovernanceMembers.combineControllers(_proxyGovernanceStorage().localOverlords, _activeRoots());
    }

    /// @dev Roots from 0x…1111 that still hold power on this proxy: none while every root is revoked by
    ///      ballot, otherwise all except those that renounced here. Bounded by GovernanceMembers.read.
    function _activeRoots() private view returns (address[] memory roots) {
        if (_isRootRevoked()) return new address[](0);
        roots = GovernanceMembers.read(_PROXY_VALIDATOR_CONTRACT, bytes4(keccak256("getRootOverlords()")));
        RootRenounceStorage storage r = _rootRenounceStorage();
        if (r.renounced.length == 0) return roots;
        uint256 count;
        for (uint256 i; i < roots.length; ++i) {
            if (!r.isRenounced[roots[i]]) roots[count++] = roots[i];
        }
        assembly ("memory-safe") { mstore(roots, count) }
    }

    /// @dev Binds ballot ids to the epoch, root revocation and electorate.
    function _governanceContext() private view returns (bytes32) {
        return keccak256(abi.encode(_getVoteEpoch(), _isRootRevoked(), _governanceMembers()));
    }

    function _guardianSlot(address addr) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_PROXY_GUARDIAN_MAP_SLOT, addr));
    }

    function _guardianArrayElement(uint256 index) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_PROXY_GUARDIAN_ARRAY_SLOT, index));
    }

    function _guardianIndexSlot(address addr) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_PROXY_GUARDIAN_ARRAY_INDEX_SLOT, addr));
    }

    function _overlordSlot(address addr) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_PROXY_OVERLORD_MAP_SLOT, addr));
    }

    function _proposalRoundKey(bytes32 proposalKey) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_PROXY_PROPOSAL_ROUND_SLOT, proposalKey));
    }
}
