# Blockscout source verification — completed 2026-09-11

## 1. Result

**32,451 public contract addresses are fully verified:** all 32,433 genesis
contracts and all 18 later public deployments. The independent audit found zero
partial matches, failures, missing records or license mismatches. This includes
historical implementations and development canaries still present on chain.

The genesis runtime checks used block 424, hash
`0x50d116ba3c5e548a50124537eda2e5e947d6807f968788b4e4b38d2f2c856d78`.
The subsequent creation scan found no additional deployments through block 440.
The final independent source audit completed at 2026-09-11 08:25:30 UTC.
The chain remains 112311, with the existing genesis hash unchanged.

Read the [machine-readable summary](blockscout-verification-20260911.json) and
[complete compressed evidence](blockscout-verification-evidence-20260911.zip).
The archive includes an address-by-address CSV, every genesis live-code check,
the independent database source/hash export, genuine Rust verification results,
normal API submission receipts, IPFS/private-code checks and service health evidence.

## 2. What was checked

* Every genesis address's actual runtime at the fixed audit block matched its
  recorded compiler artifact byte-for-byte.
* Every public database record had the correct runtime SHA-256, primary and imported
  source-file SHA-256 values, compiler, target/path, license and constructor data.
* Sixty-four public API pages independently reported full verification, correct
  source bytes and license, with no borrowed verified-twin-only status.
* Seven active proxy-to-implementation links matched the deployment inventory:
  GasManager, CodeManager, GasSponsor, delegation registry, Pente factory/group,
  and the card NFT proxy. Their implementations are verified separately.
* All 224 previously published IPFS objects retained recursive pins and passed
  exact API and gateway readback. No compiler metadata was reformatted.
* All five private Pente deployment code hashes still matched their published
  artifacts through read-only private calls. Private state was not exported.

Apache-2.0 contracts use Blockscout `apache_2_0` / 12; MIT contracts use `mit` / 3.
The genesis transparent shells remain MIT while their Apache implementations retain
Apache. All imported SPDX notices remain intact. No blanket MIT default was used.

## 3. How genesis verification was performed

The three distinct genesis builds and all 18 later public deployments were first
verified through Blockscout's normal v2 Standard JSON API. Missing genesis addresses
were then handled by a bounded maintenance worker after a validated local database
backup and a two-address dry-run/publication pilot.

The worker obtained genuine Rust `FULL` results for the three genesis builds and
reused those results only after checking identical compiler input, target, source
bytes, ABI, absent constructor arguments, no immutables, and exact live runtime at
each address. This avoids recompiling the identical proxy 32,431 times. It does not
claim that 32,433 separate compiler invocations occurred.

Address insertion used the normal `Chain.import` pipeline. Actual source publication
used the installed Blockscout verifier-result publisher, preserving transaction and
balance history. No creation transactions, constructor data or verified flags were
fabricated. A separate database-wide audit checked the resulting records rather
than trusting the worker's success messages alone.

Worker source commit: `9c04893fb4de732f43e1af061b7cc48c25d33678`.
The tool/runbook remain in [Tools/BlockscoutVerification](../Tools/BlockscoutVerification/README.md).

## 4. Explorer links and exclusions

Open the [explorer](http://100.111.69.1:8080/), or inspect:

* [Validator](http://100.111.69.1:8080/address/0x0000000000000000000000000000000000001111?tab=contract)
* [CodeManager proxy](http://100.111.69.1:8080/address/0x000000000000000000000000000000000000c0DE?tab=contract)
* [Current CodeManager implementation](http://100.111.69.1:8080/address/0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424?tab=contract)
* [GasSponsor proxy](http://100.111.69.1:8080/address/0x000000000000000000000000000000000000FEeD?tab=contract)
* [Card NFT proxy](http://100.111.69.1:8080/address/0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410?tab=contract)

Eighteen native precompiles are documented as client implementations, not Solidity
deployments with invented metadata. The tester's EIP-7702 designator is also not a
Solidity verification target; its dispatcher/implementation targets are verified.
Private Pente addresses have private code-hash evidence, not public explorer badges.

The homepage address count has a periodic cache and can lag the imported inventory;
the per-address verification records and audited database totals are authoritative.
No service restart is needed merely to refresh that display.

## 5. Operations and remaining boundaries

The maintenance job finished successfully and is now **disabled** to avoid repeating
completed work on normal reboots. Its evidence remains under
`/var/lib/cryft-explorer/dets/verification-20260911/` on Backend-01.
The pre-import logical backup remains at
`/var/backups/cryft-explorer/before-genesis-verification-20260911.dump` on Backend-01.
See the runbook for deliberate restart/revalidation procedures.

Explorer API, database, Redis, verifier, Nginx and IPFS remained active after the job.
The existing API was not restarted, no ports were opened, and all remote access
used Nebula. No chain transactions, ownership changes, new funding or private
state changes were performed by this verification task.

This completes source verification. The previously recorded functional deployment
tests remain separate evidence. Router integration, site/widget rollout, final
management acceptance and production acceptance are not completed by an explorer
verification badge.
