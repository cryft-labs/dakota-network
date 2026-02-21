// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.8.20;

/*
   _____           __       ______
  / ___/__  __ _  / /  ___ / __/ /____  _______ ____ ____
 / /__/ _ \/  ' \/ _ \/ _ \\ \/ __/ _ \/ __/ _ `/ _ `/ -_)
 \___/\___/_/_/_/_.__/\___/___/\__/\___/_/ \_,_/\_, /\__/
                                               /___/ By: CryftCreator

  Version 1.0 — Production Combo Storage  [NON-UPGRADEABLE]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  Redemption verification service.                    │
  │  Reads CodeManager + IRedeemable (view-only).        │
  │  Stores combo→uniqueId mappings and verification.    │
  │                                                      │
  │  No cross-contract state writes.                     │
  │  All validation via read-only calls to external      │
  │  contracts (CodeManager, RedeemableTokens).          │
  └──────────────────────────────────────────────────────┘
*/

import "./interfaces/ICodeManager.sol";
import "./interfaces/IRedeemable.sol";
import "./interfaces/IComboStorage.sol";

contract ComboStorage is IComboStorage {
    /// @dev Hard-code the CodeManager address before deployment.
    ///      Update this value to match the deployed CodeManager proxy.
    ICodeManager public constant codeManager = ICodeManager(0x0000000000000000000000000000000000000000);

    /// @dev Hard-code the overlord address before deployment.
    ///      This address is pre-whitelisted and can add/remove whitelist entries.
    address public constant overlord = address(0x0000000000000000000000000000000000000000);

    struct HashDetails {
        string uniqueId;
        bool exists;
    }

    /// @dev Maximum number of hash/uniqueId entries allowed per PIN slot.
    uint256 public constant MAX_PER_PIN = 32;

    mapping(address => bool) public isWhitelisted;

    /// @dev PIN → codeHash → redemption details. The PIN acts as a bucket
    ///      index for efficient O(1) lookup. The codeHash is keccak256(giftCode)
    ///      where giftCode = pin + code, computed off-chain.
    mapping(string => mapping(bytes32 => HashDetails)) public pinToHash;

    /// @dev Tracks how many hashes are currently stored under each PIN.
    mapping(string => uint256) public pinSlotCount;

    // Redemption records: ComboStorage records verified redemptions in its own state.
    // Gift contracts read these to safely finalize on their side.
    mapping(string => bool) public isRedemptionVerified;
    mapping(string => address) public redemptionRedeemer;

    event DataStoredStatus(
        string uniqueId,
        bytes32 codeHash,
        address giftContract,
        string chainId,
        uint256 storedCounter,
        bool status
    );

    event RedeemStatus(
        string uniqueId,
        address giftContract,
        string chainId,
        address redeemer,
        bool status
    );

    event WhitelistUpdated(address indexed account, bool status);

    modifier onlyOverlord() {
        require(msg.sender == overlord, "Caller is not the overlord");
        _;
    }

    modifier onlyWhitelisted() {
        require(
            isWhitelisted[msg.sender] || msg.sender == overlord,
            "Caller is not whitelisted"
        );
        _;
    }

    function addToWhitelist(address account) external onlyOverlord {
        require(account != address(0), "Cannot whitelist zero address");
        isWhitelisted[account] = true;
        emit WhitelistUpdated(account, true);
    }

    function removeFromWhitelist(address account) external onlyOverlord {
        isWhitelisted[account] = false;
        emit WhitelistUpdated(account, false);
    }

    /// @notice Store multiple pre-computed hashes in one transaction.
    ///         Codes that cannot be stored (PIN slot full, duplicate hash,
    ///         invalid uniqueId, etc.) are skipped with a status=false event.
    ///         The transaction always succeeds — partial storage is allowed.
    /// @return stored Per-index boolean indicating which entries were stored.
    function storeDataBatch(
        string[] calldata uniqueIds,
        string[] calldata pins,
        bytes32[] calldata codeHashes
    ) external onlyWhitelisted returns (bool[] memory stored) {
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
                emit DataStoredStatus(
                    uniqueIds[i], codeHashes[i],
                    address(0), "", 0, false
                );
                unchecked { ++i; }
                continue;
            }

            // External validation via CodeManager (try/catch so one bad
            // uniqueId doesn't revert the entire batch).
            try codeManager.getUniqueIdDetails(uniqueIds[i])
                returns (address giftContract, string memory chainId, uint256 counter)
            {
                pinToHash[pins[i]][codeHashes[i]] = HashDetails(uniqueIds[i], true);
                pinSlotCount[pins[i]]++;
                stored[i] = true;

                emit DataStoredStatus(
                    uniqueIds[i], codeHashes[i],
                    giftContract, chainId, counter, true
                );
            } catch {
                emit DataStoredStatus(
                    uniqueIds[i], codeHashes[i],
                    address(0), "", 0, false
                );
            }

            unchecked { ++i; }
        }
    }

    /// @notice Redeem a code by submitting its PIN and hash.
    ///         Off-chain: giftCode = pin + code, codeHash = keccak256(giftCode).
    ///         PIN routes to the correct bucket, hash verifies the code.
    ///         No cleartext code ever touches the chain. O(1) lookup.
    function redeemCode(string memory pin, bytes32 codeHash) public onlyWhitelisted {
        require(bytes(pin).length > 0, "PIN cannot be empty");
        require(codeHash != bytes32(0), "Hash cannot be zero");

        HashDetails storage details = pinToHash[pin][codeHash];
        require(details.exists, "Invalid PIN or code hash");

        string memory redeemedUniqueId = details.uniqueId;

        // Fetch details from CodeManager on the fly
        (address giftContract, string memory chainId, ) =
            codeManager.getUniqueIdDetails(redeemedUniqueId);

        // Query the gift contract for frozen/redeemed status via IRedeemable (read-only).
        IRedeemable redeemable = IRedeemable(giftContract);
        require(
            !redeemable.isUniqueIdFrozen(redeemedUniqueId),
            "The provided uniqueId is frozen and cannot be redeemed."
        );
        require(
            !redeemable.isUniqueIdRedeemed(redeemedUniqueId),
            "The provided uniqueId has already been redeemed."
        );

        // Clear stored data and free the PIN slot
        delete pinToHash[pin][codeHash];
        pinSlotCount[pin]--;

        // Record the verified redemption
        redemptionRedeemer[redeemedUniqueId] = msg.sender;
        isRedemptionVerified[redeemedUniqueId] = true;

        emit RedeemStatus(
            redeemedUniqueId,
            giftContract,
            chainId,
            msg.sender,
            true
        );
    }
}