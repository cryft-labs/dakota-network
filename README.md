# Cryft Network

Smart contracts, genesis, tools and node configuration for the **Cryft Network**: a permissioned QBFT chain on
Hyperledger Besu with [Paladin](https://github.com/LFDT-Paladin/paladin) privacy.

All project-owned contracts are licensed under **Apache 2.0**. This software is part of a patented system: see
[LICENSE](LICENSE) and <https://cryftlabs.org/licenses>.

## Live network details

| | |
|---|---|
| Network name | **Cryft Network** |
| Native coin | **Cryft Coin (CRYFT)**, 18 decimals |
| Chain id | **113211** (hex **0x1ba3b**) |
| Block 0 hash | `0xc32d64ac046ddf4177b1e5bc51265fac2bfdd5e3b1a5f252c3788b47ba6c21cc` |
| Genesis file sha256 | `af1ea7970669551b2c529d6bd16df65972286bc151d28d27d89f26d923307a68` (`Contracts/Genesis/CryftGenesis.json`) |
| Consensus | QBFT, 4 validators; 1 s blocks with activity, 64 s when idle; 64,000,000 gas per block |
| Contract size limit | 32,768 bytes |
| Public RPC | https://rpc.cryft.cards |
| Explorer | https://explore.cryft.cards |
| IPFS gateway | https://gateway.cryft.cards |
| Application contract addresses | from the `prod2` release record once deployed |

Live since 2026-11-26 on Validator-01..04, Archive-01 (archive node and private RPC) and Paladin-01. Acceptance
receipt: [`Tools/Genesis/proof/live-113211-20261126.json`](Tools/Genesis/proof/live-113211-20261126.json).

## Genesis system addresses

| Address | Contract | Role |
|---|---|---|
| `0x0000…1111` | ValidatorSmartContractAllowList | Validators, voters and roots; the network-wide upgrade delay. Built with solc 0.8.19 / London |
| `0x0000…FacAdE` | ProxyAdmin | Executes scheduled upgrades of the genesis proxies |
| `0x0000…cafE` | GasManager 2.6.0 (behind a genesis proxy) | Block-reward beneficiary; voter-governed funding with a delay and an outflow cap |
| `0x0000…c0DE` | CodeManager 3.1.0 (behind a genesis proxy) | Unique code registry and redemption records |
| `0x0000…FEeD` | ProgramGasSponsor 1.5.2 (behind a genesis proxy) | Sponsored EIP-7702 execution; starts paused |
| `0x0000…de1E6A7E` | CryftDelegationRegistry 3.0.0 (behind a genesis proxy) | Member wallet code (7702), two-phase upgrades |
| `0x0000…Face` | genesis proxy, unlinked | Reserved for an ERC-8004 agent registry |
| `0x0000F908…2935` | EIP-2935 | Historical block hashes |

Genesis roots: `0x9247524040D91D5dd1521A25f2e7711d4a0fe921`, `0x633309d1155fD658a717e4f5E4FA853615400867`.
Genesis voter: `0x633309d1155fD658a717e4f5E4FA853615400867` (handover to the governance keys at launch).

## Governance in one paragraph

Every genesis proxy upgrade is scheduled on the proxy first (`proxy_scheduleUpgrade`), is public, can be cancelled
by any guardian or overlord, and runs through the ProxyAdmin only after the upgrade delay that the 0x…1111 voters
set (`voteToSetUpgradeDelay`, 0 in dev, raised before real value). Ballots are open for a window measured in
seconds, each voter can hold only a few open ballots, and removing a voter or guardian is never blocked by junk
ballots. Details: [`Contracts/Genesis/GOVERNANCE.md`](Contracts/Genesis/GOVERNANCE.md).

## Where things are

| Path | What |
|---|---|
| [`Contracts/Genesis/`](Contracts/Genesis) | Genesis-baked contracts (validator, proxy shell, ProxyAdmin, governance libraries), GasManager, the 7702 delegation and gas-sponsorship contracts, the genesis file and its manifest |
| [`Contracts/CodeManagement/`](Contracts/CodeManagement) | CodeManager, CanonicalUid, PrivateComboStorage (Pente) |
| [`Contracts/Paladin/`](Contracts/Paladin) | ManagedProxyAdmin and the Paladin acceptance probe |
| [`Contracts/TenantRegistry/`](Contracts/TenantRegistry) | Kota tenant-access registry sources |
| [`Contracts/STYLE.md`](Contracts/STYLE.md) | The one header, layout, wording and safety standard for genesis contracts |
| [`Tools/Genesis/`](Tools/Genesis/README.md) | Reproducible genesis builder, validator keygen, local 4-node network, on-chain drills, the D.7 link tool, storage-layout proof |
| [`Tools/Deployment/`](Tools/Deployment/README.md) | Stage the genesis, install Besu and the archive RPC on the hosts, tx-pool policy |
| [`Tools/SolcCompiler/`](Tools/SolcCompiler/README.md) | Compiler wrapper (0.8.37) and the soljson runner for the validator's 0.8.19 |
| [`Tools/Paladin/`](Tools/Paladin/README.md) | Paladin build and artifact lock |
| [`Tests/`](Tests) | Governance, genesis and readiness tests (local EVM, no network) |

## Checks

```bash
python Tools/Genesis/build.py --check
python -m pytest Tests Tools/Deployment/tests Tools/SolcCompiler/tests -q
python Tools/Genesis/layout_snapshot.py --out /tmp/layout.json --compare Tools/Genesis/proof/layout-after-style-pass.json
```

## Licence notes

- Project-owned contracts and tools: Apache-2.0.
- OpenZeppelin-derived files under `Contracts/Genesis/Upgradeable/` keep their MIT licence; the validator contract
  is derived from Hyperledger Besu (Apache-2.0).
- The `CodeManager` and `PrivateComboStorage` contracts implement methods claimed in
  [U.S. Patent Application Serial No. 18/930,857](https://patents.google.com/patent/US20250139608A1/en). Any
  unauthorized use, reproduction, or deployment of these contracts or substantially similar implementations will be
  pursued through legal action. Contact <https://cryftlabs.org/licenses> for licensing.

History before the 2026-11-25 rebuild is kept behind the git tag `archive/pre-rebuild-20261125`.
