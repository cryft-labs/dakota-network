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
  │  Stores code hashes with contract-assigned PIN       │
  │  routing keys. Verifies submitted codes via hash     │
  │  comparison.                                         │
  │                                                      │
  │  Frozen/redeemed status is NOT tracked here — the    │
  │  gift contract on the public chain is the sole       │
  │  authority. On redemption, emits PenteExternalCall   │
  │  events that atomically route through CodeManager    │
  │  to the gift contract. If the gift contract reverts  │
  │  (e.g. frozen or already redeemed), the entire       │
  │  Pente transition rolls back.                        │
  │                                                      │
  │  Contract-assigned PIN routing. O(1) bucket lookup.  │
  │  No cleartext code ever touches the chain.           │
  │                                                      │
  │  Patent: U.S. App. Ser. No. 18/930,857               │
  └──────────────────────────────────────────────────────┘
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.2.0/contracts/proxy/utils/Initializable.sol";

contract PrivateComboStorage is Initializable {
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

    /// @dev Maximum entries per PIN slot. When a slot reaches this cap,
    ///      the entropy chain skips to the next PIN automatically.
    uint256 public constant MAX_PER_PIN = 32;

    /// @dev PIN → codeHash → code metadata. The PIN is a contract-assigned
    ///      routing key for O(1) bucket lookup. The codeHash is keccak256(code)
    ///      computed off-chain — the PIN is NOT part of the hash.
    mapping(string => mapping(bytes32 => CodeMetadata)) public pinToHash;

    /// @dev Tracks how many hashes are currently stored under each PIN.
    mapping(string => uint256) public pinSlotCount;

    // ── Events ────────────────────────────────────────────

    event DataStoredStatus(
        string uniqueId,
        string assignedPin
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

    // ── Constructor / Initializer ──────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the private storage contract.
    ///         Must be called once after deployment inside the privacy group.
    function initialize() public initializer {
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

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Cannot set zero address as admin");
        admin = newAdmin;
    }

    // ── Batch Code Storage ────────────────────────────────
    //
    //    Store multiple pre-computed hashes in one transaction.
    //    The caller supplies opaque entropy (e.g. random bytes
    //    generated off-chain) which the contract uses to derive
    //    PIN assignments. The entropy never leaves the privacy
    //    group and cannot be reconstructed by outside observers.
    //
    //    The hash is computed off-chain as keccak256(code) — the
    //    PIN is purely a routing key and is NOT part of the hash.
    //    This guarantees no two codes can collide within a PIN
    //    slot (distinct codes → distinct keccak256 outputs).
    //
    //    The batch is fully atomic: if any local validation fails
    //    or any public uniqueId validation fails, the entire
    //    transition reverts. PIN-slot collisions are resolved
    //    silently by chaining keccak256(entropy) until an open
    //    slot is found — no revert, no information leakage.

    /// @notice Store multiple pre-computed hashes in one transaction.
    ///         The contract assigns PINs — callers receive them in the return value.
    /// @param uniqueIds  Array of unique IDs (must be registered in CodeManager).
    /// @param codeHashes Array of keccak256(code) hashes (PIN is NOT part of the hash).
    /// @param pinLength  Number of characters for assigned PINs.
    ///                   Alphanumeric only (62 chars): 3-char = 238,328 slots; 4-char = 14,776,336.
    ///                   With specials  (76 chars): 3-char = 438,976 slots; 4-char = 33,362,176.
    /// @param useSpecialChars If true, PINs include special characters
    ///                   (0-9, A-Z, a-z, !, at, #, $, %, &, *, +, -, =, ?, ~, ^, _, |).
    ///                   If false, alphanumeric only (0-9, A-Z, a-z).
    /// @param entropy    Caller-supplied randomness for PIN derivation. Should be
    ///                   generated off-chain (e.g. keccak256 of random bytes).
    /// @return assignedPins Per-index PIN strings assigned by the contract.
    function storeDataBatch(
        string[] calldata uniqueIds,
        bytes32[] calldata codeHashes,
        uint256 pinLength,
        bool useSpecialChars,
        bytes32 entropy
    ) external onlyAuthorizedOrAdmin returns (string[] memory assignedPins) {
        uint256 len = uniqueIds.length;
        require(len == codeHashes.length, "Array length mismatch");
        require(len > 0, "Empty batch");
        require(pinLength > 0 && pinLength <= 8, "PIN length must be 1-8");
        require(entropy != bytes32(0), "Entropy cannot be zero");

        // ----------------------------------------------------
        // Phase 1: local preflight — validate inputs
        // ----------------------------------------------------

        for (uint256 i = 0; i < len; ) {
            require(bytes(uniqueIds[i]).length > 0, "Empty uniqueId");
            require(codeHashes[i] != bytes32(0), "Zero code hash");
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
            abi.encodeWithSignature(
                "validateUniqueIdsOrRevert(string[])",
                uniqueIds
            )
        );

        // ----------------------------------------------------
        // Phase 3: assign PINs and store all entries
        //
        // Caller-supplied entropy drives PIN derivation. On each
        // assignment the entropy is chained: entropy = keccak256(entropy).
        // If a slot collision occurs (same codeHash already exists
        // at the derived PIN) or the slot has reached MAX_PER_PIN,
        // the entropy is re-chained and a new PIN is tried — no
        // revert, no information leakage. No on-chain counter or
        // deterministic seed is stored, so PIN assignments cannot
        // be reconstructed without knowing the original entropy.
        // ----------------------------------------------------

        assignedPins = new string[](len);

        for (uint256 i = 0; i < len; ) {
            // Derive PIN; on collision or full slot, rehash entropy and retry.
            (string memory pin, bytes32 nextEntropy) = _assignPin(
                entropy, pinLength, useSpecialChars, codeHashes[i]
            );
            entropy = nextEntropy;

            pinToHash[pin][codeHashes[i]] = CodeMetadata({
                uniqueId: uniqueIds[i],
                exists: true
            });
            pinSlotCount[pin]++;
            assignedPins[i] = pin;

            emit DataStoredStatus(uniqueIds[i], pin);
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
    ///         Off-chain: codeHash = keccak256(code). PIN routes to the correct
    ///         bucket (assigned during storage), hash verifies the code.
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

    // ── Internal Helpers ──────────────────────────────────

    /// @dev Alphanumeric charset: 0-9, A-Z, a-z (62 characters).
    bytes internal constant CHARSET_ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

    /// @dev Full charset: alphanumeric + specials (76 characters).
    bytes internal constant CHARSET_FULL = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!@#$%&*+-=?~^_|";

    /// @dev Size of the alphanumeric-only charset.
    uint256 internal constant CHARSET_ALNUM_SIZE = 62;

    /// @dev Size of the full charset (alphanumeric + specials).
    uint256 internal constant CHARSET_FULL_SIZE = 76;

    /// @dev Derive a collision-free PIN for a given codeHash.
    ///      Chains entropy via keccak256 until an open slot is found.
    function _assignPin(
        bytes32 entropy,
        uint256 pinLength,
        bool useSpecialChars,
        bytes32 codeHash
    ) internal view returns (string memory pin, bytes32 nextEntropy) {
        nextEntropy = entropy;
        uint256 base = useSpecialChars ? CHARSET_FULL_SIZE : CHARSET_ALNUM_SIZE;
        uint256 pinSpace = _powBase(base, pinLength);
        bytes memory charset = useSpecialChars ? CHARSET_FULL : CHARSET_ALNUM;
        uint256 retries;
        do {
            pin = _toPin(uint256(nextEntropy) % pinSpace, pinLength, charset, base);
            nextEntropy = keccak256(abi.encodePacked(nextEntropy));
            retries++;
            require(retries <= 100, "PIN space exhausted");
        } while (pinToHash[pin][codeHash].exists || pinSlotCount[pin] >= MAX_PER_PIN);
    }

    /// @dev Convert a uint to a fixed-length PIN string using the given charset.
    function _toPin(
        uint256 value,
        uint256 length,
        bytes memory charset,
        uint256 base
    ) internal pure returns (string memory) {
        bytes memory buffer = new bytes(length);
        for (uint256 i = length; i > 0; ) {
            unchecked { --i; }
            buffer[i] = charset[value % base];
            value /= base;
        }
        return string(buffer);
    }

    /// @dev Compute base^exp for PIN space sizing.
    function _powBase(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = 1;
        for (uint256 i = 0; i < exp; ) {
            result *= base;
            unchecked { ++i; }
        }
    }
}
