# Token-bound accounts and inventory for Cryft Cards

> These sources are retired and kept unchanged, including their contract names and on-chain identifier strings. Nothing here is
> deployed on chain 113211. Any future implementation uses Cryft names only.

## Contracts

| File | License | Role |
| --- | --- | --- |
| `ERC6551Registry.sol` | MIT (ERC-6551 v0.3.1) | Permissionless CREATE2 registry |
| `MomentCardAccount.sol` | Apache-2.0 | Account implementation |
| `MomentProjectRegistry.sol` | Apache-2.0 | Public saved card designs (transparent upgradeable) |
| `MomentInventoryToken.sol` | Apache-2.0 | Shared ERC-1155 named inventory types (transparent upgradeable) |
| `MomentProjectProxy.sol` | Apache-2.0 | Transparent proxy and shared `MomentProjectAdmin` |
| `Interfaces/*.sol` | MIT (ERC-6551) | Standard interfaces |

Build with `Tools/SolcCompiler/compile.py` (Solidity `0.8.37`, EVM `osaka`); the output includes Standard JSON, metadata,
storage layouts, ABI and bytecode. That compiler target **cannot** reproduce the historical canonical registry bytecode
(solc `0.8.17`), so the canonical registry address is out of reach for this build. SPDX mapping is in `licenses.csv`;
bundled OpenZeppelin dependencies keep their MIT SPDX licenses.

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

The application salt is the implementation's `APPLICATION_SALT` constant (an on-chain identity; its string never changes).
Create or predict with:

```
registry.createAccount(implementation, salt, 113211, cardProxy, tokenId)
registry.account(implementation, salt, 113211, cardProxy, tokenId)
```

The address is counterfactual: assets may be sent before `createAccount`.

## Funding

Fund the **account proxy**, never the implementation.

- Native CRYFT: send to the TBA address (`receive()` is open on the proxy).
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

A new account implementation is a new `implementation` argument and therefore a
**different account address**. The application must bind the first resolved
`(registry, implementation, salt, chainId, tokenContract, tokenId)` tuple and must
not silently switch to a later implementation. Existing TBAs and their inventories
stay on the original implementation; move assets with `execute` before any
intentional migration.

## Public saved projects and named inventory tokens

Two **transparent upgradeable** applications, separate from the fixed ERC-6551
implementations above:

| Application | Purpose |
| --- | --- |
| `MomentProjectRegistry` | Append-only revisions of public reusable card designs, keyed by tenant, wallet and project ID. Each revision anchors a SHA-256 digest and IPFS URI. |
| `MomentInventoryToken` | A shared ERC-1155 collection. Each new named type has its own fixed supply; units of that type are interchangeable. Creating a type requires no new contract. |

Both proxies are initialized in their deployment transactions and implementation
initializers are locked. The owner (root) owns both applications and their shared
`MomentProjectAdmin`; only it authorizes upgrades or service relayers. Ownership
transfer requires acceptance by the proposed new owner; renunciation is unavailable.

A relayer is a trusted authenticated service: it may save public designs or mint
new types for users, but it cannot move holder balances, increase an existing
type's supply or erase project revisions. Root-controlled upgrades can change
application behavior; these guarantees describe the reviewed implementation, not
an immutable system.

`createTypeAllocated` mints each selected card's allocation and the creator's
remainder in one transaction; a receiver rejection rolls back the entire mint.
Recipient accounts must be activated contracts, unique, and sorted numerically by
address. `activateAccounts` batches up to 100 deterministic ERC-6551 activations;
it is permissionless and idempotent, confers no spending authority and stores no
configuration. The shared collection exposes storage-free `name()` and `symbol()`
getters for explorer and wallet headings; each type keeps its own name, URI,
supply and metadata symbol.

### Data and recovery boundaries

Projects contain title, message, sender name, card type and color. They never
contain redeemable code secrets, PINs, recipient email lists or passwords. They
are public, have no passphrase, and reusing one generates a fresh batch. The
contract cannot classify arbitrary URI contents: the service enforces a strict
public-design schema, and direct callers must follow the same boundary.

The registry retains historical revisions even after a newer revision is saved.
IPFS pinning and backups are required to preserve the referenced document bytes;
a chain digest is not a backup of those bytes.

### Upgrades

Compile and compare storage layouts; preserve inherited OpenZeppelin 4.9.6 layout,
existing field order/types and storage gaps. Test the upgrade against a populated
local state. Root calls the shared admin's `upgrade` or `upgradeAndCall` for the
relevant proxy.

## Tests

```sh
python -m pip install -r Tests/Governance/requirements.txt
python -m pytest Tests/Accounts -q
```

Local PyEVM tests; they deploy nothing and do not prove Besu acceptance.
