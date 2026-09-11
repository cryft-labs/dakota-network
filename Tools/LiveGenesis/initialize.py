"""Initialize the approved named genesis services on Dakota development chain."""
import argparse
from common import Deployment, ADDR, ADMIN, DEPLOYER, TESTER, ZERO

def initialize(d):
    d.preflight()
    gm_logic = d.deploy('GasManager')
    gm = d.first_link('GasManager', gm_logic, 'initializeWithVoter', [DEPLOYER])
    cm_logic = d.deploy('CodeManager')
    cm = d.first_link('CodeManager', cm_logic, 'initializeWithVoter', [DEPLOYER])
    d.tx('configure:registration_fee_vault', cm.functions.voteToUpdateFeeVault(gm.address))
    logic = d.deploy('DakotaDelegation')
    beacon = d.deploy('DakotaDelegationBeacon', logic.address)
    dispatcher = d.deploy('DakotaDelegationBeaconDispatcher', beacon.address)
    sponsor_logic = d.deploy('GasSponsor')
    sponsor = d.first_link('GasSponsor', sponsor_logic, 'initialize', [DEPLOYER, DEPLOYER, dispatcher.address, 100000])
    registry_logic = d.deploy('DakotaDelegationRegistry')
    registry = d.first_link('DakotaDelegationRegistry', registry_logic, 'initializeWithAdmin',
                            [dispatcher.address, beacon.address, sponsor.address, DEPLOYER])
    d.tx('handover:propose_beacon_registry', beacon.functions.transferOwnership(registry.address))
    d.tx('handover:accept_beacon_registry', registry.functions.acceptBeaconOwnership())
    for name, service in [('GasManager', gm), ('CodeManager', cm)]:
        d.check(name + ':explicit_voter', service.functions.getVoters().call() == [DEPLOYER])
        d.reject(name + ':cannot_reinitialize', service.functions.initializeWithVoter(TESTER), sender=DEPLOYER)
    d.check('CodeManager:fee_vault', cm.functions.feeVault().call() == gm.address)
    d.check('GasSponsor:paused_initially', sponsor.functions.paused().call())
    d.check('GasSponsor:explicit_admin', sponsor.functions.platformAdmin().call() == DEPLOYER)
    d.check('Registry:explicit_admin', registry.functions.registryAdmin().call() == DEPLOYER)
    d.check('Beacon:registry_ownership', beacon.functions.owner().call() == registry.address and beacon.functions.pendingOwner().call() == ZERO)
    snapshot = registry.functions.currentSnapshot().call()
    d.check('Registry:complete_snapshot', all(snapshot[13:17]) and snapshot[0] == dispatcher.address, snapshot)
    d.reject('GasSponsor:cannot_reinitialize', sponsor.functions.initialize(DEPLOYER, DEPLOYER, dispatcher.address, 100000), sender=DEPLOYER)
    d.reject('Registry:cannot_reinitialize', registry.functions.initializeWithAdmin(dispatcher.address, beacon.address, sponsor.address, DEPLOYER), sender=DEPLOYER)
    d.reject('Beacon:cannot_renounce', beacon.functions.renounceOwnership(), sender=registry.address)
    d.journal['initialization_complete'] = True
    d.journal['reserved_slots'] = {'0x000000000000000000000000000000000000Face': 'Unlinked: no approved agent-registry implementation in available repositories.',
                                   'other_unused_genesis_proxies': 'Reserved; not application contracts requiring initialization.'}
    d.journal['handover'] = {'management_admin': ADMIN, 'temporary_deployment_admin': DEPLOYER,
                             'complete': False, 'reason': 'Retained for authorized application deployment and testing; two-step recipient acceptance and voter/root rotation remain.'}
    d.save()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--workspace', required=True)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    d = Deployment(args.workspace, execute=args.execute)
    initialize(d) if args.execute else d.preflight()
