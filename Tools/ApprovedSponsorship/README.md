# Public registration and fee governance

The canonical public CodeManager on Dakota chain 112311 is
`0x000000000000000000000000000000000000c0DE`. It is a governed proxy, not a
tenant-specific registry. The fee is paid for each registered identifier; transaction
gas is a separate charge. Read the current fee instead of hard-coding it.

## Local codes and the dashboard

In the local-generation model, users generate and retain their redeemable secrets
on their own device. Dakota's **Registered contracts** page at `/dashboard/codes`
has no issuance, secret export or per-code activation controls. It reads public
registration counts and gift ownership from the chain. Do not upload a raw code,
PIN, entropy or private export to these endpoints, logs or the chat service.

The initial list checks gift contracts referenced by the current tenant's campaigns
and displays those currently owned by the connected wallet with a nonzero canonical
registration count. Discovery is paginated over campaign references, not an exhaustive
wallet index. An address lookup also supports locally deployed contracts. Unsupported
`owner()` interfaces are shown explicitly, never treated as ownership. Tenant operator
status and ownership of an individual card NFT do not imply ownership of the gift contract.

Registration count is not an unredeemed balance. Public status cannot establish
private active/frozen state when Pente mirroring is disabled. This page neither
reconstructs secrets nor counts private redemptions. Historical `/issues`, `/cards`
and operation-export routes remain legacy worker compatibility endpoints; they are
not part of this local registration view. The review runtime keeps card execution
and customer creation disabled. Re-enabling a legacy worker is a separate migration
decision; do not represent its server-generated secrets as local-only generation.

## Endpoints

