# Contracts/Accounts

> Nothing here is deployed on chain 113211. Card accounts on the fresh chain are the design-kit card-account
> contracts (CardAccountSessionsV8_2_7), not code from this folder.

| File | License | Status |
| --- | --- | --- |
| `ERC6551Registry.sol` | MIT (ERC-6551 v0.3.1) | Generic permissionless CREATE2 registry, kept for reference |
| `Interfaces/*.sol` | MIT (ERC-6551) | Standard interfaces |
| `MomentProjectRegistry.sol`, `MomentInventoryToken.sol`, `MomentProjectProxy.sol` | Apache-2.0 | Retired project registry and inventory sources (the optional Cryft Inventory is decision D-6); not deployed |

The retired `MomentCardAccount` implementation and its tests were removed on 2026-11-26; the tag
`archive/pre-rebuild-20261125` keeps them. SPDX mapping is in `licenses.csv`.
