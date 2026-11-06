# frame-bridge

A small Swift service that feeds the family dashboard from Apple Calendar, Reminders, Photos, Hue,
Sonos and Open-Meteo. See `Config.example.json` for the config file and `docs/signing.md` for signing.

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
