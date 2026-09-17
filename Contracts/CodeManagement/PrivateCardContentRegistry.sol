// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

interface IPrivateContentAuthority {
    function ADMIN() external view returns (address);
    function AUTHORIZED() external view returns (address);
}

/// @notice Confidential content bindings inside the same Pente group as ComboStorage.
/// @dev Privacy-group operators can read this state. Solidity visibility is NOT
/// a confidentiality boundary. Never expose the Pente RPC to wallet clients.
/// The service must authenticate viewers and verify live public NFT ownership.
contract PrivateCardContentRegistry {
    struct Entry {
        bytes32 tenant;
        bytes32 uid;
        bytes32 key;
        bytes32 context;
        string uri;
    }
    struct Content {
        bytes32 key;
        bytes32 context;
        string uri;
    }
    IPrivateContentAuthority public authority;
    uint256 public chainId;
    address public card;
    bool private initialized;
    mapping(bytes32 => Content) private contents;

    constructor() { initialized = true; }

    function initialize(address authority_, uint256 chainId_, address card_) external {
        require(!initialized, "Already initialized");
        require(authority_.code.length != 0 && chainId_ != 0 && card_ != address(0), "Invalid configuration");
        require(IPrivateContentAuthority(authority_).ADMIN() != address(0), "Invalid authority");
        initialized = true;
        authority = IPrivateContentAuthority(authority_);
        chainId = chainId_;
        card = card_;
    }

    modifier onlyService() {
        require(msg.sender == authority.ADMIN() || msg.sender == authority.AUTHORIZED(), "Service required");
        _;
    }

    function binding(bytes32 tenant, bytes32 uid) public view returns (bytes32) {
        return keccak256(abi.encode(tenant, chainId, card, uid));
    }

    /// @dev Immutable, idempotent bindings. No per-code delete on redemption.
    /// The trusted writer verifies confirmed issuance/UID assignments first.
    function storeBatch(Entry[] calldata entries) external onlyService {
        require(entries.length > 0 && entries.length <= 25, "Batch size must be 1-25");
        for (uint256 i; i < entries.length; ++i) {
            Entry calldata e = entries[i];
            require(e.tenant != bytes32(0) && e.uid != bytes32(0) && e.key != bytes32(0) && e.context != bytes32(0), "Invalid binding");
            require(bytes(e.uri).length > 7 && bytes(e.uri).length <= 160, "Invalid URI");
            Content storage previous = contents[binding(e.tenant, e.uid)];
            if (previous.key != bytes32(0)) {
                require(previous.key == e.key && previous.context == e.context && keccak256(bytes(previous.uri)) == keccak256(bytes(e.uri)), "Content already bound");
            } else {
                previous.key = e.key;
                previous.context = e.context;
                previous.uri = e.uri;
            }
        }
    }

    /// @dev RPC identity is service-controlled, not proof of an end user's wallet.
    function getContent(bytes32 tenant, bytes32 uid) external view onlyService returns (Content memory) {
        Content memory value = contents[binding(tenant, uid)];
        require(value.key != bytes32(0), "Content not found");
        return value;
    }
}
