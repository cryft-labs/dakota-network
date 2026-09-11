# Paladin/Pente deployment and maintenance

Development checkpoint: 2026-09-11. This is chapter 8's detailed runbook in the
[system manual](../../IMPLEMENTATION.md). Read the [acceptance record](../../docs/paladin-acceptance-20260911.md),
[address/funding snapshot](../../docs/paladin-funding-20260911.json) and current
live state before maintenance. This deployment uses the existing chain; never
reset genesis, regenerate its keys, recreate the group or repeat initialization.

## 1. What is running

Paladin-01 (`100.111.32.201`) runs Paladin v1.0.0, PostgreSQL 17.11 and its connected
Besu 26.8.1 node. Paladin and PostgreSQL use rootless Podman supervised by systemd.
The private group has one member, `operator@paladin01`; it is a development group,
not a tested multiparty deployment. The group name is `moment-cards-development`.

| Setting | Verified value |
|---|---|
| Chain ID | `112311` |
| Node name / privacy domain | `paladin01` / `pente` |
| Group ID | `0x8b4e5a042c782d363c72538b2a518679c8a6e942c1b9850e768d975af54eba79` |
| Public EVM / compiler | Osaka / Solidity 0.8.37 |
| Private EVM / compiler | Shanghai / Solidity 0.8.37 |
| Validator compiler | Solidity 0.8.19, London; unchanged `getValidators()` encoding |
| Paladin public fee signer | `settlement@paladin01` |
| Private application signer | `operator@paladin01` |
| Private trusted forwarder | Zero; MetaTx disabled |

The installed Pente execution selector supports London, Paris and Shanghai.
Read-only probes accepted PUSH0 privately but rejected MCOPY, which public Besu
accepted. A connected Osaka chain does not upgrade the separate private interpreter.
Private transparent proxies use ordinary DELEGATECALL, verified by deployment,
state-preserving upgrades and calls. Private EIP-7702 authorization-list processing
is not established. Gas coverage is implemented and verified at public settlement:
prepare the private transaction, then settle its endorsed public transition through
the existing EIP-7702 account dispatcher and GasSponsor. No MetaTx relay is needed.

## 2. Service inventory and connections

| Unit | Runtime user | Limit | Data/configuration |
|---|---|---|---|
| `cryft-paladin.service` | `cryft-paladin` | 4 GiB, 300% CPU, JVM heap 2 GiB | `/etc/cryft/paladin/paladin.json` |
| `cryft-paladin-db.service` | `cryft-paladin` | 2 GiB, 100% CPU | `/var/lib/cryft-paladin/postgres` |
| `cryft-nginx.service` | `cryft-proxy` | 512 MiB, 200% CPU | `/etc/cryft/nginx/conf.d/paladin.conf` |
| `cryft-besu.service` | `cryft-besu` | Existing node budget | `/etc/cryft/besu/` and its existing data directory |

Units are enabled and restart on failure. Both containers drop capabilities and
use no-new-privileges. Paladin has a read-only root filesystem and bounded temporary
mounts. PostgreSQL uses a subordinate UID mapping; host `stat` can show an unnamed
numeric owner on its mode-0700 data directory. Do not recursively chown it to root
or the host's PostgreSQL user. The application DB role is `paladin`, without
superuser, create-database or create-role rights.

Paladin image:
`ghcr.io/lfdt-paladin/paladin@sha256:b7d9b4ab98c5330a2515e8c2c97d0b5f4460278ded824bee0a10ad6008984357`.
Source tag commit: `6d4b91343426d17d713a0d61dfbcb2e262cb346d`;
image commit label: `ad0c206b2baf2866acb23220feb48eedc482848a`.
PostgreSQL image:
`docker.io/library/postgres@sha256:67f41722b7a8cbdb868a44a4995c846eddfdc2973bccb291ce937dce88ad5675`.
Preserve `/etc/cryft/paladin/installation.json` as the original installation receipt;
later contract release commits are separate records.

