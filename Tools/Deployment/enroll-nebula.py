"""Read enrollment code from SSH stdin; never print or persist the secret."""
import json,re,subprocess,sys,time
payload=json.load(sys.stdin)
code=payload['code']; address=payload['nebula_ip']
assert re.fullmatch(r'[A-Za-z0-9_-]{32,128}',code)
assert re.fullmatch(r'100\.111\.\d{1,3}\.\d{1,3}',address)
def assigned():
    interfaces=subprocess.run(['ip','-j','address'],capture_output=True,check=True,text=True).stdout
    return sorted({a['local'] for link in json.loads(interfaces) for a in link.get('addr_info',[]) if a.get('local','').startswith('100.111.')})
existing=assigned()
if existing:
    print(json.dumps({'enrollment':'already_enrolled','assigned_ips':existing,'expected_ip':address,'address_matches':address in existing}));sys.exit(0)
result=subprocess.run(['/usr/bin/dnclient','enroll','-code',code],capture_output=True,text=True,timeout=60)
# The CLI may include the submitted code in an error; always redact before output.
message=(result.stdout+'\n'+result.stderr).replace(code,'[REDACTED]')[-2000:]
observed=[]
if result.returncode==0:
    for _ in range(20):
        observed=assigned()
        if observed:break
        time.sleep(.5)
print(json.dumps({'enrollment_exit':result.returncode,'message':message,'expected_ip':address,'assigned_ips':observed,'address_matches':address in observed}))
sys.exit(result.returncode)
