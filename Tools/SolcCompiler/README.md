# Dakota compiler and verification inputs

The compiler exports `<Contract>_standard_input.json` for every compiled contract,
library, interface and abstract contract. Each JSON file embeds its full source
dependency graph and exact compiler settings; verification needs no source download
callback. Use the compiler version and fully qualified name recorded in the
matching artifact. The standard JSON input itself must contain only Solidity's
input schema, so compiler version and SHA-256 are recorded in the artifact/manifest.

The compiler uses stable source names relative to its import cache. This changes
source metadata and therefore can change bytecode hashes compared with historical
artifacts produced with absolute paths. Treat the outputs as fresh review artifacts;
the compiler itself does not overwrite genesis or deployed addresses. The deployment
manifest separately records the reviewed archive and installation status.

## Targets

| Execution context | Solidity | EVM |
|---|---|---|
| Validator contracts under `Genesis/validatorContracts/` | Pinned 0.8.19 | Pinned London |
| Public contracts | Pinned default 0.8.37 | Osaka |
| Pente private contracts and explicitly private dependencies | Pinned default 0.8.37 | Shanghai pending runtime upgrade decision |

The known private entrypoints are explicitly listed in `PRIVATE_ENTRYPOINTS`.
Do not classify privacy only by a filename substring. Use `--private` for a proxy
or other dependency that will execute inside a Pente group. Output directories
include the EVM target so public and private artifacts cannot overwrite each other.

