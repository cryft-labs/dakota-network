// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.6/contracts/token/ERC1155/ERC1155Upgradeable.sol";

/// @notice One shared collection of named fungible types. A type needs no new contract.
/// @dev Fixed supply is minted once. Metadata and creator never change. Relay authority
///      permits new issuance only: it cannot move or burn any holder's balance.
contract MomentInventoryToken is ERC1155Upgradeable {
    struct Definition { address creator; bytes32 tenant; uint256 supply; string name; string metadataURI; }
    address public owner;
    address public pendingOwner;
    mapping(address => bool) public relayers;
    mapping(uint256 => Definition) private _definitions;
    mapping(bytes32 => uint256) public requests;
    uint256 public nextId;
    bool private _entered;
    uint256[45] private __gap;
    event TypeCreated(uint256 indexed id, address indexed creator, bytes32 indexed tenant, uint256 supply, string name, string metadataURI);
    event RelayerSet(address indexed relayer, bool enabled);
    event OwnershipTransferStarted(address indexed owner, address indexed candidate);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() { _disableInitializers(); }
    function initialize(address admin, address relay) external initializer {
        require(admin != address(0), "zero admin"); __ERC1155_init(""); owner = admin; nextId = 1;
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
    function definition(uint256 id) external view returns (Definition memory) { require(_definitions[id].creator != address(0), "unknown type"); return _definitions[id]; }
    function uri(uint256 id) public view override returns (string memory) { return _definitions[id].metadataURI; }

    function createType(address creator, bytes32 tenant, bytes32 requestId, string calldata tokenName,
        string calldata metadataURI, uint256 supply, address recipient) external returns (uint256 id) {
        require(!_entered, "reentrant");
        require(msg.sender == creator || relayers[msg.sender], "issuer");
        require(creator != address(0) && recipient != address(0) && tenant != bytes32(0) && requestId != bytes32(0), "identity");
        require(supply > 0 && supply <= 1e18, "supply");
        require(bytes(tokenName).length > 0 && bytes(tokenName).length <= 320, "name");
        require(bytes(metadataURI).length > 7 && bytes(metadataURI).length <= 256, "metadata");
        bytes32 key = keccak256(abi.encode(tenant, creator, requestId));
        require(requests[key] == 0, "already issued");
        _entered = true;
        id = nextId++; requests[key] = id;
        _definitions[id] = Definition(creator, tenant, supply, tokenName, metadataURI);
        emit URI(metadataURI, id);
        emit TypeCreated(id, creator, tenant, supply, tokenName, metadataURI);
        _mint(recipient, id, supply, "");
        _entered = false;
    }
}
