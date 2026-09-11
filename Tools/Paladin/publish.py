"""Pin exact compiler metadata/sources and non-secret test card metadata on Backend-01."""
import argparse, hashlib, json, select, socketserver, sys, threading, urllib.request
from datetime import datetime, timezone
from live import Live, REPO, git, hx

def main():
    p=argparse.ArgumentParser(); p.add_argument('--workspace',required=True); a=p.parse_args(); d=Live(a.workspace)
    assert not git('diff','HEAD','--','Tools/Paladin','Contracts')
    assert git('ls-remote','origin','refs/heads/review/compiler-standard-json').split()[0]==git('rev-parse','HEAD')
    sys.path.insert(0,str(d.workspace/'work/production-hardening')); sys.path.insert(0,str(REPO/'Tools/SolcCompiler'))
    from hostctl import HOSTS,connect
    from ipfs_publish import KuboClient,metadata_cid
    ssh=connect(next(h for h in HOSTS if h['name']=='Backend-01'),True); transport=ssh.get_transport()
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
    class Server(socketserver.ThreadingTCPServer): daemon_threads=True
    servers=[]
    for port in [5001,8081]:
        s=Server(('127.0.0.1',0),Forward); s.destination=port; threading.Thread(target=s.serve_forever,daemon=True).start(); servers.append(s)
    endpoint='http://127.0.0.1:'+str(servers[0].server_address[1]); api=KuboClient(endpoint)
    gateway='http://127.0.0.1:'+str(servers[1].server_address[1])+'/ipfs/'
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    report={'source_commit':d.commit,'checked_at':datetime.now(timezone.utc).isoformat(),'objects':{},'contracts':{},'private_state_published':False}
    def confirm(content,cid=None):
        cid=cid or api.add(content,only_hash=True)
        if cid not in report['objects']:
            assert api.add(content)==cid; api.confirm(cid,content)
            with opener.open(gateway+cid,timeout=25) as r: assert r.read(len(content)+1)==content
            report['objects'][cid]={'sha256':hashlib.sha256(content).hexdigest(),'bytes':len(content),'pinned':True,'gateway_readback':True}
        return cid
    try:
        lock=json.loads((REPO/'Tools/Paladin/artifact-lock.json').read_text())
        for name in lock:
            artifact=d.artifacts[name]; metadata=artifact['metadata'].encode(); cid=metadata_cid(artifact['runtime_bytecode']); confirm(metadata,cid)
            parsed=json.loads(metadata)
            for unit,record in parsed['sources'].items():
                body=artifact['standard_json_input']['sources'][unit]['content'].encode()
                assert hx(d.w3.keccak(body))==record['keccak256']
                references=[v.removeprefix('dweb:/ipfs/') for v in record.get('urls',[]) if v.startswith('dweb:/ipfs/')]
                confirm(body,references[0] if references else None)
            standard=(d.out/'artifacts'/name/'standard-input.json').read_bytes()
            report['contracts'][name]={'metadata_cid':cid,'standard_input_cid':confirm(standard),'evm':artifact['evm']}
            print('PINNED '+name+' '+cid,flush=True)
        cardfiles={str(i)+'.json':(json.dumps({'name':'moment.cards Development Card #'+str(i),'description':'Development acceptance card for the Dakota redemption service.','attributes':[{'trait_type':'Environment','value':'Development'}]},sort_keys=True)+'\n').encode() for i in range(1,5)}
        response=d.http.post(endpoint+'/api/v0/add',params={'wrap-with-directory':'true','pin':'true','cid-version':0,'raw-leaves':'false'},
                 files=[('file',(name,body,'application/json')) for name,body in cardfiles.items()],timeout=40); response.raise_for_status()
        entries=[json.loads(line) for line in response.text.splitlines()]; directory=entries[-1]['Hash']
        pins=json.loads(api.request('pin/ls',{'arg':directory,'type':'recursive'})); assert directory in pins['Keys']
        for name,body in cardfiles.items():
            with opener.open(gateway+directory+'/'+name,timeout=25) as r: assert r.read(len(body)+1)==body
        report['card_metadata']={'directory_cid':directory,'base_uri':'ipfs://'+directory+'/','files':list(cardfiles),'pinned':True,'gateway_readback':True}
        report['passed']=True; (d.out/'ipfs-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print('IPFS verified '+str(len(report['objects']))+' compiler objects and card directory '+directory,flush=True)
    finally:
        for s in servers:s.shutdown();s.server_close()
        ssh.close()

if __name__=='__main__':main()
