"""Pin the reviewed verification package and validate exact compiler/source CIDs."""
import argparse,hashlib,json,select,socketserver,sys,threading,urllib.request
from datetime import datetime,timezone
from pathlib import Path
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'Tools/LiveGenesis'))
sys.path.insert(0,str(REPO/'Tools/SolcCompiler'))
from common import git
from ipfs_publish import KuboClient

def main():
    p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);a=p.parse_args();root=Path(a.workspace).resolve()
    assert not git('diff','HEAD','--','Contracts/Verification','Tools/BlockscoutVerification')
    assert not git('ls-files','--others','--exclude-standard','--','Contracts/Verification','Tools/BlockscoutVerification')
    assert git('ls-remote','origin','refs/heads/review/compiler-standard-json').split()[0]==git('rev-parse','HEAD')
    sys.path.insert(0,str(root/'work/production-hardening'))
    from hostctl import HOSTS,connect
    ssh=connect(next(h for h in HOSTS if h['name']=='Backend-01'),True);transport=ssh.get_transport();transport.set_keepalive(20)
    class Forward(socketserver.BaseRequestHandler):
        def handle(self):
            channel=transport.open_channel('direct-tcpip',('127.0.0.1',self.server.destination),self.client_address)
            try:
                while True:
                    ready,_,_=select.select([self.request,channel],[],[],30)
                    for source in ready:
                        data=source.recv(65536)
                        if not data:return
                        (channel if source is self.request else self.request).sendall(data)
            finally:channel.close()
    class Server(socketserver.ThreadingTCPServer):daemon_threads=True
    servers=[]
    for port in [5001,8081]:
        s=Server(('127.0.0.1',0),Forward);s.destination=port;threading.Thread(target=s.serve_forever,daemon=True).start();servers.append(s)
    api=KuboClient('http://127.0.0.1:'+str(servers[0].server_address[1]));gateway='http://127.0.0.1:'+str(servers[1].server_address[1])+'/ipfs/'
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));target=REPO/'Contracts/Verification/20260911'
    manifest=json.loads((target/'manifest.json').read_text());assert manifest['coverage_passed']
    report={'source_commit':git('rev-parse','HEAD'),'checked_at':datetime.now(timezone.utc).isoformat(),'objects':{},'builds':{},'secret_state_published':False}
    def confirm(body,cid=None):
        cid=cid or api.add(body,only_hash=True)
        if cid not in report['objects']:
            assert api.add(body)==cid;api.confirm(cid,body)
            with opener.open(gateway+cid,timeout=30) as r:assert r.read(len(body)+1)==body
            report['objects'][cid]={'sha256':hashlib.sha256(body).hexdigest(),'bytes':len(body),'recursive_pin':True,'gateway_readback':True}
        return cid
    try:
        for name,build in manifest['builds'].items():
            pinned={}
            for filename,record in build['files'].items():
                body=(target/record['path']).read_bytes();assert hashlib.sha256(body).hexdigest()==record['sha256']
                pinned[filename]=confirm(body,build['metadata_cid'] if filename=='metadata.json' else None)
            standard=json.loads((target/build['files']['standard-input.json']['path']).read_text());meta=json.loads((target/build['files']['metadata.json']['path']).read_text())
            for source,row in meta['sources'].items():
                body=standard['sources'][source]['content'].encode();cids=[x.removeprefix('dweb:/ipfs/') for x in row.get('urls',[]) if x.startswith('dweb:/ipfs/')]
                confirm(body,cids[0] if cids else None)
            report['builds'][name]={'files':pinned,'license_type':build['license_type']};print('VERIFIED IPFS '+name,flush=True)
        report['inventory_files']={name:confirm((target/name).read_bytes()) for name in ['manifest.json','genesis-addresses.csv','licenses.csv','native-precompiles.json']}
        report['passed']=True
        path=root/'outputs/blockscout-artifact-ipfs-20260911.json';path.write_bytes((json.dumps(report,indent=2)+'\n').encode())
        print('IPFS objects verified: '+str(len(report['objects'])),flush=True)
    finally:
        for s in servers:s.shutdown();s.server_close()
        ssh.close()

if __name__=='__main__':main()
