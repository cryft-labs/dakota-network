# Token-bound accounts for moment.cards

Deployed on Dakota chain `112311` on 14 September 2026. This deployment uses a
Dakota-local registry at `0x7144D34A7cB2fDF9a0C008855Da6A9B15Cf266D7` and account
implementation `0x492A6645D40Fb5896C0D53D08778D819bA5583F2`. The canonical registry
address was not claimed or installed. See [deployment/20260914.json](deployment/20260914.json)
for transaction hashes, runtime identities and the pinned source commit.

Parent card NFT proxy: `0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410`.

## Contracts

| File | License | Role |
| --- | --- | --- |
| `ERC6551Registry.sol` | MIT (ERC-6551 v0.3.1) | Permissionless CREATE2 registry |
| `MomentCardAccount.sol` | Apache-2.0 | Account implementation |
| `Interfaces/*.sol` | MIT (ERC-6551) | Standard interfaces |

Public review artifacts use Solidity `0.8.37` and EVM `osaka`. That compiler
target **cannot** reproduce the historical canonical registry bytecode (solc
`0.8.17`). See [deployment/TEMPLATE.md](deployment/TEMPLATE.md). Standard JSON,
metadata, ABI and bytecode are under `artifacts/osaka/Accounts/`. SPDX mapping
is in `licenses.csv`.

## Derivation

Each account is an ERC-1167 proxy created by the registry:

```
init = ERC-1167 constructor/header || implementation || ERC-1167 footer
     || salt || chainId || tokenContract || tokenId
account = keccak256(0xff || registry || salt || keccak256(init))[12:]
```

`token()` reads `(chainId, tokenContract, tokenId)` from the proxy footer.
`owner()` is `IERC721.ownerOf(tokenId)` on that contract, and only when
`chainId == block.chainid`.

moment.cards application salt:

```
keccak256("moment.cards:tba:v1")
```

Create or predict with:

```
registry.createAccount(implementation, salt, 112311, cardProxy, tokenId)
registry.account(implementation, salt, 112311, cardProxy, tokenId)
```

The address is counterfactual: assets may be sent before `createAccount`.

## Funding

Fund the **account proxy**, never the implementation.

- Native KOTA: send to the TBA address (`receive()` is open on the proxy).
- ERC-1155 traits: mint or `safeTransfer` into the TBA.
- ERC-721 from other collections: `safeTransferFrom` into the TBA.
- CARD NFTs from the parent collection are rejected (nested inventory / ownership cycle).

Gas for `execute` is paid by `msg.sender`. Signed `executeSigned` lets a relayer
submit an owner signature; the TBA still needs native balance if the call sends
value from the account.

## Execution and signatures

- `execute(to, value, data, operation)` — current NFT owner only. `operation`
  must be `0` (CALL). `state` increments first, then the call runs.
- `executeSigned(..., nonce, deadline, signature)` — EIP-712, `nonce == state()`,
  `block.timestamp <= deadline`. Replay of the same signature fails. A signature
  from a previous owner fails after transfer.
- EIP-1271 `isValidSignature` recovers an ECDSA signature over the supplied
  digest and requires the recovered address to be the current owner.

## Nested CARD NFTs

`onERC721Received` reverts `NestedCardNft` when `msg.sender` is the parent token
contract. A post-`execute` check also reverts if the parent card's `ownerOf`
becomes the TBA itself (unsafe self-transfer).

Unsafe `transferFrom` of a **sibling** card can still land without a receiver
hook. Do not transfer CARD NFTs into TBAs. Burn of the parent typically makes
`ownerOf` revert, which locks `execute` and can trap remaining inventory.

## Transfer and burn

| Parent NFT event | TBA control |
| --- | --- |
| Transfer to a new holder | New holder is `owner()` immediately. Previous holder cannot execute. |
| Transfer into its own TBA | Reverted by nested-card checks when the receiver hook or post-execute check runs. |
| Burn / nonexistent token | `ownerOf` reverts; `execute` / `executeSigned` revert. Assets remaining in the TBA are not recoverable through this account. |

There is no admin recovery path in the account.

## Upgrade

The registry is immutable. Each TBA is an ERC-1167 proxy with a **fixed**
implementation address baked into bytecode.

A new `MomentCardAccount` deployment is a new `implementation` argument and
therefore a **different account address**. The application must bind the first
resolved `(registry, implementation, salt, chainId, tokenContract, tokenId)`
tuple and must not silently switch to a later implementation. Existing TBAs and
their inventories stay on the original implementation; move assets with
`execute` before any intentional migration.

## Tests

```sh
python -m pip install -r Tests/Governance/requirements.txt
python -m pytest Tests/Accounts/test_tba.py -q
```

Local PyEVM tests do not deploy to chain 112311 and do not prove Besu acceptance.

## Public saved projects and named inventory tokens

The additive 16 September release introduces two **transparent upgradeable**
applications. This does not change the fixed ERC-6551 implementations above.

