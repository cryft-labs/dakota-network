"""Tenant registry rename (v1.7.0) in an isolated EVM: no live keys, no RPC.

The live system is rebuilt from the LIVE sources (the v1.6.0 baseline standard input: the factory behind an OpenZeppelin 5.2.0
TransparentUpgradeableProxy, the registry behind the factory's UpgradeableBeacon), populated as the live system was (a legacy.cards
registry with members, tiers, origins and metadata; a locked validation tenant), plus the shapes Cryft does not have yet
(a tenant with a retired slot, a tenant with two active registries), then upgraded exactly as Chad's sends do:
ProxyAdmin.upgradeAndCall(factory, v1.7.0, "") and factory.upgradeTenantRegistryBeaconImplementation(v1.7.0), and renamed.

    python -m pytest Tests/TenantRegistry/test_registry_rename.py -q
"""
import importlib.util
import json
from pathlib import Path

import pytest
from eth_tester import EthereumTester, PyEVMBackend
from eth_utils import keccak
from web3 import EthereumTesterProvider, Web3

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("tenant_registry_build", REPO / "Tools/TenantRegistry/build.py")
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)

OLD, NEW = "legacy.cards", "cryft.cards"   # any old id; the rename moves OLD to NEW
NEW_NAME, NEW_SYMBOL = "Cryft Cards Members", "CRYFTM"
ZERO = "0x" + "00" * 20
MAX_SLOTS = 128


# ── the build ──
@pytest.fixture(scope="session")
def arts():
    try:
        build.solc_binary()
    except SystemExit as missing:   # the pinned 0.8.34 is a download; never fetched by the tests
        pytest.skip(str(missing))
    new = build.compile_standard(build.standard_input())
    old = build.compile_standard(build.baseline_input())
    mock_input = {"language": "Solidity", "sources": {"MockAdminRegistry.sol": {"content": (HERE / "MockAdminRegistry.sol").read_text()}},
                  "settings": build.SETTINGS}
    mock = build.compile_standard(mock_input)

    def take(output, unit, name):
        c = output["contracts"][unit][name]
        return {"abi": c["abi"], "bin": c["evm"]["bytecode"]["object"], "runtime": c["evm"]["deployedBytecode"]["object"]}
    oz_tup = "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol"
    oz_admin = "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol"
    return {"factory_old": take(old, build.UNIT, "KotaAccessFactory"), "registry_old": take(old, build.UNIT, "KotaTenantAccessSBT"),
            "factory_new": take(new, build.UNIT, "KotaAccessFactory"), "registry_new": take(new, build.UNIT, "KotaTenantAccessSBT"),
            "proxy": take(new, oz_tup, "TransparentUpgradeableProxy"), "proxy_admin": take(new, oz_admin, "ProxyAdmin"),
            "mock": take(mock, "MockAdminRegistry.sol", "MockAdminRegistry")}


# ── the chain ──
class Chain:
    def __init__(self, arts):
        self.arts = arts
        self.tester = EthereumTester(backend=PyEVMBackend(genesis_parameters={"gas_limit": 60_000_000}))
        self.w3 = Web3(EthereumTesterProvider(self.tester))
        self.a = self.w3.eth.accounts
        self.root, self.operator, self.other_op, self.stranger, self.deployer = self.a[0], self.a[1], self.a[2], self.a[3], self.a[4]
        self.members = self.a[5:9]

    def send(self, fn, sender=None, gas=12_000_000):
        tx_hash = fn.transact({"from": sender or self.root, "gas": gas})
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        assert receipt.status == 1
        return receipt

    def deploy(self, key, *args, sender=None):
        art = self.arts[key]
        factory = self.w3.eth.contract(abi=art["abi"], bytecode=art["bin"])
        receipt = self.send(factory.constructor(*args), sender or self.deployer)
        return self.w3.eth.contract(address=receipt.contractAddress, abi=art["abi"])

    def at(self, key, address):
        return self.w3.eth.contract(address=address, abi=self.arts[key]["abi"])

    def reverts(self, fn, error, sender=None):
        """The call reverts with the custom error `error` ("Name()" or "Name(types)")."""
        wanted = "0x" + keccak(text=error)[:4].hex()
        try:
            fn.call({"from": sender or self.root, "gas": 12_000_000})
        except Exception as raised:  # noqa: BLE001
            data = getattr(raised, "data", None) or (raised.args[1] if len(raised.args) > 1 else "") or str(raised)
            if isinstance(data, dict):
                data = data.get("data", "")
            text = str(data)
            assert wanted in text or repr(keccak(text=error)[:4])[2:-1] in text, f"wanted {error} ({wanted}), got {data!r}"
            return
        raise AssertionError(f"did not revert (wanted {error})")


