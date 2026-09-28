# BG Glance — glucose widget for Garmin watches

A Connect IQ widget that shows the current blood glucose as a **glance** —
the swipe-up stack that holds calendar, weather, steps, etc. Developed and
tested on the Venu 4 (`venu441mm` / `venu445mm`); see
[docs/DEVICES.md](docs/DEVICES.md) for why the device list is short and how
to extend it.

- **Glance row**: current BG color-coded by thresholds, trend, delta vs.
  previous reading, and reading age — e.g. `142 →  +4  3m`.
- **Full view** (tap the glance): a dark card holding the big number, a
  drawn trend arrow with the delta stacked beside it, and a sparkline with
  the target thresholds labeled on its left; below the card, the reading age
  and a status chip (SYNCED / STALE / OFFLINE).
  **Swipe left/right to change the charted window** — **60 min** (default,
  drawn as dots), **3 hr**, and **6 hr** (drawn as a connected line with the
  most recent readings dotted). The longer windows are bucket-averaged
  server-side so they don't turn into an unreadable smear. Tap opens the
  settings menu.
- **Background fetch**: polls every 5 minutes (the Connect IQ minimum) via
  the paired phone; the glance renders from the stored reading (glances
  can't fetch).
- **Staleness is safety-first**: an aging reading is dimmed and flagged with
  `!`; once it's too old to trust, the number is replaced by
  `--- STALE Xm`. An old value shown as current is worse than an honest
  "no data."

> ⚠️ Not a medical device. Never use this for treatment decisions — always
> confirm on your CGM app/receiver.

## Data source

The widget talks to exactly **one** endpoint: `GET <serverUrl>` with header
`Authorization: Bearer <watchToken>`. It doesn't know or care what's behind
that endpoint — Nightscout, Dexcom Share, your own pipeline — as long as the
server implements the contract in [docs/CONTRACT.md](docs/CONTRACT.md).

`server/` has a reference implementation (a Cloudflare Worker reading
Nightscout) you can deploy in a few minutes; see
[server/README.md](server/README.md). The endpoint also computes the
reading's age server-side, which keeps a skewed watch clock from lying
about staleness. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers the
full data path and why the widget has no client-side data-source switch.

## Colors

Thresholds are configured in **mg/dL** regardless of display units. By
default the bands come from your server's configured thresholds (if it
sends them — see the `th` field in [docs/CONTRACT.md](docs/CONTRACT.md)) so
every surface agrees; toggle that off (in settings, or the on-watch menu) to
use the manual values:

| Condition | Manual default | Color |
|---|---|---|
| Urgent low / urgent high | < 80 / > 230 | red |
| Low / high | 80–89 / 181–230 | yellow |
| In range | 90–180 | green |
| Aging / stale | — | grey |

## Configuring

Settings (server URL, token, units, thresholds) are edited from the
**Garmin Connect phone app** (My Device → Connect IQ apps) — but that
editor only works for apps installed from the Connect IQ Store.
**Sideloaded builds cannot be configured from the phone**; their values
must be baked in at build time via `config.local.json` (see Building,
below).

## Building

1. Install the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
   via the SDK Manager (needs a free Garmin developer sign-in), download the
   device files for your watch, and install the **Monkey C** VS Code
   extension.
2. Generate a developer key once: `Ctrl/Cmd+Shift+P` →
   *Monkey C: Generate a Developer Key*.
3. **Sideload build** (your server/token baked in — this is what you want
   to actually use it): copy `config.example.json` to `config.local.json`,
   fill in `device`, `developerKey`, `serverUrl`, and `watchToken`, then:
   ```bash
   ./tools/build.sh        # or: tools\build.ps1 on Windows
   ```
   This renders the gitignored `resources-personal/` overlay and builds
   `BGGlance.prg` with `personal.jungle`. Later resource paths win on
   duplicate ids, so the overlay only needs the values you're overriding.
4. **Generic build** (for store submission — settings arrive via the phone
   app, defaults ship empty):
   ```bash
   monkeyc -d venu441mm -f monkey.jungle -o BGGlance.prg -y <key>
   ```
5. Optional but recommended: *Monkey C: Run* first — the simulator can fire
   temporal events on demand (Simulation → Background Events), so the whole
   fetch/parse/render loop is testable without the watch.

> ⚠️ **The VS Code build button uses `personal.jungle`**, pinned in
> `.vscode/settings.json`. The extension's own default is `monkey.jungle` —
> the generic build — and sideloading *that* gives you a watch stuck on "Set
> server URL": it compiles and installs happily, then never fetches, because
> the generic defaults ship empty. Building the generic variant is a
> deliberate CLI act (step 4), which is the right way round.

## Tests