All paths below are relative to `/v1/platform/tenants/{tenant}` and require an
origin-bound tenant wallet session. They return public data only and use the
chain/genesis verified by that session. A chain failure returns 503, not invented
zero balances, registrations or ownership. Never treat an API response as a signature.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/registered-contracts?offset=0&limit=25` | Owned registered gifts from this tenant's campaign references; limit 1–50 |
| GET | `/registered-contracts/{giftAddress}` | Registration count, identifier, owner, manager binding and optional pause state |
| GET | `/code-manager` | Canonical address, current fee in wei, fee vault, voters, quorum, block and sponsorship enforcement version |
| POST | `/code-manager/fee/prepare` | Prepare a simulated, unsigned `voteToUpdateRegistrationFee(uint256)` transaction |

Fee preparation accepts only `{"registration_fee_wei":"1000000000000000"}`.
The value is an exact positive integer string within uint256; no floats or scientific
notation. The signer must be both the current platform administrator and a current
CodeManager voter. The browser confirms chain 112311, its pinned genesis, the c0DE
destination and zero transaction value before opening the wallet confirmation.

## Fee voting

Use **Platform administration → CodeManager → Submit fee vote**. The existing
contract's two-thirds quorum determines when a fee changes. A submitted vote is not
proof of execution: follow the explorer receipt, check `RegistrationFeeUpdated`,
and refresh `registrationFee()`. In a one-voter configuration one vote reaches
quorum. With multiple voters each must vote for the exact same wei amount.
Duplicate votes and expired proposals follow existing governance rules.
The current contract rejects zero-valued vote targets, so zero registration fees
are not exposed. This release does not change the fee amount or the voting model.

The deployment wallet's initial CodeManager voter role must be handed to the
supplied management wallet with `voteToSetVoterConfiguration`, retaining voter-list
compatibility. The release journal records the actual handoff; a dashboard admin
role by itself cannot override the on-chain electorate. Other governance roles,
including gift ownership and chain root membership, remain separate.

## Sponsorship approval

`ApprovedGasSponsor` 1.2.0 upgrades the existing `0x…FEeD` proxy. Its mandatory
approval table is keyed by **target address and function selector**. Every outer
call in a delegated batch must match. Missing approval rejects the operation and
rolls back accounting. Even a valid platform voucher cannot override this rule.
Tenant managers can set budgets and user policies but cannot grant contract approval.

Approval pins target runtime bytes and, for supported genesis and managed application proxies,
the implementation address and runtime hash. An upgrade invalidates approval until
reviewed again. Gift-registration entry points also check `codeManagerAddress()`
against c0DE. Changing that pointer stops sponsorship. A clone at a new address,
a different selector, direct native transfer or a value above its approval cap is
rejected. Checks run after optional allowance-policy reservation callbacks.

The platform administrator uses `setCallApprovals` to grant or revoke reviewed
functions. A zero code hash revokes without depending on a working target. No
tenant switch disables enforcement. `initializeCallApprovals` supports one atomic
governed ProxyAdmin upgrade/seed migration and never changes Account management,
balances, allowance policy, voucher signer or registration fee.

Approval requires a source review, not just a getter that claims to use c0DE.
Do not approve arbitrary forwarding, multicall, deployment, upgrade, manager-changing
or token-withdrawal methods, or tenant-controlled mutable proxy implementations.
Review downstream calls and callbacks: an outer target allowlist is not a universal
tracer of internal EVM execution. The initial release admits only the already-reviewed
canonical registration, registered gift purchase/supply and tenant allowance-management
functions recorded in its deployment journal. The card worker still restricts its
supported gift implementation independently.

This restricts use of Dakota sponsorship funds. It does not prevent a user with
independently funded native tokens from deploying or calling another contract.
Preventing that across the chain would require separate transaction permissioning.
Restricted Account funding remains non-withdrawable by tenants; the historical
refundable-deposit bucket and platform recovery authority retain their existing rules.

## Maintenance and recovery

Before activation, confirm the old GasSponsor runtime, new Standard JSON/runtime,
the reviewed function list, API compatibility and isolated EVM results. Commit and
push reviewed inputs before deploying. Keep genesis and all validator binaries unchanged.
Use `Tools/ApprovedSponsorship/release.py --workspace <workspace>` for a read-only
plan and add `--execute` only for the authorized development deployment. The script
records signed transaction hashes before broadcasting and refuses a changed baseline.
Reconcile its journal on an uncertain response; do not recreate a pending transaction.

For a target upgrade, pause its flow, inspect the new implementation and callbacks,
reapprove exact hashes as platform administrator, and retest fee payment and
reimbursement. Never admit a clone automatically from tenant-supplied metadata.
CodeManager source and its positive-fee voting rules are unchanged in this release.
Fee-voter handoff is an atomic governance operation, not a new genesis.

Build artifacts, metadata, Standard JSON and the release journal are under
`Releases/ApprovedSponsorship/1.2.0` in dakota-network. Publish exact compiler
metadata and source bytes to Backend-01 IPFS and verify them by CID/read-back;
verify the implementation in Blockscout using its Apache-2.0 license. Historical
artifacts retain their original license and addresses. Read the release journal
for activation status; source publication alone is not on-chain activation.


## Development activation — September 14, 2026

The development chain now runs ApprovedGasSponsor **1.2.0**, implementation
`0x788e77a7f7e6d1E65a9C4b19D1C36ac93E749FB0`, behind the existing FEeD proxy. The upgrade and initial
approval table were applied atomically in block 5171. Account balances, managers,
allowance policies, signer, pause state, fee and fee vault were verified unchanged.

CodeManager's voter configuration was atomically handed from the deployment wallet
to `0x9247524040D91D5dd1521A25f2e7711d4a0fe921` in block 5172. Its current quorum
is one vote. This transfers CodeManager governance, not just a dashboard role.
The old deployment wallet can no longer cast CodeManager fee votes. The supplied
management wallet's fee vote was simulated successfully; **no fee change was sent**.
The current fee remains **0.001 KOTA per identifier**. Gift ownership and other
contracts' governance roles were not changed by this handoff.

The implementation is fully verified in Blockscout under **Apache-2.0**.
Metadata and source bytes were pinned and read back on Backend-01 IPFS;
bundle CID: `QmdyALkNEQ6pfibbMoZncw6pH7z4zM48c7LogBtHDFDRbS`. See the release's `deployment.json`
for addresses, exact approved function signatures and transaction hashes.

The strict allowlist is a **platform spending policy**, not a prerequisite for
c0DE to enforce registration fees. Official Dakota registrations already require
payment at c0DE, and platform-signed vouchers already control reimbursement.
Keep the extra restriction only if that matches the intended tenant gas offering.
It adds review overhead for custom contracts and does not stop independently funded
transactions. This policy decision remains separate from the fee-voting UI.
