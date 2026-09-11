# Dakota development genesis initialization

## Scope and prerequisites

This deployment is authorized for the existing development chain 112311, genesis
`0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8`.
It neither replaces genesis nor changes the four live validator identities.
The implementation artifacts in `artifact-lock.json` preserve the initial September
11 build and IPFS publication. CodeManager was subsequently upgraded during Paladin
acceptance; current source does not reproduce its original artifact. Replay its
exact Standard JSON for historical verification. The current address inventory is
`docs/current-contract-addresses.json`; read `Tools/Paladin/README.md` and use its
audit for the current strict implementation and private application. The original
`verify_chain.py` checks the original implementation links and will reject the
later CodeManager target; that mismatch requires the documented upgrade record,
not reverting the live proxy. Do not rerun initialization or validation stages as
routine maintenance. Never replace the historical artifact lock or journal.

Run with Python, web3, eth-account, Windows DPAPI access to the existing project
keystores, and the Nebula Nginx RPC at `100.111.69.1:8547`. Supply the workspace
root using `--workspace`. No secret appears in arguments, logs or this repository.
The wallet manifest is local at `outputs/cryft-wallets/deployment-wallets.json`.
Private credentials must never be committed.

## Initialization sequence

`initialize.py` without `--execute` checks chain identity, deployed genesis bytecode,
roots, voters, validator membership and service proxy state. With `--execute` it
requires a clean, pushed `review/compiler-standard-json` branch, then:

1. Deploys and atomically links GasManager (`0x...cafE`) and CodeManager (`0x...c0DE`)
   using the explicit temporary voter. Routes registration fees to GasManager.
2. Deploys delegation logic, its beacon and the direct immutable dispatcher.
3. Links GasSponsor (`0x...FEeD`), initially paused, and the registry
   (`0x...de1E6A7E`). Temporary platform admin and voucher signer are the project
   deployment account; the delegation test account receives no platform authority.
4. Transfers beacon ownership through propose/accept to the fixed registry and
   validates its release snapshot and implementation code.

The genesis validator contract and ProxyAdmin are already configured by genesis;
they are verified rather than reinitialized. The `0x...Face` agent-registry slot
has no approved implementation in the available source, so stays reserved.
Other unused preloaded proxy slots also remain reserved.

## Receipts, recovery and handover

The durable local journal is `outputs/live-genesis-20260911/transactions.json`.
Each signed transaction hash is saved before its single broadcast. A restart
reconciles an existing label by receipt and never silently signs a replacement.
If a receipt is missing, stop and reconcile the recorded hash and account nonce.
Never delete the journal to retry. Every creation is checked against its pinned
runtime, resolving only the constructor's expected immutable addresses.

The owner-supplied management address is
`0x9247524040D91D5dd1521A25f2e7711d4a0fe921`. Temporary deployment authority is
`0x633309d1155fD658a717e4f5E4FA853615400867`. Keep it until application testing and
verified recipient acceptance complete. GasSponsor and the registry use two-step
admin acceptance. GasManager, CodeManager and validator voters require atomic
voter rotation; chain roots require their own governance update. See
`Contracts/Genesis/GOVERNANCE.md`. A proposal alone does not complete handover.

Watch live transactions at `http://100.111.69.1:8080` over Nebula. Production
promotion, private Paladin delegation and Router lifecycle acceptance are separate
from this public-chain initialization.

## Live functional validation

`prepare_canary.py --workspace <workspace>` builds a small clearly marked development
fixture with the pinned compiler. Commit its source and refreshed artifact lock
before running `validate.py --workspace <workspace> --execute`. The stages can also
be selected individually using `--stage`. Completed stages are retained in the
journal; an incomplete stage needs state reconciliation before resuming.

Validation temporarily adds the test wallet as a voter to each independent voter
pool, proves first/second vote behavior and removes it again. Proxy controller
tests grant and remove a local test controller and exercise facade upgrades to the
same implementation. Actual validator membership stays unchanged. No irreversible
governance-management revocation is submitted.

The canary registers three public UIDs and tests scoped redemption, a deliberate
delivery failure and idempotent repair. It is not a Pente privacy group. Funding
tests send 0.000003 KOTA total to the existing test wallet, burn one dummy token
unit and one native wei, and use 0.01 KOTA of restricted treasury gas credit plus
a refundable 0.001 KOTA deployment-wallet deposit. The gas limit keeps room for
the delivery callback; a successful estimate alone can hide a caught callback failure.

A real type-4 authorization delegates the test EOA directly to the dispatcher.
Signed sponsorship executes a two-call batch, checks exact credit accounting,
rejects replay and malformed vouchers, and verifies that invalid owner signatures
cannot execute calls. An equivalent-code beacon upgrade and restoration prove
account nonce retention and release history. Invalid owner execution is deliberately
submitted once: policy consumes/reimburses an accepted voucher even if its inner
account call fails, and records `success=false` separately from receipt status.

Cleanup pauses sponsorship, removes the test relayer/group/treasury guardian,
disables the test tenant, returns unused gas credit to GasManager and withdraws
the refundable deposit to its payer. It tests cancellable admin nominations and
leaves the supplied management address nominated for later recipient acceptance.
The test EOA remains delegated for subsequent application tests, with no governance
or platform authority. Remaining bootstrap roles are explicitly recorded.
