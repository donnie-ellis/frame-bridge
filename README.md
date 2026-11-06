# frame-bridge

A small Swift service that feeds the family dashboard from Apple Calendar, Reminders, Photos, Hue,
Sonos and Open-Meteo. See `Config.example.json` for the config file and `docs/signing.md` for signing.

It runs on a Mac mini at home, because Apple's calendar, reminders and photo data can only be read
from a logged-in Mac. The wall frames are Android tablets running a kiosk app. They load both the
dashboard page and its API from this one service, over the LAN:

```
Calendar, Reminders, Photos ──┐
Hue Bridge, Sonos (LAN) ──────┼──> frame-bridge ──> http://<mac-ip>:8787 ──> frames
Open-Meteo, Workers AI ───────┘    (Mac mini)       dashboard + API + SSE
```

There is no tunnel, proxy or cloud service in front of it. The dashboard itself lives in a separate
repo, `photo-frame-dashboard`, which also owns the API contract:
`docs/api/frame-bridge.openapi.yaml` there is the source of truth, and this repo implements it.

## Feeds

| Feed | Source | Route | What it can do |
| --- | --- | --- | --- |
| Calendar | Apple Calendar (EventKit) | `/api/calendar` | Read only |
| Shopping | A Reminders list | `/api/shopping` | Read, check items off |
| Chores | One Reminders list per person | `/api/chores` | Read, check chores off |
| Photos | A Photos album (PhotoKit) | `/api/photos` | Read only, resized on the Mac |
| Lights | Hue Bridge, local API | `/api/lights`, `/api/rooms`, `/api/scenes` | Read, control lights and rooms, recall scenes |
| Weather | Open-Meteo | `/api/weather` | Read, about every 30 minutes |
| Now playing | Sonos, local UPnP | `/api/nowplaying` | Read only, never controls playback |
| Day summary | Cloudflare Workers AI | `/api/summary` | Optional, see [Day summary](#day-summary-optional) |

`/api/people` serves the family list from the config, `/api/events` is a server-sent event stream
that tells the frames what changed, and `/healthz` reports each feed's state. A feed that's down or
not configured answers `503` and shows as `error` in `/healthz`, and the rest keep working. Sonos
and the day summary are the exception: without their config section, `/healthz` leaves them out.

**Access.** Every request, including the dashboard files, needs a `frame_token` cookie, or it gets
`401`. Each frame has its own token, and the config holds only their SHA-256 hashes. This keeps
guests on the Wi-Fi out. It's plain HTTP, so it isn't protection against a determined attacker on
the LAN.

## Development

You need macOS 14 or later and Xcode's Swift 6 toolchain.

```sh
swift build && swift test
```

Tests never touch the real calendar, photo library, Hue Bridge, speakers or Cloudflare.

| Path | What's there |
| --- | --- |
| `Sources/FrameBridgeCore/` | Routes, wire models and source adapters |
| `Sources/FrameBridge/` | The executable, which only starts the app |
| `Tests/FrameBridgeCoreTests/` | Tests and recorded fixtures |
| `Resources/Info.plist` | The app bundle's plist, including the privacy strings |
| `launchd/local.frame-bridge.plist` | The LaunchAgent |
| `scripts/bundle.sh` | Builds the universal, signed `build/FrameBridge.app` |
| `scripts/install.sh` | Installs or updates the app on the Mac mini |

## Configuration

The config is one JSON file outside the repo, read once at startup, so restart the service after
changing it. The default path is `~/Library/Application Support/frame-bridge/config.json`. To run
from another path, pass it as the first argument. `Config.example.json` shows every section.

| Section | Required | What it sets |
| --- | --- | --- |
| `frames` | Yes, at least one | Frame name → SHA-256 hash of its token |
| `dashboardDir` | Yes | Absolute path of the built dashboard served at `/` |
| `people` | No | The family, in lane order. `chores` on a person names their Reminders list |
| `calendar` | No | Which calendars to read, and who each one is for |
| `shopping` | No | The Reminders list, stores and keyword maps |
| `photos` | No | The album to show |
| `weather` | No | Home coordinates and `celsius` or `fahrenheit` |
| `hue` | No | The bridge's address and scene icons |
| `sonos` | No | A speaker's address and the room to follow |
| `summary` | No | The Workers AI model |

A missing required value, or an invalid value in any section, stops the service at startup, and the
reason goes to the log. A missing optional section only turns that feed off.

The Hue key and pinned certificate, and the Cloudflare account id and token, are in the login
Keychain, not the config. Never commit the real config, tokens, hashes or coordinates.

## Day summary (optional)

`GET /api/summary` serves one to three sentences about today, written by a model on Cloudflare
Workers AI. It is generated in the background, never in the request.

1. Add the model to the config (see `Config.example.json`). Without this section the feature is off
   and `/healthz` has no `summary` entry:

   ```json
   "summary": { "model": "@cf/meta/llama-3.1-8b-instruct" }
   ```

2. Put your Cloudflare account id and a Workers AI API token in the login Keychain, once, on the
   Mac that runs frame-bridge. An empty `-w` makes `security` prompt for the value, so it stays out
   of your shell history:

   ```sh
   security add-generic-password -s local.frame-bridge.workers-ai -a account-id -w
   security add-generic-password -s local.frame-bridge.workers-ai -a api-token -w
   ```

   The account id is 32 lowercase hex characters. frame-bridge only reads these items.

It needs `calendar` or people with chore lists in the config. With the section present but the
Keychain items missing, `/healthz` reports `summary` as `error` ("not configured") and the route
answers 503.

What is sent to Cloudflare, and nothing else: today's date; for each of today's events the title,
start and end (or "all day") and the names of its people; for each of today's chores the title, the
person's name, the due time and whether it is done. Never locations, notes, ids, shopping items,
photos, weather or anything else from the config. It makes one `POST` to
`https://api.cloudflare.com/client/v4/accounts/<account id>/ai/run/<model>`: after 05:00, then again
after a calendar or chores change (at least 5 minutes apart, at most 24 a day).

## Deployment

The service builds on a development Mac and runs on the Mac mini as a LaunchAgent. A LaunchAgent
runs inside the logged-in user's session, which EventKit and iCloud need. The Mac mini is Intel on
macOS 15, so `bundle.sh` builds a universal app.

Every frame depends on this service, so deploy from a clean `main`. `<mini>` is the Mac mini's
address and `<user>` is its auto-login user.

### First install

**1. Prepare the Mac mini.** Turn on auto-login and turn off sleep. Sign in to the iCloud account
that has the family's calendars, reminders and photos. Give the Mac mini and the Hue Bridge DHCP
reservations, so their addresses don't change.

**2. Create the signing certificate**, once, on the Mac that builds. Follow
[docs/signing.md](docs/signing.md). An ad-hoc build loses its privacy grants on every rebuild, so
`install.sh` refuses one.

**3. Build and check the app**, on the Mac that builds:

```sh
swift build && swift test
./scripts/bundle.sh
lipo -archs build/FrameBridge.app/Contents/MacOS/FrameBridge    # x86_64 arm64
codesign -d -r- build/FrameBridge.app 2>&1 | grep designated    # certificate root, not cdhash
```

**4. Issue a token for each frame**, on a machine where `adb` can reach the frame. See
[Issue a frame token](#issue-a-frame-token). Keep the hashes for the next step. There's no need to
restart anything yet.

**5. Create the config** on the Mac mini. It has to exist before the install, because the service
won't start without it:

```sh
mkdir -p ~/Library/Application\ Support/frame-bridge
# Create config.json in that folder from Config.example.json, then:
chmod 600 ~/Library/Application\ Support/frame-bridge/config.json
```

Set `frames` to the hashes from step 4, and `dashboardDir` to where the dashboard will go, such as
`/Users/<user>/Library/Application Support/frame-bridge/dashboard`. Leave out any feed you aren't
setting up yet.

**6. Copy the build over and install it:**

```sh
ssh <user>@<mini> mkdir -p frame-bridge-deploy
scp -r build/FrameBridge.app launchd/local.frame-bridge.plist scripts/install.sh <user>@<mini>:~/frame-bridge-deploy/
ssh -t <user>@<mini> sh frame-bridge-deploy/install.sh
```

The script stops the agent, keeps the old app as `/Applications/FrameBridge.prev.app`, installs the
new app and plist, and starts the agent again. It prints `state`, which should be `running`. Logs go
to `~/Library/Logs/frame-bridge/frame-bridge.log`.

**7. Grant privacy access.** macOS shows no prompt to a LaunchAgent: access is denied at once, and
the app appears switched off. On the Mac mini, open System Settings → Privacy & Security and switch
**FrameBridge** on under **Photos**, **Calendars** (Full Access) and **Reminders** (Full Access).
Then restart the service:

```sh
launchctl kickstart -k gui/$(id -u)/local.frame-bridge
```

**8. Pair the Hue Bridge.** Run this in Terminal on the Mac mini itself, because the login Keychain
may be locked in an SSH session:

```sh
/Applications/FrameBridge.app/Contents/MacOS/FrameBridge hue-pair <bridge ip>
```

It shows the bridge's certificate fingerprint and asks you to trust it, then asks you to press the
link button. Restart the service with the `kickstart` command from step 7 when it says `paired`.

**9. Set up the day summary**, if you want it: see [Day summary](#day-summary-optional), then
restart the service.

**10. Deploy the dashboard** from the `photo-frame-dashboard` repo with its `deploy-dashboard`
skill, which copies `dashboard/dist/` into `dashboardDir`. This needs no restart here. Reload the
frames afterwards.

**11. [Check the deployment](#check-a-deployment).**

### Update

1. Build and check the app (step 3 above) from a clean `main`.
2. Copy it over and install it (step 6). When the Hue credentials are in the Keychain, `install.sh`
   asks for the login keychain password twice, so that the new build can read them.
3. [Check the deployment](#check-a-deployment).

Privacy grants carry over as long as the build is signed with the same certificate. A new
certificate means switching them on again (step 7).

The script only updates Keychain access for the Hue items. If you use the day summary, the Mac mini
may show a Keychain prompt for the Workers AI items after a deploy. Allow it on the Mac mini's
screen.

### Issue a frame token

Run this where `adb` can reach the frame. The last step saves the token on the frame and sets the
cookie:

```sh
TOKEN=$(openssl rand -hex 32)
printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1    # add to config.json as "<frame name>": "<hash>"
adb shell am start -n com.wesbos.homehq/.MainActivity \
  --es url http://<mac-ip>:8787/ --es token "$TOKEN"
unset TOKEN
```

On a running service, restart it to pick up the new entry:

```sh
launchctl kickstart -k gui/$(id -u)/local.frame-bridge
```

**To revoke a frame**, delete its entry from `config.json` and restart the same way. That frame gets
`401` from then on, and the others aren't affected.

### Check a deployment

`/healthz` needs a token too. Make a temporary one, on any machine on the LAN:

```sh
TOKEN=$(openssl rand -hex 32)
printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1    # add to config.json as "check": "<hash>", restart

curl -s -o /dev/null -w '%{http_code}\n' http://<mac-ip>:8787/healthz                     # 401
curl -s -b "frame_token=$TOKEN" http://<mac-ip>:8787/healthz | jq .
curl -s -o /dev/null -w '%{http_code}\n' -b "frame_token=$TOKEN" http://<mac-ip>:8787/    # 200
unset TOKEN
```

In the `/healthz` output:

- `version` is the `contractVersion` in `Sources/FrameBridgeCore/App.swift`.
- Each feed is `ok`, or `error` with a `detail` you expect, such as "not configured".
- `authorization` is `fullAccess` for calendar and shopping, and `authorized` for photos.

Then delete the `check` entry, restart, and confirm the frames show the dashboard after a reload.

### Roll back

`install.sh` keeps one previous build. On the Mac mini:

```sh
launchctl bootout gui/$(id -u)/local.frame-bridge
rm -rf /Applications/FrameBridge.app
mv /Applications/FrameBridge.prev.app /Applications/FrameBridge.app
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.frame-bridge.plist
```

If `bootstrap` fails with error 5, the old process hasn't exited yet: wait a few seconds and run it
again. The Hue Keychain items already allow the previous build, because `install.sh` adds both.

### Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `state = spawn scheduled` with a `last exit code` | The service keeps exiting. Run `tail -50 ~/Library/Logs/frame-bridge/frame-bridge.log` and look for config or `dyld` errors. If it's empty, run `/Applications/FrameBridge.app/Contents/MacOS/FrameBridge` in the foreground, then press Ctrl-C |
| Lights answer `503` "waiting for the Keychain" | A prompt is waiting on the Mac mini's screen. Allow it. The rest of the service still works |
| `authorization` is `denied` or `notDetermined` | On a first install, do step 7. After an update, the build was ad hoc or signed with another certificate: check `codesign -d -r-` on the installed app |
| Lights say "not paired", "key rejected" or "certificate doesn't match" | Run `hue-pair` again (step 8) |
| Hue or Sonos can't be reached, but both are up | Check that **FrameBridge** is on under Privacy & Security → Local Network |
| Dashboard files return `404` | `dashboardDir` is missing or empty. Check the path and deploy the dashboard |
| A frame gets `401` | Its token doesn't match any hash in the config. Issue a new one, and restart |
