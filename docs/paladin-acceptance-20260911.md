# Paladin/Pente development acceptance — September 11, 2026

Paladin is running against the existing Dakota chain. Five real private code
redemptions delivered five public moment.cards development NFTs to
`0x991acc255761dEE0421Ccd3F436788C24425122E`. The native EIP-7702 sponsored redemption
paid the public relayer and did not debit the recipient's native balance. MetaTx
remains disabled. This is direct Paladin/chain acceptance; Kota Router integration
and the moment.cards site are not yet deployed or validated.

The [maintenance runbook](../Tools/Paladin/README.md) records services, identities,
funding, addresses, secrets policy, IPFS, recovery and handover. The
[machine-readable evidence](paladin-acceptance-20260911.json) includes public hashes,
private transaction IDs, implementation hashes, current proxy targets and pins.
[Wallet balances](paladin-funding-20260911.json) were read at block 362.

## Results

| Check | Result |
|---|---|
| Local governance/hardening suite | 58 passed, including strict rejection and delivery retry; private proxy suite separately passed |
| Private/public lifecycle | Five NFTs delivered; wrong PIN/hash/caller, frozen code and replay rejected |
| Upgrade safety | Unchanged normalized storage layouts; live counts, roles and previous deliveries preserved |
| Native sponsorship | Prepared Pente transition through EIP-7702/GasSponsor; relayer reimbursed 629485000000000 wei |
| Delivery recovery | Failed target retained the recipient; repaired delivery retried once, then repeat retry was a no-op |
| Concurrent redemption | One success and one private rejection; one NFT delivery |
| Ownership rotation | Private ADMIN and ProxyAdmin accepted by maintenance identity, previous service authority cleared, then development authority restored |
| Runtime persistence | PostgreSQL and Paladin restarted; identities, group, private roles and all NFT ownership retained |
| Deployed code | Public runtime bytes/immutables and private EXTCODEHASH matched locked artifacts; factory-created group code also verified |
| IPFS | Ten compiler builds / 88 unique metadata, source and Standard JSON objects pinned and read back; both NFT metadata directories verified |
| Explorer | Real nested calls indexed for direct, sponsored and strict-retry redemptions |

The private-phase journal contains 34 directly signed public transactions, including
one deliberately reverted settlement, and 30 Paladin-submitted private transactions.
It records 52 functional checks. These counts are separate from the earlier public
genesis suite and are not a throughput benchmark. All journaled outcomes were reconciled.

## Settlement correction applied

Previously Combo consumed a code then emitted the legacy best-effort public
`recordRedemption`. A public inactive/wrong-scope/invalid-UID rejection could return
without committing a recipient while the private spend still succeeded.

The new `recordRedemptionStrict` keeps the legacy ABI available but reverts a rejected
public precondition. Combo now emits the strict selector. Accepted redemption with
a failed gift call still commits its recipient and supports retry. Neither contract's
storage layout changed. CodeManager strict implementation is
`0xBf67E1c518BF9ab50d84a754a5d1397B4a39f424`; private Combo strict implementation is
`0x477d914a7eaa6bf2c97601989d02a36cc2422734`. Both proxy addresses remain unchanged.

The fix was committed/pushed as `e0074210758e5d3493d16f6066d9c49a740a8717` before
deployment; the subsequent runtime audit ran from
`955b116cb0d0cf4c9a4755ed374421b80535c53f`. Original artifacts remain preserved for
historical addresses. Main remains the original
`8999a9aa187c34232a5ce3bbd63fcaabc07b6ace`.

Live evidence on the Nebula explorer:

- [First private redemption](http://100.111.69.1:8080/tx/0xae72012955d5ea681897f0431302c4acd123bbd98f5a19479b607d6f819ce49c)
- [Native sponsored Pente redemption](http://100.111.69.1:8080/tx/0xf290137349159f8e5baf85b0bfe18c87f84b2a67b3d0b3fddcd08bdd7cd072b1)
- [Intentional public precondition rejection](http://100.111.69.1:8080/tx/0x9a9846b09043429e2eb89bed838acc4e5ac1dc0e52d3619ea558dac46063d02d)
- [Same prepared transition retried successfully](http://100.111.69.1:8080/tx/0x06be97ae4800f24d7c90f8427122f488e60a2090ceeb6548b5a4691e19f4ff58)

## Boundaries and remaining work

Public builds use Solidity 0.8.37/Osaka; private builds use 0.8.37/Shanghai, the
installed Pente execution selector's newest target. Private PUSH0 passed and MCOPY
failed, while public Besu accepted both. Private proxy DELEGATECALL works. Public
EIP-7702 sponsored settlement is proven; private EIP-7702 authorization-list handling
is not. No unsupported private opcode target was deployed.

Sponsorship is paused, the temporary relayer and card tenant are disabled, and test
sponsor funding is zero. The operator retains private development roles; public
bootstrap ownership/voters are retained. Final administrator acceptance and an
appropriate private signing/group-control arrangement are still required.

The owner requested recovery secrets stay on Paladin-01. No off-server Paladin
credential backup was made. Full host reboot, independent restore, multiparty
privacy/availability and load tests remain outstanding, as do the Router adapter,
account-registration integration, widget/admin UI, moment.cards, Cloudflare gateway,
explorer source verification and production SSH/network lockdown. Production
promotion is not approved by this development acceptance.
