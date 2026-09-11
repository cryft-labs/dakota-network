# Development hardening checkpoint, 2026-09-11

This checkpoint is for review-branch development testing. Main is retained. All
listed source changes are local-regression verified; live Besu/Pente/application
acceptance and production promotion are not complete.

## Contract changes

| Area | Current changes |
|---|---|
| Validator | Snapshot electorate/quorum/expiry; unique membership; working second membership vote; explicit provider refresh; provider failures cannot lower quorum; atomic replacement; four-validator floor; bounded provider reads. London/0.8.19 and getValidators ABI retained. |
| GasManager | Same snapshot governance; explicit bootstrap voters; voter recovery; guarded V2 migration requiring V1 initialization; restricted gas-credit funding. |
| CodeManager | Same governance; canonical bounded UIDs; gift/approved-registrar registration; scoped group/gift authority; bounded batches; committed recipient and permissionless delivery retry; bounded call gas/return data; reentrancy guard. |
| Custom proxies | Namespaced proxy voting; dynamic roots and safe membership; 64 local plus 64 root union capacity; memory-safe forwarding uses free memory; fixed ProxyAdmin preserved. |
| PrivateComboStorage | Same-batch PIN/hash reservations; canonical identifiers/bounded batches; initializer and locked implementation; rotatable admin/service/forwarder; propose/accept/cancel admin; no hard-coded administrative EOA. Per-UID manager cleanup remains part of handover. |
| GreetingCards | Canonical parsing with invalid-ID rejection; explicit-owner initializer; two-step owner/cancellation and disabled renunciation; delivery retry uses CodeManager's committed recipient/receipt. |
| Delegation dispatcher | EOA designates immutable v2 dispatcher directly; beacon/protocol getters; no per-account EIP-1967 link or proxy initialization; corrected memory forwarding. |
| Delegation logic | Shared conservative gas envelope; return data capped per-call/aggregate; existing owner signatures and nonce semantics retained. |
| Delegation registry | Direct route/code-hash readiness; explicit initial admin; v2 status semantics; validated implementation releases; two-step admin and beacon handover/cancellation. |
| Delegation beacon | Two-step ownership, cancellation and disabled renunciation; root-validated bootstrap owner retained. |
| GasSponsor | Pins direct dispatcher runtime/protocol; shared minimumCallGas check; refundable funds separated from restricted treasury gas credits; manager withdrawal cannot extract credit; credit-first spending; platform-only credit recovery; two-step admin recovery preserved. |
| PrivateMetaTxRelay | Legacy source retained and disabled. Native private delegation and delegated public settlement must be tested before considering a hardened fallback. |

## Compiler and genesis

The public/private compiler default is 0.8.37. Public target Osaka, validator London
with 0.8.19, private compatibility control Shanghai pending actual runtime evidence.
Every compiled contract/interface/library has embedded-source standard JSON and
exact metadata. Windows long output paths work without truncating source structure.
Automatic IPFS publication checks references, exact bytes and pins and supports retry.

The genesis archive contains 32,436 allocations, updated validator/ProxyAdmin and
32,431 proxy runtimes. Existing storage, all four validator identities and all
balances are preserved: management 32, two development accounts 1 each. The only
header change from the prior development candidate is the supported Besu empty-block
option name retaining 64 seconds. See `Contracts/Genesis/development-release.json`
and `SHA256SUMS`. Extraction round-trip and every allocation comparison passed.

## Evidence

- Full source compilation: no failed root sources.
- 93 local contract/compiler regression checks passed; six optional IPFS tests were
  initially skipped, then all 15 IPFS checks passed with real isolated offline Kubo,
  including the complete artifact set. These are overlapping suites, not 108 unique tests.
- All 90 unique exported standard JSON files independently reproduce creation/runtime
  bytecode, ABI and exact metadata.
- Genesis EVM projection verifies validator return encoding and proxy/root reads.
- IPFS publication/read-back was local and offline; Backend publication is still pending.

## Remaining release work

No live chain transactions or complete application lifecycle is claimed. Verify
Besu genesis acceptance, private target/EIP-7702 and delegated settlement, deploy
the explorer, implement blocked Kota live operations and outstanding durable
authorization/idempotency/job ownership work, review Kota account-registration
contracts and newer frontend/widget sources, and test load/restore/handover.
The owner's initializer exception remains scoped to closed bootstrap. New owner
acceptance still needs that owner's signature; never claim it was performed by
the deployment account. Deploy only pushed review commits and keep main untouched.
