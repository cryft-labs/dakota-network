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

  ┌──────────────── Contract Architecture ──────────────────────────┐
  │                                                                 │
  │  DEPLOYED INSIDE A PALADIN PENTE PRIVACY GROUP.                 │
  │  All state is private to privacy group members.                 │
  │  All configuration is compile-time constant — changes           │
  │  require a contract upgrade via proxy.                          │
  │                                                                 │
  │  Designed for client-generated redeemable codes:                │
  │  codes are created off-chain, hashed, and submitted             │
  │  in batches via storeDataBatch(StoreBatchRequest).              │
  │  The contract assigns PIN routing keys and stores               │
  │  hashes for O(1) verification. No cleartext code                │
  │  ever touches the chain.                                        │
  │                                                                 │
  │  Caller-supplied entropy drives PIN assignment.                 │
  │  Collision resolution chains keccak256(entropy)                 │
  │  silently — no revert, no information leakage.                  │
  │  Each PIN slot holds up to MAX_PER_PIN entries.                 │
  │                                                                 │
  │  ── Private Active State & Selective Mirroring ───────────────  │
  │                                                                 │
  │  Active/frozen status is tracked here privately.                │
  │  At store time, mirrorStatuses[i] controls whether              │
  │  each UID's active state is mirrored to CodeManager:            │
  │    true  → state changes route to CodeManager publicly          │
  │    false → state stays private; CodeManager sees only           │
  │            USE_DEFAULT_ACTIVE_STATE (no public override)        │
  │                                                                 │
  │  setUniqueIdActiveBatch() updates private execution             │
  │  state first, then mirrors only non-disabled UIDs               │
  │  to CodeManager via PenteExternalCall.                          │
  │                                                                 │
  │  Redemption checks private UID state first, so                  │
  │  inactive or redeemed UIDs are skipped before any               │
  │  external redemption transition is emitted.                     │
  │                                                                 │
  │  ── Per-UID Manager Delegation ───────────────────────────────  │
  │                                                                 │
  │  Each UID can optionally have a dedicated manager               │
  │  address that can update its active state. If no                │
  │  manager is assigned, only ADMIN or AUTHORIZED                  │
  │  may act. Managers are set at store time or via                 │
  │  setUniqueIdManagersBatch().                                    │
  │                                                                 │
  │  ── Contract Identifier Whitelisting ─────────────────────────  │
  │                                                                 │
  │  The contract-identifier prefix (derived from                   │
  │  CodeManager + gift contract + chainId) must be                 │
  │  whitelisted before codes can be stored for it.                 │
  │  Managed via setContractIdentifierWhitelist().                  │
  │                                                                 │
  │  Patent: U.S. App. Ser. No. 18/930,857                          │
  └─────────────────────────────────────────────────────────────────┘
*/

