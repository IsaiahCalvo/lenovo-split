#!/bin/bash
set -euo pipefail
launchctl bootout "gui/$(id -u)/local.lenovosplit" >/dev/null 2>&1 || true
pkill -x LenovoSplit >/dev/null 2>&1 || true
python3 - <<'CLEANUP'
from pathlib import Path
import plistlib, shutil
base = Path.home()
app = base/'Applications'/'Lenovo Split.app'
if app.exists():
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info.get('CFBundleIdentifier') == 'local.lenovosplit', 'Not a Lenovo Split bundle'
    shutil.rmtree(app)
agent = base/'Library/LaunchAgents/local.lenovosplit.plist'
if agent.exists():
    assert plistlib.loads(agent.read_bytes()).get('Label') == 'local.lenovosplit'
    agent.unlink()
print('Removed Lenovo Split and its login entry. Preferences remain.')
CLEANUP
