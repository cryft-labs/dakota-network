// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   ___                 __       ______           __       ______
  / _ \ __ (_)  _____ / /____  / ___/__  __ _  / /  ___ / __/ /____  _______ ____ ____
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
  │  hash comparison.                                    │
  │                                                      │
  │  Frozen/redeemed status is NOT tracked here — the    │
  │  gift contract on the public chain is the sole       │
  │  authority. On redemption, emits PenteExternalCall   │
  │  events that atomically route through CodeManager    │
  │  to the gift contract. If the gift contract reverts  │
  │  (e.g. frozen or already redeemed), the entire       │
  │  Pente transition rolls back.                        │
  │                                                      │
  │  PIN-based O(1) bucket lookup. No cleartext code     │
  │  ever touches the chain.                             │
  │                                                      │
  │  Patent: U.S. App. Ser. No. 18/930,857               │
  └──────────────────────────────────────────────────────┘
*/

import "./Interfaces/ICodeManager.sol";

contract PrivateComboStorage {
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
    address public constant CODE_MANAGER = address(0x000000000000000000000000000000000000c0DE);

    /// @dev Admin address — deployer of this private contract within the privacy group.
    address public admin;

    /// @dev Authorized callers within the privacy group (e.g., redemption service).
    mapping(address => bool) public isAuthorized;

    /// @dev Per-code metadata stored privately.
    struct CodeMetadata {
        string uniqueId;
        bool exists;
    }

    /// @dev Maximum number of hash/uniqueId entries allowed per PIN slot.
    uint256 public constant MAX_PER_PIN = 32;

    /// @dev PIN → codeHash → code metadata. The PIN acts as a bucket
    ///      index for efficient O(1) lookup. The codeHash is keccak256(giftCode)
    ///      where giftCode = pin + code, computed off-chain.
    mapping(string => mapping(bytes32 => CodeMetadata)) public pinToHash;

    /// @dev Tracks how many hashes are currently stored under each PIN.
    mapping(string => uint256) public pinSlotCount;

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

    // ── Batch Code Storage ────────────────────────────────
    //
    //    Store multiple pre-computed hashes in one transaction.
    //    The batch is fully atomic: if any local validation fails,
    //    any public uniqueId validation fails, or any duplicate/full
    //    bucket is encountered during the batch, the entire
    //    transition reverts.

    /// @notice Store multiple pre-computed hashes in one transaction.
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

        require(len > 0, "Empty batch");

        // ----------------------------------------------------
        // Phase 1: local preflight against current private state
        // ----------------------------------------------------

        for (uint256 i = 0; i < len; ) {
            require(bytes(uniqueIds[i]).length > 0, "Empty uniqueId");
            require(bytes(pins[i]).length > 0, "Empty PIN");
            require(codeHashes[i] != bytes32(0), "Zero code hash");
            require(
                !pinToHash[pins[i]][codeHashes[i]].exists,
                "Code hash already stored for PIN"
            );
            require(
                pinSlotCount[pins[i]] < MAX_PER_PIN,
                "PIN slot full"
            );

            unchecked { ++i; }
        }

        // ----------------------------------------------------
        // Phase 2: atomic public-registry validation
        //
        // This routes through CodeManager on the public chain.
        // If any uniqueId is invalid, CodeManager reverts and
        // the entire Pente transition rolls back.
        // ----------------------------------------------------

        emit PenteExternalCall(
            CODE_MANAGER,
            abi.encodeCall(ICodeManager.validateUniqueIdsOrRevert, (uniqueIds))
        );

        // ----------------------------------------------------
        // Phase 3: store all entries
        //
        // Re-check state-sensitive conditions here so duplicates
        // inside the same batch also revert the whole transaction.
        // ----------------------------------------------------

        stored = new bool[](len);

        for (uint256 i = 0; i < len; ) {
            require(
                !pinToHash[pins[i]][codeHashes[i]].exists,
                "Duplicate code hash in batch"
            );
            require(
                pinSlotCount[pins[i]] < MAX_PER_PIN,
                "PIN slot full during batch store"
            );

            pinToHash[pins[i]][codeHashes[i]] = CodeMetadata({
                uniqueId: uniqueIds[i],
                exists: true
            });
            pinSlotCount[pins[i]]++;
            stored[i] = true;

            emit DataStoredStatus(uniqueIds[i], codeHashes[i], true);
            unchecked { ++i; }
        }
    }

    // ── Redemption ────────────────────────────────────────
    //
    //    Verifies a submitted code against the stored hash, then emits
    //    PenteExternalCall to route the redemption through
    //    CodeManager → gift contract. Frozen / redeemed validation
    //    is handled entirely by the gift contract on the public chain.
    //
    /// @notice Redeem a code by submitting its PIN, hash, and target redeemer address.
    ///         Off-chain: giftCode = pin + code, codeHash = keccak256(giftCode).
    ///         PIN routes to the correct bucket, hash verifies the code.
    ///         No cleartext code ever touches the chain. O(1) lookup.
    ///
    ///         The redeemer address is NOT assumed to be msg.sender — it is an
    ///         explicit parameter to support meta-transactions, sponsored calls,
    ///         and user-supplied third-party wallet addresses. The frontend
    ///         provides a predefined or user-selected redeemer address.
    ///
    ///         Frozen / redeemed status is NOT checked here — the gift contract
    ///         on the public chain is the sole authority. If the token is frozen
    ///         or already redeemed, the gift contract reverts and the entire
    ///         Pente transition rolls back atomically, undoing all private state
    ///         changes including the code deletion below.
    function redeemCode(string memory pin, bytes32 codeHash, address redeemer) external onlyAuthorizedOrAdmin {
        require(bytes(pin).length > 0, "PIN cannot be empty");
        require(codeHash != bytes32(0), "Hash cannot be zero");
        require(redeemer != address(0), "Redeemer cannot be zero address");

        CodeMetadata storage metadata = pinToHash[pin][codeHash];
        require(metadata.exists, "Invalid PIN or code hash");

        string memory redeemedUniqueId = metadata.uniqueId;

        // Clear stored hash data and free the PIN slot
        delete pinToHash[pin][codeHash];
        pinSlotCount[pin]--;

        emit RedeemStatus(redeemedUniqueId, redeemer, true);

        // Route redemption to public chain via CodeManager → gift contract.
        // The gift contract validates frozen/redeemed state and transfers
        // the NFT to the redeemer. If it reverts, the entire Pente
        // transition rolls back — including the delete above.
        emit PenteExternalCall(
            CODE_MANAGER,
            abi.encodeWithSignature(
                "recordRedemption(string,address)",
                redeemedUniqueId,
                redeemer
            )
        );
    }
}
