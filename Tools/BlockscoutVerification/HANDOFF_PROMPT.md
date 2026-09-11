# Dakota Blockscout verification and IPFS validation handoff

Later deployment: the ten Kota tenant instances are also fully verified. Their
0.8.34/Osaka/MIT inputs and receipts live in KotaRouter
`router_v4/contracts/deployment/` and `releases/20260911-v1.4.0/`.
The original 32,451-address audit below remains scoped to its recorded blocks;
see [current status](../../docs/CURRENT_STATUS.md) before interpreting it as a current chain-wide count.

**Execution checkpoint, 2026-09-11:** the owner reassigned this work to the original
agent, which completed all 32,451 public source verifications. Read
`docs/blockscout-verification-20260911.md` and its evidence before doing any work.
The instructions below are retained for revalidation and future deployments; do
not assume the original missing-address/upload backlog still exists. All 224 IPFS
objects and all five private code hashes were revalidated successfully.

Act as the engineer completing source verification for the existing Dakota
development chain. Upload and validate the audited public Solidity contracts on
our running Blockscout. Validate the IPFS metadata/source/artifact pins. Finish
with an address-by-address report and updated maintenance documentation.

## 1. Start from the correct source and existing deployment

Use `https://github.com/cryft-labs/dakota-network.git`, branch `main`, after confirming
it includes `Tools/BlockscoutVerification/HANDOFF_PROMPT.md` and the complete
`Contracts/Verification/20260911/` package. Fetch without overwriting local changes
and record the exact remote/local commit. The owner has authorized merging the
completed contract work; the earlier work branch remains
`review/compiler-standard-json`. If main lacks the package, report this rather
than using old main artifacts. Do not merge unrelated unfinished API/site branches.

On the current workstation the repository is
`C:/Users/ChadS/Documents/Codex/2026-09-08/a/work/source/dakota-network`.
Read `IMPLEMENTATION.md`, `Tools/BlockscoutVerification/README.md`,
`Tools/Explorer/README.md`, `Tools/Paladin/README.md`, and
`docs/current-contract-addresses.json`. Resolve current paths if running elsewhere.

Use these connection details as configuration, not shell-interpolated input:

```dotenv
CHAIN_ID=112311
GENESIS_BLOCK_HASH=0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8
EXPLORER_URL=http://100.111.69.1:8080
ARCHIVE_RPC_URL=http://100.111.69.1:8547/
BACKEND_NEBULA_IP=100.111.67.1
FRONTEND_NEBULA_IP=100.111.69.1
PALADIN_NEBULA_IP=100.111.32.201
ARTIFACT_ROOT=Contracts/Verification/20260911
IPFS_RECEIPT=docs/blockscout-artifact-ipfs-20260911.json
IPFS_MANIFEST_CID=QmQazJy8zGUhXUxhQJMrD5cVaPTmUwZYoBagDrSs78yGJf
```

Use the existing SSH identity/host-key inventory and Nebula, never public bootstrap
addresses or newly generated keys. Existing workstation helper:
`work/production-hardening/hostctl.py`, invoked with Nebula enabled. Backend Kubo
API/gateway are loopback 5001/8081; access them through a pinned SSH forward or
locally on Backend-01. Do not expose the publishing API, change peering or deploy
Cloudflare tunnels for this task. Keep Paladin signing/recovery secrets on Paladin-01;
do not export, display or put them in prompts, logs, Git or IPFS.

## 2. Verify the package before uploading

Read `manifest.json`, `genesis-addresses.csv`, `licenses.csv`,
`native-precompiles.json`, and the IPFS receipt. Require `coverage_passed`, every
build's compiler replay flag and matching SHA-256 for all files. The recorded audit
covers 21 builds, 32,433 genesis contracts, 18 later public creations and five private
deployments. Check the manifest's actual audit block; inspect later creation traces
and separately inventory any newly deployed contracts before claiming full current
coverage. Do not discard historical implementations/canaries still on chain.

Every build folder supplies exact `standard-input.json`, full `standard-output.json`,
`metadata.json`, ABI and creation/runtime bytecode. Independently compile inputs
with their recorded compiler versions if a mismatch is suspected. Preserve optimizer,
EVM, source paths, metadata settings, imported notices and bytecode. Never recompile
an old deployment from today's changed source or strip metadata to force a match.
Compiler targets are validator 0.8.19 London, core public logic 0.8.37 Osaka, and
private/shared proxy builds 0.8.37 Shanghai as recorded per artifact. Both full
compiler version strings are in the manifest.

For each metadata CID embedded in bytecode, fetch exact metadata and sources through
Backend Kubo API and gateway, verify hashes/CIDs against the manifest and metadata,
and require recursive pins. Validate Standard JSON input/output CIDs from the receipt
as well. The completed publication receipt records 224 distinct pinned objects with
exact API/gateway readback from source commit
`695bc9a84f3a1652115b3f5dd5abcc26430cb000`. If a pin is missing, republish only the
exact reviewed content using the
existing authorized publisher; record the repair and verify readback. IPFS availability
is presently private; do not claim global public gateway availability.

## 3. Preserve each contract's actual license

Do not default uploads to MIT or use one repository-wide license. Read the target
source's SPDX from its exact compiler metadata and use the manifest's mapping:

* Apache-2.0: Blockscout v2 `license_type=apache_2_0`; numeric legacy identifier 12.
* MIT: Blockscout v2 `license_type=mit`; numeric legacy identifier 3.

