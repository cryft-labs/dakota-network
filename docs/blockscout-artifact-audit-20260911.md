# Deployed contract artifact audit — 2026-09-11

## 1. Result

The deployed artifact audit passed. Twenty-one unique builds reproduced exact
creation bytecode, runtime templates and compiler metadata from their recorded
Standard JSON inputs. All source hashes/SPDX notices were checked. The package
includes full Standard JSON output as well as input, metadata, ABI and bytecode.

The live inventory was refreshed through public block **391**: 806 trace entries,
18 successful public contract creations, zero unmatched creations. Constructor
arguments come from actual trace input; immutable locations and values are recorded.
Five private deployment code hashes matched their recorded builds through read-only
Pente calls. No transaction signing, state changes or private secret exports occurred.

The exact compressed development genesis and its uncompressed checksum were
validated. All 32,433 genesis contracts matched one of three replayed builds:
32,431 custom transparent proxy shells, one validator and one ProxyAdmin facade.
Representative block-zero RPC reads agreed with those bytes. The other three
allocations contain balances rather than contract code. The manifest distinguishes
full local genesis coverage from representative individual RPC reads.

## 2. Licenses and exclusions

Fifteen builds declare Apache-2.0 (`apache_2_0`, API identifier 12), and six declare
MIT (`mit`, identifier 3). These values were checked against the live Blockscout
verification config and exact compiler target metadata. Proxy shells retain their
own MIT license even when an implementation is Apache. No blanket MIT default exists.

The 18 Besu 26.8.1 Osaka native precompiles are catalogued separately, with no
Solidity metadata or Standard JSON claimed. Their client source is Apache-2.0.
Private Pente addresses and the EIP-7702 tester's designator are excluded from public
Solidity uploads. Public implementation/dispatcher targets remain included.

## 3. Explorer state and remaining upload work

The explorer's Rust verifier reports enabled and both required compilers available.
All 18 later public contract pages were reachable but did not report verified source.
Representative genesis contract pages were missing address records. The audit did
not submit source uploads, alter licenses in the database, or fake verification.

The handoff requires a bounded address/code import if necessary, actual compiler
verification with explicit per-target licenses, durable upload receipts and exact
full-match validation. It also requires independent IPFS metadata/source readback.
All address results must be reported separately from artifact audit success.

## 4. Tools, publication and maintenance

Ten focused upload-helper tests passed: correct licenses and constructor data for
every public build, distinct proxy/implementation licenses, excluded address types,
no unknown-license fallback, and rejection of wrong existing target/compiler/license.
The helper defaults to dry-run and checks live chain ID, genesis hash and runtime
hash before submission. Pending/uncertain submissions cannot be silently retried.

The package is [Contracts/Verification/20260911](../Contracts/Verification/20260911/README.md).
Use [the runbook](../Tools/BlockscoutVerification/README.md) and
[the copyable handoff](../Tools/BlockscoutVerification/HANDOFF_PROMPT.md).
Successful IPFS publication is recorded in
[`blockscout-artifact-ipfs-20260911.json`](blockscout-artifact-ipfs-20260911.json).
Publication passed for all **224 distinct objects** (28,666,713 content bytes before
IPFS storage overhead), including each build's six artifact files, original sources
and inventory files. That receipt is the authority for actual recursive pins,
per-file CIDs and byte-for-byte API/gateway retrieval. Publication does not enable
public peering or a public gateway.

The owner's final instruction authorizes promotion of completed contract changes
and artifacts to `dakota-network/main`. The Kota Router and explorer review branches
contain no Solidity changes and are outside this contract merge. The separate API
adapter, moment.cards rollout, Cloudflare exposure, final ownership acceptance and
production approval remain unfinished development work.
