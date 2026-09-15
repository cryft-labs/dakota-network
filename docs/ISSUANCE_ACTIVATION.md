# Activate reviewed registration

Updated 15 September 2026. This guide covers the development release, not public production launch.

## 1. Current state

The public card implementation, WorkerGasSponsor 1.3.0 and private combo implementation are deployed and upgraded. The new allowance policy is deployed but is not connected until the owner approves this workflow. Standard JSON, source files and metadata for all four implementations are pinned on Backend-01 IPFS and were read back through its gateway. The three public implementations are fully verified in Blockscout with Apache-2.0 licenses. Private implementation verification uses Pente bytecode, not a public-chain explorer address.

The existing card contract now has a maximum supply of 64, with 54 unused slots at block 5889. The owner paid 0.052 KOTA for 52 additional registered slots. Existing tokens, UIDs and redemption state were preserved. Its direct purchase path is restricted to the configured Paladin issuer. Read live capacity before further tests.

Browser publishing and the full issuance worker remain disabled until owner activation and the final operator preflight. Opening the preview is safe; a successful build does not mean that publishing is active.

## 2. What the owner must do

On a Nebula-connected computer with MetaMask, open:

[Activate reviewed registration](http://100.111.1.4:3035/dashboard/gas#issuance-activation)

1. Connect and sign in with **0x9247524040D91D5dd1521A25f2e7711d4a0fe921** on Dakota, chain ID **112311**. Login signatures are separate from the transactions below.
2. Find **Activate reviewed registration**. Confirm the new policy is **0xEE95c61E5fcbDAc780Ecfb9Bb2F8B94E7B0b97A3**, for moment.cards Account **0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340**. The fixed worker treasury is **0xe7850ecede5d6f7d0b2d2ccabfc2f29d2c345125** on Paladin-01.
3. Click the current action button and confirm its transaction in MetaMask. Wait for the receipt before clicking the next action. The page checks the connected wallet, exact release and current chain state, and simulates each transaction before asking for a signature.
4. Continue until the panel reports **On-chain activation is complete**, then tell the operator it is complete. The operator will verify receipts and enable the worker; the page does not enable server processes.

At the inspected block, nine transactions are required, in this order:

| Order | Dashboard action | Effect |
| --- | --- | --- |
| 1 | Pause sponsorship during the allowance switch | Temporarily pauses platform-wide sponsorship while current usage and limits migrate. |
| 2 | Preserve wallet allowance 0x9247…e921 | Copies the root wallet's existing override to the new policy. |
| 3 | Preserve wallet allowance 0xB2a4…1fd9 | Copies the other existing wallet override. |
| 4 | Connect the reviewed per-user gas policy | Switches this Account to the compatible policy. |
| 5 | Set the account safety ceiling to 0.03 KOTA per operation | Sets the platform ceiling; the 0.1 KOTA daily ceiling is retained. |
| 6 | Allow the account to use the reviewed operation ceiling | Sets matching tenant limits. |
| 7 | Authorize the Paladin worker and fixed treasury | Permits bounded receipt-cost settlement by this trusted worker. |
| 8 | Enable worker sponsorship for moment.cards | Opts this Account into that worker. |
| 9 | Resume sponsored operations | Ends the temporary platform-wide pause. |

Additional preservation steps appear automatically if wallet/tier rules or today's recorded spending changed before activation. Completed steps are not repeated after refresh. If a step fails, leave sponsorship paused, retain its transaction hash, and use **Refresh activation status** before contacting the operator. Never disconnect a policy or release a reservation to work around an unresolved transaction.

These transactions transfer zero native value, but your wallet pays their network fees. Initial testing does not require another Account deposit. Only your wallet can approve these steps because it controls the gas platform, Account and allowance policy. No private key should be shared.

## 3. Limits and accounting

The new default member allowance is **0.01 KOTA per operation and 0.02 KOTA per UTC day**. Existing explicit wallet and tier overrides are preserved; they can be lower than these defaults. In particular, the root wallet's prior 0.005-per-operation override is retained. Use an ordinary approved member for the initial card test, or deliberately update that wallet override through the policy editor if root-wallet creation is required.

User gas allocation is the spending control. Member/Creator/Studio default batch limits are respectively 5/25/100 cards per batch and 2/4/6 batches per minute, subject to the tenant's own ceilings. These are throughput safeguards, not cards-per-hour entitlements. The worker reserves a conservative whole-workflow maximum before starting; a user's available allocation must cover that reservation even when the eventual cost is smaller. Unused reservation is released after verified settlement.

The trusted worker attests actual public receipt costs, including reverted transaction gas, within on-chain reserved limits. This is not a trustless receipt proof. Payments go only to the fixed treasury. Users cannot withdraw their Account allocation. Enrollment and emergency deactivation remain platform-funded maintenance. Worker holds remain reserved across midnight and uncertain receipts.

## 4. Operator preflight after approval

Verify the new policy binding, preserved overrides/current-day usage, platform and tenant ceilings, worker/treasury binding and tenant opt-in. Confirm no unintended global pause remains. Recheck public/private bytecode pins, remaining inventory, IPFS access, database recovery, worker funding and the whole-workflow gas quote. Preserve the existing session database and enrollment encryption key.

Only then enable the review API's customer-creation flag and start the full worker against the same database. Stop the enrollment-only worker by its recorded process identity before replacing it. Record exact pushed commits and runtime paths. These desktop previews are not the final persistent production services.

The browser acceptance URL is [moment.cards preview](http://100.111.1.4:3033/). Test an approved ordinary member: create one card, optionally save an encrypted recovery file, publish, refresh and recover, then redeem to the displayed destination. The final artifact has **15 characters: three numeric characters assigned privately plus twelve random characters generated locally**. It is shown only after the private receipt. No separate PIN field is exposed.

Then use two different member sessions concurrently. Confirm disjoint token IDs and UIDs, correct creator-to-code mappings, one operation for repeated idempotency keys, independent gas budgets, one successful redemption per code and correct NFT ownership/metadata in the explorer. Batch metadata uses one exact document, so concurrent minting cannot shift metadata filenames. Complete QR/fragment and embedded login acceptance over HTTPS before production; plain HTTP on Nebula does not provide HTTPS transport guarantees.

## 5. Recovery and production limits

Owner-controlled pre-registration reserves public UID capacity and pays the CodeManager fee. A later mint and private code store remain separate, recoverable steps. Confirmed public mint followed by private-store failure must preserve the original purchase, code hashes, entropy and UIDs. The UI marks recovery required and blocks reminting. An operator must inspect and prepare a reviewed retry of only the private step; automatic resubmission of a confirmed reverted private transaction is not enabled.

Database uniqueness constraints bind chain/contract/token, chain/UID and operation/index. Receipt reconciliation, fenced worker leases and shared database reservations prevent duplicate allocation across concurrent requests. The production database must be PostgreSQL with all workers using the same database. Cross-process PostgreSQL tests passed; the desktop preview still uses SQLite.

The current three-digit private configuration allows at most **32,000 simultaneous active codes** in the shared contract (1,000 values × 32 entries). Monitor this before increasing volume. Final HTTPS/tunnel routing, service persistence, backups, payment credentials and developer-authority handoff remain production gates. No main-branch promotion or public production launch is implied by this activation.

## 6. API and release references

`GET /v1/platform/tenants/{tenant}/gas/issuance-activation` returns the live ordered checklist. `POST .../issuance-activation/prepare` accepts only `step` and the displayed `release` digest and returns an unsigned transaction. Both require the tenant operator and gas platform administrator; neither accepts arbitrary calldata or submits a transaction.

Network release evidence lives in `Contracts/Verification/20260915`: exact compiler inputs/outputs, deployment addresses, transaction hashes, IPFS publication receipts and explorer verification results. The source release commit is `9019cad324802c825d56117fd787c2a0f3ec1394`. The public implementations use solc 0.8.37/Osaka; the deployed private implementation retains the reviewed Pente-compatible Shanghai target. Opcode availability alone does not prove a private EIP-7702 transaction flow; this issuance release accounts for worker public-submission gas explicitly.
