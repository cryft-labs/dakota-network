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

  ┌──────────────── IPFS Metadata Layout ─────────────────┐
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

  ┌──────────────── Contract Architecture ──────────────────────────┐
  │                                                                 │
  │  CodeManager → unique ID registry + Pente router                │
  │  This Contract → NFT mint + vault + IRedeemable                 │
  │  PrivateComboStorage → hash storage + private execution state   │
  │                                                                 │
  │  Redemption is atomic: ComboStorage (Pente private)             │
  │  verifies the code hash, checks private active state,           │
  │  then emits PenteExternalCall → CodeManager validates           │
  │  public active status and routes to this contract's             │
  │  recordRedemption() → NFT transfers from vault to               │
  │  redeemer. If this contract reverts (e.g. already               │
  │  redeemed), the entire Pente transition rolls back —            │
  │  including the private state updates in ComboStorage.           │
  │                                                                 │
  │  Active-state authority lives in PrivateComboStorage            │
  │  for execution-time decisions. Only UIDs with mirroring         │
  │  enabled propagate state changes to CodeManager publicly.       │
  │  This contract reads CodeManager's public mirror via            │
  │  isUniqueIdActive() for view queries and getCardStatus().       │
  └─────────────────────────────────────────────────────────────────┘

  ┌──────────────── Purchase Flow (mint on buy) ────────────────────┐
  │                                                                 │
  │  Setup (admin, one-time):                                       │
  │    1. Upload metadata to IPFS → set baseTokenURI                │
  │    2. setMaxSaleSupply(quantity) on this contract               │
  │                                                                 │
  │  Purchase (user or sponsor):                                    │
  │    3. Call buy(buyer, quantity, redeemedBaseURI)                │
  │       → Pays pricePerCard + registrationFee per card            │
  │       → Registers counter range on CodeManager                  │
  │       → Mints token(s) into vault                               │
  │       → Records purchase segment (buyer + URI)                  │
  │       → Redeemed metadata locked in at purchase time            │
  │       → All atomic in one transaction                           │
  │                                                                 │
  │  Post-purchase (admin):                                         │
  │    4. Whitelist contract identifier on ComboStorage             │
  │    5. Store codes via storeDataBatch(StoreBatchRequest)         │
  │       (uniqueIds must exist on CodeManager first)               │
  │       mirrorStatuses[] controls per-UID public visibility       │
  │    6. Distribute PINs + codes to buyers                         │
  │                                                                 │
  │  Token ID == uniqueId counter == IPFS JSON number               │
  │  Fully deterministic, no off-chain coordination.                │
  │  No per-token storage — segments + computation only.            │
  └─────────────────────────────────────────────────────────────────┘

  ┌──────────────── Redemption Flow ────────────────────────────────┐
  │                                                                 │
  │  Status is DERIVED from on-chain state:                         │
  │                                                                 │
  │    Active   = CodeManager says UID is active (public mirror)    │
  │    Redeemed = token exists AND not in vault                     │
  │                                                                 │
  │  Note: if a UID's mirror is disabled in ComboStorage,           │
  │  CodeManager returns DEFAULT_ACTIVE_STATE (active). The         │
  │  private execution state in ComboStorage is authoritative       │
  │  for redemption routing — inactive UIDs are blocked there       │
  │  before PenteExternalCall is emitted.                           │
  │                                                                 │
  │  1. ComboStorage.redeemCodeBatch(pins, hashes, redeemers)       │
  │     → Verifies code hash in private Pente state                 │
  │     → Checks private active state (blocks inactive/redeemed)    │
  │     → Deletes hash entry + marks UID redeemed privately         │
  │     → Emits PenteExternalCall (atomic) per valid entry          │
  │  2. CodeManager.recordRedemption(uniqueId, redeemer)            │
  │     → Resolves uniqueId → gift contract                         │
  │     → Verifies public active state mirror                       │
  │     → Calls this contract's recordRedemption()                  │
  │     → Marks UID terminally redeemed on CodeManager              │
  │  3. recordRedemption(uniqueId, redeemer)                        │
  │     → Validates: in vault                                       │
  │     → Transfers NFT from vault to redeemer                      │
  │     → tokenURI switches to redeemed metadata                    │
  │     → If reverts → entire Pente transition rolls back           │
  │       (private deletes + redeemed marks are undone)             │
  │                                                                 │
  │  Redeemer address is supplied directly — NOT assumed            │
  │  to be msg.sender. Supports meta-transactions and               │
  │  user-specified recipient wallets.                              │
  │                                                                 │
  │  Active status overrides live in CodeManager (public            │
  │  mirror) and PrivateComboStorage (execution authority).         │
  └─────────────────────────────────────────────────────────────────┘

  ┌──────────────── External API Integration ───────────────────────┐
  │                                                                 │
  │  All functions below are public/external and can be             │
  │  called by any off-chain API, dApp frontend, or                 │
  │  marketplace indexer.                                           │
  │                                                                 │
  │  ── Read (view, no gas) ──────────────────────────────────────  │
  │                                                                 │
  │  tokenURI(tokenId) → string                                     │
  │    Returns IPFS metadata URI. Unredeemed cards return           │
  │    the generic baseTokenURI; redeemed cards return              │
  │    the per-batch redeemed URI set at purchase time.             │
  │    Compatible with OpenSea / ERC721Metadata standard.           │
  │                                                                 │
  │  contractURI() → string                                         │
  │    Collection-level metadata for marketplaces.                  │
  │                                                                 │
  │  ownerOf(tokenId) → address                                     │
  │    In vault (unredeemed) → returns contract address.            │
  │    Redeemed → returns recipient's wallet address.               │
  │                                                                 │
  │  getCardStatus(uniqueId)                                        │
  │    → (tokenId, holder, frozen, redeemed)                        │
  │    Single call to get full card state. frozen reads             │
  │    the CodeManager public mirror; if mirror is disabled         │
  │    for this UID, it will show active by default.                │
  │                                                                 │
  │  cardBuyer(tokenId) → address                                   │
  │    Who originally purchased the card.                           │
  │                                                                 │
  │  getUniqueIdForToken(tokenId) → string                          │
  │  getTokenForUniqueId(uniqueId) → uint256                        │
  │    Convert between tokenId and uniqueId.                        │
  │    Computed on the fly — no storage reads.                      │
  │                                                                 │
  │  isUniqueIdFrozen(uniqueId) → bool                              │
  │  isUniqueIdRedeemed(uniqueId) → bool                            │
  │    Derived from CodeManager public state.                       │
  │    Note: frozen reflects public mirror only — UIDs with         │
  │    mirroring disabled always appear active here.                │
  │                                                                 │
  │  totalSupply() → uint256                                        │
  │  availableSupply() → uint256                                    │
  │  pricePerCard() → uint256                                       │
  │                                                                 │
  │  ── Write (requires gas + payment) ──────────────────────────   │
  │                                                                 │
  │  buy(buyer, quantity, redeemedBaseURI)                          │
  │    payable — send pricePerCard * qty + registration             │
  │    fee. Mints cards into vault. Pass the IPFS CID               │
  │    directory for redeemed metadata.                             │
  │    msg.sender pays; buyer gets card attribution.                │
  │    Emits: BatchPurchased(buyer, startTokenId, qty)              │
  │    Emits: Transfer(0x0, contract, tokenId) per token            │
  │                                                                 │
  │  recordRedemption(uniqueId, redeemer)                           │
  │    Called by CodeManager after private prechecks.               │
  │    Transfers the NFT out of the vault to redeemer.              │
  │    Emits: CardRedeemed(tokenId, uniqueId, redeemer)             │
  │                                                                 │
  │  ── Event Indexing ──────────────────────────────────────────   │
  │                                                                 │
  │  Listen for these events to track state changes:                │
  │    BatchPurchased(buyer, startTokenId, quantity)                │
  │      → New cards purchased. Token IDs are contiguous            │
  │        from startTokenId to startTokenId + qty - 1.             │
  │    CardRedeemed(tokenId, uniqueId, redeemer)                    │
  │      → Card claimed. tokenURI() now returns redeemed            │
  │        metadata.                                                │
  │    Transfer(from, to, tokenId)                                  │
  │      → Standard ERC721. from=0x0 is mint,                       │
  │        from=contract is redemption claim.                       │
  │                                                                 │
  │  ── Typical API Flow ────────────────────────────────────────   │
  │                                                                 │
  │  1. Frontend calls buy(buyer, qty, redeemedURI)                 │
  │     with msg.value = (pricePerCard + regFee) * qty              │
  │  2. Backend listens for BatchPurchased event                    │
  │  3. Backend stores codes via ComboStorage.storeDataBatch()      │
  │     with mirrorStatuses controlling public visibility           │
  │  4. Backend distributes PINs + codes to buyers                  │
  │  5. Recipient enters PIN + code on frontend                     │
  │  6. Frontend calls ComboStorage.redeemCodeBatch(pins,           │
  │     hashes, redeemers) inside Pente privacy group               │
  │  7. PenteExternalCall → CodeManager →                           │
  │     recordRedemption() transfers NFT to redeemer                │
  │  8. tokenURI(tokenId) now returns redeemed metadata             │
  │  9. Marketplace auto-refreshes via Transfer event               │
  └─────────────────────────────────────────────────────────────────┘
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.2.0/contracts/token/ERC721/ERC721Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.2.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.2.0/contracts/access/OwnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.2.0/contracts/proxy/utils/Initializable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.2.0/contracts/utils/ReentrancyGuardUpgradeable.sol";

