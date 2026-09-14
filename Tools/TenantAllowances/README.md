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
