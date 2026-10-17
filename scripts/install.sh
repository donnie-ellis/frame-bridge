#!/bin/sh
# Install or update FrameBridge on the Mac mini. Run it there, as the auto-login user, from the
# folder the build was copied into:
#
#   scp -r build/FrameBridge.app launchd/local.frame-bridge.plist scripts/install.sh <user>@<mini>:~/frame-bridge-deploy/
#   ssh -t <user>@<mini> sh frame-bridge-deploy/install.sh   (-t: it may ask for the keychain password)
#
# Stops the LaunchAgent, keeps the old app as /Applications/FrameBridge.prev.app, installs the new
# one (and the plist, when it was copied along), points its logs at ~/Library/Logs/frame-bridge
# (keeping the previous install's log as frame-bridge.log.1), and starts the agent again.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app="$here/FrameBridge.app"
label=local.frame-bridge
domain="gui/$(id -u)"
agents="$HOME/Library/LaunchAgents"
logs="$HOME/Library/Logs/frame-bridge"

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

# The login Keychain lets code without an Apple team ID read an item only when the build's code
# hash is in the item's partition list, so "Always Allow" doesn't carry over to a new build and
# the app waits on a prompt for the Hue credentials. Allow this build and the previous one (for a
# rollback). `security` asks for the login keychain password once per item.
hue_service=local.frame-bridge.hue
if security find-generic-password -s "$hue_service" -a application-key >/dev/null 2>&1; then
  cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
  partitions="apple-tool:,apple:,cdhash:$(cdhash /Applications/FrameBridge.app)"
  [ -d /Applications/FrameBridge.prev.app ] && partitions="$partitions,cdhash:$(cdhash /Applications/FrameBridge.prev.app)"
  echo "install.sh: allowing this build to read the Hue credentials (login keychain password, twice)"
  for account in application-key certificate-sha256; do
    security set-generic-password-partition-list -s "$hue_service" -a "$account" -S "$partitions" >/dev/null ||
      echo "install.sh: couldn't update the Keychain item $account; allow FrameBridge on the Mac's screen instead" >&2
  done
fi

if [ -f "$here/$label.plist" ]; then
  mkdir -p "$agents"
  cp "$here/$label.plist" "$agents/"
fi
[ -f "$agents/$label.plist" ] || { echo "install.sh: no $agents/$label.plist; copy launchd/$label.plist along" >&2; exit 1; }

# launchd doesn't expand ~, and the committed plist has no username: write the absolute path here.
mkdir -p "$logs"
plutil -replace StandardOutPath -string "$logs/frame-bridge.log" "$agents/$label.plist"
plutil -replace StandardErrorPath -string "$logs/frame-bridge.log" "$agents/$label.plist"
if [ -f "$logs/frame-bridge.log" ]; then mv -f "$logs/frame-bridge.log" "$logs/frame-bridge.log.1"; fi

launchctl bootstrap "$domain" "$agents/$label.plist"
sleep 3
launchctl print "$domain/$label" | grep -E '^[[:space:]]*(state|last exit code) =' || true
echo "Logs: $logs/frame-bridge.log"
echo "Rollback: launchctl bootout $domain/$label, move FrameBridge.prev.app back, bootstrap again."