import "./Interfaces/ICodeManager.sol";
import "./Interfaces/IRedeemable.sol";

contract CryftGreetingCards is
    Initializable,
    OwnableUpgradeable,
    ERC721Upgradeable,
    ReentrancyGuardUpgradeable,
    IRedeemable
{
    using Strings for uint256;

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

    // ──────────────────── Supply Tracking ──────────────
    /// @dev Plain uint256 instead of Counters library — saves ~2k gas per mint
    uint256 private _totalMinted;
    uint256 public totalRedeems;

    // ──────────────────── Chain & ID ───────────────────
    /// @notice The chain identifier matching CodeManager registration.
    string public chainId;
    /// @notice Pre-computed contractIdentifier = toHexString(keccak256(codeManagerAddress, this, chainId)).
    string private _contractIdentifier;

    // ──────────────────── Purchase / Supply ────────────
    /// @notice Price per card in native currency (wei). Set to 0 for free claims.
    uint256 public pricePerCard;
    /// @notice Maximum number of cards available for purchase (set by admin).
    uint256 public maxSaleSupply;

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


    // ──────────────────── Events ────────────────────────
    event BatchPurchased(address indexed buyer, uint256 startTokenId, uint256 quantity);
    event CardRedeemed(uint256 indexed tokenId, string uniqueId, address indexed redeemer);
    event PriceUpdated(uint256 newPrice);
    event SupplyRegistered(uint256 supply);
    event BaseURIUpdated(string newBaseURI);

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
    /// @param chainId_       The chain identifier matching CodeManager registration
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address codeManager_,
        string memory chainId_
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        baseTokenURI = baseURI_;
        codeManagerAddress = codeManager_;
        chainId = chainId_;
        _contractIdentifier = _computeContractIdentifier(chainId_);
    }

    /// @dev Replicates CodeManager.incrementCounter's identifier algorithm exactly.
    ///      contractIdentifier = toHexString(keccak256(codeManagerAddress, address(this), chainId))
    function _computeContractIdentifier(
        string memory cid
    ) internal view returns (string memory) {
        bytes32 hash = keccak256(abi.encodePacked(codeManagerAddress, address(this), cid));
        return Strings.toHexString(uint256(hash), 32);
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
    ///         Prerequisite: admin must call `setMaxSaleSupply(quantity)` and
    ///         store redemption codes on ComboStorage.
    ///
    ///         Registration on CodeManager happens atomically at purchase time.
    ///         After registration, the CodeManager counter is verified against
    ///         the expected value to detect any counter drift.
    ///
    ///         Token IDs and uniqueId counters are kept in 1:1 sync:
    ///           Token 1 → contractIdentifier-1 → baseTokenURI/1.json
    ///           Token 2 → contractIdentifier-2 → baseTokenURI/2.json
    ///           ...
    ///
    /// @param buyer    The address that owns the cards (can set greeting, receives attribution)
    /// @param quantity Number of cards to purchase (1 to MAX_BATCH_SIZE)
    /// @param redeemedURI   IPFS base URI for redeemed metadata of this batch
    ///                      (e.g. birthday vs holiday cards).
    function buy(address buyer, uint256 quantity, string calldata redeemedURI) external payable whenNotPaused nonReentrant {
        require(buyer != address(0), "Invalid buyer address");
        require(quantity > 0 && quantity <= MAX_BATCH_SIZE, "Batch: 1-100");
        require(bytes(redeemedURI).length > 0, "Redeemed URI required");

        // Calculate registration fee from CodeManager
        uint256 registrationFee = ICodeManager(codeManagerAddress).registrationFee() * quantity;
        uint256 totalCost = (pricePerCard * quantity) + registrationFee;
        require(msg.value == totalCost, "Payment must equal price + registration fee");

        uint256 currentTotal = _totalMinted;
        require(currentTotal + quantity <= maxSaleSupply, "Exceeds max sale supply");

        // Verify CodeManager counter matches our internal mint count before registration.
        // This ensures no external registration has drifted the counter out of sync.
        (, uint256 counterBefore) = ICodeManager(codeManagerAddress).getIdentifierCounter(
            address(this),
            chainId
        );
        require(counterBefore == currentTotal, "Counter drift: CodeManager out of sync");

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
            redeemedBaseURI: redeemedURI
        }));

        _totalMinted = endTokenId;

        emit BatchPurchased(buyer, startTokenId, quantity);
    }

    // ════════════════════════════════════════════════════
    //        IRedeemable (gift contract authority)
    // ════════════════════════════════════════════════════

    /// @notice Returns the current CodeManager-owned active state for a UID.
    function isUniqueIdActive(string memory uniqueId) public view returns (bool) {
        return ICodeManager(codeManagerAddress).isUniqueIdActive(uniqueId);
    }

    /// @notice Backward-compatible alias for consumers that still expect a frozen flag.
    ///         Frozen is simply the inverse of CodeManager's active state.
    function isUniqueIdFrozen(string memory uniqueId) public view returns (bool) {
        return !isUniqueIdActive(uniqueId);
    }

    /// @inheritdoc IRedeemable
    /// @dev Redeemed = the token exists but is no longer held by the vault.
    ///      Once transferred out, it can never return (enforced by _update).
    function isUniqueIdRedeemed(string memory uniqueId)
        public view override returns (bool)
    {
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        if (!valid || _ownerOf(tokenId) == address(0)) return false;
        return ownerOf(tokenId) != address(this);
    }

    /// @inheritdoc IRedeemable
    /// @dev Records redemption by transferring the NFT from vault to redeemer.
    ///      Only CodeManager (acting as Pente router) can call this.
    ///      Reverts if already redeemed or invalid — causing the
    ///      Pente transition to roll back atomically.
    function recordRedemption(string memory uniqueId, address redeemer) external override {
        require(msg.sender == codeManagerAddress, "Only CodeManager");
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        require(valid && _ownerOf(tokenId) != address(0), "Invalid uniqueId");
        require(ownerOf(tokenId) == address(this), "Not in vault");

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
        require(_ownerOf(tokenId) != address(0), "Nonexistent token");

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
        require(_ownerOf(tokenId) != address(0), "Nonexistent token");
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

    /// @notice Number of cards still available for purchase.
    function availableSupply() external view returns (uint256) {
        return maxSaleSupply - _totalMinted;
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
    /// @return frozen       Inverse of CodeManager's active state
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
        frozen = !ICodeManager(codeManagerAddress).isUniqueIdActive(uniqueId);
        redeemed = valid && _ownerOf(tokenId) != address(0) && ownerOf(tokenId) != address(this);

        if (valid && _ownerOf(tokenId) != address(0)) {
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
        require(_totalMinted == 0, "Cannot change manager after minting");
        codeManagerAddress = addr;
        _contractIdentifier = _computeContractIdentifier(chainId);
    }

    function setPricePerCard(uint256 price) external onlyOwner {
        pricePerCard = price;
        emit PriceUpdated(price);
    }

    /// @notice Set the maximum number of cards available for purchase.
    function setMaxSaleSupply(uint256 supply) external onlyOwner {
        require(supply >= _totalMinted, "Below already minted");
        require(supply <= MAX_SUPPLY, "Exceeds MAX_SUPPLY");
        maxSaleSupply = supply;
        emit SupplyRegistered(supply);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
    }

    // ════════════════════════════════════════════════════
    //               WITHDRAW (vault)
    // ════════════════════════════════════════════════════

    /// @notice Withdraw native currency from the contract.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance");
        (bool ok, ) = payable(owner()).call{value: balance}("");
        require(ok, "ETH transfer failed");
    }

    /// @notice Withdraw ERC20 tokens accidentally sent to the contract.
    function withdrawTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero address");
        bool ok = IERC20(token).transfer(owner(), amount);
        require(ok, "ERC20 transfer failed");
    }

    /// @notice Accept ETH payments.
    receive() external payable {}

    // ════════════════════════════════════════════════════
    //                 TRANSFER GUARD
    // ════════════════════════════════════════════════════

    /// @dev Prevent tokens from being transferred back into the vault.
    ///      Minting (_ownerOf returns address(0)) is allowed, all other transfers
    ///      TO address(this) are blocked. This ensures redeemed status (derived
    ///      from "not in vault") can never be falsified.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(this)) {
            require(_ownerOf(tokenId) == address(0), "Cannot transfer to vault");
        }
        return super._update(to, tokenId, auth);
    }
}
