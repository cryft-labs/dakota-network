# Optional tenant allowances — release 1.0.0

This release adds GasSponsor 1.1.0 without changing existing storage fields or
genesis. Existing balances, managers, signers, nonces and restricted funding remain
intact. Tenants may connect a policy and separately require sponsored-wallet
approval. The standard template is Apache-2.0, compiled with Solidity 0.8.37 for
Osaka; the validator contract and chain genesis are unchanged.

`Contracts/Templates/TenantAllowancePolicy.sol` is tenant-owned, independent of
card/redemption lifecycles and has no funds-transfer or arbitrary-execution method.
Constructor arguments are GasSponsor, Account ID, owner, optional membership
registry, initial per-operation allowance, initial daily allowance and additional
admin wallets. Amounts are native-token wei. Both amounts zero disable defaults.
Initial limits apply per member and to explicitly initialized admin wallets.
Admin wallet grants allow spending only; they do not grant contract ownership.

Wallet overrides take priority over tier rules, then defaults. With a membership
registry, nonmembers need an explicit override; suspension or a registry failure
blocks execution. Both wallet and credential counters are enforced so transferring
an existing credential or reissuing to the same wallet does not reset that day's
usage. An operator creating an entirely new identity must apply its own admission
policy. This is not a proof that two different credentials belong to one person.

Every operation reserves its maximum cost and settles the same reimbursement that
the Account pays. An unsuccessful inner operation is charged; an outer revert
rolls back accounting and execution. Periods reset at UTC midnight. Changes to
limits preserve counters. Each operation snapshots its policy and overhead so an
admin can pay for policy-management calls without escaping its current charge.
An Account manager can disconnect a broken policy without calling its code.
Disconnecting stops per-user enforcement; it does not delete the old history.

The reimbursement model includes measured execution and configured bookkeeping
overhead. With a policy, `costOverheadGas(account)` includes an additional 150,000
gas allowance for post-measurement settlement. It is not an exact receipt fee.
Voucher builders must read this getter; the existing `fixedOverheadGas()` is only
the base overhead. Policy callbacks are capped at 350,000 gas and must acknowledge
their selector. Customized policies must satisfy this interface and gas bound.

Deployment must use committed, pushed artifacts. The operator script records a
signed transaction hash before sending, checks nonce exclusivity, verifies chain
112311 and the pinned genesis, and never exports signing keys. Preserve its journal
on ambiguous sends; reconcile the recorded hash instead of creating another intent.
No genesis replacement, balance migration, new root or governance bypass is needed.

For root handover, the supplied admin owns the policy from construction. Account
management is a separate existing role and requires the GasSponsor administrator
to call `setSponsorManager`. Keep the development signer out of new policy
ownership. Review existing root-overlord membership separately; this feature does
not change it. Historical ordinary deposits remain refundable under existing
contract rules; gas-only funding remains non-withdrawable by tenants.

## Live activation and maintenance — 2026-09-14

| Role | Address |
| --- | --- |
| GasSponsor proxy | `0x000000000000000000000000000000000000FEeD` |
| GasSponsor 1.1.0 implementation | `0x83AaF0a9d4FE1748e1fCFFd5a3adfd60a16E86dF` |
| moment.cards Account | `0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340` |
| TenantAllowancePolicy | `0x1D205B1d531422f615101FE93622D65AB54943D2` |
| Policy owner / tenant operator | `0x9247524040D91D5dd1521A25f2e7711d4a0fe921` |
| Account manager | `0x9247524040D91D5dd1521A25f2e7711d4a0fe921` |
| Service voucher signer | `0xB2a458984b9dbaD55F1c70B59c22d7A1Fe931fd9` |

The policy is connected with membership integration, automatic default-member
allowances and optional explicit wallet approval switched off. Explicit denials
still apply. Initial allowances are **0.005 KOTA per operation and 0.01 KOTA per
wallet/member per UTC day**. The owner and development admin wallet have explicit
initial allowances. Account ceilings remain 0.005 per operation and 0.1 per day.
Available funds are live state; do not treat a recorded balance as a current quote.

The live member and admin-management transactions passed inner-success,
reimbursement/allowance reconciliation and replay checks. Both deployed contracts
are fully verified in the Nebula explorer under Apache-2.0. Exact metadata and
sources are pinned on Backend-01; bundle CID: `QmPjK4RW1ZV9YbrJMUr28f5BNPJjGgVsna51yn4vytRkyo`.
The deployment record contains transaction hashes, bytecode hashes and metadata CIDs.

**Account handoff confirmed:** the supplied admin wallet signed
`setSponsorManager(Account, operator)` with zero value in block 4390.
[View the confirmed transaction](http://100.111.69.1:8080/tx/0xd16513b2a8c3b10d8228d8c5860a7d876f0424bdb624c58fea62aca2ee962728).
The Account manager and allowance-policy owner are now the tenant operator shown
above. Read-only checks at block 4395 confirmed that the operator can set
Account limits and the previous manager receives `NotSponsorManager` for that call.
The handoff changed only the Account manager; its balance, limits and enabled state
were preserved. The service voucher signer remains `0xB2a458984b9dbaD55F1c70B59c22d7A1Fe931fd9`.
This Account handoff does not change other chain governance or deployment roles.
No further Account-manager or policy-owner handoff is pending. The development
service wallet does not receive tenant dashboard admin access through sponsorship.

The connected management wallet currently pays dashboard control/deployment fees.
Native delegated admin sponsorship is proven on chain, but an automatic dashboard
relay remains separate work. Paladin service-worker charges also remain separate.
Keep the service relayer funded for transaction fees; it is reimbursed after a
successful outer sponsored operation. Do not fund the allowance policy itself.
Payment checkout remains disabled. The updated sites are local Nebula-accessible
production builds for review, not a new public-domain/Droplet deployment.
