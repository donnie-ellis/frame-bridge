# Signing the app

Under launchd there is no privacy prompt: a first start is denied, and the app shows up switched
off in System Settings. An ad-hoc signature's designated requirement is the build's cdhash, so
every new build is a new app to TCC and loses its grant. Signed with a local certificate, the
requirement is `identifier "local.frame-bridge" and certificate root = H"..."`, which stays the
same across builds.

`scripts/bundle.sh` signs with the identity in `SIGN_ID`, default `FrameBridge Local Signing`.
`SIGN_ID=- ./scripts/bundle.sh` gives an ad-hoc build, for a Mac without the certificate.

## Create the certificate (once, on the Mac that builds)
1. Open **Keychain Access**. On macOS 15 and later it isn't in Applications any more: use Spotlight,
   or `open "/System/Library/CoreServices/Applications/Keychain Access.app"`.
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `FrameBridge Local Signing` (exactly; `bundle.sh` signs with this name)
   - **Identity Type:** Self-Signed Root
   - **Certificate Type:** Code Signing
   - Tick **Let me override defaults**, then **Continue**.
4. **Validity Period (days):** `3650`. The grant on the Mac mini is tied to this certificate, so it
   shouldn't expire in a year. Continue.
5. Leave every other page at its default (RSA 2048, the Code Signing extension, keychain **login**),
   and click **Create**, then **Done**.
6. No need to mark it trusted: `codesign` signs with it as is, and the Mac mini doesn't need it
   installed (the signature carries the certificate).

Optional: back it up. In Keychain Access, find `FrameBridge Local Signing` under **My
Certificates**, right-click → **Export…** as `.p12` with a password, and keep it in a password
manager. Never in the repo. If it's lost, make a new one: the next deploy then needs the one-time
switch in Settings again (see "First deploy").

## Build
1. `./scripts/bundle.sh`
2. The first time, macOS asks whether `codesign` may use the key "FrameBridge Local Signing".
   Enter the login password and choose **Always Allow**, so later builds (and the agent loop) don't
   ask again.
3. Check the signature:
   ```sh
   codesign -v build/FrameBridge.app                     # no output, exit 0
   codesign -d -r- build/FrameBridge.app 2>&1 | grep designated
   # expect: designated => identifier "local.frame-bridge" and certificate root = H"…"
   # not:    designated => cdhash H"…"   (that's an ad-hoc build: the grant won't survive)
   lipo -archs build/FrameBridge.app/Contents/MacOS/FrameBridge   # x86_64 arm64
   ```

## First deploy of a signed build (on the Mac mini)
1. Install with `deploy-bridge` as usual.
2. Under launchd there's no prompt: the first start is denied. Open System Settings → Privacy &
   Security and switch **FrameBridge** on under **Photos**, **Calendars** (Full Access) and
   **Reminders** (Full Access).
3. Restart it: `launchctl kickstart -k gui/$(id -u)/local.frame-bridge`.
4. `/healthz`: `authorization` is `fullAccess` for calendar and shopping, `authorized` for photos.

## Later deploys
Same certificate → nothing to switch. Check `/healthz` shows the same authorizations after the
deploy. If one is `denied` or `notDetermined`, the build was ad hoc or signed with another
certificate: check `codesign -d -r-` as above.