def registry_view(c, registry, holders):
    """Everything a registry answers that the rename must leave alone (identity aside)."""
    r = registry
    out = {"operator": r.functions.operator().call(), "locked": r.functions.registryLocked().call(),
           "totalMinted": r.functions.totalMinted().call(), "activeHolders": r.functions.activeHolders().call(),
           "tierCount": r.functions.tierCount().call(), "defaultTierId": r.functions.defaultTierId().call(),
           "origins": r.functions.allowedOrigins().call(), "factory": r.functions.factory().call(),
           "epoch": r.functions.authorityEpoch().call(), "backup": r.functions.backupApprover().call(),
           "contractURI": r.functions.contractURI().call(), "base": r.functions.baseTokenURI().call(),
           "revealed": r.functions.metadataRevealed().call(), "perToken": r.functions.perTokenMetadataEnabled().call(),
           "updater": r.functions.metadataUpdater().call(), "version": r.functions.registryVersion().call(),
           "maxHolders": r.functions.maxHolders().call(), "holders": {}}
    for h in holders:
        token = r.functions.tokenOf(h).call()
        out["holders"][h] = {"balance": r.functions.balanceOf(h).call(), "raw": r.functions.rawBalanceOf(h).call(),
                             "token": token, "tier": r.functions.tierOf(h).call(), "minter": r.functions.minters(h).call(),
                             "owner": r.functions.ownerOf(token).call() if token else None,
                             "uri": r.functions.tokenURI(token).call() if token else None}
    return out


def identity(registry):
    return (registry.functions.name().call(), registry.functions.symbol().call(), registry.functions.tenantId().call())


def factory_view(f, tenant):
    n = f.functions.registrySlotCount(tenant).call()
    return {"slots": [f.functions.registryAt(tenant, i).call() for i in range(n + 1)], "list": f.functions.registriesOf(tenant).call(),
            "operator": f.functions.tenantOperatorOf(tenant).call(), "locked": f.functions.tenantDeploymentLocked(tenant).call(),
            "active": f.functions.activeRegistryCount(tenant).call(), "retired": f.functions.retiredRegistryCount(tenant).call()}