Pente uses a separate embedded EVM. In Paladin v1.0.0, the transaction selector
accepts London, Paris and Shanghai. A Cancun helper exists but is not selected;
the public Besu fork does not set private execution rules. Raising the private
target requires a reviewed runtime upgrade and new group configuration, followed
by actual private deployment/transaction tests. Source evidence:
[transaction selector](https://github.com/LFDT-Paladin/paladin/blob/6d4b91343426d17d713a0d61dfbcb2e262cb346d/domains/pente/src/main/java/io/kaleido/paladin/pente/domain/PenteEVMTransaction.java#L212),
[embedded dependency](https://github.com/LFDT-Paladin/paladin/blob/6d4b91343426d17d713a0d61dfbcb2e262cb346d/domains/pente/build.gradle#L115).

The user's requested private EVM upgrade remains a decision pending that runtime
work. The compiler rejects unsupported Pente targets while this gate is unresolved.

## Usage

From the repository root, using an isolated Python environment:

```sh
python -m pip install -r Tools/SolcCompiler/requirements.txt
python -m pip install pytest==9.1.1
python Tools/SolcCompiler/compile.py --output-dir /absolute/path/to/review-artifacts
python Tools/SolcCompiler/compile.py --file Contracts/Genesis/7702/GasSponsor.sol --output-dir /absolute/path/to/review-artifacts
python Tools/SolcCompiler/compile.py --private --file Contracts/Genesis/Upgradeable/Proxy/Transparent/TransparentUpgradeableProxy.sol --output-dir /absolute/path/to/review-artifacts
python -m pytest Tools/SolcCompiler/tests -q
```

Install solc 0.8.19 and 0.8.37 through py-solc-x, or set `SOLCX_BINARY_PATH` to a
directory containing those verified compiler installations. The tool installs a
missing compiler version through py-solc-x; Python packages are never auto-installed
at import time. TLS verification remains enabled. Remote dependencies are still
downloaded into the cache, so archive the generated source-embedded input and
compiler provenance with the release. Full dependency-commit/hash pinning remains
part of release hardening.

Each artifact folder contains runtime/creation bytecode, ABI, metadata, full
artifact and standard JSON input. Interfaces and abstract contracts have empty
bytecode and `deployable: false`. Batch failure produces a nonzero process exit
after recording errors in the manifest. Duplicate contract names inside one
compilation fail explicitly rather than overwrite one another.

For verification, feed the exported file directly to the recorded solc executable
with `--standard-json`, or upload it to an explorer's standard JSON verification
form. Library addresses and constructor/initializer arguments must still match the
approved deployment. The JSON export does not supply deployment approval or
simulate constructor-initialized state.

The tests recompile exported JSON without filesystem import callbacks and compare
creation bytecode, runtime bytecode and ABI. They also check validator pinning,
private-version rejection, and separate public/private artifact paths.

## IPFS publication at release

Runtime bytecode normally embeds a CBOR-encoded IPFS reference to the compiler
metadata. Solc itself does not publish it; this CLI now publishes automatically
when its IPFS destination is configured. Decode the trailer using
its final two-byte length and a CBOR decoder; do not search for a fixed byte
prefix. Interfaces without runtime bytecode have no embedded reference.

Publish the exact `<Contract>_metadata.json` and each referenced source. Extract
source bytes from the matching standard input's `sources[name].content` using
UTF-8 without newline conversion. These are the compiled, potentially
import-rewritten sources; substituting original repository files may change CIDs.
Do not pretty-print metadata, add a BOM or append a newline.

Before publication, use the selected IPFS client's hash-only operation to check
each metadata CID against the bytecode and each source CID against its metadata
URL. Configure compatible UnixFS importing; a raw-file SHA-256 or a directory CID
is not a replacement. Stop on a mismatch. See [Solidity metadata](https://docs.soliditylang.org/en/latest/metadata.html)
and [Kubo add options](https://docs.ipfs.tech/reference/kubo/cli/#ipfs-add).

Publish the approved release's files, record returned CIDs, verify fetched bytes,
and confirm persistent pins on the primary and backup target. Metadata's source
URLs are JSON text, so pinning metadata alone does not pin its source files.
Track every source independently or retain them in a pinned release directory.
An upload response is not evidence that a remote pin job has completed. See
[IPFS pinning](https://docs.ipfs.tech/how-to/pin-files/).

Also archive standard JSON, ABI, bytecode and a release manifest as a separate
bundle. Record its CID alongside the metadata/source CIDs and approved commit,
compiler and genesis hashes. A bundle's CID does not replace the individual
references embedded by solc. After deployment, verify those references against
the actual installed runtime, accounting for proxies and implementation addresses.

The user authorized automatic publication of compiled contract content, including
the compiled sources of private contracts. This does not authorize publishing
private runtime state. The publisher uses only the invocation's artifact manifest,
metadata and embedded sources, never a recursive repository upload. Do not place
redemption secrets, PINs, keys or environment credentials in contract sources.
Publishing does not approve contracts, genesis or deployment.

## Automatic publisher configuration

Load these values into the compiler process environment from protected deployment
configuration. The CLI does not auto-load arbitrary `.env` files.

```dotenv
IPFS_AUTO_PUBLISH=true
IPFS_API_URL=https://100.111.67.1:8444
IPFS_TLS_CA_FILE=/protected/backend-server-ca.crt
IPFS_TLS_CLIENT_CERT_FILE=/protected/compiler-client.crt
IPFS_TLS_CLIENT_KEY_FILE=/protected/compiler-client.key
IPFS_API_AUTH_FILE=
IPFS_TIMEOUT_SECONDS=60
IPFS_MAX_FILE_BYTES=67108864
```

Backend-01 is the selected destination; the service/certificates are not yet
installed. See [Backend IPFS deployment](deploy/backend-ipfs/README.md). When an
additional HTTP authorization layer is used, `IPFS_API_AUTH_FILE` contains one
complete `Basic ...` or `Bearer ...` header value. It is never echoed. Non-local
endpoints require verified HTTPS. Redirects and inherited HTTP proxies are disabled.
An explicit `--ipfs-api` overrides the endpoint environment value.

Default `IPFS_AUTO_PUBLISH=auto` publishes whenever an endpoint is configured.
`true` requires one and fails if missing; `false` or `--no-ipfs` explicitly builds
locally. A release requiring publication must not use that local-only override.
No confirmation is requested for each compilation once publishing is configured.
Source fixes still require the user's review/commit before installation, and the
contract/genesis deployment approval remains separate.

After the whole requested compilation succeeds, the publisher verifies all
metadata/source CIDs through Kubo's hash-only import, then adds and recursively
pins each unique object, reads back its exact bytes and checks pin status. It
also publishes a deterministic ZIP containing the metadata/source objects,
standard inputs, ABI/bytecode files and a portable index. Only the current
invocation's manifest is used; unrelated old output files are excluded.

`ipfs-publication.json` records `published`, `failed`, `skipped`, or
`failed_before_publication` with per-object verification evidence. The local ZIP
is `ipfs-release-bundle.zip`. Failed publication exits nonzero; a compilation
failure publishes nothing. Partial pins can remain after a network failure and
are never automatically removed. Retry the same CID-addressed data safely:

```sh
python Tools/SolcCompiler/compile.py --publish-only --output-dir /absolute/path/to/artifacts
```

Use a separate output directory per concurrent build. The output receipt and ZIP
describe compiled content, not a signed approval or the final deployed genesis.
Backend pin/read-back verification does not prove public tunnel availability or
replication. Those need deployment checks. Secondary publishing is not implemented;
backup/second-node retention remains an operations task. With Nebula-only peers,
use our Cloudflare gateway explicitly; public DHT discovery is intentionally off.

For integration tests, set `IPFS_TEST_BINARY` to a verified Kubo executable.
Tests launch and stop an isolated offline localhost node. Optionally set
`DAKOTA_FULL_ARTIFACTS` to validate an existing complete review manifest. Without
those inputs, the corresponding integration tests are skipped explicitly.

Windows artifact paths use the extended absolute path form so deep dependency
verification files can be saved and published without truncating their source hierarchy.
