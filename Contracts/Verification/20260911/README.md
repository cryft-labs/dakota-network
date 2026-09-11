# Deployed contract verification package — 2026-09-11

Read [the runbook](../../../Tools/BlockscoutVerification/README.md) and
[the upload handoff](../../../Tools/BlockscoutVerification/HANDOFF_PROMPT.md).

`manifest.json` is the authoritative build/deployment inventory, with audit block,
genesis checksums, compiler replay evidence, per-file SHA-256, metadata CIDs,
constructor arguments, immutable values and exact SPDX/API license mappings.
`genesis-addresses.csv` lists all 32,433 genesis contracts; `licenses.csv` maps
all 21 distinct builds; `native-precompiles.json` documents 18 native exclusions.
Five private deployments are catalogued in the manifest and excluded from public
Blockscout uploads. Historical and current implementation builds are both retained.

Each build includes self-contained Standard JSON input and full output, exact
metadata bytes, ABI, creation bytecode and a runtime template. Deployed immutable
values are in the manifest rather than silently patched into compiler output.
Upload `standard-input.json` with the manifest's actual contract name and explicit
license. Do not upload `standard-output.json` as input, or reformat metadata.

All builds reproduced exactly and all audited deployed addresses matched. This is
artifact validation, not a claim that Blockscout source uploads have completed.
The IPFS publication receipt is [here](../../../docs/blockscout-artifact-ipfs-20260911.json)
once publication succeeds; it records exact per-file CIDs and pin/readback evidence.
