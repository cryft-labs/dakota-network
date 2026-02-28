// SPDX-License-Identifier: Apache-2.0
//
// Original work Copyright 2021 ConsenSys.
// Derivative work Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// NOTICE: This file has been modified from the original Consensys/Besu
// ValidatorSmartContractInterface. Changes include extended overlord
// and voter introspection. Do not assume it is stock or unmodified —
// review all changes before use.

pragma solidity >=0.8.2 <0.8.20;

interface ValidatorSmartContractInterface {
    function getValidators() external view returns (address[] memory);
    function getVoters() external view returns (address[] memory);
    function isVoter(address potentialVoter) external view returns (bool);
    function isValidator(address potentialValidator) external view returns (bool);
    function getRootOverlords() external view returns (address[] memory);
    function isRootOverlord(address potentialOverlord) external view returns (bool);
}
