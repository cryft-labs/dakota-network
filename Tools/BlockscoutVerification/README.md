# Contract artifacts and Blockscout verification

## 1. Scope and evidence

The 2026-09-11 audit is in [Contracts/Verification/20260911](../../Contracts/Verification/20260911).
Its manifest records the exact audit block and hashes. All 21 distinct Solidity
builds reproduced their recorded creation bytecode, runtime templates and metadata
from self-contained Standard JSON inputs. Source content hashes and SPDX notices
were also checked. Historical deployments retain historical inputs; compiling the
latest source is not sufficient to verify an older implementation.

Coverage comprises 32,433 genesis contracts, 18 successful later public contract
creations (including internal CREATE operations), and five recorded private Pente
deployments. All genesis allocations were streamed from the checksum-verified live
genesis, with representative block-zero RPC code checks. This is not a claim of
32,433 individual RPC reads. Later public contracts were checked against creation
traces, current runtime code and immutable spans. Private contracts were checked
using read-only private EXTCODEHASH calls.

The public chain is 112311; genesis block hash is
`0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8`.
The audit does not sign transactions, change ownership, reset genesis or install
services. Source verification is a separate operation, not implied by this audit.

## 2. Files and correct licenses

Each build folder has `standard-input.json`, `standard-output.json`, `metadata.json`,
`abi.json`, `creation-bytecode.txt` and `runtime-bytecode.txt`. The metadata preserves
the compiler's exact bytes. The manifest provides every file's SHA-256, the embedded
metadata CID, compiler/EVM target, immutable references and source licenses.
`genesis-addresses.csv` maps every genesis contract address to a build, while
`licenses.csv` provides the explicit upload license.

| Target SPDX | Blockscout v2 `license_type` | Legacy numeric identifier |
| --- | --- | --- |
| Apache-2.0 | `apache_2_0` | 12 |
| MIT | `mit` | 3 |

Fifteen builds are Apache-2.0. Six are MIT: the genesis ProxyAdmin facade and custom
TransparentUpgradeableProxy, ManagedProxyAdmin, ManagedApplicationProxy,
ERC1967Proxy and DeliveryFailureProbe. Implementations and their proxy shells can
have different licenses. Preserve all imported notices in the uploaded input.
Use the target source's recorded SPDX, never the repository license as a blanket
default. Unknown/compound expressions require review rather than silent MIT/none.

`CodeManagerStrict` is a build alias; its Solidity contract name is `CodeManager`.
`PrivateComboStorageStrict` similarly compiles `PrivateComboStorage`. Use the
manifest's `contract_name` and `source_path`, not a directory alias.

The required compilers are `v0.8.19+commit.7dd6d404` (validator, London) and
`v0.8.37+commit.f401782d` (public Osaka and private Shanghai). Do not change EVM,
optimizer, source paths, library linking, metadata settings or compiler version
for a verification retry. Standard JSON **input**, not output, is submitted.

## 3. Different address categories

* **Genesis Solidity contracts:** 32,431 identical proxy shells, the validator and
  the fixed ProxyAdmin facade. No deployment transaction/constructor execution
  exists at genesis. Use deployed-runtime verification, empty constructor arguments
  and the exact recorded build. Blockscout's Rust path supports deployed bytecode
  when creation input is absent; do not invent transactions or constructor data.
* **Later public contracts:** use actual constructor argument suffixes from the
  recorded successful creation traces, including factory-created contracts.
* **Private Pente contracts:** their five addresses are not public Besu bytecode
  targets. Preserve their artifacts and private code-hash evidence without trying
  to verify them as public explorer contracts or publishing private state.
* **EIP-7702 account:** the tester's 23-byte authorization designator is not a
  Solidity build. Verify the dispatcher/delegation target separately.
* **Native precompiles:** `native-precompiles.json` lists Besu 26.8.1 Osaka addresses
  0x01 through 0x11 and 0x0100. They are implemented in the client, return empty
  `eth_getCode`, and have no Solidity compiler metadata or Standard JSON input.
  Their client source is Apache-2.0. Keep an explicit not-applicable record instead
  of fabricating Solidity artifacts or claiming compiler verification.

## 4. Existing explorer and genesis indexing

Explorer: `http://100.111.69.1:8080/`. Archive RPC:
`http://100.111.69.1:8547/`. Both are Nginx-protected Nebula endpoints. Backend-01
hosts the rootless explorer API/database; Frontend-01 hosts the UI/archive.

At this audit, `/api/v2/smart-contracts/verification/config` reports the Rust verifier
enabled, Standard JSON available and both required compilers present. Inspect this
live state before changing services. No uploads were performed by the audit.
Some genesis addresses return 404 because address records are not indexed yet.

