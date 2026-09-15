# Local code generation and registration

API 1.14.0 Â· 15 September 2026 Â· Review implementation. New contract activation and browser acceptance are pending; historical live tests below used the prior format.

## 1. Ownership of the credentials

New v2 batches use 12 independent uniformly random Crockford-base32 characters
(`0123456789ABCDEFGHJKMNPQRSTVWXYZ`, 60 bits), generated with `crypto.getRandomValues`.
The browser independently generates nonzero 32-byte entropy and hashes the uppercase
12-character text with Ethereum Keccak-256. Neither SHA3-256 nor SHA-256 is equivalent.
The Router receives only the hash and entropy, never the cleartext code.

The private contract assigns the three-digit numeric component. Only after its
confirmed receipt may the browser prepend that component to form the user's one
15-character redeemable code. Leading zeroes matter. Do not display, predict or
print the complete artifact before private confirmation. Legacy saved v1 files
retain their 64-hex-character codes, eight-character components and `kota1:` format.

This does not make the service trustless: the private-state worker can access the
hash and internal component needed for redemption. Protect those as credentials.
Do not send codes, recovery files, private receipts or registration material to
Kota completions, public metadata, analytics, request logs or error reporting.

## 2. Prepare, optionally back up, then publish

The widget, dashboard creator and moment.cards use the same protocol:

1. Validate the design/campaign, current membership and batch allowance.
2. Generate codes and entropy with `crypto.getRandomValues`. Keep them in memory.
3. Create a stable request key, `local-` followed by 32 random hexadecimal characters.
4. Offer an optional private JSON recovery file before issuance. Publishing does
   not require a download. The user may add an optional passcode (at least eight
   characters) for AES-256-GCM encryption with PBKDF2-SHA256, 600,000 iterations,
   a fresh 16-byte salt and 12-byte nonce on each export. Do not persist credentials in localStorage, IndexedDB
   or sessionStorage. A download action cannot prove that a file was saved safely.
5. Submit the exact prepared request and key. After a timeout, retry that same pair.
   Never silently generate a replacement batch.

Unencrypted recovery files contain cleartext codes. Encrypted files still require
private handling, and their passcodes cannot be recovered by the service. They are read and
validated locally; the file itself is never uploaded. Import validates tenant,
wallet, request shape, quantity, hashes and unique entropy. A wallet change or
logout clears the in-memory issuer cache. Import the saved file to distribute the
same batch on another device. Without that file or the original in-memory codes,
the service cannot reconstruct a new batch's cleartext codes.

## 3. API protocol

Paths below are relative to `/v1/platform/tenants/{tenant}`. Use the authenticated,
origin-bound session of the creating member. Operator status does not grant access
to another issuer's registration receipt.

`POST /cards` keeps the design fields; `POST /issues` keeps `campaign_id`. Both accept
`quantity` (1â€“100, default 1), require an `Idempotency-Key`, and require this field:

```typescript
registration: {
  format: 'client-hash-v1',
  code_format: 'numeric-prefix-15', // omit only when resuming an existing v1 batch
  entries: generatedCodes.map(({code, entropy}) => ({
    code_hash: keccak256(utf8Bytes(code)),
    entropy, // independent nonzero 0x-prefixed bytes32
  })),
}
```

Entry count must equal quantity. Code hashes and entropy must each be distinct.
Extra fields inside registration/entries, including cleartext `code` or `pin`,
are rejected. The request still needs membership, campaign access and capacity.
Local generation does not bypass public identifier-registration fees or gas rules.

Accepted writes return 202 with a durable operation. A transaction receipt alone
does not mean the whole operation is complete. Preserve its ID and poll
`GET /operations/{id}`. Membership counters and hash reservations are transactional;
concurrent retries of the same accepted request create only one operation. Reusing
a hash in another request returns 409. Claims remain reserved after failures to
avoid reassigning material that may already have reached private state.

After a refresh or uncertain response, import the saved file and call
`GET /issuance-requests/{key}?action=create` (or `action=issue`). This returns the
original issuer's operation, without executing anything, even while the worker or
customer creation is paused. A 404 means no matching request exists for this
wallet, tenant, key and action; the saved request can then be resubmitted. Other
errors must be resolved rather than interpreted as a missing operation.

After completion, `GET /operations/{id}/registration` returns:

```typescript
{
  format: 'client-hash-v1', tenant, wallet, operation_id,
  idempotency_key, action,
  items: [{code_hash, pin, token_id, unique_id}],
}
```

Match each receipt hash to its local code. Validate tenant, wallet, request key,
action, count, unique hashes/token assignments and internal-component format.
Do not rely on response order. Assemble complete codes locally for display,
text distribution or standard/Avery duplex PDF printing. The receipt is private
and must not be cached by proxies.

## 4. Redemption

The recipient enters or scans one complete credential. The frontend separates it
internally, uppercases the 12-character v2 code portion and hashes it (legacy case is preserved), and submits `code_hash`, `pin` and the selected
receiving wallet to `POST /redemptions`. Display that wallet before submission.
Neither cleartext codes nor receipts belong in chat prompts. The existing HTTPS,
fragment-only QR handoff and immediate fragment removal remain required. HTTP
Nebula previews deliberately reject QR autofill.

## 5. Rollout and maintenance

`PLATFORM_LOCAL_REGISTRATION_REQUIRED` defaults to true. Production refuses to
start with it false. False is an explicit isolated-development compatibility
option, not a migration shortcut for production. Deploy the matching API, worker
and clients together. Clients must not silently fall back to server generation.

