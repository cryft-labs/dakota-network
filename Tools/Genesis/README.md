# Cryft Network genesis (rebuild 2026-11-25)

Fresh genesis for chain id **113211** (`0x1ba3b`). It replaces the lost 112311 chain and its hand-built
1.24 GB archive. Work order WO-1; audit findings X-1..X-72 in `review-20261121/contract-audit-20261125/CONSOLIDATED.md`.

## Files

| File | What |
|---|---|
| `inputs.json` | Chain config, governance (roots, voters, vote window, upgrade delay), balances, the 5 system proxies, EIP-2935/7002/7251, pinned compilers |
| `validators.json` | Validator addresses, node public keys and enodes (public parts only) |
| `keygen.py` | Makes the 4 validator node keys on the Mac. Custody: `~/Cryft/codex-outputs/cryft-wallets/private/validators-20261125/` (0600) **and** the login Keychain (`cryft-validator-0N-20261125`). Never git, never printed. `--verify` checks both copies agree |
| `build.py` | Builds `Contracts/Genesis/CryftGenesis.json`, `genesis-release.json` and `standard-input/`. `--check` proves the committed files are a byte-identical rebuild |
| `localnet.py` | 4 Besu 26.8.1 nodes on 127.0.0.1. `production` = the real genesis and keys, read-only; `rehearsal` = same builder, ephemeral governance keys |
| `rehearse.py` | On-chain checks and governance drills; writes a JSON receipt |

## Decisions baked in

- Roots `[0x9247…e921, 0x6333…0867]`, voter `0x6333…0867` (handover to Chad at launch). No test account. Balances: 0x9247 32 CRYFT, 0x6333 100 CRYFT.
- 64M gas, 1 s blocks, 64 s empty-block period, QBFT timing unchanged, `contractSizeLimit` 32768, all forks through Osaka/BPO5 at 0.
- Vote windows are seconds (7 days). Proxy upgrade delay is a 0x1111 voter setting, **0 now (dev)**; raising it is on the before-real-value checklist (`voteToSetUpgradeDelay`).
- **5 genesis proxies, not 32,431.** See `proxyCountDecision` in `inputs.json`.
- **EIP-2935** history contract. Besu 26.8.1 runs its pre-block call under QBFT only if the config also names the deposit, EIP-7002 and EIP-7251 contracts, so those two canonical contracts are in the alloc too (code copied from Besu's bundled `hoodi.json`), and deposits point at the zero address (no deposit request can ever be produced).
- Validator contract compiled with solc 0.8.19 / London through the official soljson build (`Tools/SolcCompiler/soljson.py`, sha256-pinned), proxy and ProxyAdmin with 0.8.37 / Osaka.

## Commands

```bash
python Tools/Genesis/build.py --check
python -m pytest Tests/Genesis -q
python Tools/Genesis/localnet.py start --kind production --run /tmp/net && python Tools/Genesis/localnet.py wait --run /tmp/net
python Tools/Genesis/rehearse.py --run /tmp/net --kind production --out proof.json
python Tools/Genesis/localnet.py stop --run /tmp/net --wipe
```

Deploy: `Tools/Deployment/stage-genesis.py --commit <sha> --genesis-sha256 <genesis_sha256 from genesis-release.json>`,
then `install-besu.py` (it reads the tx-pool policy from `Tools/Deployment/txpool-policy.json`).

## Still to do after genesis (not genesis-baked)

- D.7 bootstrap: `Tools/Genesis/link.py` (plan `link-plan.json`, pins `link-lock.json`, guard `Contracts/Genesis/genesis-block.json`) links cafE/c0DE/FEeD/de1E6A7E with init data; rehearsed (`proof/link-rehearsal-20261126.json`)
  using the new initializers (`initializeWithVoters`, `initializeWithAdmin(..., upgradeDelay)`); no beacon handover.
- Raise the upgrade delays and move value proxies under the system timelock before real value (audit §3.2).
