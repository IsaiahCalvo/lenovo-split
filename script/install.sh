#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGED_APP="$ROOT_DIR/dist/Lenovo Split.next.app"
[ -d "$STAGED_APP" ] || { echo 'Build the app first.' >&2; exit 1; }
python3 - "$STAGED_APP" <<'PY'
import pathlib,plistlib,shutil,subprocess,sys,os
staged=pathlib.Path(sys.argv[1]);home=pathlib.Path.home()
target=home/'Applications'/'Lenovo Split.app'
agent=home/'Library'/'LaunchAgents'/'local.lenovosplit.plist'
info=plistlib.loads((staged/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='local.lenovosplit' and info['LSUIElement'] is True
if target.exists():
 existing=plistlib.loads((target/'Contents/Info.plist').read_bytes())
 assert existing['CFBundleIdentifier']=='local.lenovosplit','Existing app is not ours'
 backup=staged.parent/'Lenovo Split.previous.app'
 if backup.exists():shutil.rmtree(backup)
 shutil.copytree(target,backup)
 shutil.rmtree(target)
target.parent.mkdir(exist_ok=True)
subprocess.run(['/usr/bin/ditto',str(staged),str(target)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--strict',str(target)],check=True)
agent.parent.mkdir(parents=True,exist_ok=True)
job={'Label':'local.lenovosplit','ProgramArguments':['/usr/bin/open','-g','-a',str(target),'--args','--background'], 'RunAtLoad':True,'ProcessType':'Interactive','LimitLoadToSessionType':'Aqua'}
tmp=agent.with_suffix('.plist.tmp');tmp.write_bytes(plistlib.dumps(job));os.chmod(tmp,0o600);tmp.replace(agent)
print('Installed:',target)
print('Login entry:',agent)
print('Enable: launchctl bootstrap gui/'+str(os.getuid())+' '+str(agent))
PY
