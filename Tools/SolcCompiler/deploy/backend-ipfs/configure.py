"""Configure an initialized, STOPPED Kubo repo; preserve its existing identity."""
import argparse
import copy
import ipaddress
import json
import os
from pathlib import Path
import re


def settings(existing, nebula_ip="100.111.67.1", overlay_cidr="100.111.0.0/16", peers=None):
    overlay = ipaddress.IPv4Network(overlay_cidr)
    address = ipaddress.IPv4Address(nebula_ip)
    if address not in overlay:
        raise ValueError("IPFS peer listener must be inside the Nebula CIDR")
    if not existing.get("Identity", {}).get("PeerID") or not existing["Identity"].get("PrivKey"):
        raise ValueError("Initialize Kubo once as cryft-ipfs before configuring it")
    peers = peers or []
    for peer in peers:
        if not isinstance(peer.get("ID"), str) or not peer["ID"] or not peer.get("Addrs"):
            raise ValueError("Each peer needs its actual ID and explicit Nebula addresses")
        for multiaddr in peer["Addrs"]:
            match = re.fullmatch(r"/ip4/([0-9.]+)/(?:tcp/([0-9]+)|udp/([0-9]+)/quic-v1)", multiaddr)
            if not match or ipaddress.IPv4Address(match[1]) not in overlay:
                raise ValueError("Peer addresses must use literal Nebula IPv4 addresses")
            if not 1 <= int(match[2] or match[3]) <= 65535:
                raise ValueError("Invalid peer port")
    result = copy.deepcopy(existing)
    swarm = [f"/ip4/{address}/tcp/4001", f"/ip4/{address}/udp/4001/quic-v1"]
    result.setdefault("Addresses", {}).update({"API": "/ip4/127.0.0.1/tcp/5001",
        "Gateway": "/ip4/127.0.0.1/tcp/8081", "Swarm": swarm,
        "Announce": swarm, "AppendAnnounce": [], "NoAnnounce": []})
    result["Bootstrap"] = []
    result["Peering"] = {"Peers": peers}
    result.setdefault("Discovery", {}).setdefault("MDNS", {})["Enabled"] = False
    result["Routing"] = {"Type": "none", "DelegatedRouters": []}
    result.setdefault("Provide", {})["Enabled"] = False
    result.setdefault("Ipns", {})["DelegatedPublishers"] = []
    result.setdefault("Gateway", {}).update({"NoFetch": True, "NoDNSLink": True,
        "PublicGateways": {}, "HTTPHeaders": {"X-Content-Type-Options": ["nosniff"]}})
    # Deny all IPv4 except Nebula and loopback; no IPv6 peer transport is selected.
    networks = [ipaddress.IPv4Network("0.0.0.0/0")]
    for allowed in (overlay, ipaddress.IPv4Network("127.0.0.0/8")):
        remaining = []
        for network in networks:
            if allowed.subnet_of(network):
                remaining.extend(network.address_exclude(allowed))
            elif not network.subnet_of(allowed):
                remaining.append(network)
        networks = remaining
    filters = [f"/ip4/{network.network_address}/ipcidr/{network.prefixlen}" for network in networks]
    filters.append("/ip6/::/ipcidr/0")
    result.setdefault("Swarm", {}).update({"AddrFilters": filters, "DisableNatPortMap": True,
        "EnableHolePunching": False, "RelayClient": {"Enabled": False, "StaticRelays": []},
        "RelayService": {"Enabled": False}})
    result.setdefault("Datastore", {}).update({"StorageMax": "50GB", "StorageGCWatermark": 80,
                                               "GCPeriod": "1h"})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--nebula-ip", default="100.111.67.1")
    parser.add_argument("--overlay-cidr", default="100.111.0.0/16")
    parser.add_argument("--peers-file", type=Path)
    args = parser.parse_args()
    path = args.repo.resolve() / "config"
    peers = json.loads(args.peers_file.read_text(encoding="utf-8")) if args.peers_file else []
    data = settings(json.loads(path.read_text(encoding="utf-8")), args.nebula_ip, args.overlay_cidr, peers)
    temporary = path.with_name("config.next")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        os.chmod(temporary, 0o600)
        json.dump(data, stream, indent=2)
        stream.write("\n")
    os.replace(temporary, path)
    print("Configured localhost API/gateway and Nebula-only peers; existing identity preserved.")


if __name__ == "__main__":
    main()