@pytest.fixture
def live(arts):
    """Cryft's shape on the live (v1.6.0) code."""
    c = Chain(arts)
    plans = c.deploy("mock")
    c.send(plans.functions.setTier(1, True, 3, 0, 3))          # tier 1: three registries, unlimited holders, both features
    for who in (c.operator, c.other_op, c.root):
        c.send(plans.functions.set(who, 1, 1))
    factory_impl = c.deploy("factory_old")
    init = factory_impl.encode_abi("initialize", [c.root, plans.address])
    proxy = c.deploy("proxy", factory_impl.address, c.root, init)
    admin_slot = c.w3.eth.get_storage_at(proxy.address, int("b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103", 16))
    c.proxy_admin = c.at("proxy_admin", Web3.to_checksum_address(admin_slot[-20:]))
    f = c.at("factory_new", proxy.address)                       # the v1.7.0 ABI is a superset; old reads go through it too
    c.factory, c.factory_old = f, c.at("factory_old", proxy.address)
    c.registry_impl_old = c.deploy("registry_old")
    c.send(c.factory_old.functions.deployTenantRegistryBeacon(c.registry_impl_old.address))
    # OLD: the registry with members (index 0), and a second one retired (index 1) so the move carries a tombstone
    c.send(c.factory_old.functions.deployTenantRegistry(OLD, c.operator, "Legacy Cards Members", "LEGACY",
                                                        ["https://legacy.cards", "https://www.legacy.cards"]))
    c.A = c.at("registry_new", f.functions.registryAt(OLD, 0).call())
    c.send(f.functions.deployAdditionalRegistry(OLD, "Kota Tenant User Access", "KTUA", []), c.operator)
    c.send(f.functions.retireRegistry(OLD, 1))
    tier = c.A.functions.createTier("Member", "ipfs://tier").call({"from": c.operator})
    c.send(c.A.functions.createTier("Member", "ipfs://tier"), c.operator)
    c.send(c.A.functions.setDefaultTier(tier), c.operator)
    c.send(c.A.functions.setTokenMetadataConfiguration("ipfs://base/", ".json", "", True), c.operator)
    c.send(c.A.functions.setPerTokenMetadataEnabled(True), c.operator)
    c.send(c.A.functions.setMetadataUpdater(c.stranger), c.operator)
    c.send(c.A.functions.grantAccessBatch(c.members[:3]), c.operator)
    c.send(c.A.functions.setTokenMetadataURI(1, "ipfs://one"), c.stranger)
    c.send(c.A.functions.setMinter(c.members[3], True), c.operator)
    # a locked validation tenant, as kota-validation-20260911
    c.send(c.factory_old.functions.deployTenantRegistry("kota-validation", c.root, "Kota Tenant User Access", "KTUA", []))
    c.B = c.at("registry_new", f.functions.registryAt("kota-validation", 0).call())
    c.send(c.B.functions.grantAccess(c.deployer), c.root)
    c.send(f.functions.setRegistryLocked("kota-validation", True))
    # a tenant with two active registries
    c.send(c.factory_old.functions.deployTenantRegistry("two", c.other_op, "Kota Tenant User Access", "KTUA", ["https://two"]))
    c.send(f.functions.deployAdditionalRegistry("two", "Kota Tenant User Access", "KTUA", []), c.other_op)
    c.C0 = c.at("registry_new", f.functions.registryAt("two", 0).call())
    c.C1 = c.at("registry_new", f.functions.registryAt("two", 1).call())
    c.send(c.C0.functions.grantAccess(c.members[0]), c.other_op)
    c.registries = [c.A, c.B, c.C0, c.C1]
    c.holders = list(c.members) + [c.deployer, c.stranger]
    return c


def upgrade(c, target=None):
    """Sends 1 and 2: the factory to v1.7.0 (ProxyAdmin.upgradeAndCall, empty data), then the beacon to v1.7.0."""
    c.factory_impl_new = c.deploy("factory_new")
    c.registry_impl_new = c.deploy("registry_new", target or c.A.address)
    c.send(c.proxy_admin.functions.upgradeAndCall(c.factory.address, c.factory_impl_new.address, b""))
    c.send(c.factory.functions.upgradeTenantRegistryBeaconImplementation(c.registry_impl_new.address))


def rename(c, sender=None):
    return c.send(c.factory.functions.renameTenant(OLD, NEW, c.A.address, NEW_NAME, NEW_SYMBOL), sender)


# ── the tests ──
def test_upgrade_alone_changes_nothing(live):
    c = live
    tenants = (OLD, "kota-validation", "two")
    before = ([registry_view(c, r, c.holders) for r in c.registries], [identity(r) for r in c.registries],
              [factory_view(c.factory, t) for t in tenants], [c.factory.functions.tenantIdOf(r.address).call() for r in c.registries],
              c.factory.functions.registryCount().call(), c.factory.functions.admin().call())
    upgrade(c)
    after = ([registry_view(c, r, c.holders) for r in c.registries], [identity(r) for r in c.registries],
             [factory_view(c.factory, t) for t in tenants], [c.factory.functions.tenantIdOf(r.address).call() for r in c.registries],
             c.factory.functions.registryCount().call(), c.factory.functions.admin().call())
    assert before == after
    assert c.factory.functions.tenantRenamed().call() is False
    assert c.factory.functions.tenantRegistryBeaconImplementation().call() == c.registry_impl_new.address
    assert all(not r.functions.registryRenamed().call() for r in c.registries)
    assert c.registry_impl_new.functions.RENAME_TARGET().call() == c.A.address


