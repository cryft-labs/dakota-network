// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.8.20;

/**
 * @title ICodeManager
 * @notice Interface for the CodeManager contract.
 *         CodeManager is responsible ONLY for unique ID registration and validation.
 *         Status management (frozen, redeemed, ownership) is delegated to individual gift contracts.
 */
interface ICodeManager {
    struct ContractData {
        address giftContract;
        string chainId;
    }

    /// @notice Returns the registration details for a unique ID.
    function getUniqueIdDetails(string memory uniqueId)
        external
        view
        returns (
            address giftContract,
            string memory chainId,
            uint256 counter
        );

    /// @notice Returns whether a unique ID was validly registered (valid counter, valid contract identifier).
    function validateUniqueId(string memory uniqueId) external view returns (bool isValid);

    /// @notice Returns the contract data (giftContract, chainId) for a given contract identifier.
    function getContractData(string memory contractIdentifier)
        external
        view
        returns (ContractData memory);

    /// @notice Compute the contract identifier and return the counter for a given giftContract + chainId.
    function getIdentifierCounter(address giftContract, string memory chainId)
        external
        view
        returns (string memory contractIdentifier, uint256 counter);

    /// @notice Returns whether an address is whitelisted.
    function isWhitelistedAddress(address addr) external view returns (bool);

    /// @notice The fee (in wei) required per unique ID registration.
    function registrationFee() external view returns (uint256);

    /// @notice Register unique IDs by incrementing the counter range.
    ///         Permissionless — requires `registrationFee * quantity` payment.
    function registerUniqueIds(
        address giftContract,
        string memory chainId,
        uint256 quantity
    ) external payable;
}
