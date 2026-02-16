// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.8.20;

interface ValidatorSmartContractInterface {
    function getValidators() external view returns (address[] memory);
    function getAllVoters() external view returns (address[] memory);
    function isVoter(address potentialVoter) external view returns (bool);
    function isValidator(address potentialValidator) external view returns (bool);
}
