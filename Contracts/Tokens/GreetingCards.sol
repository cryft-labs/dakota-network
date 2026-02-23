// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
  _____            __  _             _____            __
 / ___/______ ___ / /_(_)__  ___ _  / ___/__ ________/ /__
/ (_ / __/ -_) -_) __/ / _ \/ _ `/ / /__/ _ `/ __/ _  (_-<
\___/_/  \__/\__/\__/_/_//_/\_, /  \___/\_,_/_/  \_,_/___/
                           /___/   By: CryftCreator

  Version 1.0 — Production Greeting Cards  [UPGRADEABLE]

  ┌──────────────── IPFS Metadata Layout ────────────────┐
  │                                                       │
  │  Upload directories to IPFS per card type:            │
  │                                                       │
  │  unredeemed/<CID>/                                    │
  │    1.json, 2.json, ...                                │
  │    images/  1.png, 2.png, ...                         │
  │                                                       │
  │  redeemed-birthday/<CID>/                             │
  │    1.json, 2.json, ...                                │
  │    images/  1.png, 2.png, ...                         │
  │                                                       │
  │  redeemed-holiday/<CID>/                              │
  │    1.json, 2.json, ...                                │
  │    images/  1.png, 2.png, ...                         │
  │                                                       │
  │  Each redeemed directory is passed to buy() so each   │
  │  batch atomically locks in its own card-type metadata.│
  │  Buyers prepare their personalized redeemed JSON      │
  │  files before purchasing — the CID is immutable.      │
  │                                                       │
  │  Each JSON follows the OpenSea metadata standard:     │
  │  {                                                    │
  │    "name": "Cryft Greeting Card #1",                  │
  │    "description": "...",                              │
  │    "image": "ipfs://<IMG_CID>/1.png",                 │
  │    "attributes": [                                    │
  │      {"trait_type":"Occasion","value":"Birthday"},    │
  │      {"trait_type":"Design","value":"Starlight"},     │
  │      {"trait_type":"Series","value":"Genesis"},       │
  │      {"display_type":"number",                        │
  │       "trait_type":"Card Number","value":1}           │
  │    ]                                                  │
  │  }                                                    │
  │                                                       │
  │  tokenURI() routing:                                  │
  │    Unredeemed → baseTokenURI + tokenId + ".json"      │
  │    Redeemed  → per-batch redeemed URI + tokenId       │
  └───────────────────────────────────────────────────────┘

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                       │
  │  CodeManager   → unique ID registry        (read)     │
  │  ComboStorage  → redemption verification   (read)     │
  │  This Contract → NFT mint + vault + IRedeemable     │
  │                                                       │
  │  No contract writes to another's state.               │
  │  Cross-contract calls are strictly view / read-only.  │
  └───────────────────────────────────────────────────────┘

  ┌──────────────── Purchase Flow (mint on buy) ─────────┐
  │                                                       │
  │  Setup (admin, one-time):                             │
  │    1. Upload metadata to IPFS → set baseTokenURI      │
  │    2. Store redemption codes on ComboStorage           │
  │    3. setRegisteredSupply(quantity) on this contract   │
  │                                                       │
  │  Purchase (user or sponsor):                          │
  │    4. Call buy(buyer, quantity, redeemedBaseURI)       │
  │       → Pays pricePerCard + registrationFee per card  │
  │       → Registers counter range on CodeManager        │
  │       → Mints token(s) into vault                     │
  │       → Records purchase segment (buyer + URI)        │
  │       → Redeemed metadata locked in at purchase time  │
  │       → All atomic in one transaction                 │
  │    5. Distribute codes to buyers                      │
  │                                                       │
  │  Token ID == uniqueId counter == IPFS JSON number     │
  │  Fully deterministic, no off-chain coordination.      │
  │  No per-token storage — segments + computation only.  │
  └───────────────────────────────────────────────────────┘

  ┌──────────────── Redemption Flow ─────────────────────┐
  │                                                       │
  │  Status is DERIVED from on-chain state:               │
  │                                                       │
  │    Frozen   = not yet purchased (token not minted)    │
  │             OR explicitly frozen (lost/stolen code)   │
  │    Redeemed = token exists AND not in vault           │
  │                                                       │
  │  1. Holder calls ComboStorage.redeemCode(giftCode)    │
  │     → ComboStorage READs frozen/redeemed via          │
  │       IRedeemable (view calls — no cross-contract     │
  │       state writes)                                   │
  │     → ComboStorage records verified redemption        │
  │     → Emits RedeemStatus event                        │
  │  2. Redeemer calls claimRedemption(uniqueId, recipient)│
  │     → This contract READs ComboStorage verification   │
  │     → Transfers NFT from vault to recipient           │
  │     → recipient ≠ msg.sender (gift to another wallet) │
  │     → tokenURI switches to redeemed metadata          │
  │                                                       │
  │  Admin or buyer can call setFrozen(tokenId, true)     │
  │  to block redemption of a compromised code.           │
  └───────────────────────────────────────────────────────┘

  ┌──────────────── External API Integration ────────────┐
  │                                                       │
  │  All functions below are public/external and can be   │
  │  called by any off-chain API, dApp frontend, or       │
  │  marketplace indexer.                                 │
  │                                                       │
  │  ── Read (view, no gas) ──────────────────────────── │
  │                                                       │
  │  tokenURI(tokenId) → string                           │
  │    Returns IPFS metadata URI. Unredeemed cards return  │
  │    the generic baseTokenURI; redeemed cards return     │
  │    the per-batch redeemed URI set at purchase time.    │
  │    Compatible with OpenSea / ERC721Metadata standard.  │
  │                                                       │
  │  contractURI() → string                               │
  │    Collection-level metadata for marketplaces.         │
  │                                                       │
  │  ownerOf(tokenId) → address                           │
  │    In vault (unredeemed) → returns contract address.   │
  │    Redeemed → returns recipient's wallet address.      │
  │                                                       │
  │  getCardStatus(uniqueId) → (tokenId, holder,          │
  │                              frozen, redeemed)         │
  │    Single call to get full card state. Use this to     │
  │    build UI status displays.                           │
  │                                                       │
  │  cardBuyer(tokenId) → address                         │
  │    Who originally purchased the card.                  │
  │                                                       │
  │  getUniqueIdForToken(tokenId) → string                │
  │  getTokenForUniqueId(uniqueId) → uint256              │
  │    Convert between tokenId and uniqueId.               │
  │    Computed on the fly — no storage reads.             │
  │                                                       │
  │  isUniqueIdFrozen(uniqueId) → bool                    │
  │  isUniqueIdRedeemed(uniqueId) → bool                  │
  │    Derived status checks.                              │
  │                                                       │
  │  totalSupply() → uint256                              │
  │  availableSupply() → uint256                          │
  │  pricePerCard() → uint256                             │
  │                                                       │
  │  ── Write (requires gas + payment) ───────────────── │
  │                                                       │
  │  buy(buyer, quantity, redeemedBaseURI)                 │
  │    payable — send pricePerCard * qty + registration    │
  │    fee. Mints cards into vault. Pass the IPFS CID     │
  │    directory for redeemed metadata.                    │
  │    msg.sender pays; buyer gets card attribution.       │
  │    Emits: BatchPurchased(buyer, startTokenId, qty)     │
  │    Emits: Transfer(0x0, contract, tokenId) per token   │
  │                                                       │
  │  claimRedemption(uniqueId, recipient)                  │
  │    Call after ComboStorage.redeemCode() succeeds.      │
  │    msg.sender must be the verified redeemer.           │
  │    recipient receives the NFT (≠ msg.sender).         │
  │    Emits: CardRedeemed(tokenId, uniqueId, recipient)   │
  │    Emits: Transfer(contract, recipient, tokenId)       │
  │                                                       │
  │  setFrozen(tokenId, frozen)                           │
  │    Buyer or admin freezes/unfreezes a card.            │
  │    Use when a redemption code is lost or stolen.       │
  │    Emits: TokenFrozen(tokenId, frozen)                 │
  │                                                       │
  │  ── Event Indexing ───────────────────────────────── │
  │                                                       │
  │  Listen for these events to track state changes:      │
  │    BatchPurchased(buyer, startTokenId, quantity)       │
  │      → New cards purchased. Token IDs are contiguous   │
  │        from startTokenId to startTokenId + qty - 1.    │
  │    CardRedeemed(tokenId, uniqueId, redeemer)           │
  │      → Card claimed. tokenURI() now returns redeemed   │
  │        metadata.                                       │
  │    TokenFrozen(tokenId, frozen)                        │
  │      → Card frozen/unfrozen by buyer or admin.         │
  │    Transfer(from, to, tokenId)                         │
  │      → Standard ERC721. from=0x0 is mint,              │
  │        from=contract is redemption claim.               │
  │                                                       │
  │  ── Typical API Flow ─────────────────────────────── │
  │                                                       │
  │  1. Frontend calls buy(buyer, qty, redeemedURI)       │
  │     with msg.value = (pricePerCard + regFee) * qty     │
  │  2. Backend listens for BatchPurchased event           │
  │  3. Backend distributes redemption codes to buyer      │
  │  4. Recipient enters code on frontend                  │
  │  5. Frontend calls ComboStorage.redeemCode(giftCode)   │
  │  6. Frontend calls claimRedemption(uniqueId, wallet)   │
  │  7. tokenURI(tokenId) now returns redeemed metadata    │
  │  8. Marketplace auto-refreshes via Transfer event      │
  └───────────────────────────────────────────────────────┘
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/token/ERC721/ERC721Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/token/ERC20/IERC20Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/access/OwnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/utils/StringsUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/proxy/utils/Initializable.sol";

import "./interfaces/ICodeManager.sol";
import "./interfaces/IRedeemable.sol";
import "./interfaces/IComboStorage.sol";

contract CryftGreetingCards is
    Initializable,
    OwnableUpgradeable,
    ERC721Upgradeable,
    IRedeemable
{
    using StringsUpgradeable for uint256;

    // ──────────────────── Constants ────────────────────
    uint256 public constant MAX_SUPPLY = 10000;
    uint256 public constant MAX_BATCH_SIZE = 100;

    // ──────────────────── IPFS URIs ────────────────────
    /// @notice Base URI for unredeemed cards (e.g. "ipfs://QmAbc.../")
    string public baseTokenURI;
    /// @notice Collection-level metadata for marketplaces (OpenSea contractURI)
    string private _contractURI;

    // ──────────────────── Service Addresses ────────────
    address public codeManagerAddress;
    address public comboStorageAddress;

    // ──────────────────── Supply Tracking ──────────────
    /// @dev Plain uint256 instead of Counters library — saves ~2k gas per mint
    uint256 private _totalMinted;
    uint256 public totalRedeems;

    // ──────────────────── Card Creator ─────────────────
    /// @notice The creator who registered the uniqueIds on CodeManager.
    address public cardCreator;
    /// @notice The chain identifier matching CodeManager registration.
    string public chainId;
    /// @notice Pre-computed contractIdentifier = toHexString(keccak256(creator, this, chainId)).
    string private _contractIdentifier;

    // ──────────────────── Purchase / Supply ────────────
    /// @notice Price per card in native currency (wei). Set to 0 for free claims.
    uint256 public pricePerCard;
    /// @notice Number of cards available for purchase (set by admin, must match CodeManager).
    uint256 public registeredSupply;

    // ──────────────────── Pause ─────────────────────────
    bool public paused;

    // ──────────────────── Purchase Segments ─────────────
    /// @dev Each segment records a contiguous range of tokens from one purchase.
    ///      Segment[0] covers tokens 1..endTokenId, segment[n] covers tokens
    ///      previousEnd+1..endTokenId.
    ///      redeemedBaseURI is set atomically at purchase time so different
    ///      card types (birthday, holiday, etc.) can coexist in one contract.
    struct PurchaseSegment {
        uint96  endTokenId;
        address buyer;
        string  redeemedBaseURI;
    }
    PurchaseSegment[] private _purchaseSegments;


    // ──────────────────── Explicit Freeze ───────────────
    /// @dev Admin can freeze individual tokens (e.g. lost/stolen code).
    ///      Only affects tokens already in the vault — not a substitute for
    ///      the "not yet purchased" frozen state which is derived automatically.
    mapping(uint256 => bool) private _explicitlyFrozen;

    // ──────────────────── Events ────────────────────────
    event BatchPurchased(address indexed buyer, uint256 startTokenId, uint256 quantity);
    event CardRedeemed(uint256 indexed tokenId, string uniqueId, address indexed redeemer);
    event PriceUpdated(uint256 newPrice);
    event SupplyRegistered(uint256 supply);
    event BaseURIUpdated(string newBaseURI);
    event TokenFrozen(uint256 indexed tokenId, bool frozen);

    // ──────────────────── Modifiers ─────────────────────
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    // ════════════════════════════════════════════════════
    //                  INITIALIZATION
    // ════════════════════════════════════════════════════

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the greeting card collection.
    /// @param name_          ERC721 token name
    /// @param symbol_        ERC721 token symbol
    /// @param baseURI_       IPFS base URI for unredeemed card metadata
    /// @param codeManager_   Address of the CodeManager registry contract
    /// @param comboStorage_  Address of the ComboStorage redemption service
    /// @param creator_       The wallet that registered uniqueIds on CodeManager
    /// @param chainId_       The chain identifier matching CodeManager registration
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address codeManager_,
        address comboStorage_,
        address creator_,
        string memory chainId_
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __Ownable_init();

        baseTokenURI = baseURI_;
        codeManagerAddress = codeManager_;
        comboStorageAddress = comboStorage_;
        cardCreator = creator_;
        chainId = chainId_;
        _contractIdentifier = _computeContractIdentifier(chainId_);
    }

    /// @dev Replicates CodeManager.incrementCounter's identifier algorithm exactly.
    ///      contractIdentifier = toHexString(keccak256(codeManagerAddress, address(this), chainId))
    function _computeContractIdentifier(
        string memory cid
    ) internal view returns (string memory) {
        bytes32 hash = keccak256(abi.encodePacked(codeManagerAddress, address(this), cid));
        return StringsUpgradeable.toHexString(uint256(hash), 32);
    }

    // ════════════════════════════════════════════════════
    //         SEGMENT / ID HELPERS (internal)
    // ════════════════════════════════════════════════════

    /// @dev Compute uniqueId deterministically: contractIdentifier + "-" + tokenId.
    ///      No storage needed — tokenId IS the counter by design.
    function _computeUniqueId(uint256 tokenId) internal view returns (string memory) {
        return string(abi.encodePacked(_contractIdentifier, "-", tokenId.toString()));
    }

    /// @dev Parse and validate a uniqueId, returning (valid, tokenId).
    ///      Extracts the counter (digits after the last '-'), verifies it's
    ///      within the minted range, and confirms the full string matches
    ///      the deterministic format. Returns (false, 0) on any failure.
    function _parseTokenId(string memory uniqueId) internal view returns (bool valid, uint256 tokenId) {
        bytes memory b = bytes(uniqueId);
        if (b.length == 0) return (false, 0);

        uint256 multiplier = 1;
        uint256 i = b.length;

        // Walk backward, parsing digits until we hit the '-' separator
        while (i > 0) {
            unchecked { --i; }
            if (b[i] == 0x2D) break; // '-'
            uint8 d = uint8(b[i]) - 48;
            if (d > 9) return (false, 0);
            tokenId += d * multiplier;
            multiplier *= 10;
        }

        if (tokenId == 0 || tokenId > _totalMinted) return (false, 0);

        // Verify full uniqueId matches the deterministic format
        if (keccak256(bytes(uniqueId)) != keccak256(abi.encodePacked(_contractIdentifier, "-", tokenId.toString()))) {
            return (false, 0);
        }

        return (true, tokenId);
    }

    /// @dev Look up the buyer of a token from purchase segments.
    ///      Binary search — segments are sorted by ascending endTokenId.
    function _buyerOf(uint256 tokenId) internal view returns (address) {
        uint256 idx = _segmentIndexOf(tokenId);
        if (idx < _purchaseSegments.length) return _purchaseSegments[idx].buyer;
        return address(0);
    }

    /// @dev Look up the redeemed base URI for a token from its purchase segment.
    function _redeemedBaseURIOf(uint256 tokenId) internal view returns (string memory) {
        uint256 idx = _segmentIndexOf(tokenId);
        if (idx < _purchaseSegments.length) {
            return _purchaseSegments[idx].redeemedBaseURI;
        }
        return "";
    }

    /// @dev Binary search for the segment index containing a tokenId.
    function _segmentIndexOf(uint256 tokenId) internal view returns (uint256) {
        uint256 len = _purchaseSegments.length;
        uint256 lo = 0;
        uint256 hi = len;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_purchaseSegments[mid].endTokenId < tokenId) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    // ════════════════════════════════════════════════════
    //                    PURCHASING
    // ════════════════════════════════════════════════════

    /// @notice Purchase greeting cards. Tokens are minted into the vault and
    ///         registered on CodeManager atomically at purchase time.
    ///
    ///         Prerequisite: admin must call `setRegisteredSupply(quantity)` and
    ///         store redemption codes on ComboStorage.
    ///
    ///         Registration fee (`registrationFee * quantity`) is paid to CodeManager
    ///         from the buyer's payment and forwarded to the rewards contract.
    ///
    ///         Token IDs and uniqueId counters are kept in 1:1 sync:
    ///           Token 1 → contractIdentifier-1 → baseTokenURI/1.json
    ///           Token 2 → contractIdentifier-2 → baseTokenURI/2.json
    ///           ...
    ///
    /// @param buyer    The address that owns the cards (can set greeting, receives attribution)
    /// @param quantity Number of cards to purchase (1 to MAX_BATCH_SIZE)
    /// @param _redeemedURI  IPFS base URI for redeemed metadata of this batch
    ///                      (e.g. birthday vs holiday cards).
    function buy(address buyer, uint256 quantity, string calldata _redeemedURI) external payable whenNotPaused {
        require(buyer != address(0), "Invalid buyer address");
        require(quantity > 0 && quantity <= MAX_BATCH_SIZE, "Batch: 1-100");
        require(bytes(_redeemedURI).length > 0, "Redeemed URI required");

        // Calculate registration fee from CodeManager
        uint256 registrationFee = ICodeManager(codeManagerAddress).registrationFee() * quantity;
        uint256 totalCost = (pricePerCard * quantity) + registrationFee;
        require(msg.value >= totalCost, "Insufficient payment (price + registration fee)");

        uint256 currentTotal = _totalMinted;
        require(currentTotal + quantity <= registeredSupply, "Exceeds registered supply");

        // Register the counter range on CodeManager atomically with minting.
        // This ensures uniqueIds are valid on CodeManager the moment they're minted.
        // Registration fee is forwarded to CodeManager → feeVault.
        ICodeManager(codeManagerAddress).registerUniqueIds{value: registrationFee}(
            address(this),
            chainId,
            quantity
        );

        uint256 startTokenId = currentTotal + 1;
        uint256 endTokenId = currentTotal + quantity;

        // Mint all tokens into the vault (ERC721 Transfer events emitted per token)
        for (uint256 i; i < quantity; ) {
            _mint(address(this), startTokenId + i);
            unchecked { ++i; }
        }

        // Record one purchase segment for the entire batch
        _purchaseSegments.push(PurchaseSegment({
            endTokenId: uint96(endTokenId),
            buyer: buyer,
            redeemedBaseURI: _redeemedURI
        }));

        _totalMinted = endTokenId;

        emit BatchPurchased(buyer, startTokenId, quantity);
    }

    // ════════════════════════════════════════════════════
    //                    REDEMPTION
    // ════════════════════════════════════════════════════

    /// @notice Claim a verified redemption. Call this after ComboStorage
    ///         has recorded a successful code match for the uniqueId.
    ///
    ///         Flow:
    ///         1. ComboStorage.redeemCode() verifies code → records result
    ///         2. This function reads ComboStorage state to confirm (view call)
    ///         3. NFT is transferred from vault to the provided recipient
    ///         4. ownerOf(tokenId) now returns recipient (on-chain ownership)
    ///         5. tokenURI() now returns the batch's redeemed URI
    ///
    ///         The recipient is NOT msg.sender — this is a gift flow where the
    ///         redeemer specifies which wallet receives the NFT.
    ///
    /// @param uniqueId  The unique ID whose redemption was verified by ComboStorage
    /// @param recipient The wallet address that will receive the NFT (cannot be msg.sender)
    function claimRedemption(string calldata uniqueId, address recipient) external whenNotPaused {
        // Read ComboStorage verification state (view call — no cross-contract write)
        IComboStorage combo = IComboStorage(comboStorageAddress);
        require(combo.isRedemptionVerified(uniqueId), "Not verified by ComboStorage");

        address redeemer = combo.redemptionRedeemer(uniqueId);
        require(msg.sender == redeemer, "Not the verified redeemer");

        require(recipient != address(0), "Zero recipient");
        require(recipient != msg.sender, "Recipient cannot be caller");

        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        require(valid, "Unknown uniqueId");
        require(ownerOf(tokenId) == address(this), "Not in vault");

        unchecked { ++totalRedeems; }

        // Transfer NFT from vault to the provided recipient
        _transfer(address(this), recipient, tokenId);

        emit CardRedeemed(tokenId, uniqueId, recipient);
    }

    // ════════════════════════════════════════════════════
    //        IRedeemable (gift contract authority)
    // ════════════════════════════════════════════════════

    /// @inheritdoc IRedeemable
    /// @dev Frozen when:
    ///      1. UniqueId is invalid or token not yet minted (not purchased), OR
    ///      2. Token is in the vault but explicitly frozen by admin
    ///         (e.g. lost/stolen redemption code).
    ///      Unfrozen (active) = token is in the vault and not explicitly frozen.
    function isUniqueIdFrozen(string memory uniqueId)
        public view override returns (bool)
    {
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        if (!valid || !_exists(tokenId)) return true;
        return _explicitlyFrozen[tokenId];
    }

    /// @inheritdoc IRedeemable
    /// @dev Redeemed = the token exists but is no longer held by the vault.
    ///      Once transferred out, it can never return (enforced by _beforeTokenTransfer).
    function isUniqueIdRedeemed(string memory uniqueId)
        public view override returns (bool)
    {
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        if (!valid || !_exists(tokenId)) return false;
        return ownerOf(tokenId) != address(this);
    }

    /// @inheritdoc IRedeemable
    /// @dev GreetingCards uses per-batch IPFS URIs as content, not per-UID content IDs.
    ///      Returns empty string since content is managed via tokenURI / batch metadata.
    function getUniqueIdContent(string memory)
        public pure override returns (string memory)
    {
        return "";
    }

    /// @inheritdoc IRedeemable
    /// @dev GreetingCards derives frozen from explicit admin flags + vault state.
    ///      Only CodeManager (acting as Pente router) can call this.
    function setFrozen(string memory uniqueId, bool frozen) external override {
        require(msg.sender == codeManagerAddress, "Only CodeManager");
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        require(valid && _exists(tokenId), "Invalid uniqueId");
        require(ownerOf(tokenId) == address(this), "Not in vault");
        _explicitlyFrozen[tokenId] = frozen;
        emit TokenFrozen(tokenId, frozen);
    }

    /// @inheritdoc IRedeemable
    /// @dev GreetingCards uses batch-level IPFS URIs, not per-UID content.
    ///      This is a no-op; content is managed via setRedeemedBaseURI / setBatchRedeemedURI.
    function setContent(string memory, string memory) external view override {
        require(msg.sender == codeManagerAddress, "Only CodeManager");
        // No per-UID content in GreetingCards — content is batch-level IPFS metadata.
    }

    /// @inheritdoc IRedeemable
    /// @dev Records redemption by transferring the NFT from vault to redeemer.
    ///      Only CodeManager (acting as Pente router) can call this.
    ///      Reverts if already redeemed, frozen, or invalid — causing the
    ///      Pente transition to roll back atomically.
    function recordRedemption(string memory uniqueId, address redeemer) external override {
        require(msg.sender == codeManagerAddress, "Only CodeManager");
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        require(valid && _exists(tokenId), "Invalid uniqueId");
        require(ownerOf(tokenId) == address(this), "Not in vault");
        require(!_explicitlyFrozen[tokenId], "Token is frozen");

        unchecked { ++totalRedeems; }
        _transfer(address(this), redeemer, tokenId);
        emit CardRedeemed(tokenId, uniqueId, redeemer);
    }

    // ════════════════════════════════════════════════════
    //              TOKEN URI (IPFS routing)
    // ════════════════════════════════════════════════════

    /// @notice Returns the metadata URI for a token.
    ///         Unredeemed: baseTokenURI + tokenId + ".json"
    ///         Redeemed:   per-batch redeemed URI + tokenId + ".json"
    ///
    ///         Example:
    ///           Token 42 unredeemed → "ipfs://QmAbc.../42.json"
    ///           Token 42 redeemed   → "ipfs://QmXyz.../42.json"
    function tokenURI(uint256 tokenId)
        public view override returns (string memory)
    {
        require(_exists(tokenId), "Nonexistent token");

        // Redeemed = no longer in vault
        bool redeemed = ownerOf(tokenId) != address(this);

        if (redeemed) {
            string memory baseURI = _redeemedBaseURIOf(tokenId);
            if (bytes(baseURI).length == 0) return "";
            return string(abi.encodePacked(baseURI, tokenId.toString(), ".json"));
        }

        // Unredeemed — generic card front
        if (bytes(baseTokenURI).length == 0) return "";
        return string(abi.encodePacked(baseTokenURI, tokenId.toString(), ".json"));
    }

    /// @notice Collection-level metadata for OpenSea and other marketplaces.
    ///         Should point to a JSON: { "name", "description", "image", "external_link" }
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    // ════════════════════════════════════════════════════
    //                  VIEW FUNCTIONS
    // ════════════════════════════════════════════════════

    /// @notice Total number of minted tokens.
    function totalSupply() public view returns (uint256) {
        return _totalMinted;
    }

    /// @notice Get the uniqueId for a given token (computed, no storage).
    function getUniqueIdForToken(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "Nonexistent token");
        return _computeUniqueId(tokenId);
    }

    /// @notice Get the token ID for a given uniqueId (parsed, no storage).
    function getTokenForUniqueId(string calldata uniqueId) external view returns (uint256) {
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        require(valid, "Unknown uniqueId");
        return tokenId;
    }

    /// @notice Get the buyer of a token (looked up from purchase segments).
    function cardBuyer(uint256 tokenId) external view returns (address) {
        return _buyerOf(tokenId);
    }

    /// @notice Get the original creator of this card collection.
    function getCardCreator() external view returns (address) {
        return cardCreator;
    }

    /// @notice Number of cards registered but not yet purchased.
    function availableSupply() external view returns (uint256) {
        return registeredSupply - _totalMinted;
    }

    /// @notice Validate a uniqueId against the CodeManager registry (read-only).
    function isValidUniqueId(string calldata uniqueId) external view returns (bool) {
        return ICodeManager(codeManagerAddress).validateUniqueId(uniqueId);
    }

    /// @notice Fetch full uniqueId details from CodeManager (read-only).
    function getDetailsFromCodeManager(string calldata uniqueId)
        external view
        returns (address giftContract, string memory chainId_, uint256 counter)
    {
        return ICodeManager(codeManagerAddress).getUniqueIdDetails(uniqueId);
    }

    /// @notice Get the full status of a card in a single call.
    /// @return tokenId      The ERC721 token ID (0 if not purchased)
    /// @return nftHolder    The current ERC721 holder (vault before redemption, recipient after)
    /// @return frozen       Derived: not yet purchased (no token exists)
    /// @return redeemed     Derived: token exists and no longer in vault
    function getCardStatus(string calldata uniqueId)
        external view
        returns (
            uint256 tokenId,
            address nftHolder,
            bool frozen,
            bool redeemed
        )
    {
        bool valid;
        (valid, tokenId) = _parseTokenId(uniqueId);
        frozen = !valid || !_exists(tokenId);
        redeemed = valid && _exists(tokenId) && ownerOf(tokenId) != address(this);

        if (valid && _exists(tokenId)) {
            nftHolder = ownerOf(tokenId);
        }
    }

    // ════════════════════════════════════════════════════
    //                ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════

    function setBaseTokenURI(string calldata uri) external onlyOwner {
        baseTokenURI = uri;
        emit BaseURIUpdated(uri);
    }

    function setContractURI(string calldata uri) external onlyOwner {
        _contractURI = uri;
    }

    function setCodeManagerAddress(address addr) external onlyOwner {
        require(addr != address(0), "Zero address");
        codeManagerAddress = addr;
    }

    function setComboStorageAddress(address addr) external onlyOwner {
        require(addr != address(0), "Zero address");
        comboStorageAddress = addr;
    }

    function setPricePerCard(uint256 price) external onlyOwner {
        pricePerCard = price;
        emit PriceUpdated(price);
    }

    /// @notice Register the number of cards available for purchase.
    ///         Must match the quantity registered on CodeManager.
    function setRegisteredSupply(uint256 supply) external onlyOwner {
        require(supply >= _totalMinted, "Below already minted");
        require(supply <= MAX_SUPPLY, "Exceeds MAX_SUPPLY");
        registeredSupply = supply;
        emit SupplyRegistered(supply);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /// @notice Freeze or unfreeze a token in the vault.
    ///         Use this when a redemption code is lost or stolen to prevent
    ///         unauthorized redemption via ComboStorage. The buyer or the
    ///         contract owner can freeze/unfreeze it.
    /// @param tokenId  The token to freeze/unfreeze
    /// @param frozen   true = frozen (blocked), false = active (redeemable)
    function setFrozen(uint256 tokenId, bool frozen) external {
        require(_exists(tokenId), "Nonexistent token");
        require(
            msg.sender == _buyerOf(tokenId) || msg.sender == owner(),
            "Only buyer or owner"
        );
        require(ownerOf(tokenId) == address(this), "Not in vault");
        _explicitlyFrozen[tokenId] = frozen;
        emit TokenFrozen(tokenId, frozen);
    }

    // ════════════════════════════════════════════════════
    //               WITHDRAW (vault)
    // ════════════════════════════════════════════════════

    /// @notice Withdraw native currency from the contract.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance");
        (bool ok, ) = payable(owner()).call{value: balance}("");
        require(ok, "Transfer failed");
    }

    /// @notice Withdraw ERC20 tokens accidentally sent to the contract.
    function withdrawTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero address");
        IERC20Upgradeable(token).transfer(owner(), amount);
    }

    /// @notice Accept ETH payments.
    receive() external payable {}

    // ════════════════════════════════════════════════════
    //                 TRANSFER GUARD
    // ════════════════════════════════════════════════════

    /// @dev Prevent tokens from being transferred back into the vault.
    ///      Minting (from == address(0)) is allowed, all other transfers TO
    ///      address(this) are blocked. This ensures redeemed status (derived
    ///      from "not in vault") can never be falsified.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal override {
        require(
            to != address(this) || from == address(0),
            "Cannot transfer to vault"
        );
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }
}
