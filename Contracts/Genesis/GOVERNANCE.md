# Cryft governance guide

How authority works on the Cryft Network (chain 113211) as built in the 2026-11-25 genesis. Audit references
(X-…) are in the rebuild review notes; the contracts themselves follow [`../STYLE.md`](../STYLE.md).

## 1. Who holds what

| Contract | Authority | Notes |
|---|---|---|
| ValidatorSmartContractAllowList `0x…1111` | **Voters** approve every change by a 2/3 supermajority ballot: validators, voters, roots, provider lists, the ballot window and the network **upgrade delay**. | Genesis storage sets every field; there is no `initialize()` (X-6). Built with solc 0.8.19 / London. |
| Genesis proxies (`cafE`, `c0DE`, `FEeD`, `de1E6A7E`, `Face`) | **Roots** (from 0x…1111) and each proxy's local **overlords** govern the proxy; **guardians** (roots count as guardians) schedule upgrades. | Upgrades are scheduled and delayed (section 2). A root can renounce its own power on one proxy; revoking all roots needs an overlord quorum (X-17). |
| ProxyAdmin `0x…FacAdE` | Executes an upgrade for a guardian of the target proxy, only once that upgrade was scheduled and its delay has passed. | Stateless; `upgradeAndCall` requires call data. |
| GasManager 2.6.0 at `0x…cafE` | Its own **voters** (initial list set at link). Funding and burns: ballot, then an **execution delay**, then execution within the approval window, under a per-period **outflow cap**. | Burn approvals expire and die on any voter change; guardians capped at 64. |
| CodeManager 3.1.0 at `0x…c0DE` | Its own **voters**. Fee vault, registration fee (capped), per-gift privacy-group grants (with per-group epochs). | No global privacy-group grant (X-21). |
| ProgramGasSponsor 1.5.2 at `0x…FEeD` | **Platform admin** (two-step transfer) and a separate **pauser** that can only stop. | Starts paused; program sponsors are admin-locked. |
| CryftDelegationRegistry 3.0.0 at `0x…de1E6A7E` | **Registry admin** (two-step transfer). Member wallet code changes in two phases with a configurable delay; the admin or any proxy guardian can cancel. | The beacon is owned by the registry from construction (X-2). |

## 2. Upgrading a genesis proxy

1. A guardian calls `proxy_scheduleUpgrade(implementation, data)` on the proxy. The event `UpgradeScheduled` is
   public. Each proposer holds at most one schedule per proxy.
2. Anyone watches: a guardian or overlord can `proxy_cancelUpgrade(id)` during the wait.
3. After `getUpgradeDelay()` seconds (read from 0x…1111, 0 to 30 days) and within 14 days, a guardian calls the
   ProxyAdmin's `upgrade(proxy, implementation)` (no data) or `upgradeAndCall(proxy, implementation, data)`.
4. The delay is **0 in dev**. Raising it (`voteToSetUpgradeDelay`) is on the before-real-value checklist.

A proxy that was never linked rejects every call and coin transfer. Linking (`proxy_linkLogicAdmin`) needs init
data in the same transaction, so nobody can initialize a contract before its owner (X-16).

## 3. Ballots

- Windows are measured in **seconds** (1 hour to 30 days; 7 days by default), never in block counts (X-14).
- A ballot freezes its electorate, threshold and expiry when it opens; only a member can open one.
- Each voter can hold at most `max(1, 64 / electorate)` open ballots, 64 in all (X-13).
- Removing a voter, replacing the voter set, and removing a guardian or overlord are **exempt**: they never count
  toward those caps and never wait for another proxy ballot, so junk ballots cannot block them.
- Anyone may clear an expired ballot (`resetExpiredTally`); that frees the opener's slot and grants nothing.

## 4. Provider lists and recovery

Provider (external member list) changes go only through the hash-bound configuration ballots
(`voteToSetVoterConfiguration`, `voteToSetValidatorConfiguration`, `voteToSetRootConfiguration`): voters approve
the exact resulting membership hash (X-55). A provider outage keeps the last approved list. Besu reads
`getValidators()` from the approved cache, never from providers. At least 4 validators remain at all times.

## 5. Before real value

- Raise the proxy upgrade delay (0x…1111) and the delegation upgrade delay (registry).
- Move value proxies under the system timelock and revoke roots there; hand roots and voters to the governance
  keys (audit §3.2).
- Replace the placeholder voucher signer with its dedicated key before unpausing sponsorship.