The additive `issuance_assignments` table binds chain, card contract, token ID, UID,
tenant, issuer, operation, entry index, code hash and confirmed purchase transaction.
Its unique constraints prevent cross-user UID reuse. Read IDs from the actual
`BatchPurchased` receipt, never a preflight supply counter.

The additive `code_registration_claims` table records tenant/hash/operation
reservations. Back it up with the operation database and protect the existing
encryption key. Do not delete claims to work around a failed batch. Reconcile
submitted transaction intents and private receipts before deciding on replacement
inventory or a new batch. A legacy queued operation with no generated material
fails closed when the flag is true; an older durable operation that already holds
encrypted generated codes can finish reconciliation without replacing its codes.

Completed historical operations retain their issuer-only `/operations/{id}/codes`
export. Their `/registration` endpoint returns 409 with an explicit historical
export message. New operations' `/codes` endpoint returns 409; their cleartext
codes exist only in the browser/recovery file. Administrative registered-contract
views remain public-chain status views, not a secret inventory.

Before enabling real issuance, verify unallocated public inventory, worker funding,
private-state health, storage backups and exact deployed code. The September 14 test raised the registered ceiling from eight to twelve
and used token nine, leaving three unused slots. Read the live available supply
before another run; do not reset the chain.

Acceptance must cover a fresh batch, refresh/import, network interruption,
concurrent retry, wrong wallet, wrong credential, one successful redemption and
replay rejection, confirmed NFT ownership, explorer/IPFS details and printable QR
handoff on HTTPS. Offline tests and production builds are necessary but do not
substitute for this live acceptance or ownership handoff.

## Verified development result â€” 14 September 2026

The live run created and redeemed token **9** using API source commit
`95e6b928ce7832c5a5dd21788da68e1345118461` and the real development member
`0x35f9a01bc437c998175E56eD78F77C808FC64c18`. It verified saved-request recovery, identical-request retry,
client-hash registration, no cleartext code in the service database/export,
wrong-credential rejection, four concurrent redemption requests resolving to one
operation, replay rejection and actual NFT delivery. The member paid no native gas.
Backend-01 IPFS metadata/media and Blockscout indexing matched the final tokenURI.

Delivery transaction: `0xbd5e3b2b4e3c0c25bec4ee0e22adce0cf1d6398e248ad499ddd17fab990dd0b6`.
Inventory registration transaction: `0x56566a2e325a8a38c688eeccdf11d43c67c0b797d5359307fff86cf51c06fff5`.
Four additional slots were registered for **0.004 KOTA**, raising the ceiling to 12;
the completed test consumed one, leaving three for subsequent development checks.
No genesis or contract implementation changed during this run.

This was a live API harness, not a real thirdweb browser-session acceptance run.
The ordinary preview worker remains disabled. HTTPS host/widget acceptance,
production PostgreSQL and persistent services, token-bound inventory settlement,
payment configuration and final ownership/production review remain open gates.
Open sponsorship restoration also remains pending exact approval.


## Token-bound inventory update â€” 14 September 2026

The earlier disabled-inventory notes describe the previous snapshot. Registry and
account deployment are now live, with wallet-approved preparation and receipt
confirmation in API 1.13.0. See the [inventory guide](TOKEN_BOUND_INVENTORIES.md).
Parent-card nesting and native/ERC-20 inventory controls remain unsupported.


## Concurrent issuance and gas accounting â€” 15 September review

Public pre-registration remains owner-controlled: `setMaxSaleSupply` pays the
CodeManager fee for additional UID capacity. This is separate from membership gas
allowances and actual code issuance. Pente synchronization only raises its observed
capacity; older observations arriving later do not roll it back or fail a batch.
The new numeric private entry point rejects a partial batch atomically. A confirmed
public purchase followed by failed private storage still needs recovery; it is not
an atomic transaction across the two steps. Never delete the public purchase intent,
UID mapping or code claims, and never remint an uncertain batch. After a confirmed
private revert, an operator must inspect the failure and prepare a reviewed retry
of the private step against the same hashes, entropy and assigned UIDs. Automatic
resubmission of a reverted private step is not enabled in this release.

New custom cards use `buyWithSharedMetadata` with one exact IPFS document per batch;
metadata remains correct if capacity increases while other users mint. Legacy
purchase segments keep their existing directory-plus-token-filename behavior.
The moment.cards owner can restrict direct purchases to the authorized issuer so
someone cannot drain free inventory outside its membership workflow. This is an
optional campaign contract control, not a platform-wide sponsorship allowlist.

WorkerGasSponsor 1.3.0 requires platform worker authorization and tenant opt-in.
Admission reserves a bounded whole-workflow budget in the database, then on chain
before issuance starts. The trusted worker attests public receipt costs, including
reverted transaction gas; this is not a trustless receipt proof. The chain settles
within the reservation, charges the same user policy used by delegation and pays
only the fixed treasury. The Router verifies the settlement event's operation,
tenant account, wallet, evidence and actual charge. Pending funds remain locked
across UTC day changes and uncertain receipts; duplicate retries do not rebill.
A rejecting treasury defers its own revenue without trapping user reservations.
Enrollment and emergency code deactivation remain platform-funded maintenance.

The original worker-paid transactions are not retroactively billed to users. New
metered work requires the reviewed implementation, replacement allowance policy,
usage-preserving policy migration and explicit activation. Current test snapshots
are not proof that this activation has happened. The three-digit configuration
retains the existing 32-entries-per-component limit: at most 32,000 simultaneous
active private codes in this shared contract. Monitor capacity and keep production
volume below that limit until a separately reviewed scaling change is released.
