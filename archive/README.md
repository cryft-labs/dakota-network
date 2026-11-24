# archive/

The place for code retired from the live tree (rename plan, part C; Chad, 2026-11-23: "retire and move the unused code
to an archive directory within the repo"). Files land here with `git mv`, keeping their relative paths
(archive/Tools/x/y.py was Tools/x/y.py), so `git log --follow` keeps their history. Nothing here is built, deployed,
published or tested: the repo has no pytest configuration, and its tests are run as `pytest Tests` and `pytest Tools`,
which never reach archive/.

## 2026-11-23: nothing moved

Every file was checked against the retired contracts (deploy/retired-contracts.json in dakota-private-design): legacy
cards 0x9e8C…a410, Moment Inventory 0xF1a8…08C4, QR Development 0x534E…1fb, MomentCardAccount 0x492A…83F2. No code in
this repo serves only them:

| Path | Why it stays |
|---|---|
| Contracts/Accounts/MomentCardAccount.sol and its artifacts | Deployed and verified (0x492A…83F2); rule 4 keeps its source and artifacts. |
| Tests/Accounts/test_tba.py | Tests the ERC-6551 registry, which is live (0x7144…66D7 holds the V8 CardAccountV8 accounts), beside MomentCardAccount. |
| Tools/LiveGenesis/deploy_accounts.py | The deploy record of that same live registry (and MomentCardAccount). |
| Contracts/Accounts/Moment{InventoryToken,ProjectProxy,ProjectRegistry}.sol, Tests/Accounts/test_moment_projects_inventory.py, Tools/LiveGenesis/deploy_moment_projects.py, deploy_inventory_allocation.py, deploy_inventory_identity.py | Moment Inventory 0xF1a8 is still wired by the router (services/platform/projects.py, contracts/projects-inventory-release.json), so it is live until that is proven unused. |
| Tools/ApprovedSponsorship/release.py, restore_open.py | Upgrades the genesis GasSponsor (live); 0x9e8C is one entry of its seed list. |
| Tools/Paladin/issuance-release.py, private-content-release.py | Paladin tooling (kept by rule); the membership registry 0xA6B1 they name is live. |
| Tools/LiveGenesis/common.py | The kit's governance/common.py unlocks keys through it. |
| Contracts/Tokens/GreetingCards.sol | The legacy card contract's verified source (rule 3). |

Candidates to look at again once the router drops the Moment Inventory routes: the Moment Inventory tooling above.

## 2026-11-24: dakota-cards-portal

`archive/dakota-cards-portal/` was `dakota-cards-portal/`, the static landing page of the old dakota.cards site. It was
not hosted anywhere. Retired 2026-11-24 with every other dakota.cards address (Chad: "update to explore.cryft.cards and
retire all old uses for dakota.cards"); the live names are cryft.cards, explore.cryft.cards, rpc.cryft.cards,
gateway.cryft.cards and docs.cryft.cards. Its pages keep the old dakota.cards links as a record of what it was.
