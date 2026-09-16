// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../Genesis/Upgradeable/Initializable.sol";

/// @notice Upgradeable, append-only references to public card content and metadata.
/// @dev Never submit codes, PINs, email addresses or encryption passwords here.
///      Deploy behind a transparent proxy, initializing atomically. Relayers are
///      trusted authenticated services; their writes cannot erase older revisions.
contract MomentProjectRegistry is Initializable {
    struct Revision { bytes32 digest; string uri; uint64 createdAt; }
    address public owner;
    address public pendingOwner;
    mapping(address => bool) public relayers;
    mapping(bytes32 => Revision[]) private _revisions;
    mapping(bytes32 => bytes32[]) private _projects;
    uint256[45] private __gap;
    event ProjectSaved(bytes32 indexed tenant, address indexed account, bytes32 indexed projectId, uint256 version, bytes32 digest, string uri);
    event RelayerSet(address indexed relayer, bool enabled);
    event OwnershipTransferStarted(address indexed owner, address indexed candidate);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() { _disableInitializers(); }
    function initialize(address admin, address relay) external initializer {
        require(admin != address(0), "zero admin"); owner = admin;
        if (relay != address(0)) { relayers[relay] = true; emit RelayerSet(relay, true); }
        emit OwnershipTransferred(address(0), admin);
    }
    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }
    function setRelayer(address relay, bool enabled) external onlyOwner {
        require(relay != address(0), "zero relay"); relayers[relay] = enabled; emit RelayerSet(relay, enabled);
    }
    function transferOwnership(address candidate) external onlyOwner {
        require(candidate != address(0), "zero owner"); pendingOwner = candidate; emit OwnershipTransferStarted(owner, candidate);
    }
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "pending owner"); emit OwnershipTransferred(owner, msg.sender); owner = msg.sender; pendingOwner = address(0);
    }
    function projectKey(bytes32 tenant, address account, bytes32 projectId) public pure returns (bytes32) {
        return keccak256(abi.encode(tenant, account, projectId));
    }
    function version(bytes32 tenant, address account, bytes32 projectId) external view returns (uint256) {
        return _revisions[projectKey(tenant, account, projectId)].length;
    }
    function revision(bytes32 tenant, address account, bytes32 projectId, uint256 index) external view returns (Revision memory) {
        return _revisions[projectKey(tenant, account, projectId)][index];
    }
    function projects(bytes32 tenant, address account, uint256 offset, uint256 limit) external view returns (bytes32[] memory items, uint256 total) {
        require(limit > 0 && limit <= 100, "page size");
        bytes32[] storage all = _projects[keccak256(abi.encode(tenant, account))]; total = all.length;
        uint256 size = offset >= total ? 0 : (total - offset < limit ? total - offset : limit);
        items = new bytes32[](size); for (uint256 i; i < size; ++i) items[i] = all[offset + i];
    }
    function save(address account, bytes32 tenant, bytes32 projectId, uint256 expectedVersion, bytes32 digest, string calldata uri) external {
        require(msg.sender == account || relayers[msg.sender], "writer");
        require(account != address(0) && tenant != bytes32(0) && projectId != bytes32(0) && digest != bytes32(0), "identity");
        require(bytes(uri).length > 7 && bytes(uri).length <= 256, "uri");
        bytes32 key = projectKey(tenant, account, projectId);
        require(_revisions[key].length == expectedVersion, "version changed");
        if (expectedVersion == 0) _projects[keccak256(abi.encode(tenant, account))].push(projectId);
        _revisions[key].push(Revision(digest, uri, uint64(block.timestamp)));
        emit ProjectSaved(tenant, account, projectId, expectedVersion + 1, digest, uri);
    }
}
