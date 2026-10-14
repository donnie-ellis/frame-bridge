#!/bin/sh
# Install or update FrameBridge on the Mac mini. Run it there, as the auto-login user, from the
# folder the build was copied into:
#
#   scp -r build/FrameBridge.app launchd/local.frame-bridge.plist scripts/install.sh <user>@<mini>:~/frame-bridge-deploy/
#   sh ~/frame-bridge-deploy/install.sh
#
# Stops the LaunchAgent, keeps the old app as /Applications/FrameBridge.prev.app, installs the new
# one (and the plist, when it was copied along), and starts the agent again.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app="$here/FrameBridge.app"
label=local.frame-bridge
domain="gui/$(id -u)"
agents="$HOME/Library/LaunchAgents"

[ -d "$app/Contents/MacOS" ] || { echo "install.sh: no FrameBridge.app in $here" >&2; exit 1; }
codesign -v "$app" || { echo "install.sh: $app fails codesign -v (damaged copy?)" >&2; exit 1; }
# An ad-hoc build loses the Photos/Calendars/Reminders grants (docs/signing.md).
if codesign -d -r- "$app" 2>&1 | grep -q 'designated => cdhash'; then
  echo "install.sh: $app is signed ad hoc; build it with the FrameBridge Local Signing certificate" >&2
  exit 1
fi

launchctl bootout "$domain/$label" 2>/dev/null || true
# bootout returns before the old process is gone; bootstrapping too soon fails with error 5.
i=0
while launchctl print "$domain/$label" >/dev/null 2>&1 && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done

rm -rf /Applications/FrameBridge.prev.app
[ -d /Applications/FrameBridge.app ] && mv /Applications/FrameBridge.app /Applications/FrameBridge.prev.app
cp -R "$app" /Applications/

if [ -f "$here/$label.plist" ]; then
  mkdir -p "$agents"
  cp "$here/$label.plist" "$agents/"
fi
[ -f "$agents/$label.plist" ] || { echo "install.sh: no $agents/$label.plist; copy launchd/$label.plist along" >&2; exit 1; }

launchctl bootstrap "$domain" "$agents/$label.plist"
sleep 3
launchctl print "$domain/$label" | grep -E '^[[:space:]]*(state|last exit code) =' || true
echo "Rollback: launchctl bootout $domain/$label, move FrameBridge.prev.app back, bootstrap again."