Deployment is complete on chain 112311. All five addresses are fully verified in
Blockscout with their Apache-2.0 top-level licenses. See
[deployment/20260916](deployment/20260916) for receipts, checks and configuration.

| Role | Address |
| --- | --- |
| Inventory token proxy | `0xF1a8a53Ef5400F63B4E5cA9FCbeBed097f9b08C4` |
| Inventory implementation | `0xD78a10d70d4fDeb4294521e8e2fD895Afa7f0b3b` |
| Project registry proxy | `0xEE299c9a23117a626A27D500Da886Dff89b542F8` |
| Project implementation | `0x577D197FD37fCecdeDE41cc4C21EDe6960c694f7` |
| Shared proxy administrator | `0xc551BC2A8c09c16daAE37a2288c672a42Ab3F8f5` |

Use proxy addresses in applications. The release bundle is pinned at
`ipfs://QmQybJDSeakYMGYFZnnEBcRKPusnHc8PtPtoSSKdVgZ7KA`; all 55 compiler
objects were read back and their recursive pins confirmed on Backend-01.
This does not establish public IPFS peering or public gateway availability.

Live dev-wallet tests saved two revisions, minted three interchangeable units
of a named test type, and transferred one unit to the existing test wallet.
Read-only negative checks rejected stale revisions, another wallet's write,
repeated issuance and an administrator attempting to transfer a holder's tokens.
No live upgrade was performed; populated-state upgrade preservation passed on
the isolated test chain. Root ownership and worker permissions stayed unchanged.

| Application | Purpose |
| --- | --- |
| `MomentProjectRegistry` | Append-only revisions of public reusable card designs, keyed by tenant, wallet and project ID. Each revision anchors a SHA-256 digest and IPFS URI. |
| `MomentInventoryToken` | A shared ERC-1155 collection. Each new named type has its own fixed supply; units of that type are interchangeable. Creating a type requires no new contract. |

Both proxies are initialized in their deployment transactions. Implementation
initializers are locked. The existing dev signer pays deployment gas, while
`0x9247524040D91D5dd1521A25f2e7711d4a0fe921` immediately owns both applications
and their shared `MomentProjectAdmin`. Only the root can authorize upgrades or
service relayers. The dev signer receives no privileged role. Ownership transfer
requires acceptance by the proposed new owner; renunciation is unavailable.

The initial application relayer is Paladin's existing public worker address,
`0xe7850ecede5d6f7d0b2d2ccabfc2f29d2c345125`. It is a trusted authenticated
service: it may save public designs or mint new types for users, but this release
does not let it move holder balances, increase an existing type's supply or erase
project revisions. Root-controlled upgrades can change application behavior;
these guarantees describe the reviewed implementation, not an immutable system.

### Data and recovery boundaries

Projects contain title, message, sender name, card type and color. They never
contain redeemable code secrets, PINs, recipient email lists or passwords. They
are public, have no passphrase, and reusing one generates a fresh batch. The
contract cannot classify arbitrary URI contents: the service enforces a strict
public-design schema, and direct callers must follow the same boundary.

Completed codes are separate: only after private registration supplies the final
code may the browser offer an encrypted recovery JSON. Public projects cannot
recover lost code secrets. The registry retains historical revisions even after
a newer revision is saved. IPFS pinning and backups are required to preserve the
referenced document bytes; a chain digest is not a backup of those bytes.

### Deployment and upgrades

Compile the three source files with `Tools/SolcCompiler/compile.py`, targeting
Solidity 0.8.37 / Osaka and output directory `projects-inventory-artifacts`.
The output includes standard JSON, metadata, storage layouts, ABI and bytecode.
Publish the source and metadata to the configured Backend-01 Kubo API before
deployment. All four top-level artifacts use **Apache-2.0**; bundled OpenZeppelin
dependencies retain their MIT SPDX licenses. Use `apache_2_0` / ID `12` when
verifying these top-level contracts in Blockscout.

`Tools/LiveGenesis/deploy_moment_projects.py --workspace <workspace>` performs a
read-only preflight. Add `--execute` only for the reviewed, committed and pushed
release. The journal at `outputs/moment-projects-inventory-20260916/` records each
signed transaction hash before broadcast and verifies exact runtime bytecode,
EIP-1967 slots, initializer locks and owner permissions. An uncertain transaction
must be reconciled by its recorded hash before another deployment attempt.

To upgrade, compile and compare storage layouts; preserve inherited OpenZeppelin
4.9.6 layout, existing field order/types and storage gaps. Test the upgrade against
a populated local state. Root calls the shared admin's `upgrade` or
`upgradeAndCall` for the relevant proxy. Publish/verify the new implementation
and update the Router's implementation hash pin only after review. Router calls
fail closed while an implementation differs from its configured release pin.

```sh
python -m pytest Tests/Accounts/test_moment_projects_inventory.py -q
```