`source/BGDataTest.mc` holds Connect IQ unit tests for `BGData` — the
safety-critical logic that decides whether a reading is shown as current or
aged out, and how a server response becomes the stored reading. They cover the
staleness boundaries, `parseResponse`/`parseHistory` guards, the
threshold/color bands, the format helpers, and that the request auths via an
`Authorization: Bearer` header rather than the query string. Build the
`--unit-test` target and run it in the simulator (start the simulator first, or
use *Monkey C: Run Tests* in VS Code):

```bash
monkeyc -d venu441mm -f monkey.jungle --unit-test -o test.prg -y <key>
monkeydo test.prg venu441mm -t
```

The `(:test)` functions are compiled only under `--unit-test`, so they add
nothing to a release or sideload build. **`monkeydo` exits non-zero even when
every test passes**, so read the result from the summary line it prints —
`PASSED (passed=N, failed=0, errors=0)` — not from `$?`.

## Installing (sideload)

For the full cut-a-release checklist — jungle/SDK selection, the
persisted-property upgrade trap, and the on-wrist hardware gate — see
[docs/RELEASING.md](docs/RELEASING.md). The short version:

First, smoke-test the live endpoint the build will talk to — it proves the
deployed server still honours the contract `BGData.mc` parses and that the
payload fits the watch's memory budget:

```bash
WATCH_ENDPOINT_URL=https://<host>/api/watch/glucose \
WATCH_TOKEN=<your token> \
python tools/check_endpoint.py
```

It exits non-zero if any check fails, so run it green before flashing. The
token is read from the environment and never printed. Then:

1. Connect the watch via USB. On Windows it shows up in File Explorer; on
   macOS install [OpenMTP](https://openmtp.ganeshrvel.com) (Finder can't see
   MTP devices).
2. Copy `BGGlance.prg` into the watch's `GARMIN/Apps` folder (or use
   `tools/sideload.ps1` on Windows, which verifies the on-watch byte count
   against the source).
3. Unplug — the watch shows "Verifying Connect IQ Apps" and installs it.
4. **Open the widget once immediately** — a freshly sideloaded PRG may have
   no background service until it's been opened once (see
   [docs/RELEASING.md](docs/RELEASING.md)).

**On-device debugging:** create `GARMIN/Apps/LOGS/BGGlance.TXT` on the watch
and `System.println` output lands there — the only practical way to debug
the background service on hardware.

## Putting it at the top of the glance stack

Garmin doesn't let apps choose their position — but you can pin it:

- Swipe up from the watch face, touch and **hold** any glance to enter edit
  mode (or Settings → Appearance → Glances → Edit), add **BG** if it isn't
  listed, then drag it to the **top**.
- From then on, one swipe up from the watch face shows BG.

The first reading appears within 5 minutes of install (the background cycle).

## Troubleshooting

- **"Set server URL" / "Set watch token"** — that property is empty in the
  build: fill it in the Connect app settings (store install) or
  `config.local.json` (sideload). Shown in the menu's Refresh sublabel, the
  on-screen error line, and the glance — a missing setting is never silent.
- **"No data yet"** — the first 5-minute background fetch hasn't fired yet.
- **`--- STALE Xm`** — no fresh data for a while: watch out of phone range,
  phone offline, server down, or your CGM stopped uploading. Swipe up to the
  menu and read both status lines — the **Auto-fetch row** reports the
  automatic 5-minute service, and the line under the chart in the full view
  reports the last fetch by *either* path — then curl the endpoint from a
  browser to check the server side.
- **`No phone link (-104)` / `Phone timeout (-2)`** — the request never left
  the watch: it was out of Bluetooth range of the phone at the moment of the
  fetch. There is nothing to fix in software; the fix is proximity, and the
  staleness display handles the rest.
- **`Timed out (-300)`** — reached the phone and failed beyond it. Rare.
- **Diagnostics toggle** (menu, default OFF) — appends a compact history of
  recent background-fetch outcomes to the request when it's on, so failures
  the watch could never otherwise report are readable in the server's access
  log. Carries no glucose value and no token. Turn it on for an
  investigation window; see `source/BGData.mc` (`diagToken`) for the exact
  format and adaptive-width rules.

  Separately, every request sends `v=<build>`, so the server log answers
  "which build is actually on the wrist" without anyone reading the menu —
  and an **absent** `v=` means an older build. A freshly sideloaded PRG that
  was never opened makes no background request at all, which is silent and
  looks identical to a phone-link failure; `v=` is what tells the two apart
  afterwards.
- **Endpoint via `http://` or a self-signed cert** — Garmin refuses it; put
  the endpoint behind a real certificate (Let's Encrypt, Cloudflare, etc.).
  `server/` ships with a valid cert by default via Cloudflare Workers.