| Endpoint | Purpose / access |
|---|---|
| `http://100.111.32.201:8550/` | Privileged Paladin signing RPC, Nginx POST-only; admin `100.111.1.4`, Backend `100.111.67.1`, and loopback allowed |
| `127.0.0.1:8548`, `:8549` | Raw Paladin HTTP/WS; loopback only |
| `127.0.0.1:5433` | PostgreSQL; loopback only |
| `127.0.0.1:6100` | Metrics; loopback only |
| `http://127.0.0.1:8552/`, `/ws` | Local Nginx bridge from Paladin to Besu HTTP/WS |
| `http://100.111.69.1:8547/` | Frontend archival Besu through Nginx; `/ws` for WebSocket |
| `http://100.111.69.1:8080/` | Operator explorer |

Signing RPC grants access to node-held identities. It is not the end-user API.
Never route browsers, the widget, public Cloudflare ingress or arbitrary tenants to
it. Nginx currently enforces 30 requests/second per source, burst 50, 24 connections,
4 MiB request bodies and no automatic POST retries. A shared Backend source IP is
not tenant authorization: Kota Router must enforce tenant/principal/action scope.
Nebula authenticates/encrypts interhost traffic; HTTP here is inside that tunnel.
SSH uses the existing pinned host keys and admin identity over Nebula. Public root
SSH lockdown and narrower production network policy are still outstanding.

## 3. Contract addresses and authority

Public and private addresses belong to different execution states. A public RPC
call cannot inspect or manage the private Combo proxy directly.

| Contract | State | Current address |
|---|---|---|
| CodeManager fixed proxy | Public | `0x000000000000000000000000000000000000c0DE` |
| CodeManager strict implementation | Public | `0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424` |
| PenteFactory proxy | Public | `0x120052f8392c4a3b88b48d82e585138B6df80376` |
| PenteFactory implementation | Public | `0x9E2ab1B3A9dB5308BEc62b14C64822157F41b5fb` |
| Pente group proxy | Public | `0x533E526f095407490BB0089D3fc38e73484523B0` |
| Pente group implementation | Public | `0x15d20F07e21210B36Ec16c9da6EFA97429A10D75` |
| Development card NFT proxy | Public | `0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410` |
| Card implementation | Public | `0xf4DD94337a44E474bbAB986b095702f90367baD5` |
| Card ProxyAdmin | Public | `0x3571242a64Ac7166b36aAD18a1407853cCe52f71` |
| Combo proxy | Private group above | `0x7a3eacca11e28712ed6e0dfc464795b2a0c2a342` |
| Combo strict implementation | Private | `0x477d914a7eaa6bf2c97601989d02a36cc2422734` |
| Combo ProxyAdmin | Private | `0x4a35f4517ad2e26b332854b1eb94a67092968400` |

Card owner, Card ProxyAdmin owner and PenteFactory owner remain the development
deployer. Combo ADMIN, AUTHORIZED and private ProxyAdmin owner are the private
operator. CodeManager upgrades use the existing public facade/guardian governance;
private application upgrades use the private ManagedProxyAdmin. Its two-step owner
transfer cannot be renounced. Pente group protocol upgrades instead require valid
group endorsement signatures through `preAuthorizeUpgrade`, then the UUPS upgrade;
the public factory owner is not automatically the existing group's upgrade authority.

CodeManager authorizes this Pente group only for the development card contract.
The former implementations and failure probes remain historical deployments;
they are not the current proxy targets. Do not install an older implementation just
because a historical receipt names it. The [JSON record](../../docs/paladin-acceptance-20260911.json)
includes runtime hashes, artifact aliases and metadata CIDs.

## 4. Funding: exactly which addresses need KOTA

Use native **KOTA on chain 112311**, with 18 decimals. Public transfers on another
chain do not fund this network. Confirm chain ID, destination and current balance
before sending. Read balances with the archive RPC or the read-only command:

```powershell
python Tools/Paladin/funding.py --workspace C:\Users\ChadS\Documents\Codex\2026-09-08\a
```

