#!/bin/sh
# Build a universal FrameBridge.app into build/. EventKit only shows its privacy prompt to an
# .app bundle, and the Mac mini is Intel, so a bare arm64 binary won't do.
set -eu
cd "$(dirname "$0")/.."

flags="-c release --arch arm64 --arch x86_64"
swift build $flags
bin=$(swift build $flags --show-bin-path)/FrameBridge

app=build/FrameBridge.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$bin" "$app/Contents/MacOS/FrameBridge"
# Ad-hoc signature. TCC ties the privacy grant to it, so a new build may need re-approval.
codesign --force --sign - "$app"
echo "$app"
