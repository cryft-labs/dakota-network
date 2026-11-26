// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// Derived from Hyperledger Besu ValidatorSmartContractInterface (Apache-2.0, ConsenSys 2021).
pragma solidity >=0.8.19 <0.9.0;

/// @title ValidatorSmartContractInterface
/// @notice What Besu (QBFT contract-validator mode) and the genesis proxies read from the validator contract.
/// @dev Compiled with the validator contract (solc 0.8.19, London), so it uses no newer syntax.
/// @custom:version 1.0.0
/// @custom:security-contact security@cryft.cards
interface ValidatorSmartContractInterface {
    /// @notice Returns the approved validator set that QBFT uses.
    function getValidators() external view returns (address[] memory);

    /// @notice Returns the approved voter set.
    function getVoters() external view returns (address[] memory);

    /// @notice Returns true if `potentialVoter` is an approved voter.
    function isVoter(address potentialVoter) external view returns (bool);

    /// @notice Returns true if `potentialValidator` is in the approved validator set.
    function isValidator(address potentialValidator) external view returns (bool);

    /// @notice Returns the approved root set.
    function getRootOverlords() external view returns (address[] memory);

    /// @notice Returns true if `potentialOverlord` is an approved root.
    function isRootOverlord(address potentialOverlord) external view returns (bool);
}
