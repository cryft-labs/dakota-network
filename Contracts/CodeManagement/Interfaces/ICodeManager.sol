// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title ICodeManager
/// @notice Registration, validation and public active state of unique code identifiers.
/// @custom:version 3.1.0
/// @custom:security-contact security@cryft.cards
interface ICodeManager {
    // ─── Type declarations ───────────────────────────────────────────────────────────────────────

    /// @notice The gift contract and chain id registered under a contract identifier.
    struct ContractData {
        address giftContract;
        string chainId;
    }

    // ─── External functions ──────────────────────────────────────────────────────────────────────

    /// @notice Registers unique codes by advancing the counter range, paid at `registrationFee` each.
    function registerUniqueIds(
        address giftContract,
        string memory chainId,
        uint256 quantity
    ) external payable;

    /// @notice Returns the registration details for a unique ID.
    function getUniqueIdDetails(string memory uniqueId)
        external
        view
        returns (address giftContract, string memory chainId, uint256 counter);

    /// @notice Returns whether a unique ID was validly registered (valid counter, valid contract identifier).
    function validateUniqueId(string memory uniqueId) external view returns (bool isValid);

    /// @notice Returns whether a unique ID is currently active; invalid or unregistered IDs return false.
    function isUniqueIdActive(string memory uniqueId) external view returns (bool isActive);

    /// @notice Returns whether a unique ID has been redeemed.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool);

    /// @notice Returns the gift contract and chain id registered under a contract identifier.
    function getContractData(string memory contractIdentifier)
        external
        view
        returns (ContractData memory);

    /// @notice Returns the contract identifier and current counter for a gift contract and chain id.
    function getIdentifierCounter(address giftContract, string memory chainId)
        external
        view
        returns (string memory contractIdentifier, uint256 counter);

    /// @notice Returns the registered counter for a contract identifier.
    function getCounterByIdentifier(string memory contractIdentifier)
        external
        view
        returns (uint256);

    /// @notice Returns the fee in wei per registered unique ID.
    function registrationFee() external view returns (uint256);
}
