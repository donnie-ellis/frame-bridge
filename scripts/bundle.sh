#!/bin/sh
# Build a universal FrameBridge.app into build/. EventKit only shows its privacy prompt to an
# .app bundle, and the Mac mini is Intel, so a bare arm64 binary won't do.
set -eu
cd "$(dirname "$0")/.."

SIGN_ID="${SIGN_ID:-FrameBridge Local Signing}"

flags="-c release --arch arm64 --arch x86_64"
swift build $flags
bin=$(swift build $flags --show-bin-path)/FrameBridge

app=build/FrameBridge.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$bin" "$app/Contents/MacOS/FrameBridge"
# Sign with a local certificate: the designated requirement is then identifier + certificate root,
# not a cdhash, so TCC privacy grants survive rebuilds. SIGN_ID=- signs ad hoc, and that build
# loses its grants on every rebuild.
if ! codesign --force --sign "$SIGN_ID" "$app"; then
  echo "bundle.sh: codesign failed with identity '$SIGN_ID'; see docs/signing.md (or SIGN_ID=- for an ad-hoc build)" >&2
  exit 1
fi
echo "$app"