def test_rename_moves_the_tenant_and_rewrites_only_the_target(live):
    c = live
    upgrade(c)
    others_before = [(registry_view(c, r, c.holders), identity(r)) for r in (c.B, c.C0, c.C1)]
    a_before = registry_view(c, c.A, c.holders)
    old_view = factory_view(c.factory, OLD)
    receipt = rename(c)
    # the registry: identity rewritten, everything else as it was
    assert identity(c.A) == (NEW_NAME, NEW_SYMBOL, NEW)
    assert c.A.functions.registryRenamed().call() is True
    assert registry_view(c, c.A, c.holders) == a_before
    # other registries untouched
    assert [(registry_view(c, r, c.holders), identity(r)) for r in (c.B, c.C0, c.C1)] == others_before
    # the factory: the tenant under its new id, the former id an alias answering the same
    assert factory_view(c.factory, NEW) == old_view
    assert factory_view(c.factory, OLD) == old_view
    assert c.factory.functions.registryAt(OLD, 0).call() == c.A.address
    assert c.factory.functions.registryAt(NEW, 0).call() == c.A.address
    assert c.factory.functions.registryAt(NEW, 1).call() == ZERO          # the retired slot keeps its index
    assert c.factory.functions.registrySlotCount(NEW).call() == 2
    assert c.factory.functions.tenantIdOf(c.A.address).call() == NEW
    assert c.factory.functions.canonicalTenantId(OLD).call() == NEW
    assert c.factory.functions.canonicalTenantId(NEW).call() == NEW
    assert c.factory.functions.renamedTenantOf(OLD).call() == NEW
    assert c.factory.functions.tenantRenamed().call() is True
    assert c.factory.functions.registryCount().call() == 5
    ev = c.factory.events.TenantRenamed().process_receipt(receipt)[0]["args"]
    assert (ev["previousTenantId"], ev["newTenantId"], ev["registry"], ev["approvedBy"]) == (OLD, NEW, c.A.address, c.root)
    ev = c.A.events.RegistryRenamed().process_receipt(receipt)[0]["args"]
    assert (ev["previousTenantId"], ev["newTenantId"], ev["name"], ev["symbol"]) == (OLD, NEW, NEW_NAME, NEW_SYMBOL)
    # the former id's raw entries are gone (moved), not copied: read the storage directly
    for slot in (1, 3, 4, 10, 11, 12):
        key = int.from_bytes(keccak(OLD.encode() + slot.to_bytes(32, "big")), "big")
        assert int.from_bytes(c.w3.eth.get_storage_at(c.factory.address, key), "big") == 0, slot


def test_after_the_rename_the_tenant_keeps_working_under_both_ids(live):
    c = live
    upgrade(c)
    rename(c)
    # minting reads maxHolders through tenantIdOf (the new id) and the moved operator
    c.send(c.A.functions.grantAccess(c.members[3]), c.operator)
    assert c.A.functions.balanceOf(c.members[3]).call() == 1
    assert c.A.functions.tierOf(c.members[3]).call() == 1
    c.send(c.A.functions.grantAccess(c.a[9]), c.members[3])                # a minter still mints
    c.send(c.A.functions.addAllowedOrigin("https://cryft.cards"), c.operator)
    c.send(c.A.functions.addAllowedOrigin("https://www.cryft.cards"), c.operator)
    assert c.A.functions.allowedOrigins().call()[-2:] == ["https://cryft.cards", "https://www.cryft.cards"]
    # platform writes under the former id reach the same tenant
    c.send(c.factory.functions.setRegistryLocked(OLD, True))
    assert c.A.functions.registryLocked().call() and c.A.functions.balanceOf(c.members[0]).call() == 0
    assert c.factory.functions.tenantDeploymentLocked(NEW).call() and c.factory.functions.tenantDeploymentLocked(OLD).call()
    c.send(c.factory.functions.setRegistryLocked(NEW, False))
    assert c.A.functions.balanceOf(c.members[0]).call() == 1
    c.send(c.factory.functions.setRegistryOperator(OLD, c.other_op))       # recovery under the former id
    assert c.A.functions.operator().call() == c.other_op
    assert c.factory.functions.tenantOperatorOf(NEW).call() == c.other_op == c.factory.functions.tenantOperatorOf(OLD).call()
    # the tenant operator adds and retires under either id
    c.send(c.factory.functions.deployAdditionalRegistry(OLD, "Kota Tenant User Access", "KTUA", []), c.other_op)
    assert c.factory.functions.registrySlotCount(NEW).call() == 3
    c.send(c.factory.functions.retireRegistry(NEW, 2), c.other_op)
    assert c.factory.functions.activeRegistryCount(OLD).call() == 1
    # the operator's own change goes through the factory callback (tenantIdOf: the new id)
    c.send(c.A.functions.setOperator(c.operator), c.other_op)
    assert c.factory.functions.tenantOperatorOf(OLD).call() == c.operator
    # a member may always renounce
    c.send(c.A.functions.revokeAccess(c.members[1]), c.members[1])
    assert c.A.functions.balanceOf(c.members[1]).call() == 0


