"""Read enrollment code from SSH stdin; never print or persist the secret."""
import json,re,subprocess,sys,time
payload=json.load(sys.stdin)
code=payload['code']; address=payload['nebula_ip']
replace_existing=payload.get('replace_existing',False)
assert isinstance(replace_existing,bool)
assert re.fullmatch(r'[A-Za-z0-9_-]{32,128}',code)
assert re.fullmatch(r'100\.111\.\d{1,3}\.\d{1,3}',address)
def assigned():
    interfaces=subprocess.run(['ip','-j','address'],capture_output=True,check=True,text=True).stdout
    return sorted({a['local'] for link in json.loads(interfaces) for a in link.get('addr_info',[]) if a.get('local','').startswith('100.111.')})
existing=assigned()
if existing and not replace_existing:
    print(json.dumps({'enrollment':'already_enrolled','assigned_ips':existing,'expected_ip':address,'address_matches':address in existing}));sys.exit(0)
try:
    result=subprocess.run(['/usr/bin/dnclient','enroll','-code',code],capture_output=True,text=True,timeout=60)
except subprocess.TimeoutExpired:
    # TimeoutExpired contains command arguments, including the enrollment code.
    print(json.dumps({'enrollment':'timeout_outcome_unknown','expected_ip':address}))
    sys.exit(1)
# The CLI may include the submitted code in an error; always redact before output.
message=(result.stdout+'\n'+result.stderr).replace(code,'[REDACTED]')[-2000:]
observed=[]
restart_exit=None
if result.returncode==0:
    # Defined's server migration procedure permits enrollment over an existing
    # identity, followed by a restart. No identity files need to be deleted.
    # Use bootstrap/recovery SSH for replacement because the tunnel can drop.
    if replace_existing:
        restart=subprocess.run(['systemctl','restart','dnclient'],capture_output=True,text=True,timeout=20)
        restart_exit=restart.returncode
    for _ in range(20):
        observed=assigned()
        if address in observed:break
        time.sleep(.5)
print(json.dumps({'enrollment_exit':result.returncode,'replaced_existing':replace_existing,'restart_exit':restart_exit,'message':message,'expected_ip':address,'assigned_ips':observed,'address_matches':address in observed}))
sys.exit(result.returncode or restart_exit or 0)
