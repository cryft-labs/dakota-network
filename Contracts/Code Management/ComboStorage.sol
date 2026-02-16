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
  │                                                       │
  │  Redemption verification service.                      │
  │  Reads CodeManager + IRedeemable (view-only).          │
  │  Stores combo→uniqueId mappings and verification.      │
  │                                                       │
  │  No cross-contract state writes.                       │
  │  All validation via read-only calls to external        │
  │  contracts (CodeManager, GreetingCards).                │
  └───────────────────────────────────────────────────────┘
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.9.0/contracts/utils/StringsUpgradeable.sol";
import "./interfaces/ICodeManager.sol";
import "./interfaces/IRedeemable.sol";
import "./interfaces/IComboStorage.sol";

contract ComboStorage is IComboStorage {
    ICodeManager private codeManager;

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

    uint8 public pinLength;

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

    modifier onlyWhitelisted() {
        require(
            codeManager.isWhitelistedAddress(msg.sender),
            "Caller is not whitelisted"
        );
        _;
    }

    function updatePinLength(uint8 _newPinLength) public onlyWhitelisted {
        pinLength = _newPinLength;
    }

    function setCodeManagerAddress(address _codeManagerAddress) external onlyWhitelisted {
        require(
            _codeManagerAddress != address(0),
            "Invalid CodeManager address"
        );
        codeManager = ICodeManager(_codeManagerAddress);
    }

    function getCodeManagerAddress() external view returns (address) {
        return address(codeManager);
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

    function storeData(
        string memory uniqueId,
        address giftContractAddress,
        string memory chainId,
        bytes32 hash,
        string memory salt
    ) public onlyWhitelisted returns (string memory) {
        // Check for the hashComboUsed right at the start to ensure the salt/hash combo hasn't been used.
        bytes32 comboHash = keccak256(abi.encodePacked(salt, hash));
        require(
            !hashComboUsed[comboHash],
            "This seed/hash combo is already used"
        );

        require(
            giftContractAddress != address(0),
            "Invalid gift contract address"
        );
        require(bytes(uniqueId).length > 0, "Unique ID cannot be empty");

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

        string memory chosenPin = generateUniquePin(fetchedDetails.counter);
        storeHashSaltAndPin(chosenPin, hash, salt, uniqueId);

        // Mark the comboHash as used after successfully storing the details.
        hashComboUsed[comboHash] = true;

        emit DataStoredStatus(
            uniqueId,
            chosenPin,
            giftContractAddress,
            chainId,
            fetchedDetails.counter,
            true
        );
        return chosenPin;
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

    function generateUniquePin(uint256 nonce)
        internal
        view
        returns (string memory)
    {
        uint256 iterations = 32;
        bool isUnique = false;
        string memory chosenPin;
        uint256 senderValue = uint256(uint160(address(msg.sender)));
        string memory characters = "abcdefghijklmnopqrstuvwxyz0123456789";
        uint256 charLength = bytes(characters).length;

        for (uint256 i = 0; i < iterations; i++) {
            uint256 rand = (block.timestamp + senderValue + nonce + i) %
                (charLength *
                    charLength *
                    charLength *
                    charLength *
                    charLength);
            string memory candidatePin = string(
                abi.encodePacked(
                    bytes1(
                        bytes(characters)[
                            (rand /
                                (charLength *
                                    charLength *
                                    charLength *
                                    charLength)) % charLength
                        ]
                    ),
                    bytes1(
                        bytes(characters)[
                            (rand / (charLength * charLength * charLength)) %
                                charLength
                        ]
                    ),
                    bytes1(
                        bytes(characters)[
                            (rand / (charLength * charLength)) % charLength
                        ]
                    ),
                    bytes1(bytes(characters)[(rand / charLength) % charLength]),
                    bytes1(bytes(characters)[rand % charLength])
                )
            );

            if (!isUnique && pinToHashSeeds[candidatePin].length == 0) {
                isUnique = true;
                chosenPin = candidatePin;
            }
        }

        require(isUnique, "Failed to generate a unique PIN");
        return chosenPin;
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

    function storeHashSaltAndPin(
        string memory chosenPin,
        bytes32 hash,
        string memory salt,
        string memory uniqueId
    ) internal {
        require(
            bytes(chosenPin).length == pinLength,
            "PIN must be of length designated"
        );
        pinToHashSeeds[chosenPin].push(HashSeedDetails(hash, salt, uniqueId));
        uniqueIdToPin[uniqueId] = chosenPin;
    }

    function generateHash(string memory code, string memory seed)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(seed, code));
    }

    function redeemCode(string memory giftCode) public onlyWhitelisted {
        uint8 dynamicPinLength;

        // Determine the pin length based on the length of the giftCode
        uint256 giftCodeLength = bytes(giftCode).length;
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
        // Extracting the PIN and code using the dynamicPinLength
        string memory pin = substring(giftCode, 0, dynamicPinLength);
        string memory code = substring(
            giftCode,
            dynamicPinLength,
            giftCodeLength
        );

        bool validCode = false;
        string memory redeemedUniqueId = "";

        HashSeedDetails[] storage hashSeedArray = pinToHashSeeds[pin];
        if (hashSeedArray.length > 0) {
            for (uint256 i = 0; i < hashSeedArray.length; i++) {
                HashSeedDetails storage details = hashSeedArray[i];

                bytes32 generatedHash = generateHash(code, details.seed);

                if (generatedHash == details.hash) {
                    validCode = true;
                    redeemedUniqueId = details.uniqueId;

                    UniqueIdDetails
                        memory redeemedDetails = uniqueIdDetailsStorage[
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

                    // Clear the hash and seed
                    details.hash = bytes32(0);
                    details.seed = "";

                    // Remove the redeemed uniqueId from the pinToHashSeeds mapping
                    delete hashSeedArray[i];
                    for (uint256 j = i; j < hashSeedArray.length - 1; j++) {
                        hashSeedArray[j] = hashSeedArray[j + 1];
                    }
                    hashSeedArray.pop();

                    // Remove the redeemed uniqueId's association with the PIN
                    delete uniqueIdToPin[redeemedUniqueId];

                    // Clear the uniqueIdDetails from storage
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
                        validCode
                    );
                    break;
                }
            }
        }

        if (!validCode) {
            revert("Invalid code or PIN.");
        }
    }
}