In the installed Blockscout v11.3.0 source (commit
`43af7ea84797e2f3a55ac1191d9cbe67436eb3e8`), on-demand code fetching requires an
existing address record. If needed, prepare a bounded, idempotent importer using
the supported `Explorer.Chain.import` address pipeline and the address CSV plus
deduplicated runtime files. Read its exact current schema, back up the database,
test a small batch, preserve existing balances/history/code/verification, and
insert only missing address/code records. Do not load the 1.25 GB genesis blindly.

Do **not** use the chain-spec precompiled-source importer as compiler verification:
it directly inserts smart-contract records, defaults the license to `none`, and
can mark records as full matches without running the compiler. Do not write fake
verification flags, fake creation transactions or placeholder constructor data.

## 5. Safe upload helper

Python dependencies: `requests`, `web3`; tests also use `pytest`. Use ordinary Python,
not optimized `python -O`, because validation assertions are safety gates.

```text
python Tools/BlockscoutVerification/upload.py --address 0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424
python Tools/BlockscoutVerification/upload.py --address 0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424 --execute --receipt-directory /protected/path/verification-receipts
```

The first command prints a request plan only. The second submits one inventoried
public contract after checking local file hashes, licenses, live chain identity,
current runtime hash and live compiler/license support. Use the existing private
network and exact public endpoint above; no wallet or signing key is needed.

Multipart POST path:
`/api/v2/smart-contracts/{address}/verification/via/standard-input`.
The file field is `files[0]`; data fields are `compiler_version`, `contract_name`,
`license_type`, `autodetect_constructor_args=false`, and `constructor_args`.
V2 accepts the explicit string license; the numeric identifiers above are not an
instruction to substitute a different field or use a blanket license.

The helper stores a receipt before submission and will not blindly resubmit an
uncertain or already accepted request. HTTP success means queued, not verified.
Poll GET `/api/v2/smart-contracts/{address}` and require the exact target, source
path, compiler, license and full-match status. Reconcile pending receipts through
API/worker logs before retrying. An already verified wrong license requires a
supported correction; changing source SPDX or deleting evidence is not a repair.

Verify one representative of each distinct public build first, then process all
remaining addresses with durable checkpoints and conservative concurrency. Sharing
bytecode does not prove every address has an explorer verification record. Report
full, partial, queued, failed and excluded counts separately. Proxy linkage and
implementation verification are separate checks.

## 6. IPFS publication and recovery

`publish.py --workspace <existing-workspace>` requires this package and tool to be
clean, committed and pushed to `review/compiler-standard-json` before it uses the
existing pinned-host-key SSH helper. It forwards Backend-01's loopback Kubo API
5001 and gateway 8081 over Nebula; neither API nor secrets become public.

It publishes all six files per build, original source content, and inventory files.
Metadata/source objects must reproduce their embedded CIDs. Every distinct object
is recursively pinned, fetched from the API and read back from the gateway with
exact byte equality. The receipt is
`outputs/blockscout-artifact-ipfs-20260911.json`; its committed copy belongs at
`docs/blockscout-artifact-ipfs-20260911.json` after successful publication. Consult
that receipt for authoritative CIDs/counts rather than inventing a bundle CID.

Public peering and Cloudflare gateway exposure remain separate future operations.
Metadata does not contain its own Standard JSON input CID: the input/output CIDs
are catalogued in the receipt. Keep the exact metadata bytes and compiler input;
pretty-printing metadata changes its CID. No seeds, credentials, codes, PINs or
private state belong in this package. Paladin recovery secrets remain on Paladin-01.

`audit.py --workspace <existing-workspace> --stage all` reconstructs the package
using locked original deployment artifacts/journals, installed solc versions and
read-only live RPCs. A fresh checkout can independently compile each self-contained
input and compare exported metadata/bytecode without possessing those journals.
Do not overwrite this release with a later audit; create a new dated release.

## 7. Handoff and references

Use [HANDOFF_PROMPT.md](HANDOFF_PROMPT.md) for the other LLM's upload task. Contract
branch promotion is authorized by the owner; it does not mark the unfinished API,
Cloudflare exposure, owner handover or production acceptance as complete.

API references: [Blockscout verification API](https://docs.blockscout.com/devs/verification/blockscout-smart-contract-verification-api)
and [pinned verification controller](https://github.com/blockscout/blockscout/blob/43af7ea84797e2f3a55ac1191d9cbe67436eb3e8/apps/block_scout_web/lib/block_scout_web/controllers/api/v2/verification_controller.ex).
Runtime-only request behavior is in
[the pinned helper](https://github.com/blockscout/blockscout/blob/43af7ea84797e2f3a55ac1191d9cbe67436eb3e8/apps/explorer/lib/explorer/smart_contract/helper.ex).