contract PrivateComboStorage {
    enum UniqueIdLocalStatus {
        USE_DEFAULT_ACTIVE_STATE,
        INACTIVE,
        REDEEMED
    }

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
    //
    //    All configuration is compile-time constant. To change
    //    addresses, limits, or access control, deploy a new
    //    implementation and upgrade the proxy. Constants are
    //    embedded in bytecode — no state trie lookups needed.
    //

    /// @dev The CodeManager address on the public chain.
    ///      PenteExternalCall events target this address.
    ///      Update via contract upgrade if CodeManager is redeployed.
    address public constant CODE_MANAGER = address(0x000000000000000000000000000000000000c0DE);

    /// @dev Admin — authorized to call storeDataBatch and redeemCodeBatch.
    ///      Update via contract upgrade.
    address public constant ADMIN = address(0x01d5E8F6aa4650e571acAa8733F46c3d16fa13cB);

    /// @dev Authorized service account — also authorized to call
    ///      storeDataBatch and redeemCodeBatch (e.g., redemption service).
    ///      Update via contract upgrade.
    address public constant AUTHORIZED = address(0xc0dE49f742792913219DA0606f59a27431BCC0de);

    /// @dev Default active state defined in CodeManager. Private status writes
    ///      only route deviations from this default.
    bool public constant DEFAULT_ACTIVE_STATE = true;

    /// @dev Per-code metadata stored privately.
    struct CodeMetadata {
        string uniqueId;
        bool exists;
    }

    struct StorePreparation {
        uint256[] validIndexes;
        uint256 validCount;
        string[] assignedPins;
    }

    struct StoreBatchRequest {
        string[] uniqueIds;
        bytes32[] codeHashes;
        uint256[] pinLengths;
        bool[] useSpecialChars;
        bytes32[] entropies;
        address[] uidManagers;
        bool[] mirrorStatuses;
    }

    struct ActiveBatchContext {
        string[] mirroredUniqueIds;
        bool[] mirroredActiveStates;
        bytes32[] seenUids;
        uint256 validCount;
        uint256 mirroredCount;
    }

    /// @dev Maximum entries per PIN slot. When a slot reaches this cap,
    ///      the entropy chain skips to the next PIN automatically.
    ///      Update via contract upgrade.
    uint256 public constant MAX_PER_PIN = 32;

    /// @dev PIN → codeHash → code metadata. The PIN is a contract-assigned
    ///      routing key for O(1) bucket lookup. The codeHash is keccak256(code)
    ///      computed off-chain — the PIN is NOT part of the hash.
    mapping(string => mapping(bytes32 => CodeMetadata)) public pinToHash;

    /// @dev Tracks how many hashes are currently stored under each PIN.
    mapping(string => uint256) public pinSlotCount;

    /// @dev Whitelisted contract identifiers (the UID prefix before the counter).
    mapping(bytes32 => bool) public isWhitelistedContractIdentifier;

    /// @dev Per-UID manager allowed to route active-state changes.
    mapping(bytes32 => address) public uniqueIdManager;

    /// @dev Tracks whether a UID has ever been admitted into private storage.
    mapping(bytes32 => bool) private _knownUniqueIds;

    /// @dev Sparse override for UIDs whose active/frozen state should remain
    ///      private. Default false means public mirroring is enabled.
    mapping(bytes32 => bool) public isUniqueIdStatusMirrorDisabled;

    /// @dev Private sparse execution state for each UID.
    mapping(bytes32 => UniqueIdLocalStatus) private _uniqueIdLocalStatuses;

    // ── Events ────────────────────────────────────────────

    event DataStoredStatus(
        string uniqueId,
        string assignedPin
    );

    event RedeemStatus(
        string uniqueId,
        address redeemer
    );

    event RedeemFailed(
        uint256 index,
        string reason
    );

    event StoreFailed(
        uint256 index,
        string reason
    );

    event ActiveStatusFailed(
        uint256 index,
        string reason
    );

    event ContractIdentifierWhitelistUpdated(
        string contractIdentifier,
        bool allowed
    );

    event UniqueIdManagerUpdated(
        string uniqueId,
        address indexed manager,
        address indexed updatedBy
    );

    event UniqueIdStatusUpdated(
        string uniqueId,
        bool active,
        bool usesDefaultState
    );

    event UniqueIdStatusMirrorUpdated(
        string uniqueId,
        bool mirrorStatusPublicly
    );

    // ── Modifiers ─────────────────────────────────────────

    modifier onlyAuthorized() {
        require(
            msg.sender == ADMIN || msg.sender == AUTHORIZED,
            "Caller is not authorized"
        );
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == ADMIN, "Caller is not admin");
        _;
    }

    // ── Constructor ───────────────────────────────────────

    /// @dev No constructor logic needed. All configuration is
    ///      compile-time constant. Upgrades are handled via proxy.

    // ── Admin Configuration ─────────────────────────────

    /// @notice Allow or disallow one or more contract identifiers for private storage.
    function setContractIdentifierWhitelist(
        string[] calldata contractIdentifiers,
        bool[] calldata allowed
    ) external onlyAdmin {
        uint256 len = contractIdentifiers.length;
        require(len == allowed.length, "Array length mismatch");
        require(len > 0, "Empty batch");

        for (uint256 i = 0; i < len; ) {
            require(bytes(contractIdentifiers[i]).length > 0, "Empty contract identifier");
            bytes32 contractIdentifierHash = keccak256(bytes(contractIdentifiers[i]));
            isWhitelistedContractIdentifier[contractIdentifierHash] = allowed[i];
            emit ContractIdentifierWhitelistUpdated(contractIdentifiers[i], allowed[i]);
            unchecked { ++i; }
        }
    }

    // ── Batch Code Storage ────────────────────────────────
    //
    //    Store multiple pre-computed hashes in one transaction.
    //    The caller supplies one opaque entropy seed per entry
    //    (e.g. random bytes generated off-chain). Each entry uses
    //    its own seed for initial PIN derivation. If the derived
    //    PIN is unavailable, the contract chains keccak256(seed)
    //    until an open slot is found.
    //
    //    The hash is computed off-chain as keccak256(code) — the
    //    PIN is purely a routing key and is NOT part of the hash.
    //    This guarantees no two codes can collide within a PIN
    //    slot (distinct codes → distinct keccak256 outputs).
    //
    //    Entries that fail local validation (empty uniqueId, invalid
    //    UID format, non-whitelisted contract identifier, zero hash)
    //    are skipped with a StoreFailed event — no PIN is
    //    assigned, no state is written, and the entry is excluded
    //    from the public-chain UID validation call. Only entries
    //    that pass local checks are sent to CodeManager and
    //    stored. PIN-slot collisions are resolved silently by
    //    chaining keccak256(entropy) until an open slot is found.

    /// @notice Store multiple pre-computed hashes in one transaction.
    ///         The contract assigns PINs — callers receive them in the return value.
    ///
    ///         Entries that fail local validation (empty uniqueId, invalid UID format,
    ///         non-whitelisted contract identifier, zero code hash, invalid pin length,
    ///         or zero entropy) are skipped — a StoreFailed
    ///         event is emitted with the index and reason, and the entry is
    ///         excluded from the public-chain validation call. The corresponding
    ///         assignedPins slot is left as an empty string.
    ///
    ///         Entries that pass local validation are sent to CodeManager for UID
    ///         verification. If any valid UID fails on CodeManager, the entire
    ///         Pente transition rolls back (unavoidable — PenteExternalCall is
    ///         fire-and-forget with no return value).
    /// @param request Batched store request containing uniqueIds, codeHashes,
    ///                pinLengths, useSpecialChars, entropies, uidManagers, and
    ///                mirrorStatuses. `mirrorStatuses[i] == false` keeps the
    ///                UID's active/frozen state private in this contract.
    /// @return assignedPins Per-index PIN strings assigned by the contract.
    ///                      Empty string for entries that failed local validation.
    function storeDataBatch(
        StoreBatchRequest calldata request
    ) external onlyAuthorized returns (string[] memory assignedPins) {
        require(
            request.uniqueIds.length == request.codeHashes.length
                && request.uniqueIds.length == request.pinLengths.length
                && request.uniqueIds.length == request.useSpecialChars.length
                && request.uniqueIds.length == request.entropies.length
                && request.uniqueIds.length == request.uidManagers.length
                && request.uniqueIds.length == request.mirrorStatuses.length,
            "Array length mismatch"
        );
        require(request.uniqueIds.length > 0, "Empty batch");

        StorePreparation memory preparation = _prepareStoreBatch(request);

        assignedPins = preparation.assignedPins;

        _persistStoredHashes(
            request.uniqueIds,
            request.codeHashes,
            preparation.validIndexes,
            preparation.validCount,
            preparation.assignedPins
        );

        _persistStoredUniqueIdConfig(
            request.uniqueIds,
            request.uidManagers,
            request.mirrorStatuses,
            preparation.validIndexes,
            preparation.validCount
        );
    }

    function _prepareStoreBatch(
        StoreBatchRequest calldata request
    ) internal returns (StorePreparation memory preparation) {
        (preparation.validIndexes, preparation.validCount) = _collectValidStoreIndexes(
            request.uniqueIds,
            request.codeHashes,
            request.pinLengths,
            request.entropies
        );

        _emitStoreValidation(request.uniqueIds, preparation.validIndexes, preparation.validCount);

        preparation.assignedPins = _assignPinsForValidEntries(
            request.codeHashes,
            request.pinLengths,
            request.useSpecialChars,
            request.entropies,
            preparation.validIndexes,
            preparation.validCount
        );
    }

    /// @dev Phase 1 helper for storeDataBatch.
    ///      Validates each entry locally and returns the indexes that survived.
    function _collectValidStoreIndexes(
        string[] calldata uniqueIds,
        bytes32[] calldata codeHashes,
        uint256[] calldata pinLengths,
        bytes32[] calldata entropies
    ) internal returns (uint256[] memory validIndexes, uint256 validCount) {
        uint256 len = uniqueIds.length;
        validIndexes = new uint256[](len);
        bytes32[] memory seenUids = new bytes32[](len);

        for (uint256 i = 0; i < len; ) {
            if (bytes(uniqueIds[i]).length == 0) {
                emit StoreFailed(i, "Empty uniqueId");
                unchecked { ++i; }
                continue;
            }

            (bool hasContractIdentifier, bytes32 contractIdentifierHash) = _tryGetContractIdentifierHash(uniqueIds[i]);
            if (!hasContractIdentifier) {
                emit StoreFailed(i, "Invalid uniqueId format");
                unchecked { ++i; }
                continue;
            }
            if (!isWhitelistedContractIdentifier[contractIdentifierHash]) {
                emit StoreFailed(i, "Contract identifier not whitelisted");
                unchecked { ++i; }
                continue;
            }
            if (codeHashes[i] == bytes32(0)) {
                emit StoreFailed(i, "Zero code hash");
                unchecked { ++i; }
                continue;
            }
            if (pinLengths[i] == 0 || pinLengths[i] > 8) {
                emit StoreFailed(i, "PIN length must be 1-8");
                unchecked { ++i; }
                continue;
            }
            if (entropies[i] == bytes32(0)) {
                emit StoreFailed(i, "Zero entropy");
                unchecked { ++i; }
                continue;
            }

            bytes32 uidHash = keccak256(bytes(uniqueIds[i]));
            if (_knownUniqueIds[uidHash]) {
                emit StoreFailed(i, "UniqueId already stored");
                unchecked { ++i; }
                continue;
            }

            bool isDuplicate;
            for (uint256 j = 0; j < validCount; ) {
                if (seenUids[j] == uidHash) {
                    isDuplicate = true;
                    break;
                }
                unchecked { ++j; }
            }
            if (isDuplicate) {
                emit StoreFailed(i, "Duplicate uniqueId in batch");
                unchecked { ++i; }
                continue;
            }
            seenUids[validCount] = uidHash;
            validIndexes[validCount] = i;
            unchecked { ++validCount; }
            unchecked { ++i; }
        }
    }

    /// @dev Phase 2 helper for storeDataBatch.
    ///      Emits a single validation call for only the locally valid UIDs.
    function _emitStoreValidation(
        string[] calldata uniqueIds,
        uint256[] memory validIndexes,
        uint256 validCount
    ) internal {
        if (validCount == 0) {
            return;
        }

        string[] memory validUniqueIds = new string[](validCount);
        for (uint256 i = 0; i < validCount; ) {
            validUniqueIds[i] = uniqueIds[validIndexes[i]];
            unchecked { ++i; }
        }

        emit PenteExternalCall(
            CODE_MANAGER,
            abi.encodeWithSignature(
                "validateUniqueIdsOrRevert(string[])",
                validUniqueIds
            )
        );
    }

    /// @dev Assign PINs for all locally validated entries.
    function _assignPinsForValidEntries(
        bytes32[] calldata codeHashes,
        uint256[] calldata pinLengths,
        bool[] calldata useSpecialChars,
        bytes32[] calldata entropies,
        uint256[] memory validIndexes,
        uint256 validCount
    ) internal returns (string[] memory assignedPins) {
        assignedPins = new string[](validIndexes.length);

        for (uint256 i = 0; i < validCount; ) {
            uint256 index = validIndexes[i];
            assignedPins[index] = _assignPinForStoredEntry(
                index,
                codeHashes,
                pinLengths,
                useSpecialChars,
                entropies
            );
            unchecked { ++i; }
        }
    }

    function _assignPinForStoredEntry(
        uint256 index,
        bytes32[] calldata codeHashes,
        uint256[] calldata pinLengths,
        bool[] calldata useSpecialChars,
        bytes32[] calldata entropies
    ) internal returns (string memory assignedPin) {
        return _assignPin(
            entropies[index],
            pinLengths[index],
            useSpecialChars[index],
            codeHashes[index]
        );
    }

    /// @dev Persist code-hash metadata for validated entries.
    function _persistStoredHashes(
        string[] calldata uniqueIds,
        bytes32[] calldata codeHashes,
        uint256[] memory validIndexes,
        uint256 validCount,
        string[] memory assignedPins
    ) internal {
        for (uint256 i = 0; i < validCount; ) {
            uint256 index = validIndexes[i];
            pinToHash[assignedPins[index]][codeHashes[index]] = CodeMetadata({
                uniqueId: uniqueIds[index],
                exists: true
            });
            pinSlotCount[assignedPins[index]]++;

            emit DataStoredStatus(uniqueIds[index], assignedPins[index]);
            unchecked { ++i; }
        }
    }

    /// @dev Persist UID-level config for validated entries.
    function _persistStoredUniqueIdConfig(
        string[] calldata uniqueIds,
        address[] calldata uidManagers,
        bool[] calldata mirrorStatuses,
        uint256[] memory validIndexes,
        uint256 validCount
    ) internal {
        for (uint256 i = 0; i < validCount; ) {
            uint256 index = validIndexes[i];
            bytes32 uidHash = keccak256(bytes(uniqueIds[index]));
            _knownUniqueIds[uidHash] = true;
            if (uidManagers[index] != address(0)) {
                emit UniqueIdManagerUpdated(uniqueIds[index], uidManagers[index], msg.sender);
                uniqueIdManager[uidHash] = uidManagers[index];
            }
            if (!mirrorStatuses[index]) {
                isUniqueIdStatusMirrorDisabled[uidHash] = true;
                emit UniqueIdStatusMirrorUpdated(uniqueIds[index], false);
            }
            unchecked { ++i; }
        }
    }


    /// @notice Update managers for one or more UIDs.
    ///         The current UID manager, ADMIN, or AUTHORIZED may reassign a UID.
    ///         A zero-address manager means no separate manager is assigned,
    ///         leaving future control to ADMIN/AUTHORIZED until a manager is set.
    ///         Invalid entries are skipped and reported instead of reverting.
    function setUniqueIdManagersBatch(
        string[] calldata uniqueIds,
        address[] calldata newManagers
    ) external {
        uint256 len = uniqueIds.length;
        require(len == newManagers.length, "Array length mismatch");
        require(len > 0, "Empty batch");

        for (uint256 i = 0; i < len; ) {
            if (bytes(uniqueIds[i]).length == 0) {
                emit ActiveStatusFailed(i, "Empty uniqueId");
                unchecked { ++i; }
                continue;
            }
            bytes32 uidHash = keccak256(bytes(uniqueIds[i]));
            if (!_knownUniqueIds[uidHash]) {
                emit ActiveStatusFailed(i, "Unknown uniqueId");
                unchecked { ++i; }
                continue;
            }
            address currentManager = uniqueIdManager[uidHash];
            if (
                msg.sender != ADMIN &&
                msg.sender != AUTHORIZED &&
                (currentManager == address(0) || msg.sender != currentManager)
            ) {
                emit ActiveStatusFailed(i, "Caller is not authorized for uniqueId");
                unchecked { ++i; }
                continue;
            }

            uniqueIdManager[uidHash] = newManagers[i];
            emit UniqueIdManagerUpdated(uniqueIds[i], newManagers[i], msg.sender);
            unchecked { ++i; }
        }
    }

    // ── Active State Routing ─────────────────────────────

    /// @notice Route sparse active-state updates to CodeManager.
    ///         The caller must be the UID's manager, ADMIN, or AUTHORIZED.
    ///         If no separate manager is assigned, only ADMIN/AUTHORIZED may act.
    ///         Invalid local entries are skipped and reported. Valid entries
    ///         always update private execution state first. Only UIDs without a
    ///         private-only mirror override are then mirrored to CodeManager for
    ///         public visibility.
    function setUniqueIdActiveBatch(
        string[] calldata uniqueIds,
        bool[] calldata activeStates
    ) external {
        uint256 len = uniqueIds.length;
        require(len == activeStates.length, "Array length mismatch");
        require(len > 0, "Empty batch");

        ActiveBatchContext memory context = ActiveBatchContext({
            mirroredUniqueIds: new string[](len),
            mirroredActiveStates: new bool[](len),
            seenUids: new bytes32[](len),
            validCount: 0,
            mirroredCount: 0
        });

        for (uint256 i = 0; i < len; ) {
            _processActiveStatusEntry(i, uniqueIds, activeStates, context);
            unchecked { ++i; }
        }

        if (context.mirroredCount == 0) {
            return;
        }

        string[] memory mirroredUniqueIds = context.mirroredUniqueIds;
        bool[] memory mirroredActiveStates = context.mirroredActiveStates;

        assembly ("memory-safe") {
            mstore(mirroredUniqueIds, mload(add(context, 0x80)))
            mstore(mirroredActiveStates, mload(add(context, 0x80)))
        }

        emit PenteExternalCall(
            CODE_MANAGER,
            abi.encodeWithSignature(
                "setUniqueIdActiveBatch(string[],bool[])",
                mirroredUniqueIds,
                mirroredActiveStates
            )
        );
    }

    function _processActiveStatusEntry(
        uint256 index,
        string[] calldata uniqueIds,
        bool[] calldata activeStates,
        ActiveBatchContext memory context
    ) internal {
        if (bytes(uniqueIds[index]).length == 0) {
            emit ActiveStatusFailed(index, "Empty uniqueId");
            return;
        }

        (bool hasContractIdentifier, bytes32 contractIdentifierHash) = _tryGetContractIdentifierHash(uniqueIds[index]);
        if (!hasContractIdentifier) {
            emit ActiveStatusFailed(index, "Invalid uniqueId format");
            return;
        }
        if (!isWhitelistedContractIdentifier[contractIdentifierHash]) {
            emit ActiveStatusFailed(index, "Contract identifier not whitelisted");
            return;
        }

        bytes32 uidHash = keccak256(bytes(uniqueIds[index]));
        if (!_knownUniqueIds[uidHash]) {
            emit ActiveStatusFailed(index, "Unknown uniqueId");
            return;
        }

        address currentManager = uniqueIdManager[uidHash];
        if (
            msg.sender != ADMIN &&
            msg.sender != AUTHORIZED &&
            (currentManager == address(0) || msg.sender != currentManager)
        ) {
            emit ActiveStatusFailed(index, "Caller is not authorized for uniqueId");
            return;
        }
        if (_uniqueIdLocalStatuses[uidHash] == UniqueIdLocalStatus.REDEEMED) {
            emit ActiveStatusFailed(index, "UniqueId already redeemed");
            return;
        }

        for (uint256 j = 0; j < context.validCount; ) {
            if (context.seenUids[j] == uidHash) {
                emit ActiveStatusFailed(index, "Duplicate uniqueId in batch");
                return;
            }
            unchecked { ++j; }
        }

        if (activeStates[index] == DEFAULT_ACTIVE_STATE) {
            delete _uniqueIdLocalStatuses[uidHash];
            emit UniqueIdStatusUpdated(uniqueIds[index], activeStates[index], true);
        } else {
            _uniqueIdLocalStatuses[uidHash] = UniqueIdLocalStatus.INACTIVE;
            emit UniqueIdStatusUpdated(uniqueIds[index], activeStates[index], false);
        }

        context.seenUids[context.validCount] = uidHash;
        if (!isUniqueIdStatusMirrorDisabled[uidHash]) {
            context.mirroredUniqueIds[context.mirroredCount] = uniqueIds[index];
            context.mirroredActiveStates[context.mirroredCount] = activeStates[index];
            unchecked { ++context.mirroredCount; }
        }
        unchecked { ++context.validCount; }
    }

    // ── Batch Redemption ────────────────────────────────────
    //
    //    Verifies submitted codes against stored hashes. Entries
    //    that fail local validation (bad PIN, zero hash, missing
    //    entry) are skipped with a RedeemFailed event — no
    //    PenteExternalCall is emitted for them. Valid entries are
    //    deleted and routed through CodeManager → gift contract
    //    via PenteExternalCall. Active-state validation happens here
    //    first; CodeManager mirrors the state publicly and records
    //    redeemed finality.
    //
    /// @notice Redeem one or more codes in a single transaction.
    ///         Off-chain: codeHash = keccak256(code). PIN routes to the correct
    ///         bucket (assigned during storage), hash verifies the code.
    ///         No cleartext code ever touches the chain. O(1) lookup.
    ///
    ///         The redeemer addresses are NOT assumed to be msg.sender — they are
    ///         explicit parameters to support meta-transactions, sponsored calls,
    ///         and user-supplied third-party wallet addresses. The frontend
    ///         provides predefined or user-selected redeemer addresses.
    ///
    ///         Entries that fail local validation (empty PIN, zero hash, zero
    ///         redeemer, or no matching entry in private state) are skipped —
    ///         a RedeemFailed event is emitted with the index and reason, and
    ///         no PenteExternalCall is emitted for that entry. This prevents
    ///         a single bad entry from poisoning the entire batch.
    ///
    ///         Entries that pass local validation are deleted from private
    ///         state, marked redeemed locally, and routed to the public chain.
    ///         Inactive or already redeemed UIDs are skipped before they can
    ///         hit the external transition. If the gift contract reverts for
    ///         any routed entry, the entire Pente transition still rolls back —
    ///         including the local redeemed marking and deletes above.
    /// @param pins      Array of PINs (assigned during storage).
    /// @param codeHashes Array of keccak256(code) hashes.
    /// @param redeemers  Array of redeemer addresses to receive the NFTs.
    function redeemCodeBatch(
        string[] calldata pins,
        bytes32[] calldata codeHashes,
        address[] calldata redeemers
    ) external onlyAuthorized {
        uint256 len = pins.length;
        require(len == codeHashes.length && len == redeemers.length, "Array length mismatch");
        require(len > 0, "Empty batch");

        bytes32[] memory seenHashes = new bytes32[](len);
        uint256 seenCount;

        for (uint256 i = 0; i < len; ) {
            if (bytes(pins[i]).length == 0) {
                emit RedeemFailed(i, "PIN cannot be empty");
                unchecked { ++i; }
                continue;
            }
            if (codeHashes[i] == bytes32(0)) {
                emit RedeemFailed(i, "Hash cannot be zero");
                unchecked { ++i; }
                continue;
            }
            if (redeemers[i] == address(0)) {
                emit RedeemFailed(i, "Redeemer cannot be zero address");
                unchecked { ++i; }
                continue;
            }

            {
                bool isDuplicate;
                for (uint256 j = 0; j < seenCount; ) {
                    if (seenHashes[j] == codeHashes[i]) {
                        isDuplicate = true;
                        break;
                    }
                    unchecked { ++j; }
                }
                if (isDuplicate) {
                    emit RedeemFailed(i, "Duplicate code hash in batch");
                    unchecked { ++i; }
                    continue;
                }
                seenHashes[seenCount] = codeHashes[i];
                unchecked { ++seenCount; }
            }

            CodeMetadata storage metadata = pinToHash[pins[i]][codeHashes[i]];
            if (!metadata.exists) {
                emit RedeemFailed(i, "Invalid PIN or code hash");
                unchecked { ++i; }
                continue;
            }

            string memory redeemedUniqueId = metadata.uniqueId;
            bytes32 uniqueIdHash = keccak256(bytes(redeemedUniqueId));
            if (_uniqueIdLocalStatuses[uniqueIdHash] == UniqueIdLocalStatus.REDEEMED) {
                emit RedeemFailed(i, "UniqueId already redeemed");
                unchecked { ++i; }
                continue;
            }
            if (!_isUniqueIdActive(uniqueIdHash)) {
                emit RedeemFailed(i, "UniqueId is inactive");
                unchecked { ++i; }
                continue;
            }

            delete pinToHash[pins[i]][codeHashes[i]];
            pinSlotCount[pins[i]]--;
            _uniqueIdLocalStatuses[uniqueIdHash] = UniqueIdLocalStatus.REDEEMED;

            emit RedeemStatus(redeemedUniqueId, redeemers[i]);

            // Route redemption to public chain via CodeManager → gift contract.
            // Only entries that pass local validation reach this point.
            // CodeManager mirrors redeemed state publicly, and the gift contract
            // enforces redemption finality. If either layer reverts, the entire
            // Pente transition rolls back — including the local updates above.
            emit PenteExternalCall(
                CODE_MANAGER,
                abi.encodeWithSignature(
                    "recordRedemption(string,address)",
                    redeemedUniqueId,
                    redeemers[i]
                )
            );

            unchecked { ++i; }
        }
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
    ///      Starts from a caller-provided entry seed and chains
    ///      keccak256(seed) only as a retry path until an open slot is found.
    function _assignPin(
        bytes32 entropy,
        uint256 pinLength,
        bool useSpecialChars,
        bytes32 codeHash
    ) internal view returns (string memory pin) {
        bytes32 nextEntropy = entropy;
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

    /// @dev Return whether a UID is active according to private execution state.
    function _isUniqueIdActive(bytes32 uniqueIdHash) internal view returns (bool) {
        UniqueIdLocalStatus status = _uniqueIdLocalStatuses[uniqueIdHash];
        if (status == UniqueIdLocalStatus.REDEEMED) {
            return false;
        }
        if (status == UniqueIdLocalStatus.INACTIVE) {
            return false;
        }
        return DEFAULT_ACTIVE_STATE;
    }

    /// @dev Extract the contract-identifier prefix (before '-') and hash it.
    function _tryGetContractIdentifierHash(
        string memory uniqueId
    ) internal pure returns (bool ok, bytes32 contractIdentifierHash) {
        bytes memory value = bytes(uniqueId);
        if (value.length == 0) {
            return (false, bytes32(0));
        }

        uint256 delimiterIndex = value.length;
        for (uint256 i = 0; i < value.length; ) {
            if (value[i] == 0x2D) {
                delimiterIndex = i;
                break;
            }
            unchecked { ++i; }
        }

        if (delimiterIndex == 0 || delimiterIndex == value.length) {
            return (false, bytes32(0));
        }

        bytes memory contractIdentifier = new bytes(delimiterIndex);
        for (uint256 i = 0; i < delimiterIndex; ) {
            contractIdentifier[i] = value[i];
            unchecked { ++i; }
        }

        return (true, keccak256(contractIdentifier));
    }
}
