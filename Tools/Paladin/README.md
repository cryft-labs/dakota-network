# Paladin on the Cryft Network (Phase E)

Paladin v1.0.0 with the Pente privacy domain runs on Paladin-01 (Nebula `100.111.32.201`) beside its companion
Besu, for chain 113211.

## Pieces

| File | Runs on | What |
|---|---|---|
| `build.py` | Mac | Builds the Pente factory/privacy group (pinned Paladin v1.0.0 source, commit `6d4b9134`) and the in-repo Paladin contracts; keeps `artifact-lock.json` |
| `deploy_factory.py` | Mac | Deploys the PenteFactory (implementation + ERC1967 proxy with `initialize()` in one transaction) with the dev deployer |
| `install-runtime.py` | Paladin-01 (root) | Installs Paladin + Postgres (rootless Podman, user `cryft-paladin`, data on the `/var/lib/cryft` volume), nginx `:8550`, and seals the seed |
| `fund_settlement.py` | Mac | Tops settlement@paladin01 up to a target from the dev deployer |
| `verify.py` | Mac | Read-only acceptance: services, listeners, access rules, factory, sealed seed, identities, settlement balance |
| `nginx.conf` | Paladin-01 | `:8550` for Backend-01 only; `127.0.0.1:8552` to the colocated Besu |
| `storage_layout.py` | Mac | Layout normalisation shared by the build tools |

## Pinned runtime

- Paladin image `ghcr.io/lfdt-paladin/paladin@sha256:b7d9b4ab…4357`
- Postgres image `docker.io/library/postgres@sha256:67f41722…5675`
- Paladin JSON-RPC `127.0.0.1:8548` (WS `:8549`), published by nginx on `100.111.32.201:8550` for Backend-01 only.
  Postgres `127.0.0.1:5433`. Metrics `127.0.0.1:6100`. No public listeners.

## Seed custody (Chad, I-1, 2026-11-25)

The seed is generated on Paladin-01 and stays there in plaintext (`/etc/cryft/paladin/secrets.json`, root 0600).
`install-runtime.py --seal-cert` seals `secrets.json` to the backup recipient certificate (openssl cms, AES-256-GCM,
RSA-OAEP-SHA256; the kit's cryft-backup format) as `secrets.json.cms`. That sealed file is copied to the Mac's
custody folder now and offsite once the Backblaze bucket exists. Re-seal and re-ship after any change. Never print
the seed.

Identities derived from the seed (bip32): `operator@paladin01` and `settlement@paladin01`. The Paladin signer is
single-purpose: never a creditor, relayer or top-up signer.

## Order

```bash
python Tools/Paladin/build.py                     # artifacts + lock (Mac)
python Tools/Paladin/deploy_factory.py --execute  # PenteFactory proxy and its deploy block (Mac)
# Paladin-01, as root, from the staged release C:
python3 /opt/cryft/releases/C/Tools/Paladin/install-runtime.py --commit C --factory <proxy> --from-block <block> \
    --seal-cert /root/cryft-bootstrap/backup-recipient.crt
python Tools/Paladin/fund_settlement.py --execute # 0.03 CRYFT to start (Mac)
python Tools/Paladin/verify.py --out receipt.json # Mac
```

Privacy groups and private contracts (PrivateComboStorage) are created in the contracts phase (runbook F, V82-P).