| Purpose | Public address | Balance at block 362 | When to fund |
|---|---|---:|---|
| Paladin automatic public settlement | `0x08Bb45a62993dC2BdEB0b5aebA28A191B9cC4549` | 0.024371939 KOTA | Pays for automatic Pente deployments, maintenance and settlement |
| Deployment account / development sponsor relayer | `0x633309d1155fD658a717e4f5E4FA853615400867` | 0.909362996 KOTA | Pays deployment, registration and outer sponsored-transaction fees |
| Delegated test recipient | `0x991acc255761dEE0421Ccd3F436788C24425122E` | 0.997995562 KOTA | Needed for its own unsponsored transactions; sponsored redemption did not debit its native balance |
| Final management root | `0x9247524040D91D5dd1521A25f2e7711d4a0fe921` | 32 KOTA | Signs its own governance/acceptance operations |
| Private operator | `0xe7850EcEDe5d6f7d0B2d2cCaBfC2f29D2C345125` | 0 KOTA | No native funding needed for this private execution role |

Balances are a dated snapshot, not minimums. Initial Paladin funding was 0.03 KOTA.
A development operating policy is to alert below 0.01 KOTA and refill toward 0.03;
this alert/refill is **not automated**. At the current 1 gwei fee configuration,
0.01 KOTA covers only ten transactions at one million gas each. Size the reserve
from observed gas use, pending transactions and concurrency, not this small test.
The private gas limit still bounds execution even though private computation does
not charge a native balance. Public settlement always has a payer.

To top up a fee wallet, send a normal native transfer from an authorized funded
account and confirm its receipt and destination balance. For treasury funding,
GasManager at `0x000000000000000000000000000000000000cafE` provides a governed
proposal/vote/execute flow. V2 uses `proposeFundGasV2(fundingId,to,amount,note)`,
`voteToFundGasV2(fundKey)`, then `executeFundGasV2(fundKey)` after approval. Execution
requires an allowed guardian or the funded account. A depleted funded account may
need a guardian to execute because it cannot pay its own transaction fee. Never
create a second approval after an uncertain broadcast; reconcile the original key.

Sponsorship funding is a separate ledger at
`0x000000000000000000000000000000000000FEeD`. The development tenant/sponsor key is
the card proxy `0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410`. `depositFor(card)` records
refundable tenant funds; governed treasury sponsorship uses `proposeSponsorFunding`,
the GasManager vote, and `executeSponsorFunding` to credit the restricted gas ledger.
Do not use a plain transfer to FEeD as a substitute for a ledger deposit. Read
`getSponsorFunding(card)` and the tenant/relayer/cap configuration before enabling.
Both ledger components are zero after acceptance; sponsorship is paused, the test
tenant disabled and the temporary relayer disabled. The public relayer still needs
its own native fee reserve before reimbursement. See the [sponsorship guide](../../Contracts/Genesis/7702/GAS-SPONSORSHIP.md).

The current registration fee is `1000000000000000` wei (0.001 KOTA) per new UID.
Query `registrationFee()` before calculating payment. Registration fees, tenant
sponsor deposits and a signer's native balance are three different balances.

## 5. Transaction lifecycle and recovery

1. The gift or approved registration operator registers a bounded UID range publicly
   and pays its fee. Scope the privacy group to that gift through CodeManager governance.
2. Inside Pente, whitelist the canonical identifier, synchronize the confirmed
   registered count and store code hashes/PIN assignments. Never log or publish
   plaintext codes, PINs, private transaction inputs or full domain receipts.
3. Use `pgroup_sendTransaction` for automatic public settlement. For native sponsored
   settlement use `ptx_prepareTransaction`, persist its idempotency key/transaction ID,
   retrieve the prepared public `transition(...)` and encode its exact endorsed data.
4. Wrap that public call using the verified EIP-7702 account's signed execution
   envelope and the independently signed bounded sponsor voucher. Submit once and
   reconcile by hash. `sponsorship.py` demonstrates the accepted native path.
   The normal prepared `transition` validates group endorsements; this path does
   not require `approveTransition`. Do not remove signatures or invent approval steps.
5. Check the public receipt, inner SponsoredOperation result when used, Paladin
   receipt, public committed recipient/delivery status and NFT owner. Outer receipt
   success alone is insufficient. A failed sponsor inner call can consume a voucher;
   any new voucher needs a new operation ID/nonce while preserving transaction identity.

The strict Combo emits `recordRedemptionStrict(string,address)` to public CodeManager.
Invalid/inactive/wrong-scope/already-committed public preconditions revert the entire
Pente transition, leaving the private code unspent. A live public-only freeze proved
that the same prepared redemption succeeds after the condition is restored. The
legacy `recordRedemption` ABI remains best-effort for existing callers; do not use
it as the private code-consumption boundary.

