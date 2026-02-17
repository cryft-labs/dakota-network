// SPDX-License-Identifier: MIT
//
// Based on OpenZeppelin Contracts v4.9.0 (proxy/transparent/TransparentUpgradeableProxy.sol).
// Extended by Cryft Labs — overlord/guardian governance with threshold voting.
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.

pragma solidity ^0.8.0;

import "../ERC1967/ERC1967Proxy.sol";

/**
 * @dev Interface for {TransparentUpgradeableProxy}. In order to implement transparency, {TransparentUpgradeableProxy}
 * does not implement this interface directly, and some of its functions are implemented by an internal dispatch
 * mechanism. The compiler is unaware that these functions are implemented by {TransparentUpgradeableProxy} and will not
 * include them in the ABI so this interface must be used to interact with it.
 */
interface ITransparentUpgradeableProxy is IERC1967 {
    function admin() external view returns (address);

    function implementation() external view returns (address);

    function changeAdmin(address) external;

    function upgradeTo(address) external;

    function upgradeToAndCall(address, bytes memory) external payable;
}

/// @dev Minimal interface for querying root overlords from the genesis validator contract.
interface IValidatorRootOverlord {
    function getRootOverlords() external view returns (address[] memory);
    
    function isRootOverlord(address addr) external view returns (bool);
}

/**
 * @dev This contract implements a proxy that is upgradeable by an admin.
 *
 * To avoid https://medium.com/nomic-labs-blog/malicious-backdoors-in-ethereum-proxies-62629adf3357[proxy selector
 * clashing], which can potentially be used in an attack, this contract uses the
 * https://blog.openzeppelin.com/the-transparent-proxy-pattern/[transparent proxy pattern]. This pattern implies two
 * things that go hand in hand:
 *
 * 1. If any account other than the admin calls the proxy, the call will be forwarded to the implementation, even if
 * that call matches one of the admin functions exposed by the proxy itself.
 * 2. If the admin calls the proxy, it can access the admin functions, but its calls will never be forwarded to the
 * implementation. If the admin tries to call a function on the implementation it will fail with an error that says
 * "admin cannot fallback to proxy target".
 *
 * These properties mean that the admin account can only be used for admin actions like upgrading the proxy or changing
 * the admin, so it's best if it's a dedicated account that is not used for anything else. This will avoid headaches due
 * to sudden errors when trying to call a function from the proxy implementation.
 *
 * Our recommendation is for the dedicated account to be an instance of the {ProxyAdmin} contract. If set up this way,
 * you should think of the `ProxyAdmin` instance as the real administrative interface of your proxy.
 *
 * NOTE: The real interface of this proxy is that defined in `ITransparentUpgradeableProxy`. This contract does not
 * inherit from that interface, and instead the admin functions are implicitly implemented using a custom dispatch
 * mechanism in `_fallback`. Consequently, the compiler will not produce an ABI for this contract. This is necessary to
 * fully implement transparency without decoding reverts caused by selector clashes between the proxy and the
 * implementation.
 *
 * WARNING: It is not recommended to extend this contract to add additional external functions. If you do so, the compiler
 * will not check that there are no selector conflicts, due to the note above. A selector clash between any new function
 * and the functions declared in {ITransparentUpgradeableProxy} will be resolved in favor of the new one. This could
 *0000000000000000000000000000000000001 render the admin operations inaccessible, which could prevent upgradeability. Transparency may also be compromised.
 */
