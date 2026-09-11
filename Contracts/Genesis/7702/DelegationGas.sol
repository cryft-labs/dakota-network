// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.20 <0.9.0;

/// @dev Conservative bounds shared by the execution logic and sponsor. Clients
/// should query minimumCallGas on the deployed sponsor before signing vouchers.
library DelegationGas {
    uint256 internal constant MAX_EXECUTION_GAS = 5000000;
    uint256 internal constant MAX_INPUT_BYTES = 65536;
    uint256 internal constant POST_EXECUTION = 30000;

    function executionReserve(uint256 budget) internal pure returns (uint256) {
        return budget + (budget + 62) / 63 + POST_EXECUTION;
    }

    function minimumCallGas(uint256 budget, uint256 inputBytes) internal pure returns (uint256) {
        require(budget > 0 && budget <= MAX_EXECUTION_GAS && inputBytes <= MAX_INPUT_BYTES, "Invalid execution budget");
        // Reserve signature, storage, calldata hashing/copy and beacon lookup
        // before the execution check, then account for dispatcher DELEGATECALL.
        uint256 entry = executionReserve(budget) + 200000 + 16 * inputBytes;
        return entry + (entry + 62) / 63 + 10000;
    }
}