def test_rename_runs_once_and_only_for_the_admin(live):
    c = live
    upgrade(c)
    c.reverts(c.factory.functions.renameTenant(OLD, NEW, c.A.address, NEW_NAME, NEW_SYMBOL), "NotAdmin()", c.operator)
    c.reverts(c.factory.functions.renameTenant(OLD, NEW, c.A.address, NEW_NAME, NEW_SYMBOL), "NotAdmin()", c.stranger)
    rename(c)
    c.reverts(c.factory.functions.renameTenant(OLD, NEW, c.A.address, NEW_NAME, NEW_SYMBOL), "TenantAlreadyRenamed()")
    c.reverts(c.factory.functions.renameTenant(NEW, "x.cards", c.A.address, NEW_NAME, NEW_SYMBOL), "TenantAlreadyRenamed()")
    c.reverts(c.factory.functions.renameTenant("two", "y.cards", c.C0.address, NEW_NAME, NEW_SYMBOL), "TenantAlreadyRenamed()")
    # the registry's own rewrite: only the factory, and only once
    c.reverts(c.A.functions.renameRegistry(NEW, "z", "z", "z"), "NotFactory()", c.root)
    c.reverts(c.A.functions.renameRegistry(NEW, "z", "z", "z"), "NotFactory()", c.operator)


@pytest.mark.parametrize("args,error", [
    (("", NEW, None, NEW_NAME, NEW_SYMBOL), "InvalidRename()"),
    ((OLD, "", None, NEW_NAME, NEW_SYMBOL), "InvalidRename()"),
    ((OLD, "x" * 65, None, NEW_NAME, NEW_SYMBOL), "InvalidRename()"),
    ((OLD, NEW, None, "", NEW_SYMBOL), "InvalidRename()"),
    ((OLD, NEW, None, NEW_NAME, ""), "InvalidRename()"),
    ((OLD, NEW, None, "n" * 65, NEW_SYMBOL), "InvalidRename()"),
    ((OLD, OLD, None, NEW_NAME, NEW_SYMBOL), "InvalidRename()"),
    ((OLD, "kota-validation", None, NEW_NAME, NEW_SYMBOL), "TenantIdTaken()"),
    ((OLD, "two", None, NEW_NAME, NEW_SYMBOL), "TenantIdTaken()"),
    (("never.registered", NEW, None, NEW_NAME, NEW_SYMBOL), "TenantStateMissing()"),
    ((OLD, NEW, "B", NEW_NAME, NEW_SYMBOL), "RegistryMissing()"),
    ((OLD, NEW, ZERO, NEW_NAME, NEW_SYMBOL), "RegistryMissing()"),
    (("two", NEW, "C0", NEW_NAME, NEW_SYMBOL), "InvalidRename()"),           # two active registries
    (("kota-validation", NEW, "B", NEW_NAME, NEW_SYMBOL), "NotRenameTarget()"),   # not RENAME_TARGET
    ((OLD, NEW, None, NEW_NAME, "CRYFT"), "InvalidRename()"),                # the coin's symbol, never
])
def test_rename_inputs_are_validated(live, args, error):
    c = live
    upgrade(c)
    names = {None: c.A.address, "B": c.B.address, "C0": c.C0.address}
    args = list(args)
    args[2] = names.get(args[2], args[2])
    c.reverts(c.factory.functions.renameTenant(*args), error)
    assert c.factory.functions.tenantRenamed().call() is False
    assert identity(c.A) == ("Legacy Cards Members", "LEGACY", OLD)


