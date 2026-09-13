# Token-bound accounts for moment.cards

Review package for ERC-6551 on Dakota chain `112311`. These contracts are **not
deployed**. Canonical registry `0x000000006551c19487814612e58FE06813775758` and
Nick's CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` currently
have no bytecode on this genesis.

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
