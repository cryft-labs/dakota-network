"""Match live Solidity trailers to exact metadata/source pins on Backend-01."""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import select
import socketserver
import sys
import threading
import urllib.request
import zipfile
from common import Deployment, ADDR, REPO, git, hx

def audit(workspace, publish_missing=False):
    d = Deployment(workspace)
    sys.path.insert(0, str(d.workspace / 'work/production-hardening'))
    sys.path.insert(0, str(REPO / 'Tools/SolcCompiler'))
    from hostctl import HOSTS, connect
    from ipfs_publish import KuboClient, metadata_cid, PublicationError
    if publish_missing:
        assert not git('diff', 'HEAD', '--', 'Tools/LiveGenesis', 'Tools/SolcCompiler')
        assert git('ls-remote', 'origin', 'refs/heads/review/compiler-standard-json').split()[0] == git('rev-parse', 'HEAD')
    ssh = connect(next(h for h in HOSTS if h['name'] == 'Backend-01'), True)
    transport = ssh.get_transport(); transport.set_keepalive(20)
    class Forward(socketserver.BaseRequestHandler):
        def handle(self):
            channel = transport.open_channel('direct-tcpip', ('127.0.0.1', self.server.destination), self.client_address)
            try:
                while True:
                    readable, _, _ = select.select([self.request, channel], [], [], 30)
                    for source in readable:
                        data = source.recv(65536)
                        if not data: return
                        (channel if source is self.request else self.request).sendall(data)
            finally: channel.close()
    class Server(socketserver.ThreadingTCPServer): daemon_threads = True
    servers = []
    for port in [5001, 8081]:
        server = Server(('127.0.0.1', 0), Forward); server.destination = port
        threading.Thread(target=server.serve_forever, daemon=True).start(); servers.append(server)
    api = KuboClient('http://127.0.0.1:' + str(servers[0].server_address[1]))
    gateway = 'http://127.0.0.1:' + str(servers[1].server_address[1]) + '/ipfs/'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    report = {'checked_at': datetime.now(timezone.utc).isoformat(), 'chain_id': 112311,
              'host': 'Backend-01', 'transport': 'pinned-host-key SSH over Nebula to loopback Kubo API/gateway',
              'public_gateway_verified': False, 'contracts': [], 'objects': {}, 'source_commit': git('rev-parse', 'HEAD')}
    def confirm(content, cid=None):
        cid = cid or api.add(content, only_hash=True)
        if cid in report['objects']:
            assert report['objects'][cid]['sha256'] == hashlib.sha256(content).hexdigest(); return cid
        assert api.add(content, only_hash=True) == cid, 'Exact bytes do not produce expected CID'
        published = False
        try: api.confirm(cid, content)
        except PublicationError:
            if not publish_missing: raise
            assert api.add(content) == cid
            api.confirm(cid, content); published = True
        with opener.open(gateway + cid, timeout=25) as response: body = response.read(len(content) + 1)
        assert body == content, 'Gateway bytes differ from pinned artifact'
        report['objects'][cid] = {'sha256': hashlib.sha256(content).hexdigest(), 'bytes': len(content),
            'recursive_pin_verified': True, 'api_readback_verified': True, 'private_gateway_readback_verified': True,
            'published_this_run': published}
        return cid
    try:
        identity = json.loads(api.request('id'))
        with ssh.open_sftp() as sftp:
            with sftp.open('/etc/cryft/ipfs/installation.json', 'r') as stream: installed = json.loads(stream.read())
        assert identity['ID'] == installed['peer_id']; report['peer_id'] = identity['ID']
        instances = [('ValidatorSmartContractAllowList', ADDR['ValidatorSmartContractAllowList']), ('ProxyAdmin', ADDR['ProxyAdmin'])]
        instances += [('TransparentUpgradeableProxy', ADDR[n]) for n in ['GasManager', 'CodeManager', 'GasSponsor', 'DakotaDelegationRegistry', 'ReservedAgentRegistry']]
        instances += [('DakotaDelegation' if name == 'DakotaDelegationUpgradeCanary' else name, row['address']) for name, row in d.journal['deployments'].items()]
        for name, address in instances:
            art = d.artifacts[name]; code = hx(d.w3.eth.get_code(address))
            cid = metadata_cid(code)
            assert cid == metadata_cid(art['runtime_bytecode'])
            if isinstance(art['metadata'], str): metadata_bytes = art['metadata'].encode('utf-8')
            else:
                result = json.loads((d.out / name / 'standard-output.json').read_text())
                metadata_bytes = result['contracts']['GenesisCanary.sol']['GenesisCanary']['metadata'].encode('utf-8')
                assert json.loads(metadata_bytes) == art['metadata']
            confirm(metadata_bytes, cid); metadata = json.loads(metadata_bytes)
            assert metadata['settings']['evmVersion'] == d.lock[name]['evm']
            assert metadata['compiler']['version'].startswith(d.lock[name]['compiler'] + '+')
            inputs = art['standard_json_input']['sources']
            assert set(inputs) == set(metadata['sources'])
            source_records = {}
            for source, info in metadata['sources'].items():
                content = inputs[source]['content'].encode('utf-8')
                assert hx(d.w3.keccak(content)) == info['keccak256']
                references = [u.removeprefix('dweb:/ipfs/') for u in info.get('urls', []) if u.startswith('dweb:/ipfs/')]
                if not references: assert info.get('content') == inputs[source]['content']
                else: assert len(references) == 1
                source_records[source] = confirm(content, references[0] if references else None)
            report['contracts'].append({'name': name, 'address': address, 'runtime_keccak256': hx(d.w3.keccak(bytes.fromhex(code[2:]))),
                'metadata_cid': cid, 'compiler': metadata['compiler']['version'], 'evm': metadata['settings']['evmVersion'],
                'compilation_target': metadata['settings']['compilationTarget'], 'sources': source_records})
            print('IPFS VERIFIED ' + name + ' ' + address + ' ' + cid, flush=True)
        core = json.loads((d.workspace / 'outputs/backend-ipfs-publication-20260911.json').read_text())
        bundle_cid = core['release_bundle_cid']
        bundle = api.request('cat', {'arg': bundle_cid}, response_limit=32 * 1024 * 1024)
        known = next(o for o in core['objects'] if o['cid'] == bundle_cid)
        assert hashlib.sha256(bundle).hexdigest() == known['sha256']; confirm(bundle, bundle_cid)
        with zipfile.ZipFile(io.BytesIO(bundle)) as z:
            index = json.loads(z.read('release-index.json'))
        assert len(index['contracts']) == len(core['contracts']) == 90
        report['core_bundle'] = {'cid': bundle_cid, 'contracts': len(index['contracts']), 'verified': True}
        report['passed'] = True
        path = d.out / 'ipfs-verification.json'
        path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print('IPFS complete: ' + str(len(report['contracts'])) + ' deployed runtimes; ' + str(len(report['objects'])) + ' unique objects', flush=True)
    finally:
        for server in servers: server.shutdown(); server.server_close()
        ssh.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--workspace', required=True)
    parser.add_argument('--publish-missing', action='store_true')
    args = parser.parse_args(); audit(args.workspace, args.publish_missing)
