// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

/// @title DelegationGas
/// @notice Gas bounds shared by the delegated account logic and the gas sponsor.
/// @dev Conservative on purpose. Clients query `minimumCallGas` on the deployed sponsor before they sign a
///      voucher.
/// @custom:version 1.5.3
/// @custom:security-contact security@cryft.cards
library DelegationGas {
    // ─── Constants and immutables ────────────────────────────────────────────────────────────────

    uint256 internal constant MAX_EXECUTION_GAS = 5000000;
    uint256 internal constant MAX_INPUT_BYTES = 65536;
    uint256 internal constant POST_EXECUTION = 30000;

    /// @dev Signature check, storage, calldata hashing and copy, and the beacon lookup before execution.
    uint256 private constant _ENTRY_OVERHEAD = 200_000;
    uint256 private constant _CALLDATA_GAS_PER_BYTE = 16;
    /// @dev The dispatcher's DELEGATECALL into the shared logic.
    uint256 private constant _DISPATCH_OVERHEAD = 10_000;

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────────

    /// @notice The execution budget is zero or above the ceiling, or the input is too long.
    error InvalidExecutionBudget();

    // ─── Internal functions ──────────────────────────────────────────────────────────────────────

    /// @notice Gas the account must hold before it runs calls with `budget` gas (EIP-150 63/64 rule included).
    function executionReserve(uint256 budget) internal pure returns (uint256) {
        return budget + (budget + 62) / 63 + POST_EXECUTION;
    }

    /// @notice Smallest outer call gas a sponsor must forward for `budget` execution gas and `inputBytes` of
    ///         calldata.
    function minimumCallGas(uint256 budget, uint256 inputBytes) internal pure returns (uint256) {
        if (budget == 0 || budget > MAX_EXECUTION_GAS || inputBytes > MAX_INPUT_BYTES) {
            revert InvalidExecutionBudget();
        }
        uint256 entry = executionReserve(budget) + _ENTRY_OVERHEAD + _CALLDATA_GAS_PER_BYTE * inputBytes;
        return entry + (entry + 62) / 63 + _DISPATCH_OVERHEAD;
    }
}