def test_exactly_64_bytes_is_accepted(live):
    c = live
    upgrade(c)
    long_id = "c" * 64
    c.send(c.factory.functions.renameTenant(OLD, long_id, c.A.address, "N" * 64, "S" * 64))
    assert identity(c.A) == ("N" * 64, "S" * 64, long_id)
    assert c.factory.functions.registryAt(OLD, 0).call() == c.A.address


def test_former_and_new_ids_cannot_be_registered_again(live):
    c = live
    upgrade(c)
    rename(c)
    for tenant in (OLD, NEW):
        c.reverts(c.factory.functions.deployTenantRegistry(tenant, c.other_op, "Kota Tenant User Access", "KTUA", []), "RegistryExists()")
    c.reverts(c.factory.functions.migrateTenantState(OLD), "TenantStateAlreadyInitialized()")


def test_every_other_registry_behaves_as_before(live):
    c = live
    upgrade(c)
    rename(c)
    # the locked validation registry: still locked, reads zero, the factory unlocks it under its own id
    assert c.B.functions.balanceOf(c.deployer).call() == 0 and c.B.functions.rawBalanceOf(c.deployer).call() == 1
    c.reverts(c.B.functions.addAllowedOrigin("https://x"), "RegistryIsLocked()", c.root)
    c.send(c.factory.functions.setRegistryLocked("kota-validation", False))
    assert c.B.functions.balanceOf(c.deployer).call() == 1
    # the two-registry tenant: mint, origin, tier, renounce, retire
    c.send(c.C1.functions.grantAccess(c.members[2]), c.other_op)
    c.send(c.C0.functions.addAllowedOrigin("https://two.example"), c.other_op)
    c.send(c.C0.functions.revokeAccess(c.members[0]), c.members[0])
    c.send(c.factory.functions.retireRegistry("two", 1), c.other_op)
    assert c.C1.functions.registryLocked().call()
    # renameRegistry is refused on each of them, even by the factory's own path
    for r in (c.B, c.C0, c.C1):
        assert r.functions.registryRenamed().call() is False
        assert r.functions.RENAME_TARGET().call() == c.A.address
    # a registry created after the upgrade runs v1.7.0 and is not the target
    c.send(c.factory.functions.deployTenantRegistry("fresh", c.other_op, "Kota Tenant User Access", "KTUA", []))
    fresh = c.at("registry_new", c.factory.functions.registryAt("fresh", 0).call())
    assert identity(fresh) == ("Kota Tenant User Access", "KTUA", "fresh")
    c.send(fresh.functions.grantAccess(c.members[3]), c.other_op)


def test_an_implementation_with_no_target_renames_nothing(live):
    c = live
    upgrade(c, target=ZERO)
    c.reverts(c.factory.functions.renameTenant(OLD, NEW, c.A.address, NEW_NAME, NEW_SYMBOL), "NotRenameTarget()")
    assert c.factory.functions.tenantRenamed().call() is False


def test_the_move_is_bounded_and_keeps_every_index(live):
    """The tenant with the most slots the factory allows minus one active: every tombstone keeps its index."""
    c = live
    upgrade(c)
    for _ in range(6):                                               # six more slots, each retired at once
        c.send(c.factory.functions.deployAdditionalRegistry(OLD, "Kota Tenant User Access", "KTUA", []), c.operator)
        c.send(c.factory.functions.retireRegistry(OLD, c.factory.functions.registrySlotCount(OLD).call() - 1))
    before = [c.factory.functions.registryAt(OLD, i).call() for i in range(8)]
    receipt = rename(c)
    assert [c.factory.functions.registryAt(NEW, i).call() for i in range(8)] == before
    assert [c.factory.functions.registryAt(OLD, i).call() for i in range(8)] == before
    assert receipt.gasUsed < 1_000_000
    assert c.factory.functions.MAX_REGISTRY_SLOTS_PER_TENANT().call() == MAX_SLOTS
