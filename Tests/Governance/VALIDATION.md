# Governance validation — 2026-09-10

This records local validation of the governance revision against source baseline `8999a9aa187c34232a5ce3bbd63fcaabc07b6ace`. It is not a live-network deployment or an independent security audit.

| Check | Result |
| --- | --- |
| Isolated EVM regression suite on publication branch | 41 passed |
| Repository sponsorship gate | Passed: storage positions, required methods, selector collisions, dispatcher statelessness, and Dakota's 32 KiB runtime limit |
| Self-contained Standard JSON replays | Ten reviewed contracts: runtime, ABI, and metadata matched |
| Existing callable interfaces | Validator, GasManager, CodeManager, and custom proxy retained existing inputs, outputs, and mutability |
| Legacy linear storage comparison | Validator: 15 existing fields preserved, five appended; GasManager: 25 preserved; CodeManager: 17 preserved; proxy: zero linear fields |
| Proxy/application voting storage | Separate namespaces; ballots tested at the same proxy address in both directions |
| Besu validator query | Raw `getValidators()` selector returns the same standard `address[]` encoding |

Reviewed runtime sizes, with optimizer 200 runs:

| Contract | Compiler / EVM | Bytes |
| --- | --- | ---: |
| ValidatorSmartContractAllowList | 0.8.19 / London | 21,412 |
| GasManager | 0.8.34 / Osaka | 23,467 |
| CodeManager | 0.8.34 / Osaka | 20,888 |
| TransparentUpgradeableProxy | 0.8.34 / Osaka | 18,841 |
| ProxyAdmin | 0.8.34 / Osaka | 3,200 |
| GasSponsor | 0.8.34 / Osaka | 12,129 |
| DakotaDelegationRegistry | 0.8.34 / Osaka | 13,112 |
| DakotaDelegation | 0.8.34 / Osaka | 5,341 |
| DakotaDelegationBeacon | 0.8.34 / Osaka | 1,046 |
| DakotaDelegationBeaconDispatcher | 0.8.34 / Osaka | 644 |

The documented chain limit remains **32,768 bytes**. Rebuild after any source or compiler change. These numbers do not approve existing archived artifacts, final genesis allocations, or an upgrade of populated storage. New proxy controller enumeration requires fresh-genesis state or a separately reviewed migration.

At this September 10 checkpoint, the following were pending: final root/voter/validator addresses, the retained validator-initializer exception, real Besu configuration and consensus tests, exact metadata publication to Backend-01, and application/Paladin/sponsorship integration review. Follow the [maintenance guide](../../Contracts/Genesis/GOVERNANCE.md).

Later genesis, live governance, Paladin and IPFS results are recorded in the
[current status index](../../docs/CURRENT_STATUS.md). Do not use these historical
0.8.34 runtime sizes as the current 0.8.37 deployment artifacts.
