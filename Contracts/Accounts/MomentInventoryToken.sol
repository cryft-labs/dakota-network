// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.6/contracts/token/ERC1155/ERC1155Upgradeable.sol";

interface IMomentAccountRegistry {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId) external returns (address);
}

/// @notice One shared collection of named fungible types. A type needs no new contract.
/// @dev Fixed supply is minted once. Metadata and creator never change. Relay authority
///      permits new issuance only: it cannot move or burn any holder's balance.
contract MomentInventoryToken is ERC1155Upgradeable {
    struct Definition { address creator; bytes32 tenant; uint256 supply; string name; string metadataURI; }
    struct AllocatedType {
        address creator; bytes32 tenant; bytes32 requestId; string tokenName;
        string metadataURI; uint256 supply; address[] recipients; uint256 perRecipient;
    }
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
    event TypeAllocated(uint256 indexed id, address indexed creator, uint256 recipients, uint256 perRecipient, uint256 remainder);

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
    /// @notice Collection identity for explorers; each type retains its own metadata.
    function name() external pure returns (string memory) { return "Moment Inventory"; }
    function symbol() external pure returns (string memory) { return "MOMINV"; }
    function implementationVersion() external pure returns (string memory) { return "1.1.1"; }

    modifier nonReentrant() {
        require(!_entered, "reentrant"); _entered = true; _; _entered = false;
    }

    /// @notice Permissionless, idempotent activation of existing deterministic accounts.
    /// @dev Registry identity and account binding are verified by callers. This gives
    ///      no authority to spend account assets, and stores no new configuration.
    function activateAccounts(address registry, address implementation, bytes32 salt,
        uint256 chainId, address tokenContract, uint256[] calldata tokenIds)
        external nonReentrant returns (address[] memory accounts) {
        require(registry.code.length > 0 && implementation.code.length > 0 && tokenContract.code.length > 0, "contracts");
        require(chainId == block.chainid && tokenIds.length > 0 && tokenIds.length <= 100, "batch");
        accounts = new address[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            accounts[i] = IMomentAccountRegistry(registry).createAccount(implementation, salt, chainId, tokenContract, tokenIds[i]);
            require(accounts[i].code.length > 0, "account not deployed");
        }
    }

    /// @notice Atomically create a type, fill card inventories and return its surplus.
    /// @dev The entire mint reverts if any receiver rejects. No wallet allowance,
    ///      temporary relayer custody, or authority over existing balances is added.
    function createTypeAllocated(AllocatedType calldata request) external nonReentrant returns (uint256 id) {
        uint256 count = request.recipients.length;
        require(count > 0 && count <= 1000 && request.perRecipient > 0, "allocation");
        uint256 allocated = count * request.perRecipient;
        require(allocated <= request.supply, "insufficient supply");
        for (uint256 i; i < count; ++i) {
            address recipient = request.recipients[i];
            require(recipient.code.length > 0 && recipient != request.creator, "card account");
            require(i == 0 || uint160(recipient) > uint160(request.recipients[i-1]), "ordered unique accounts");
        }
        id = _createDefinition(request.creator, request.tenant, request.requestId, request.tokenName, request.metadataURI, request.supply);
        for (uint256 i; i < count; ++i) _mint(request.recipients[i], id, request.perRecipient, "");
        uint256 remainder = request.supply - allocated;
        if (remainder > 0) _mint(request.creator, id, remainder, "");
        emit TypeAllocated(id, request.creator, count, request.perRecipient, remainder);
    }

    function createType(address creator, bytes32 tenant, bytes32 requestId, string calldata tokenName,
        string calldata metadataURI, uint256 supply, address recipient) external nonReentrant returns (uint256 id) {
        require(recipient != address(0), "identity");
        id = _createDefinition(creator, tenant, requestId, tokenName, metadataURI, supply);
        _mint(recipient, id, supply, "");
    }

    function _createDefinition(address creator, bytes32 tenant, bytes32 requestId, string calldata tokenName,
        string calldata metadataURI, uint256 supply) private returns (uint256 id) {
        require(msg.sender == creator || relayers[msg.sender], "issuer");
        require(creator != address(0) && tenant != bytes32(0) && requestId != bytes32(0), "identity");
        require(supply > 0 && supply <= 1e18, "supply");
        require(bytes(tokenName).length > 0 && bytes(tokenName).length <= 320, "name");
        require(bytes(metadataURI).length > 7 && bytes(metadataURI).length <= 256, "metadata");
        bytes32 key = keccak256(abi.encode(tenant, creator, requestId));
        require(requests[key] == 0, "already issued");
        id = nextId++; requests[key] = id;
        _definitions[id] = Definition(creator, tenant, supply, tokenName, metadataURI);
        emit URI(metadataURI, id);
        emit TypeCreated(id, creator, tenant, supply, tokenName, metadataURI);
    }
}
