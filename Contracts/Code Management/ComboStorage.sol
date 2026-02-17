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
  │  contracts (CodeManager, RedeemableCards).           │
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

    struct HashSeedDetails {
        bytes32 hash;
        string seed;
        string uniqueId;
    }

    struct UniqueIdDetails {
        address giftContract;
        string chainId;
        uint256 counter;
    }

    mapping(address => bool) public isWhitelisted;
    mapping(bytes32 => bool) public hashComboUsed;

    mapping(string => HashSeedDetails[]) public pinToHashSeeds;
    mapping(string => string) public uniqueIdToPin;
    mapping(string => UniqueIdDetails) public uniqueIdDetailsStorage;

    // Redemption records: ComboStorage records verified redemptions in its own state.
    // Gift contracts read these to safely finalize on their side.
    mapping(string => bool) public isRedemptionVerified;
    mapping(string => address) public redemptionRedeemer;

    event DataStoredStatus(
        string uniqueId,
        string chosenPin,
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

    function getPinForUniqueId(string memory uniqueId)
        public
        view
        onlyWhitelisted
        returns (string memory uniqueIdReturned, string memory pin)
    {
        require(bytes(uniqueId).length > 0, "Unique ID cannot be empty");
        string memory associatedPin = uniqueIdToPin[uniqueId];
        require(
            bytes(associatedPin).length > 0,
            "No PIN associated with this Unique ID"
        );
        return (uniqueId, associatedPin);
    }

    /// @notice Store a pre-generated PIN + hash/salt combo for a registered unique ID.
    ///         PINs and redemption codes are generated off-chain; this function
    ///         validates the unique ID against CodeManager and records the mapping.
    function storeData(
        string memory uniqueId,
        address giftContractAddress,
        string memory chainId,
        string memory pin,
        bytes32 hash,
        string memory salt
    ) public onlyWhitelisted {
        require(bytes(pin).length > 0, "PIN cannot be empty");
        require(bytes(uniqueId).length > 0, "Unique ID cannot be empty");
        require(
            giftContractAddress != address(0),
            "Invalid gift contract address"
        );

        // Verify the unique ID is registered in CodeManager
        require(
            codeManager.validateUniqueId(uniqueId),
            "Unique ID not registered in CodeManager"
        );

        // Check for the hashComboUsed right at the start to ensure the salt/hash combo hasn't been used.
        bytes32 comboHash = keccak256(abi.encodePacked(salt, hash));
        require(
            !hashComboUsed[comboHash],
            "This seed/hash combo is already used"
        );

        // Fetch unique ID details from the CodeManager contract
        UniqueIdDetails memory fetchedDetails;
        (
            fetchedDetails.giftContract,
            fetchedDetails.chainId,
            fetchedDetails.counter
        ) = codeManager.getUniqueIdDetails(uniqueId);

        // Verify details against supplied details
        require(
            fetchedDetails.giftContract == giftContractAddress,
            "Mismatched gift contract address"
        );
        require(
            keccak256(abi.encodePacked(fetchedDetails.chainId)) ==
                keccak256(abi.encodePacked(chainId)),
            "Mismatched chain ID"
        );

        // Extract contractIdentifier and counter from the uniqueId
        (, uint256 extractedCounter) = splitUniqueId(uniqueId);
        require(
            fetchedDetails.counter == extractedCounter,
            "Mismatched counter"
        );

        // Store the uniqueId details for later retrieval
        uniqueIdDetailsStorage[uniqueId] = fetchedDetails;

        // Store the PIN → hash/salt/uniqueId mapping
        pinToHashSeeds[pin].push(HashSeedDetails(hash, salt, uniqueId));
        uniqueIdToPin[uniqueId] = pin;

        // Mark the comboHash as used after successfully storing the details.
        hashComboUsed[comboHash] = true;

        emit DataStoredStatus(
            uniqueId,
            pin,
            giftContractAddress,
            chainId,
            fetchedDetails.counter,
            true
        );
    }

    function getDetailsFromCodeManager(string memory uniqueId)
        public
        view
        returns (
            address giftContract,
            string memory chainId,
            uint256 counter
        )
    {
        return codeManager.getUniqueIdDetails(uniqueId);
    }

    function splitUniqueId(string memory uniqueId)
        internal
        pure
        returns (string memory contractIdentifier, uint256 counter)
    {
        uint256 delimiterIndex = bytes(uniqueId).length;
        for (uint256 i = 0; i < bytes(uniqueId).length; i++) {
            if (bytes(uniqueId)[i] == "-") {
                delimiterIndex = i;
                break;
            }
        }

        require(
            delimiterIndex != bytes(uniqueId).length,
            "Invalid uniqueId format"
        );

        contractIdentifier = substring(uniqueId, 0, delimiterIndex);
        counter = parseUint(
            substring(uniqueId, delimiterIndex + 1, bytes(uniqueId).length)
        );
    }

    function parseUint(string memory s) internal pure returns (uint256) {
        uint256 res = 0;
        for (uint256 i = 0; i < bytes(s).length; i++) {
            // Ensure that each character is a digit
            require(
                bytes(s)[i] >= "0" && bytes(s)[i] <= "9",
                "Non-numeric character"
            );

            // Convert each character to its numeric value
            res = res * 10 + (uint256(uint8(bytes(s)[i])) - 48);
        }
        return res;
    }

    // Helper function to extract a substring
    function substring(
        string memory str,
        uint256 startIndex,
        uint256 endIndex
    ) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    function generateHash(string memory code, string memory seed)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(seed, code));
    }

    function redeemCode(string memory giftCode) public onlyWhitelisted {
        uint256 giftCodeLength = bytes(giftCode).length;
        uint8 dynamicPinLength;

        if (giftCodeLength == 9) {
            dynamicPinLength = 2;
        } else if (giftCodeLength == 12) {
            dynamicPinLength = 3;
        } else if (giftCodeLength == 16) {
            dynamicPinLength = 4;
        } else if (giftCodeLength == 20) {
            dynamicPinLength = 5;
        } else if (giftCodeLength == 25) {
            dynamicPinLength = 5;
        } else if (giftCodeLength == 30) {
            dynamicPinLength = 5;
        } else {
            revert("Invalid giftCode length.");
        }

        string memory pin = substring(giftCode, 0, dynamicPinLength);
        string memory code = substring(giftCode, dynamicPinLength, giftCodeLength);

        HashSeedDetails[] storage hashSeedArray = pinToHashSeeds[pin];

        for (uint256 i = 0; i < hashSeedArray.length; i++) {
            HashSeedDetails storage details = hashSeedArray[i];

            if (generateHash(code, details.seed) == details.hash) {
                string memory redeemedUniqueId = details.uniqueId;

                UniqueIdDetails memory redeemedDetails = uniqueIdDetailsStorage[
                    redeemedUniqueId
                ];

                // Query the gift contract for frozen/redeemed status via IRedeemable (read-only).
                // Frozen check is kept here so compromised uniqueIds cannot be redeemed
                // unless explicitly unfrozen by the creator first. Not all gift contracts
                // auto-unfreeze on redemption — ComboStorage stays agnostic.
                IRedeemable redeemable = IRedeemable(redeemedDetails.giftContract);
                require(
                    !redeemable.isUniqueIdFrozen(redeemedUniqueId),
                    "The provided uniqueId is frozen and cannot be redeemed."
                );
                require(
                    !redeemable.isUniqueIdRedeemed(redeemedUniqueId),
                    "The provided uniqueId has already been redeemed."
                );

                // Remove entry from array (shift left + pop)
                for (uint256 j = i; j < hashSeedArray.length - 1; j++) {
                    hashSeedArray[j] = hashSeedArray[j + 1];
                }
                hashSeedArray.pop();

                // Clear associated mappings
                delete uniqueIdToPin[redeemedUniqueId];
                delete uniqueIdDetailsStorage[redeemedUniqueId];

                // Record the verified redemption in ComboStorage's own state.
                // Gift contracts read this to safely finalize on their side.
                isRedemptionVerified[redeemedUniqueId] = true;
                redemptionRedeemer[redeemedUniqueId] = msg.sender;

                emit RedeemStatus(
                    redeemedUniqueId,
                    redeemedDetails.giftContract,
                    redeemedDetails.chainId,
                    msg.sender,
                    true
                );
                return;
            }
        }

        revert("Invalid code or PIN.");
    }
}