There are 15 Apache builds and six MIT builds. The MIT builds are ProxyAdmin,
TransparentUpgradeableProxy, ManagedProxyAdmin, ManagedApplicationProxy,
ERC1967Proxy and DeliveryFailureProbe. The CodeManager, GasManager, GasSponsor,
delegation/registry/beacon components, validator, private combo logic, greeting-card
logic and Pente logic are Apache-2.0. Proxy shells and their implementations must
be verified separately with their respective licenses. Keep imported source notices
unchanged. Unknown or compound SPDX expressions require explicit review, never a
fallback. `CodeManagerStrict` is an artifact alias, while its actual Solidity name
is `CodeManager`; use the manifest's target name/path. The same applies to
`PrivateComboStorageStrict` / `PrivateComboStorage`.

## 4. Inspect and use the existing Blockscout verifier

GET `/api/v2/smart-contracts/verification/config` and confirm the live license map,
Standard JSON support and both compiler versions. The last audit found the Rust
verifier already enabled. Inspect its existing health/configuration before installing
or changing anything. Installed backend baseline: Blockscout v11.3.0, source commit
`43af7ea84797e2f3a55ac1191d9cbe67436eb3e8`. Do not dump secret environment files.
Preserve rootless users, persistent services, databases, Nginx restrictions and ports.

Some genesis addresses currently lack an indexed address record and return 404.
If needed, prepare and commit a bounded, idempotent importer using the current
`Explorer.Chain.import` address pipeline. Back up the database and test a small batch
first. Use the audited CSV and deduplicated runtimes, insert missing address/code
records only, and preserve balances/history/existing verification. Do not blindly
load the 1.25 GB genesis. The precompiled-source chain-spec importer is unsuitable:
it inserts smart-contract records with default license `none` without compiler
verification. Never fabricate verified flags or creation transactions to solve 404s.

Use `Tools/BlockscoutVerification/upload.py` in dry-run mode first. For example:

```text
python Tools/BlockscoutVerification/upload.py --address 0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424
python Tools/BlockscoutVerification/upload.py --address 0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424 --execute --receipt-directory /protected/path/verification-receipts
```

Use ordinary Python (not `-O`), with `requests` and `web3` installed. Replace the
receipt directory with a durable local path. This example is the current Apache
CodeManager implementation. Then validate a MIT genesis proxy and the validator
before expanding to all distinct public builds and their remaining addresses.

The API is multipart POST
`/api/v2/smart-contracts/{address}/verification/via/standard-input`, file field
`files[0]` containing **standard-input.json**, plus explicit `compiler_version`,
`contract_name`, `license_type`, `autodetect_constructor_args=false`, and
`constructor_args`. Use real recorded constructor suffixes for later deployments.
Genesis contracts have no constructor transaction: submit empty arguments and let
the Rust verifier match deployed runtime; do not invent arguments or transactions.
`standard-output.json` is an audit artifact, not the upload input.

HTTP 200 means queued. Keep durable per-address request/response/poll checkpoints.
The helper refuses blind retry of uncertain/accepted submissions; reconcile them
using current API state and worker logs. Require full verification, correct target
name/path, exact compiler and correct license in GET
`/api/v2/smart-contracts/{address}`. Partial, pending and failed are not verified.
Check proxy implementation/admin linkage separately without changing it on chain.
If an address is already verified with the wrong license, report the mismatch and
use a supported metadata correction after examining the installed API. Do not change
SPDX, force fake success, erase source records, or blindly resubmit to an endpoint
that rejects already fully verified contracts.

Start with one worker and conservative request pacing. Validate one representative
per distinct public build before bulk processing the 32,431 identical genesis proxy
shells. Resume from durable checkpoints; identical bytecode does not mean all
addresses have verified explorer records. Keep logs bounded and monitor database,
verifier load and indexing lag. Any required code/service change must be reviewed,
committed and pushed on a work branch before applying it to hosts.

## 5. Exclusions and completion criteria

Do not submit the five private Pente addresses to the public explorer: verify their
artifacts/private code hashes separately without publishing state or redemption
secrets. Do not submit the tester's EIP-7702 designator as Solidity; verify its target.
The 18 native precompiles (0x01..0x11 and 0x0100) are Besu client code, not Solidity
deployments. Catalogue their Besu version, source/license and explicit metadata/
Standard-JSON not-applicable status. If adding explorer labels, label native behavior
accurately without pretending that a compiler verified an empty runtime.

Make no genesis resets, contract upgrades, ownership changes, account funding,
private transactions or service replacements during this task. Keep the chain usable
while the main engineer continues application work; coordinate before any shared
service change. Current contract promotion does not authorize production launch.

Deliver a complete CSV/JSON report with address, category, actual contract name,
artifact path, SPDX/API license, compiler, metadata CID, explorer URL, full/partial/
queued/failed/excluded status and evidence. Report totals and unresolved addresses
honestly; a correct source package is not proof every address was uploaded. Update
the technical manual with actual verification operations, troubleshooting and IPFS
maintenance. Commit and push documentation/tools on a work branch, preserving
secrets and other uncommitted work. Ask only for a genuinely missing credential or
a decision that cannot be resolved from existing authorization and evidence.

Official API reference:
https://docs.blockscout.com/devs/verification/blockscout-smart-contract-verification-api
For genesis runtime-only behavior, inspect the pinned backend's
`apps/explorer/lib/explorer/smart_contract/helper.ex`; for address import and license
handling inspect the corresponding installed source rather than guessing API fields.