Once a redemption is accepted, a gift delivery failure retains its recipient and
marks delivery pending. Repair the gift implementation/configuration, then call
`retryRedemptionDelivery(uid)`; it is permissionless and always uses the committed
recipient. Do not reopen the code, redirect the recipient, or mint a replacement.
For duplicate concurrent requests, read both receipts/events; the live test produced
one winner and one rejected private redemption, with one NFT delivery.

## 6. Routine maintenance and restart

Before maintenance, pause new application jobs, reconcile public nonces and Paladin
IDs, and wait for transactions already submitted. Preserve journals. The read-only
audit needs network access and Python dependencies used by `Tools/LiveGenesis` plus
requests/Paramiko; it does not decrypt wallet keys:

```powershell
python Tools/Paladin/verify.py --workspace C:\Users\ChadS\Documents\Codex\2026-09-08\a
```

On Paladin-01, inspect and restart through systemd, never by starting duplicate
containers manually:

```bash
systemctl status cryft-paladin cryft-paladin-db cryft-nginx cryft-besu
systemctl stop cryft-paladin
systemctl restart cryft-paladin-db
systemctl start cryft-paladin
systemctl is-enabled cryft-paladin cryft-paladin-db
systemctl is-active cryft-paladin cryft-paladin-db
```

The controlled database/Paladin restart passed with the same group, identities,
private authority, proxy implementation and five delivered NFTs. An actual host
reboot and independent backup restore remain separate unperformed tests. The
explicit `verify.py --restart-services` option repeats this maintenance window only
from a clean published review commit. Do not use it as a continuous health probe.

Read `journalctl -u cryft-paladin --since ...` locally when diagnosing failures;
sanitize before sharing because error logs can include request data. Runtime logging
is warning-level and SQL debug logging is disabled. Check DB readiness, disk space,
settlement balance, Besu height/peers and Nginx access before changing code. Initial
indexer null-receipt warnings were transient; confirmed HTTP/WS receipts and actual
indexed groups are the acceptance evidence. Do not add an RPC rewrite workaround
without reproducing a persistent protocol error.

Rootless PostgreSQL uses `slirp4netns` because this host lacks `pasta`. Paladin's JNA
temporary directory must remain executable; its working tmpfs uses mode 1777.
Its command is `/config/paladin.json engine`. These resolved startup failures are
encoded in `install-runtime.py`. Database and key files persist independently of
containers. Never delete Podman volumes, PostgreSQL data or the signing seed to
resolve an ordinary startup failure.

## 7. Keys, backup and ownership handover

**Owner instruction: keep Paladin recovery secrets on Paladin-01.** No off-server
seed/database-credential recovery copy was created or authorized. Do not export
them to this computer, Git, IPFS, a prompt or a new backup service.

`/etc/cryft/paladin/secrets.json` is root-only mode 0600. The seed, database password
and PostgreSQL environment files are root-owned, runtime-group-readable mode 0640
inside the protected configuration directory. The non-login user is `cryft-paladin`.
The static seed derives the node's settlement/operator/maintenance identities.
Changing or losing it changes access to those identities. A rebuild from the public
chain cannot reconstruct private payloads or signing material.

An eventual approved recovery plan must retain a consistent PostgreSQL backup,
its roles/schema, the signing seed, group/domain configuration and exact runtime
versions together. Preserve local file permissions and restore first on an isolated
host with signing disabled. Verify derived addresses and group state before allowing
transactions. **No offhost backup, restore drill or high-availability failover has
been completed.** Additional Pente members and transport configuration require an
explicit membership/design review, not just a second process sharing this database.

The final management public address is
`0x9247524040D91D5dd1521A25f2e7711d4a0fe921`. Public card ownership and Card ProxyAdmin
use two-step transfers; the PenteFactory's pinned upstream owner transfer is single-step
and needs particular care. Registry/GasSponsor admin acceptance is pending. The
private operator-to-maintenance two-step ADMIN/ProxyAdmin transfer was tested and
then restored to the operator. Acceptance clears the old AUTHORIZED role, which
must be assigned deliberately by the new ADMIN. Audit per-UID managers and forwarders.

