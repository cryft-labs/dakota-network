"""Read enrollment code from SSH stdin; never print or persist the secret."""
import json,re,subprocess,sys
payload=json.load(sys.stdin)
code=payload['code']; address=payload['nebula_ip']
assert re.fullmatch(r'[A-Za-z0-9_-]{32,128}',code)
assert re.fullmatch(r'100\.111\.\d{1,3}\.\d{1,3}',address)
interfaces=subprocess.run(['ip','-j','address'],capture_output=True,check=True,text=True).stdout
if any(a.get('local')==address for link in json.loads(interfaces) for a in link.get('addr_info',[])):
    print(json.dumps({'enrollment':'already_assigned','ip':address}));sys.exit(0)
result=subprocess.run(['/usr/bin/dnclient','enroll','-code',code],capture_output=True,text=True,timeout=60)
# The CLI may include the submitted code in an error; always redact before output.
message=(result.stdout+'\n'+result.stderr).replace(code,'[REDACTED]')[-2000:]
print(json.dumps({'enrollment_exit':result.returncode,'message':message,'expected_ip':address}))
sys.exit(result.returncode)
