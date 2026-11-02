# Known-answer fixture for the Swan pattern pack (see sec.ts). Not real code.
import os, pickle, subprocess, yaml, requests
def cases(user, fh):
    subprocess.run(user, shell=True, check=True)  # P01 shell=True, more args after
    subprocess.run(["ls", user], check=True)  # P02 no shell
    subprocess.check_output(user, shell=True)  # P03 shell=True last
    os.system(user)  # P04 os.system
    eval(user)  # P05 eval
    exec(user)  # P06 exec
    pickle.loads(user)  # P07 pickle.loads
    pickle.load(fh)  # P08 pickle.load
    yaml.load(user)  # P09 yaml.load without Loader
    yaml.load(user, Loader=yaml.SafeLoader)  # P10 safe loader
    requests.get(user, verify=False)  # P11 TLS off, last
    requests.get(user)  # P12 TLS on
    requests.post(user, json={}, verify=False, timeout=5)  # P13 TLS off, more args after
    try:  # P14 bare except: pass
        pass
    except:
        pass