A public EOA address alone is not a usable private signing identity. Before final
private handover, choose and verify the owner's private identity/signing integration
and group-control arrangement. Then transfer each independent authority, prove a
successful authorized action and remove obsolete deployer/root/voter/service rights.
Never claim the handover complete merely because a proposal or public transfer exists.

## 8. Builds, IPFS and upgrades

Current aliases `CodeManagerStrict` and `PrivateComboStorageStrict` name versioned
artifacts for the existing Solidity contract names. Both preserve the full storage
layout of their predecessors. Public runtime is 24,784 bytes, within Dakota's
32,768-byte limit; private runtime is 17,127 bytes, within the private 24,576-byte
limit. Do not assume the default Ethereum public code-size limit applies here.

`build-strict.py` compiles and checks normalized storage layout. `build.py` preserves
historical hashes and deliberately refuses to overwrite changed deployed artifacts.
To recover an old build on a new workstation, replay its exact pinned Standard JSON
from IPFS or check out its recorded source commit; current source is not the old build.
Commit/push changes and artifact locks to `review/compiler-standard-json` before
publication or live mutation. The owner subsequently approved merging the completed
contract release and verification artifacts into network main; production rollout
and owner acceptance remain separate. `publish.py` pins exact
metadata, source bytes and Standard JSON through Nebula SSH to Backend-01's loopback
Kubo API, then verifies recursive pins and gateway bytes. It never publishes private
runtime state. The Paladin-specific receipt covers ten builds and 88 unique compiler
objects. The later complete deployed package in `Contracts/Verification/20260911`
adds all public/genesis builds, full Standard JSON output, exact license mapping
and native-precompile exclusions. Its publication receipt is
`docs/blockscout-artifact-ipfs-20260911.json`; see
[the verification runbook](../BlockscoutVerification/README.md).

| Current implementation | Metadata CID | Standard JSON input CID |
|---|---|---|
| CodeManagerStrict | `QmYvDrmyXvqdF86gxRxMfyzXiZf1dLN7bwxdVnKD2CmNKs` | `QmYPc5rwDUJaDzj4atcwzuiyKm2u5E7qmSGy3yKsjQHDQh` |
| PrivateComboStorageStrict | `QmSAb4hForuwzfbFPj5n7LwbXQeyK3fzAsyAwxb2zNnPW4` | `Qmbk8eGGKhyBAYUoMUdNGjmz1d6yHNnsqZfB5UUEKS9Unh` |

NFTs 1–4 retain directory `QmeCdJ3uwNspKHnL9oK8hz4vE3aY77YYn48m6EMUK5d5Kz`;
NFT 5 uses `QmdqZ72P2SjJLTS1NiB2hbqxQ3sycHg7cXyaCEuagboDo2`. Filenames are `<id>.json`.
Both directories are pinned and verified. Backend API/gateway are `127.0.0.1:5001`
and `127.0.0.1:8081`; no public Cloudflare gateway is configured yet. Source pinning
is separate from Blockscout source verification, which is still pending.

For later compatible upgrades, compare full storage layouts and ABI behavior, pin
artifacts, read actual implementation addresses, record a durable transaction label,
then upgrade the public CodeManager **before** enabling a private caller that needs
its new method. Upgrade private Combo through its private ManagedProxyAdmin. Verify
code hashes, roles, registered counts, existing codes and delivered recipients before
resuming work. The September strict upgrade already completed; `strict-upgrade.py`
is its journaled deployment record, not a template to rerun for every new release.

## 9. Application integration and remaining acceptance

The successful tests invoked real Paladin and chain APIs directly. Kota Router's
private adapter still reports `blocked/private_submission_not_implemented` for live
requests and `simulated` for dry runs. Implement the adapter with durable operation
IDs/outbox, scoped authorization and receipt/delivery reconciliation before exposing
code issuance/redemption endpoints. The optional widget, admin UI and moment.cards
must use those same endpoints; no browser may receive node signing access.

Outstanding: Router/API and account-registration integration; deployed moment.cards
and widget/admin UI; final management acceptance and private identity handover;
public Cloudflare/IPFS gateway and explorer source uploads (the verifier now reports
enabled); production SSH/network
lockdown; full reboot/backup-restore/multiparty/load tests. This runbook documents
working development settlement, not production approval.