contract TransparentUpgradeableProxy is ERC1967Proxy {
    bytes32 private constant _proxy_isInitSlot =
        keccak256("TransparentUpgradeableProxy.isInit");
    bytes32 private constant _proxy_guardianMapSlot =
        keccak256("TransparentUpgradeableProxy.guardianMap");
    bytes32 private constant _proxy_guardianCountSlot =
        keccak256("TransparentUpgradeableProxy.guardianCount");
    bytes32 private constant _proxy_guardianArraySlot =
        keccak256("TransparentUpgradeableProxy.guardianArray");
    bytes32 private constant _proxy_guardianArrayIndexSlot =
        keccak256("TransparentUpgradeableProxy.guardianArrayIndex");
    bytes32 private constant _proxy_overlordMapSlot =
        keccak256("TransparentUpgradeableProxy.overlordMap");
    bytes32 private constant _proxy_overlordCountSlot =
        keccak256("TransparentUpgradeableProxy.overlordCount");
    bytes32 private constant _proxy_rootRevokedSlot =
        keccak256("TransparentUpgradeableProxy.rootRevoked");
    bytes32 private constant _proxy_voteEpochSlot =
        keccak256("TransparentUpgradeableProxy.voteEpoch");
    bytes32 private constant _proxy_proposalVoteCountSlot =
        keccak256("TransparentUpgradeableProxy.proposalVoteCount");
    bytes32 private constant _proxy_proposalVoterSlot =
        keccak256("TransparentUpgradeableProxy.proposalVoter");
    bytes32 private constant _proxy_proposalStartBlockSlot =
        keccak256("TransparentUpgradeableProxy.proposalStartBlock");
    bytes32 private constant _proxy_proposalRoundSlot =
        keccak256("TransparentUpgradeableProxy.proposalRound");
    bytes32 private constant _proxy_voteExpirySlot =
        keccak256("TransparentUpgradeableProxy.voteExpiry");
    bytes32 private constant _proxy_activeProposalSlot =
        keccak256("TransparentUpgradeableProxy.activeProposal");
    bytes32 private constant _proxy_activeProposalStartSlot =
        keccak256("TransparentUpgradeableProxy.activeProposalStart");

    address private constant _proxy_validatorContract = 0x0000000000000000000000000000000000001111;
    uint256 private constant DEFAULT_VOTE_EXPIRY = 60000; // ~1 week at 3s blocks
    uint256 private constant MAX_GUARDIANS = 10;

    /// @dev Returns root overlords as reported by the validator contract (0x1111).
    function proxy_getRootOverlords() external view returns (address[] memory) {
        try IValidatorRootOverlord(_proxy_validatorContract).getRootOverlords() returns (address[] memory overlords) {
            return overlords;
        } catch {
            return new address[](0);
        }
    }

    /// @dev Checks if an address is a root overlord via the validator contract (0x1111).
    function _isRootOverlordAddress(address addr) internal view returns (bool) {
        if (addr == address(0)) return false;
        try IValidatorRootOverlord(_proxy_validatorContract).isRootOverlord(addr) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    /// @dev Returns the count of root overlords from the validator contract.
    function _getRootOverlordCount() internal view returns (uint256) {
        try IValidatorRootOverlord(_proxy_validatorContract).getRootOverlords() returns (address[] memory overlords) {
            return overlords.length;
        } catch {
            return 0;
        }
    }

    event OverlordAdded(address indexed overlord);
    event OverlordRemoved(address indexed overlord);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event RootOverlordRevoked();
    event RootOverlordRestored(address indexed restoredBy);
    event OverlordChangeProposed(address indexed voter, address indexed target, bool isAdd, uint256 currentVotes, uint256 threshold);
    event ExpiryChangeProposed(address indexed voter, uint256 newExpiry, uint256 currentVotes, uint256 threshold);
    event VoteExpiryChanged(uint256 oldExpiry, uint256 newExpiry);
    event GuardiansCleared(uint256 count);
    event ClearGuardiansProposed(address indexed voter, uint256 currentVotes, uint256 threshold);
    event GuardianChangeProposed(address indexed voter, address indexed target, bool isAdd, uint256 currentVotes, uint256 threshold);
    event RestoreRootProposed(address indexed voter, uint256 currentVotes, uint256 threshold);
    event RevokeRootProposed(address indexed voter, uint256 currentVotes, uint256 threshold);
    event AdminChangeProposed(address indexed voter, address indexed newAdmin, uint256 currentVotes, uint256 threshold);
    event ProposalRoundExpired(bytes32 indexed proposalKey, uint256 newRound);

    modifier onlyOverlord() {
        require(
            (_isRootOverlordAddress(msg.sender) && !_isRootRevoked()) || _isOverlord(msg.sender),
            "Only overlord can call this function"
        );
        _;
    }

    modifier onlyRootOverlord() {
        require(
            _isRootOverlordAddress(msg.sender) && !_isRootRevoked(),
            "Only root overlord can call this function"
        );
        _;
    }

    modifier onlyGuardian() {
        require(
            (_isRootOverlordAddress(msg.sender) && !_isRootRevoked()) || _isGuardian(msg.sender),
            "Only guardian can call this function"
        );
        _;
    }

    function proxy_getIsInit() public view returns (bool) {
        bool isInit;
        bytes32 slot = _proxy_isInitSlot;
        assembly {
            isInit := sload(slot)
        }
        return isInit;
    }

    function setIsInit(bool value) internal {
        bytes32 slot = _proxy_isInitSlot;
        assembly {
            sstore(slot, value)
        }
    }

    // ── Root overlord revocation (proxy-safe slot storage) ──

    function _isRootRevoked() internal view returns (bool) {
        bool revoked;
        bytes32 slot = _proxy_rootRevokedSlot;
        assembly {
            revoked := sload(slot)
        }
        return revoked;
    }

    function _setRootRevoked(bool status) internal {
        bytes32 slot = _proxy_rootRevokedSlot;
        assembly {
            sstore(slot, status)
        }
    }

    function proxy_isRootOverlordRevoked() external view returns (bool) {
        return _isRootRevoked();
    }

    /**
     * @dev Root overlord voluntarily disables its own privileges.
     *      Requires at least one other overlord to exist so the system
     *      is not left without governance.
     *      Only another overlord can restore access via restoreRootOverlord().
     */
    function proxy_revokeRootOverlord() external {
        require(_isRootOverlordAddress(msg.sender), "Only root overlord can revoke");
        require(!_isRootRevoked(), "Root overlord already revoked");
        require(_rawOverlordCount() > 0, "Cannot revoke: no other overlords exist");
        _setRootRevoked(true);
        emit RootOverlordRevoked();
    }

    /**
     * @dev A non-root overlord restores root overlord privileges.
     *      Root overlord cannot restore itself. Requires 2/3 threshold vote.
     *      Use proposeRestoreRootOverlord() instead.
     */
    function _restoreRootOverlord() internal {
        _setRootRevoked(false);
        emit RootOverlordRestored(msg.sender);
    }

    // ── Guardian management (proxy-safe slot storage) ──

    function _guardianSlot(address addr) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_proxy_guardianMapSlot, addr));
    }

    function _isGuardian(address addr) internal view returns (bool) {
        bytes32 slot = _guardianSlot(addr);
        bool result;
        assembly {
            result := sload(slot)
        }
        return result;
    }

    function _setGuardian(address addr, bool status) internal {
        bytes32 slot = _guardianSlot(addr);
        assembly {
            sstore(slot, status)
        }
    }

    function proxy_getGuardianCount() public view returns (uint256) {
        uint256 count;
        bytes32 slot = _proxy_guardianCountSlot;
        assembly {
            count := sload(slot)
        }
        return count;
    }

    function _setGuardianCount(uint256 count) internal {
        bytes32 slot = _proxy_guardianCountSlot;
        assembly {
            sstore(slot, count)
        }
    }

    // ── Guardian array (for enumeration / bulk clear) ──

    function _guardianArrayElement(uint256 index) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_proxy_guardianArraySlot, index));
    }

    function _getGuardianAt(uint256 index) internal view returns (address) {
        bytes32 slot = _guardianArrayElement(index);
        address addr;
        assembly {
            addr := sload(slot)
        }
        return addr;
    }

    function _setGuardianAt(uint256 index, address addr) internal {
        bytes32 slot = _guardianArrayElement(index);
        assembly {
            sstore(slot, addr)
        }
    }

    function _guardianIndexSlot(address addr) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_proxy_guardianArrayIndexSlot, addr));
    }

    /// @dev Returns stored index + 1 (0 means not in array).
    function _getGuardianIndex(address addr) internal view returns (uint256) {
        bytes32 slot = _guardianIndexSlot(addr);
        uint256 idx;
        assembly {
            idx := sload(slot)
        }
        return idx;
    }

    function _setGuardianIndex(address addr, uint256 indexPlusOne) internal {
        bytes32 slot = _guardianIndexSlot(addr);
        assembly {
            sstore(slot, indexPlusOne)
        }
    }

    function _pushGuardian(address addr) internal {
        uint256 count = proxy_getGuardianCount();
        _setGuardianAt(count, addr);
        _setGuardianIndex(addr, count + 1); // store index+1 so 0 = absent
    }

    function _removeGuardianFromArray(address addr) internal {
        uint256 indexPlusOne = _getGuardianIndex(addr);
        if (indexPlusOne == 0) return; // not in array
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

    function proxy_isGuardian(address addr) external view returns (bool) {
        return (_isRootOverlordAddress(addr) && !_isRootRevoked()) || _isGuardian(addr);
    }

    /// @dev View: returns all guardian addresses in the map.
    function proxy_getGuardians() external view returns (address[] memory) {
        uint256 count = proxy_getGuardianCount();
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = _getGuardianAt(i);
        }
        return result;
    }

    function addGuardian(address newGuardian) internal {
        _setGuardian(newGuardian, true);
        _pushGuardian(newGuardian);
        _setGuardianCount(proxy_getGuardianCount() + 1);
        emit GuardianAdded(newGuardian);
    }

    function removeGuardian(address guardianToRemove) internal {
        _setGuardian(guardianToRemove, false);
        _removeGuardianFromArray(guardianToRemove);
        _setGuardianCount(proxy_getGuardianCount() - 1);
        emit GuardianRemoved(guardianToRemove);
    }

    function _clearAllGuardians() internal {
        uint256 count = proxy_getGuardianCount();
        for (uint256 i = 0; i < count; i++) {
            address addr = _getGuardianAt(i);
            _setGuardian(addr, false);
            _setGuardianIndex(addr, 0);
            _setGuardianAt(i, address(0));
        }
        _setGuardianCount(0);
        emit GuardiansCleared(count);
    }

    // ── Overlord management (proxy-safe slot storage) ──

    function _overlordSlot(address addr) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_proxy_overlordMapSlot, addr));
    }

    function _isOverlord(address addr) internal view returns (bool) {
        bytes32 slot = _overlordSlot(addr);
        bool result;
        assembly {
            result := sload(slot)
        }
        return result;
    }

    function _setOverlord(address addr, bool status) internal {
        bytes32 slot = _overlordSlot(addr);
        assembly {
            sstore(slot, status)
        }
    }

    /// @dev Returns the raw (stored) overlord count, excluding root overlord.
    function _rawOverlordCount() internal view returns (uint256) {
        uint256 count;
        bytes32 slot = _proxy_overlordCountSlot;
        assembly {
            count := sload(slot)
        }
        return count;
    }

    /// @dev Returns total overlord count, including root overlords when active.
    function proxy_getOverlordCount() public view returns (uint256) {
        uint256 count = _rawOverlordCount();
        if (!_isRootRevoked()) {
            count += _getRootOverlordCount();
        }
        return count;
    }

    function _setOverlordCount(uint256 count) internal {
        bytes32 slot = _proxy_overlordCountSlot;
        assembly {
            sstore(slot, count)
        }
    }

    function proxy_isOverlord(address addr) external view returns (bool) {
        return (_isRootOverlordAddress(addr) && !_isRootRevoked()) || _isOverlord(addr);
    }

    function proxy_addOverlord(address newOverlord) external onlyRootOverlord {
        require(newOverlord != address(0), "Overlord cannot be zero address");
        require(!_isRootOverlordAddress(newOverlord), "Already a root overlord");
        require(!_isOverlord(newOverlord), "Already an overlord");
        require(
            !_isGuardian(newOverlord),
            "Address is a guardian and cannot also be an overlord"
        );
        _setOverlord(newOverlord, true);
        _setOverlordCount(_rawOverlordCount() + 1);
        _clearActiveProposal();
        _incrementVoteEpoch(); // invalidate pending proposals
        emit OverlordAdded(newOverlord);
    }

    function proxy_removeOverlord(address overlordToRemove) external onlyRootOverlord {
        require(_isOverlord(overlordToRemove), "Not an overlord");
        require(
            _rawOverlordCount() > 1 || (_getRootOverlordCount() > 0 && !_isRootRevoked()),
            "Cannot remove last non-root overlord when no root overlords are active"
        );
        _setOverlord(overlordToRemove, false);
        _setOverlordCount(_rawOverlordCount() - 1);
        _clearActiveProposal();
        _incrementVoteEpoch(); // invalidate pending proposals
        emit OverlordRemoved(overlordToRemove);
    }

    // ── Overlord threshold voting (2/3 supermajority) ──

    function _getVoteEpoch() internal view returns (uint256) {
        uint256 epoch;
        bytes32 slot = _proxy_voteEpochSlot;
        assembly {
            epoch := sload(slot)
        }
        return epoch;
    }

    function _incrementVoteEpoch() internal {
        bytes32 slot = _proxy_voteEpochSlot;
        uint256 epoch;
        assembly {
            epoch := sload(slot)
            epoch := add(epoch, 1)
            sstore(slot, epoch)
        }
    }

    function _getProposalId(bool isAdd, address target) internal view returns (bytes32) {
        bytes32 proposalKey = keccak256(abi.encodePacked(_getVoteEpoch(), isAdd, target));
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Returns the base key for a proposal (without round), used for round tracking.
    function _getProposalKey(bool isAdd, address target) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_getVoteEpoch(), isAdd, target));
    }

    /// @dev Same pattern for expiry-change proposals.
    function _getExpiryProposalKey(uint256 newExpiry) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_getVoteEpoch(), "expiry", newExpiry));
    }

    function _getExpiryProposalId(uint256 newExpiry) internal view returns (bytes32) {
        bytes32 proposalKey = _getExpiryProposalKey(newExpiry);
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Proposal key for clearing guardians.
    function _getClearGuardiansProposalKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_getVoteEpoch(), "clearGuardians"));
    }

    function _getClearGuardiansProposalId() internal view returns (bytes32) {
        bytes32 proposalKey = _getClearGuardiansProposalKey();
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Proposal key for guardian add/remove.
    function _getGuardianProposalKey(bool isAdd, address target) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_getVoteEpoch(), "guardian", isAdd, target));
    }

    function _getGuardianProposalId(bool isAdd, address target) internal view returns (bytes32) {
        bytes32 proposalKey = _getGuardianProposalKey(isAdd, target);
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Proposal key for restoring root overlord.
    function _getRestoreRootProposalKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_getVoteEpoch(), "restoreRoot"));
    }

    function _getRestoreRootProposalId() internal view returns (bytes32) {
        bytes32 proposalKey = _getRestoreRootProposalKey();
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Proposal key for forcibly revoking root overlord.
    function _getRevokeRootProposalKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_getVoteEpoch(), "revokeRoot"));
    }

    function _getRevokeRootProposalId() internal view returns (bytes32) {
        bytes32 proposalKey = _getRevokeRootProposalKey();
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    /// @dev Proposal key for changing the proxy admin.
    function _getAdminChangeProposalKey(address newAdmin) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_getVoteEpoch(), "adminChange", newAdmin));
    }

    function _getAdminChangeProposalId(address newAdmin) internal view returns (bytes32) {
        bytes32 proposalKey = _getAdminChangeProposalKey(newAdmin);
        return keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
    }

    function _getProposalVoteCount(bytes32 proposalId) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encodePacked(_proxy_proposalVoteCountSlot, proposalId));
        uint256 count;
        assembly {
            count := sload(slot)
        }
        return count;
    }

    function _setProposalVoteCount(bytes32 proposalId, uint256 count) internal {
        bytes32 slot = keccak256(abi.encodePacked(_proxy_proposalVoteCountSlot, proposalId));
        assembly {
            sstore(slot, count)
        }
    }

    function _hasVoted(bytes32 proposalId, address voter) internal view returns (bool) {
        bytes32 slot = keccak256(abi.encodePacked(_proxy_proposalVoterSlot, proposalId, voter));
        bool voted;
        assembly {
            voted := sload(slot)
        }
        return voted;
    }

    function _setHasVoted(bytes32 proposalId, address voter, bool voted) internal {
        bytes32 slot = keccak256(abi.encodePacked(_proxy_proposalVoterSlot, proposalId, voter));
        assembly {
            sstore(slot, voted)
        }
    }

    // ── Proposal start block tracking ──

    function _getProposalStartBlock(bytes32 proposalId) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encodePacked(_proxy_proposalStartBlockSlot, proposalId));
        uint256 startBlock;
        assembly {
            startBlock := sload(slot)
        }
        return startBlock;
    }

    function _setProposalStartBlock(bytes32 proposalId, uint256 blockNum) internal {
        bytes32 slot = keccak256(abi.encodePacked(_proxy_proposalStartBlockSlot, proposalId));
        assembly {
            sstore(slot, blockNum)
        }
    }

    // ── Proposal round tracking (increments on expiry to invalidate stale votes) ──

    function _proposalRoundKey(bytes32 proposalKey) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_proxy_proposalRoundSlot, proposalKey));
    }

    function _getProposalRound(bytes32 proposalKey) internal view returns (uint256) {
        bytes32 slot = _proposalRoundKey(proposalKey);
        uint256 round;
        assembly {
            round := sload(slot)
        }
        return round;
    }

    function _incrementProposalRound(bytes32 proposalKey) internal {
        bytes32 slot = _proposalRoundKey(proposalKey);
        uint256 round;
        assembly {
            round := sload(slot)
            round := add(round, 1)
            sstore(slot, round)
        }
    }

    // ── Vote expiry window ──

    function proxy_getVoteExpiry() public view returns (uint256) {
        uint256 expiry;
        bytes32 slot = _proxy_voteExpirySlot;
        assembly {
            expiry := sload(slot)
        }
        return expiry == 0 ? DEFAULT_VOTE_EXPIRY : expiry;
    }

    function _setVoteExpiry(uint256 newExpiry) internal {
        bytes32 slot = _proxy_voteExpirySlot;
        assembly {
            sstore(slot, newExpiry)
        }
    }

    // ── Active proposal session (single-session lock) ──

    function _getActiveProposal() internal view returns (bytes32) {
        bytes32 result;
        bytes32 slot = _proxy_activeProposalSlot;
        assembly {
            result := sload(slot)
        }
        return result;
    }

    function _setActiveProposal(bytes32 proposalId) internal {
        bytes32 slot = _proxy_activeProposalSlot;
        assembly {
            sstore(slot, proposalId)
        }
    }

    function _getActiveProposalStart() internal view returns (uint256) {
        uint256 startBlock;
        bytes32 slot = _proxy_activeProposalStartSlot;
        assembly {
            startBlock := sload(slot)
        }
        return startBlock;
    }

    function _setActiveProposalStart(uint256 blockNum) internal {
        bytes32 slot = _proxy_activeProposalStartSlot;
        assembly {
            sstore(slot, blockNum)
        }
    }

    function _clearActiveProposal() internal {
        _setActiveProposal(bytes32(0));
        _setActiveProposalStart(0);
    }

    /**
     * @dev Returns true if a voting session is currently in progress and not expired.
     */
    function _isSessionActive() internal view returns (bool) {
        bytes32 active = _getActiveProposal();
        if (active == bytes32(0)) return false;
        uint256 start = _getActiveProposalStart();
        return block.number <= start + proxy_getVoteExpiry();
    }

    /**
     * @dev Enforces single-session voting. If a different proposal tries to start
     *      while a session is active, it reverts. If the session has expired, it clears
     *      the lock and allows the new proposal.
     */
    function _enforceSession(bytes32 proposalId) internal {
        bytes32 active = _getActiveProposal();
        if (active == bytes32(0)) {
            // No active session — start one
            _setActiveProposal(proposalId);
            _setActiveProposalStart(block.number);
            return;
        }
        if (active == proposalId) {
            // Voting on the active proposal — allowed
            return;
        }
        // Different proposal — check if current session expired
        uint256 start = _getActiveProposalStart();
        require(
            block.number > start + proxy_getVoteExpiry(),
            "Another proposal is still active, wait for it to expire or pass"
        );
        // Expired — clear and start new session
        _clearActiveProposal();
        _setActiveProposal(proposalId);
        _setActiveProposalStart(block.number);
    }

    /// @dev View: is a voting session currently active?
    function proxy_isVotingSessionActive() external view returns (bool) {
        return _isSessionActive();
    }

    /**
     * @dev Returns the minimum votes needed: ceil(voterCount * 2 / 3).
     *      voterCount includes rootOverlord only when it is active (not revoked).
     *      Examples: 1→1, 2→2, 3→2, 4→3, 5→4, 6→4
     */
    function proxy_getOverlordThreshold() public view returns (uint256) {
        uint256 count = proxy_getOverlordCount(); // already includes root when active
        return (count * 2 + 2) / 3;
    }

    /**
     * @dev Any overlord can propose or vote to add/remove an overlord.
     *      When 2/3 threshold is met, the change auto-executes and all
     *      pending proposals are invalidated (epoch increments).
     *      Works independently of rootOverlord — allows self-governance.
     */
    function proxy_proposeOverlordChange(address target, bool isAdd) external onlyOverlord {
        require(target != address(0), "Target cannot be zero address");
        require(!_isRootOverlordAddress(target), "Cannot vote on root overlord via proxy");
        require(proxy_getOverlordCount() > 0, "No overlords to vote");

        if (isAdd) {
            require(!_isOverlord(target), "Already an overlord");
            require(
                !_isGuardian(target),
                "Address is a guardian and cannot also be an overlord"
            );
        } else {
            require(_isOverlord(target), "Not an overlord");
            require(
                _rawOverlordCount() > 1 || (_getRootOverlordCount() > 0 && !_isRootRevoked()),
                "Cannot remove last non-root overlord when no root overlords are active"
            );
        }

        bytes32 proposalKey = _getProposalKey(isAdd, target);
        bytes32 proposalId = _getProposalId(isAdd, target);

        // Check if current proposal has expired
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.number > startBlock + proxy_getVoteExpiry()) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        // Enforce single-session voting
        _enforceSession(proposalId);

        // Record start block on first vote of this round
        if (_getProposalStartBlock(proposalId) == 0) {
            _setProposalStartBlock(proposalId, block.number);
        }

        require(!_hasVoted(proposalId, msg.sender), "Already voted on this proposal");

        _setHasVoted(proposalId, msg.sender, true);
        uint256 newVoteCount = _getProposalVoteCount(proposalId) + 1;
        _setProposalVoteCount(proposalId, newVoteCount);

        uint256 threshold = proxy_getOverlordThreshold();
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
            _incrementVoteEpoch(); // invalidate all pending proposals
        }
    }

    /**
     * @dev Any overlord can propose a new vote expiry window.
     *      Auto-executes at 2/3 threshold. Subject to the same expiry window.
     *      Minimum expiry: 100 blocks (~5 minutes at 3s blocks) to prevent abuse.
     */
    function proxy_proposeExpiryChange(uint256 newExpiry) external onlyOverlord {
        require(newExpiry >= 100, "Expiry too short, minimum 100 blocks");
        require(newExpiry != proxy_getVoteExpiry(), "Already set to this value");
        require(proxy_getOverlordCount() > 0, "No overlords to vote");

        bytes32 proposalKey = _getExpiryProposalKey(newExpiry);
        bytes32 proposalId = _getExpiryProposalId(newExpiry);

        // Check if current proposal has expired
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.number > startBlock + proxy_getVoteExpiry()) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        // Enforce single-session voting
        _enforceSession(proposalId);

        // Record start block on first vote of this round
        if (_getProposalStartBlock(proposalId) == 0) {
            _setProposalStartBlock(proposalId, block.number);
        }

        require(!_hasVoted(proposalId, msg.sender), "Already voted on this proposal");

        _setHasVoted(proposalId, msg.sender, true);
        uint256 newVoteCount = _getProposalVoteCount(proposalId) + 1;
        _setProposalVoteCount(proposalId, newVoteCount);

        uint256 threshold = proxy_getOverlordThreshold();
        emit ExpiryChangeProposed(msg.sender, newExpiry, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            uint256 oldExpiry = proxy_getVoteExpiry();
            _setVoteExpiry(newExpiry);
            emit VoteExpiryChanged(oldExpiry, newExpiry);
            _clearActiveProposal();
            _incrementVoteEpoch(); // invalidate all pending proposals
        }
    }

    /// @dev View: current votes for a proposal in this epoch.
    function proxy_getProposalVotes(address target, bool isAdd) external view returns (uint256) {
        return _getProposalVoteCount(_getProposalId(isAdd, target));
    }

    /// @dev View: has a specific overlord voted on a proposal in this epoch?
    function proxy_hasVotedOnProposal(address voter, address target, bool isAdd) external view returns (bool) {
        return _hasVoted(_getProposalId(isAdd, target), voter);
    }

    /// @dev View: block number when the current proposal round started (0 if none).
    function proxy_getProposalStartBlock(address target, bool isAdd) external view returns (uint256) {
        return _getProposalStartBlock(_getProposalId(isAdd, target));
    }

    /// @dev View: current votes for an expiry change proposal.
    function proxy_getExpiryProposalVotes(uint256 newExpiry) external view returns (uint256) {
        return _getProposalVoteCount(_getExpiryProposalId(newExpiry));
    }

    /// @dev View: has a specific overlord voted on an expiry change proposal?
    function proxy_hasVotedOnExpiryProposal(address voter, uint256 newExpiry) external view returns (bool) {
        return _hasVoted(_getExpiryProposalId(newExpiry), voter);
    }

    /// @dev View: current votes for the clear guardians proposal.
    function proxy_getClearGuardiansProposalVotes() external view returns (uint256) {
        return _getProposalVoteCount(_getClearGuardiansProposalId());
    }

    /// @dev View: has a specific overlord voted on the clear guardians proposal?
    function proxy_hasVotedOnClearGuardians(address voter) external view returns (bool) {
        return _hasVoted(_getClearGuardiansProposalId(), voter);
    }

    /// @dev View: current votes for a guardian change proposal.
    function proxy_getGuardianProposalVotes(address target, bool isAdd) external view returns (uint256) {
        return _getProposalVoteCount(_getGuardianProposalId(isAdd, target));
    }

    /// @dev View: has a specific overlord voted on a guardian change proposal?
    function proxy_hasVotedOnGuardianProposal(address voter, address target, bool isAdd) external view returns (bool) {
        return _hasVoted(_getGuardianProposalId(isAdd, target), voter);
    }

    /// @dev View: current votes for the restore root overlord proposal.
    function proxy_getRestoreRootProposalVotes() external view returns (uint256) {
        return _getProposalVoteCount(_getRestoreRootProposalId());
    }

    /// @dev View: has a specific overlord voted on the restore root proposal?
    function proxy_hasVotedOnRestoreRoot(address voter) external view returns (bool) {
        return _hasVoted(_getRestoreRootProposalId(), voter);
    }

    /// @dev View: current votes for the revoke root overlord proposal.
    function proxy_getRevokeRootProposalVotes() external view returns (uint256) {
        return _getProposalVoteCount(_getRevokeRootProposalId());
    }

    /// @dev View: has a specific overlord voted on the revoke root proposal?
    function proxy_hasVotedOnRevokeRoot(address voter) external view returns (bool) {
        return _hasVoted(_getRevokeRootProposalId(), voter);
    }

    /// @dev View: current votes for an admin change proposal.
    function proxy_getAdminChangeProposalVotes(address newAdmin) external view returns (uint256) {
        return _getProposalVoteCount(_getAdminChangeProposalId(newAdmin));
    }

    /// @dev View: has a specific overlord voted on an admin change proposal?
    function proxy_hasVotedOnAdminChange(address voter, address newAdmin) external view returns (bool) {
        return _hasVoted(_getAdminChangeProposalId(newAdmin), voter);
    }

    /**
     * @dev View: returns the active proposal ID, the block it started, and
     *      whether it has expired. Returns bytes32(0) if no proposal is active.
     */
    function proxy_getActiveProposal()
        external
        view
        returns (
            bytes32 proposalId,
            uint256 startBlock,
            bool expired
        )
    {
        proposalId = _getActiveProposal();
        startBlock = _getActiveProposalStart();
        if (proposalId != bytes32(0) && startBlock > 0) {
            expired = block.number > startBlock + proxy_getVoteExpiry();
        }
    }

    /// @dev View: current vote epoch (increments on every executed proposal or direct overlord change).
    function proxy_getVoteEpoch() external view returns (uint256) {
        return _getVoteEpoch();
    }

    /**
     * @dev Overlords vote to clear all guardians at once.
     *      Auto-executes at 2/3 threshold. Subject to the same expiry/session rules.
     *      Guardians are temporary — add them for setup, clear when done.
     */
    function proxy_proposeClearGuardians() external onlyOverlord {
        require(proxy_getGuardianCount() > 0, "No guardians to clear");
        require(proxy_getOverlordCount() > 0, "No overlords to vote");

        bytes32 proposalKey = _getClearGuardiansProposalKey();
        bytes32 proposalId = _getClearGuardiansProposalId();

        // Check if current proposal has expired
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.number > startBlock + proxy_getVoteExpiry()) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        // Enforce single-session voting
        _enforceSession(proposalId);

        // Record start block on first vote of this round
        if (_getProposalStartBlock(proposalId) == 0) {
            _setProposalStartBlock(proposalId, block.number);
        }

        require(!_hasVoted(proposalId, msg.sender), "Already voted on this proposal");

        _setHasVoted(proposalId, msg.sender, true);
        uint256 newVoteCount = _getProposalVoteCount(proposalId) + 1;
        _setProposalVoteCount(proposalId, newVoteCount);

        uint256 threshold = proxy_getOverlordThreshold();
        emit ClearGuardiansProposed(msg.sender, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            _clearAllGuardians();
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /**
     * @dev Overlords vote to add or remove a guardian.
     *      Auto-executes at 2/3 threshold. Subject to same expiry/session rules.
     */
    function proxy_proposeGuardianChange(address target, bool isAdd) external onlyOverlord {
        require(target != address(0), "Target cannot be zero address");
        require(target != _proxy_validatorContract, "Root overlords are implicit guardians, manage via validator contract");
        require(proxy_getOverlordCount() > 0, "No overlords to vote");

        if (isAdd) {
            require(!_isGuardian(target), "Already a guardian");
            require(proxy_getGuardianCount() < MAX_GUARDIANS, "Guardian limit reached (10)");
            require(
                !_isOverlord(target) && !_isRootOverlordAddress(target),
                "Address is an overlord and cannot also be a guardian"
            );
        } else {
            require(_isGuardian(target), "Not a guardian");
        }

        bytes32 proposalKey = _getGuardianProposalKey(isAdd, target);
        bytes32 proposalId = _getGuardianProposalId(isAdd, target);

        // Check if current proposal has expired
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.number > startBlock + proxy_getVoteExpiry()) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        // Enforce single-session voting
        _enforceSession(proposalId);

        // Record start block on first vote of this round
        if (_getProposalStartBlock(proposalId) == 0) {
            _setProposalStartBlock(proposalId, block.number);
        }

        require(!_hasVoted(proposalId, msg.sender), "Already voted on this proposal");

        _setHasVoted(proposalId, msg.sender, true);
        uint256 newVoteCount = _getProposalVoteCount(proposalId) + 1;
        _setProposalVoteCount(proposalId, newVoteCount);

        uint256 threshold = proxy_getOverlordThreshold();
        emit GuardianChangeProposed(msg.sender, target, isAdd, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            if (isAdd) {
                addGuardian(target);
            } else {
                removeGuardian(target);
            }
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /**
     * @dev Overlords vote to restore root overlord privileges.
     *      Root overlord cannot participate (it's revoked).
     *      Auto-executes at 2/3 threshold.
     */
    function proxy_proposeRestoreRootOverlord() external {
        require(_isOverlord(msg.sender), "Only a non-root overlord can propose restore");
        require(_isRootRevoked(), "Root overlord is not revoked");
        require(proxy_getOverlordCount() > 0, "No overlords to vote");

        bytes32 proposalKey = _getRestoreRootProposalKey();
        bytes32 proposalId = _getRestoreRootProposalId();

        // Check if current proposal has expired
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.number > startBlock + proxy_getVoteExpiry()) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        // Enforce single-session voting
        _enforceSession(proposalId);

        // Record start block on first vote of this round
        if (_getProposalStartBlock(proposalId) == 0) {
            _setProposalStartBlock(proposalId, block.number);
        }

        require(!_hasVoted(proposalId, msg.sender), "Already voted on this proposal");

        _setHasVoted(proposalId, msg.sender, true);
        uint256 newVoteCount = _getProposalVoteCount(proposalId) + 1;
        _setProposalVoteCount(proposalId, newVoteCount);

        uint256 threshold = proxy_getOverlordThreshold();
        emit RestoreRootProposed(msg.sender, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            _restoreRootOverlord();
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /**
     * @dev Overlords vote to forcibly revoke root overlord privileges.
     *      This is separate from revokeRootOverlord() which is voluntary.
     *      Root overlord CAN vote here (it counts toward threshold).
     *      Auto-executes at 2/3 threshold.
     */
    function proxy_proposeRevokeRootOverlord() external onlyOverlord {
        require(!_isRootRevoked(), "Root overlord already revoked");
        require(_rawOverlordCount() > 0, "Cannot revoke: no other overlords exist");
        require(proxy_getOverlordCount() > 0, "No overlords to vote");

        bytes32 proposalKey = _getRevokeRootProposalKey();
        bytes32 proposalId = _getRevokeRootProposalId();

        // Check if current proposal has expired
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.number > startBlock + proxy_getVoteExpiry()) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        // Enforce single-session voting
        _enforceSession(proposalId);

        // Record start block on first vote of this round
        if (_getProposalStartBlock(proposalId) == 0) {
            _setProposalStartBlock(proposalId, block.number);
        }

        require(!_hasVoted(proposalId, msg.sender), "Already voted on this proposal");

        _setHasVoted(proposalId, msg.sender, true);
        uint256 newVoteCount = _getProposalVoteCount(proposalId) + 1;
        _setProposalVoteCount(proposalId, newVoteCount);

        uint256 threshold = proxy_getOverlordThreshold();
        emit RevokeRootProposed(msg.sender, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            _setRootRevoked(true);
            emit RootOverlordRevoked();
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    /**
     * @dev Overlords vote to change the proxy admin (the ProxyAdmin contract).
     *      This is a governance-level action — changing who controls upgrades.
     *      Auto-executes at 2/3 threshold.
     */
    function proxy_proposeAdminChange(address newAdmin) external onlyOverlord {
        require(newAdmin != address(0), "New admin cannot be zero address");
        require(newAdmin != _getAdmin(), "Already the current admin");
        require(proxy_getOverlordCount() > 0, "No overlords to vote");

        bytes32 proposalKey = _getAdminChangeProposalKey(newAdmin);
        bytes32 proposalId = _getAdminChangeProposalId(newAdmin);

        // Check if current proposal has expired
        uint256 startBlock = _getProposalStartBlock(proposalId);
        if (startBlock > 0 && block.number > startBlock + proxy_getVoteExpiry()) {
            _incrementProposalRound(proposalKey);
            proposalId = keccak256(abi.encodePacked(proposalKey, _getProposalRound(proposalKey)));
            emit ProposalRoundExpired(proposalKey, _getProposalRound(proposalKey));
        }

        // Enforce single-session voting
        _enforceSession(proposalId);

        // Record start block on first vote of this round
        if (_getProposalStartBlock(proposalId) == 0) {
            _setProposalStartBlock(proposalId, block.number);
        }

        require(!_hasVoted(proposalId, msg.sender), "Already voted on this proposal");

        _setHasVoted(proposalId, msg.sender, true);
        uint256 newVoteCount = _getProposalVoteCount(proposalId) + 1;
        _setProposalVoteCount(proposalId, newVoteCount);

        uint256 threshold = proxy_getOverlordThreshold();
        emit AdminChangeProposed(msg.sender, newAdmin, newVoteCount, threshold);

        if (newVoteCount >= threshold) {
            _changeAdmin(newAdmin);
            _clearActiveProposal();
            _incrementVoteEpoch();
        }
    }

    function proxy_linkLogicAdmin(
        address _logic,
        address admin_,
        bytes memory _data
    ) external payable onlyGuardian {
        require(proxy_getIsInit() == false, "Already linked");
        require(_logic != address(0), "Logic address cannot be zero");
        require(admin_ != address(0), "Admin address cannot be zero");
        setIsInit(true);

        _Initializing(_logic, _data); // Initialize the proxy logic
        _changeAdmin(admin_); // Change the admin
    }

    /**
     * @dev Modifier used internally that will delegate the call to the implementation unless the sender is the admin.
     *
     * CAUTION: This modifier is deprecated, as it could cause issues if the modified function has arguments, and the
     * implementation provides a function with the same selector.
     */
    modifier ifAdmin() {
        if (msg.sender == _getAdmin()) {
            _;
        } else {
            _fallback();
        }
    }

    /**
     * @dev If caller is the admin process the call internally, otherwise transparently fallback to the proxy behavior
     */
    function _fallback() internal virtual override {
        if (msg.sender == _getAdmin()) {
            bytes memory ret;
            bytes4 selector = msg.sig;
            if (selector == ITransparentUpgradeableProxy.upgradeTo.selector) {
                ret = _dispatchUpgradeTo();
            } else if (
                selector ==
                ITransparentUpgradeableProxy.upgradeToAndCall.selector
            ) {
                ret = _dispatchUpgradeToAndCall();
            } else if (
                selector == ITransparentUpgradeableProxy.changeAdmin.selector
            ) {
                ret = _dispatchChangeAdmin();
            } else if (
                selector == ITransparentUpgradeableProxy.admin.selector
            ) {
                ret = _dispatchAdmin();
            } else if (
                selector == ITransparentUpgradeableProxy.implementation.selector
            ) {
                ret = _dispatchImplementation();
            } else {
                revert(
                    "TransparentUpgradeableProxy: admin cannot fallback to proxy target"
                );
            }
            assembly {
                return(add(ret, 0x20), mload(ret))
            }
        } else {
            super._fallback();
        }
    }

    /**
     * @dev Returns the current admin.
     *
     * TIP: To get this value clients can read directly from the storage slot shown below (specified by EIP1967) using the
     * https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
     * `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`
     */
    function _dispatchAdmin() private returns (bytes memory) {
        _requireZeroValue();

        address admin = _getAdmin();
        return abi.encode(admin);
    }

    /**
     * @dev Returns the current implementation.
     *
     * TIP: To get this value clients can read directly from the storage slot shown below (specified by EIP1967) using the
     * https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
     * `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
     */
    function _dispatchImplementation() private returns (bytes memory) {
        _requireZeroValue();

        address implementation = _implementation();
        return abi.encode(implementation);
    }

    /**
     * @dev Changes the admin of the proxy.
     *
     * Emits an {AdminChanged} event.
     */
    function _dispatchChangeAdmin() private returns (bytes memory) {
        _requireZeroValue();

        address newAdmin = abi.decode(msg.data[4:], (address));
        _changeAdmin(newAdmin);

        return "";
    }

    /**
     * @dev Upgrade the implementation of the proxy.
     */
    function _dispatchUpgradeTo() private returns (bytes memory) {
        _requireZeroValue();

        address newImplementation = abi.decode(msg.data[4:], (address));
        _upgradeToAndCall(newImplementation, bytes(""), false);

        return "";
    }

    /**
     * @dev Upgrade the implementation of the proxy, and then call a function from the new implementation as specified
     * by `data`, which should be an encoded function call. This is useful to initialize new storage variables in the
     * proxied contract.
     */
    function _dispatchUpgradeToAndCall() private returns (bytes memory) {
        (address newImplementation, bytes memory data) = abi.decode(
            msg.data[4:],
            (address, bytes)
        );
        _upgradeToAndCall(newImplementation, data, true);

        return "";
    }

    /**
     * @dev Returns the current admin.
     *
     * CAUTION: This function is deprecated. Use {ERC1967Upgrade-_getAdmin} instead.
     */
    function _admin() internal view virtual returns (address) {
        return _getAdmin();
    }

    /**
     * @dev To keep this contract fully transparent, all `ifAdmin` functions must be payable. This helper is here to
     * emulate some proxy functions being non-payable while still allowing value to pass through.
     */
    function _requireZeroValue() private {
        require(msg.value == 0);
    }
}