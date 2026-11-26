# Cryft contract style (genesis-baked and genesis-linked contracts)

Applies to every contract baked into genesis or linked behind a genesis proxy: the validator contract (0x…1111),
the governance libraries, the proxy shell, ProxyAdmin (0x…FacAdE) and the vendored OpenZeppelin 4.9 helpers,
GasManager, CodeManager and CanonicalUid, the GasSponsor family, the delegation contracts, ManagedProxyAdmin.
Set by Chad on 2026-11-25: "consistent formatting, safety, layout and wording … like you'd expect from a
production grade system".

## 1. File header (exact shape)

```solidity
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity 0.8.37;

import {Name} from "./Name.sol";

/// @title CodeManager
/// @notice Registers unique code identifiers and records their redemption.
/// @dev Linked behind the genesis proxy 0x…c0DE. Upgrades are scheduled on the proxy and wait the network
///      upgrade delay. Storage is append-only.
/// @custom:version 3.1.0
/// @custom:security-contact security@cryft.cards
contract CodeManager is ... {
```

- Files derived from OpenZeppelin or Besu keep their original licence on the SPDX line and add one line under the
  copyright: `// Derived from OpenZeppelin Contracts v4.9.x (proxy/ERC1967/ERC1967Upgrade.sol), MIT.` (or
  `// Derived from Hyperledger Besu ValidatorSmartContractAllowList (Apache-2.0, ConsenSys 2021).`).
- Compiler: every genesis contract uses `pragma solidity 0.8.37;` and is built for EVM Osaka.
- The one exception is the validator contract (0x…1111). Its compiler must never change: solc 0.8.19, EVM London,
  optimizer 200 runs, through the soljson 0.8.19 build (`Tools/Genesis/inputs.json` → `compilers.validator`).
  It, its interface and the governance libraries it compiles (GovernanceMembers, GovernanceVotes) keep
  `pragma solidity >=0.8.19 <0.9.0;` and use no syntax newer than 0.8.19 (e.g. `if (!cond) revert Error();`,
  never `require(cond, Error())`).
- Named imports only (`import {X} from "...";`).
- `@custom:version` holds the contract's own version (the same string its `implementationVersion()` returns, if
  it has one; `implementationVersion()` is the one name for that getter).
  Libraries and interfaces carry the version of the set they ship with.
- No ASCII banners, no dates other than the copyright years, no old chain ids, hostnames, branch names or
  "Dakota"/"Moment". "Kota" only for the API (KotaAccess*).

## 2. Layout (Solidity style guide order, the same in every contract)

1. Type declarations (structs, enums)
2. Constants and immutables
3. Storage (state variables, then namespaced-storage accessors)
4. Events
5. Errors
6. Modifiers
7. Constructor (implementations: `_disableInitializers()`)
8. Initializers
9. receive / fallback
10. External functions
11. Public functions
12. Internal functions
13. Private functions

Inside each function group: state-changing first, then `view`, then `pure`.

**Never move a state variable relative to another state variable, and never change inheritance order.** Storage
order is the upgrade contract; `Tools/Genesis/layout_snapshot.py` proves it did not change.

Section dividers, one style everywhere (an indented line inside a contract, 100 characters wide in total):

```solidity
    // ─── Storage ─────────────────────────────────────────────────────────────────────────────────
```

Inside a library, constants and internal functions have no leading underscore (they are the library's API);
private library members do.

Casing: contracts, structs, events, errors and enum members `PascalCase`; functions, parameters, locals and storage
`camelCase`; constants and immutables `UPPER_SNAKE`; internal/private contract members start with `_`. The one
exception is the `proxy_` prefix on the genesis proxy shell's external functions (`proxy_scheduleUpgrade`,
`proxy_getGuardians`, …): it keeps them apart from every implementation selector behind the proxy, so it stays.

Section titles are exactly the names in the list above (e.g. `External functions`, `View functions` is not a
section; views sit at the end of their visibility group).

## 3. Wording

- NatSpec on every external and public function, event and error: `@notice` in plain words (one sentence,
  present tense, what it does for the caller), `@dev` only for non-obvious rules, `@param`/`@return` where the
  name alone is not enough.
- One vocabulary across contracts: **root** (root overlord listed in 0x…1111), **voter**, **overlord** (a proxy's
  local controller), **guardian**, **ballot** (a governance vote), **window** (seconds a ballot stays open),
  **upgrade delay**, **schedule / execute / cancel**.
- Custom errors with clear names (`UpgradeNotScheduled`, `NotGuardian`) instead of string reverts in code you
  touch. Error names are `PascalCase` nouns or states, never sentences.

## 4. Safety (checked in every contract)

- Checks-effects-interactions; a reentrancy guard on every function that moves coin or calls out after a state change.
- Every loop has an explicit bound (a constant cap on the array it walks).
- An event on every state change.
- Locked initializers on every implementation (`_disableInitializers()` in the constructor).
- No unused code, imports, variables or TODOs.
- Counters never fatal: no overflow or underflow may lock a contract.
