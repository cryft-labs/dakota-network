// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   ___  ____           __       ______           __       ______
  / _ \/ __(_)  _____ / /____  / ___/__  __ _  / /  ___ / __/ /____  _______ ____ ____
 / ___/ _// / |/ / _ `/ __/ -_) /__/ _ \/  ' \/ _ \/ _ \\ \/ __/ _ \/ __/ _ `/ _ `/ -_)
/_/  /_/ /_/|___/\_,_/\__/\__/\___/\___/_/_/_/_.__/\___/___/\__/\___/_/ \_,_/\_, /\__/
                                                                            /___/ By: CryftCreator

  Version 1.0 — Private Combo Storage  [PENTE PRIVACY GROUP]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  DEPLOYED INSIDE A PALADIN PENTE PRIVACY GROUP.      │
  │  All state is private to privacy group members.      │
  │                                                      │
  │  Stores hash+salt pairs (secret representations of   │
  │  redeemable codes). Verifies submitted codes via     │
  │  hash comparison. Manages per-UID state (frozen,     │
  │  redeemed, content) privately.                       │
  │                                                      │
  │  On state changes, emits PenteExternalCall events    │
  │  that atomically route through CodeManager to the    │
  │  gift contract on the public chain.                  │
  │                                                      │
  │  PIN-based O(1) bucket lookup. No cleartext code     │
  │  ever touches the chain.                             │
  │                                                      │
  │  Patent: U.S. App. Ser. No. 18/930,857               │
  └──────────────────────────────────────────────────────┘
*/

import "./interfaces/ICodeManager.sol";
import "./interfaces/IComboStorage.sol";

