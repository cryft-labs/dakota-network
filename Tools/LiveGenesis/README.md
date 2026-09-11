# Dakota development genesis initialization

## Scope and prerequisites

This deployment is authorized for the existing development chain 112311, genesis
`0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8`.
It neither replaces genesis nor changes the four live validator identities.
The implementation artifacts in `artifact-lock.json` reproduce from current source
and match the September 11 IPFS publication. Do not use older compiler output.

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