contract PrivateComboStorage is IComboStorage {
    // ── Pente External Call ───────────────────────────────
    //
    //    The PenteExternalCall event is the mechanism by which private
    //    state transitions in this Pente privacy group atomically trigger
    //    public-chain transactions via CodeManager. When Pente processes
    //    the endorsed transition, it decodes this event and submits the
    //    encoded function call to the CodeManager contract on the base
    //    ledger.
    //
    event PenteExternalCall(
        address indexed contractAddress,
        bytes encodedCall
    );

    // ── State ─────────────────────────────────────────────

    /// @dev The CodeManager address on the public chain.
    ///      PenteExternalCall events target this address.
    ///      Hard-code before deployment to match the deployed CodeManager proxy.
    address public constant codeManager = address(0x0000000000000000000000000000000000000000);

    /// @dev Admin address — deployer of this private contract within the privacy group.
    address public admin;

    /// @dev Authorized callers within the privacy group (e.g., redemption service).
    mapping(address => bool) public isAuthorized;

    /// @dev Per-code metadata stored privately.
    struct CodeMetadata {
        string uniqueId;
        bool exists;
        bool frozen;
        bool redeemed;
        string contentId;
    }

    /// @dev Maximum number of hash/uniqueId entries allowed per PIN slot.
    uint256 public constant MAX_PER_PIN = 32;

    /// @dev PIN → codeHash → code metadata. The PIN acts as a bucket
    ///      index for efficient O(1) lookup. The codeHash is keccak256(giftCode)
    ///      where giftCode = pin + code, computed off-chain.
    mapping(string => mapping(bytes32 => CodeMetadata)) public pinToHash;

    /// @dev Tracks how many hashes are currently stored under each PIN.
    mapping(string => uint256) public pinSlotCount;

    /// @dev Redemption records (private tracking within privacy group).
    mapping(string => bool) public override isRedemptionVerified;
    mapping(string => address) public override redemptionRedeemer;

    /// @dev Per-UID private state tracking.
    mapping(string => bool) private _isFrozen;
    mapping(string => bool) private _isRedeemed;
    mapping(string => string) private _contentId;

    // ── Events ────────────────────────────────────────────

    event DataStoredStatus(
        string uniqueId,
        bytes32 codeHash,
        bool status
    );

    event RedeemStatus(
        string uniqueId,
        address redeemer,
        bool status
    );

    event FrozenStatusUpdated(string uniqueId, bool frozen);
    event ContentUpdated(string uniqueId, string contentId);
    event AuthorizationUpdated(address indexed account, bool status);

    // ── Modifiers ─────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "Caller is not admin");
        _;
    }

    modifier onlyAuthorizedOrAdmin() {
        require(
            msg.sender == admin || isAuthorized[msg.sender],
            "Caller is not authorized"
        );
        _;
    }

    // ── Constructor ───────────────────────────────────────

    constructor() {
        admin = msg.sender;
    }

    // ── Authorization ─────────────────────────────────────

    function authorize(address account) external onlyAdmin {
        require(account != address(0), "Cannot authorize zero address");
        isAuthorized[account] = true;
        emit AuthorizationUpdated(account, true);
    }

    function deauthorize(address account) external onlyAdmin {
        isAuthorized[account] = false;
        emit AuthorizationUpdated(account, false);
    }

    // ── IComboStorage View Functions ──────────────────────

    /// @inheritdoc IComboStorage
    function isFrozen(string memory uniqueId) external view override returns (bool) {
        return _isFrozen[uniqueId];
    }

    /// @inheritdoc IComboStorage
    function isRedeemed(string memory uniqueId) external view override returns (bool) {
        return _isRedeemed[uniqueId];
    }

    /// @inheritdoc IComboStorage
    function getContentId(string memory uniqueId) external view override returns (string memory) {
        return _contentId[uniqueId];
    }

    // ── Batch Code Storage ────────────────────────────────
    //
    //    Store multiple pre-computed hashes in one transaction.
    //    All stored codes default to frozen=true.
    //    Codes that cannot be stored are skipped with status=false.
    //    The transaction always succeeds — partial storage is allowed.

    /// @notice Store multiple pre-computed hashes in one transaction.
    ///         Each stored code defaults to frozen=true.
    /// @param uniqueIds Array of unique IDs (must be registered in CodeManager).
    /// @param pins      Array of PINs (bucket keys for O(1) lookup).
    /// @param codeHashes Array of keccak256(giftCode) hashes.
    /// @return stored Per-index boolean indicating which entries were stored.
    function storeDataBatch(
        string[] calldata uniqueIds,
        string[] calldata pins,
        bytes32[] calldata codeHashes
    ) external onlyAuthorizedOrAdmin returns (bool[] memory stored) {
        uint256 len = uniqueIds.length;
        require(
            len == pins.length && len == codeHashes.length,
            "Array length mismatch"
        );

        stored = new bool[](len);

        for (uint256 i = 0; i < len; ) {
            // Local validation — skip on failure
            if (
                bytes(pins[i]).length == 0 ||
                codeHashes[i] == bytes32(0) ||
                bytes(uniqueIds[i]).length == 0 ||
                pinToHash[pins[i]][codeHashes[i]].exists ||
                pinSlotCount[pins[i]] >= MAX_PER_PIN
            ) {
                emit DataStoredStatus(uniqueIds[i], codeHashes[i], false);
                unchecked { ++i; }
                continue;
            }

            // Store with default frozen=true
            pinToHash[pins[i]][codeHashes[i]] = CodeMetadata({
                uniqueId: uniqueIds[i],
                exists: true,
                frozen: true,
                redeemed: false,
                contentId: ""
            });
            pinSlotCount[pins[i]]++;
            _isFrozen[uniqueIds[i]] = true;
            stored[i] = true;

            emit DataStoredStatus(uniqueIds[i], codeHashes[i], true);
            unchecked { ++i; }
        }
    }

    // ── Freeze / Content Management ───────────────────────
    //
    //    These functions update private state AND emit PenteExternalCall
    //    to route the change through CodeManager to the gift contract.
    //    The gift contract is the SOLE AUTHORITY — if it reverts, the
    //    entire Pente transition rolls back atomically.

    /// @notice Set frozen status for a UID. Emits PenteExternalCall to
    ///         route through CodeManager → gift contract.
    function setFrozen(string memory uniqueId, bool frozen) external onlyAuthorizedOrAdmin {
        _isFrozen[uniqueId] = frozen;
        emit FrozenStatusUpdated(uniqueId, frozen);

        // Route to public chain via CodeManager
        emit PenteExternalCall(
            codeManager,
            abi.encodeWithSignature(
                "setUidFrozen(string,bool)",
                uniqueId,
                frozen
            )
        );
    }

    /// @notice Set content for a UID. Emits PenteExternalCall to
    ///         route through CodeManager → gift contract.
    ///         Spec [0067]: admin changes what code redeems to.
    function setContent(string memory uniqueId, string memory contentId) external onlyAuthorizedOrAdmin {
        _contentId[uniqueId] = contentId;
        emit ContentUpdated(uniqueId, contentId);

        // Route to public chain via CodeManager
        emit PenteExternalCall(
            codeManager,
            abi.encodeWithSignature(
                "setUidContent(string,string)",
                uniqueId,
                contentId
            )
        );
    }

    // ── Redemption ────────────────────────────────────────
    //
    //    Verifies a submitted code against the stored hash, updates
    //    private state, then emits PenteExternalCall to route the
    //    redemption through CodeManager → gift contract.
    //
    /// @notice Redeem a code by submitting its PIN and hash.
    ///         Off-chain: giftCode = pin + code, codeHash = keccak256(giftCode).
    ///         PIN routes to the correct bucket, hash verifies the code.
    ///         No cleartext code ever touches the chain. O(1) lookup.
    function redeemCode(string memory pin, bytes32 codeHash) external onlyAuthorizedOrAdmin {
        require(bytes(pin).length > 0, "PIN cannot be empty");
        require(codeHash != bytes32(0), "Hash cannot be zero");

        CodeMetadata storage metadata = pinToHash[pin][codeHash];
        require(metadata.exists, "Invalid PIN or code hash");
        require(!metadata.frozen, "Code is frozen and cannot be redeemed");
        require(!metadata.redeemed, "Code has already been redeemed");

        string memory redeemedUniqueId = metadata.uniqueId;

        // Update private state
        metadata.redeemed = true;
        _isRedeemed[redeemedUniqueId] = true;
        isRedemptionVerified[redeemedUniqueId] = true;
        redemptionRedeemer[redeemedUniqueId] = msg.sender;

        // Clear stored hash data and free the PIN slot
        delete pinToHash[pin][codeHash];
        pinSlotCount[pin]--;

        emit RedeemStatus(redeemedUniqueId, msg.sender, true);

        // Route redemption to public chain via CodeManager → gift contract
        emit PenteExternalCall(
            codeManager,
            abi.encodeWithSignature(
                "recordRedemption(string,address)",
                redeemedUniqueId,
                msg.sender
            )
        );
    }
}
