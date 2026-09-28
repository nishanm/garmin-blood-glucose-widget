# Architecture

**Goal:** current glucose number, trend, and reading age visible in the
watch's glance loop (the swipe-up carousel), refreshed automatically every
~5 minutes.

**One data source, deliberately.** The watch talks only to the server
endpoint documented in [CONTRACT.md](CONTRACT.md) and knows nothing about
Nightscout, Dexcom, or any other upstream. A `dataSource` property that let
the watch pick a source directly existed briefly during an earlier attempt
to make the widget generically publishable; it was removed (see *Why there
is no client-side data-source switch* below) because the server already
handles upstream failover and a second client-side source did real harm.

## System overview

```
Your CGM data source (Nightscout, Dexcom Share, a custom pipeline, ...)
      │
   Your server: GET /api/watch/glucose   (implements CONTRACT.md)
      │  valid HTTPS cert — required by Garmin
      │
   Phone: Garmin Connect app (proxies all watch HTTP)
      │  (BLE)
   Watch: Connect IQ widget (this repo)
     ├─ Background service: temporal event every 5 min → fetch → Storage
     ├─ Glance view: number + trend + age (the swipe-up surface)
     └─ Full widget view: larger display when glance is tapped
```

The server is responsible for all upstream failover and normalization
(trend spellings, threshold sourcing, etc.) — see `server/` for a reference
implementation backed by Nightscout. The watch has no client-side source
selection to get wrong.

### Why there is no client-side data-source switch

A `dataSource` property (read one upstream directly vs. go through the
server) existed briefly during an attempt to make the widget generically
publishable. It caused a real outage and was removed, and it should not
come back without solving all three of these:

1. **It duplicates a failover the server already does.** It adds a source,
   not resilience.
2. **It can't fail loudly.** Selecting an unconfigured source made
   `requestSpec()` return an error sentinel, and `refresh()` returned on it
   *silently* — so "Refresh now", fetch-on-open, and the ~1/min self-heal
   all became no-ops. Because a failed fetch keeps the last good reading on
   screen, the watch showed a plausible number that simply stopped
   advancing. `refresh()` now stores any spec error instead of bailing
   quietly, and the on-screen error line no longer filters setup sentinels
   when a reading is present.
3. **New properties don't initialize on a sideloaded update** (see the
   gotcha below), so a new selector would default to an unconfigured source
   on every existing install — turning an added feature into an instant
   regression.

## Component A — the server

Not part of this repo's build; see `server/` for a reference Cloudflare
Worker implementation and `docs/CONTRACT.md` for the full request/response
contract it must satisfy. In short: `GET /api/watch/glucose` with
`Authorization: Bearer <token>` (header only — a query-string token ends up
in access and proxy logs), returning a small JSON reading plus optional
bucket-averaged history for the chart.

## Component B — widget (this repo)

| File | Role |
|---|---|
| `manifest.xml` | Lists glance-capable products for the generic build; `venu441mm`/`venu445mm` are the only hardware-tested pair. Permissions `Background`, `Communications` |
| `source/BGWidgetApp.mc` | AppBase: registers temporal event, wires glance/view/service, persists background data |
| `source/BGServiceDelegate.mc` | Background service — the steady 5-min fetch, reading only (never asks for history) |
| `source/BGGlanceView.mc` | Glance: `142 →  +4  3m`, dimmed/flagged when aging. No chart — no room, tighter memory |
| `source/BGWidgetView.mc` | Full view: big number, polygon-drawn arrow, swipeable sparkline (60 min / 3 h / 6 h), staleness banner, page-dot indicator |
| `source/BGChart.mc` | The sparkline. Dots for the 60 min frame, a gap-broken line + recent dots for the longer frames. Draws nothing (returns false) for any reason it can't plot honestly |
| `source/BGMenu.mc` | The pull-out menu: Refresh (whose sublabel is the Auto-fetch status row), the server-thresholds and Diagnostics toggles, and the build-version row |
| `source/BGData.mc` | Shared config/parse/format helpers (all three scopes) |

Refresh loop: temporal event (5 min — the Connect IQ floor) → HTTPS GET via
the phone → `Background.exit(parsed)` → `onBackgroundData` persists to
Storage → the glance renders **only from Storage** (glances can't fetch).
The **full view** additionally fetches on demand — on open, on a swipe to a
window it hasn't loaded yet, and a ~1/min self-heal while visible when data
is overdue — which is the fast-recovery path after walking back into phone
range instead of waiting out the background cycle. All fetches are single
requests, never loops, and the on-demand path is rate-limited to 2 fetches
per rolling 10 s across all triggers. Each frame's series is cached under
its own Storage key so re-swiping is instant. The selected window is
in-memory view state that resets to 60 min on every open — deliberately not
a persisted property (the "new setting doesn't initialize on a sideloaded
update" trap below).

**The at-fetch-time diagnostic ring.** The background service records every
attempt — outcome code, timestamp, and `phoneConnected` sampled *at that
moment* — into a ring in Storage (`DIAG_KEY` in `BGData.mc`), written and
read entirely within the background context so it never depends on
background-to-foreground delivery. This exists because the delivery-side
keys cannot tell the truth: Connect IQ holds only the most recent
`Background.exit()` payload while the app is closed, so a run of successes
overwrites itself and one later failure erases the lot. The Auto-fetch row
reads the ring for all three of the values it shows — age, error, and link
state — and falls back to the delivered keys only when the ring is empty.
With the Diagnostics toggle on, the newest entries also ride the query
string as `d=`, the only way the server can see attempts that never reached
it. Full sizing/budget rationale is in the comments above `DIAG_MAX`,
`DIAG_SEND`, and `DIAG_SEND_MAX` in `source/BGData.mc`.

The request also carries **`v=<build>`** unconditionally, so the server log
can always tell which build is actually on the wrist — a freshly sideloaded
PRG that was never opened makes no background request at all, which is
silent and would otherwise look identical to a phone-link failure.

## Staleness rules (safety-critical)

Effective age = server `age_min` at fetch time + time since fetch, so a dead
phone connection ages the reading out naturally.

| Condition | Display |
|---|---|
| age within the warn threshold | Normal: colored number, arrow, delta, `Xm` |
| warn < age ≤ stale threshold | Dimmed number + `!` |
| age > stale threshold | Gray `--- STALE Xm` — never show an old number as current |

A confidently displayed old number is worse than an honest "no data." See
`WARN_AGE_MIN` / `STALE_AGE_MIN` in `source/BGData.mc` for the exact minute
values and the reasoning behind them.

Colors (when fresh, default manual bands): green in-range, yellow low/high,
red urgent-low/urgent-high — all configurable, always in mg/dL. When
`useNsThresholds` is on (default) and the server's response carries a `th`
block, those bands are used instead so every surface (server dashboard,
watch) agrees.

## Failure modes

| Failure | Behavior |
|---|---|
| Phone out of BLE range | Fetch fails with `-104` before leaving the watch → staleness display. The dominant failure mode by far. Not fixable in software |
| Phone reachable, its network is not | Fetch fails with `-300` beyond the phone → same staleness display |
| Server/tunnel down | HTTP error → last reading ages into stale display |
| Upstream data source stalls | Server should still respond with the last known reading and a high `age_min` → same stale UI, rather than erroring |
| Token leaked | Read-only glucose values, no PII; rotate the token server-side, then see the persisted-property gotcha below before assuming a reflash fixes it |
| `serverUrl`/`watchToken` missing from the build | `refresh()` stores the sentinel → "Set server URL" / "Set watch token" in the menu status line, the on-screen error line, and the glance. Never silent |

## Gotchas (hard-won — read before changing settings or glance code)

**Adding a new property does NOT initialize it on watches that _update_.**
Sideloading a new `.prg` over an existing install (same app id) keeps the
old persisted properties and **does not apply `properties.xml` defaults for
newly-added keys** — `Application.Properties.getValue` returns `null` for
them.
- **Rule:** any new setting needs an on-watch way to _write_ it (a `Menu2`
  item that calls `Application.Properties.setValue`), or the value stays
  whatever the code default is until the user does a **full uninstall +
  reinstall** (the only thing that re-applies `properties.xml` defaults).
- Corollary: a code default that means "unconfigured" is safer than one
  that silently picks a mode the user didn't choose — and whatever
  "unconfigured" does, it must be **visible on-wrist**, never a quiet early
  return.

**Changing the default of an EXISTING property also does nothing** — a
stored value beats the baked-in default forever, for the same reason.
Reflashing cannot rotate a credential; see [RELEASING.md](RELEASING.md) for
the actual fix (deleting the on-watch settings file).

**Glance/background scope can't touch resources.** `WatchUi.loadResource` /
`Rez.*` are not available in `(:glance)` or `(:background)` code — the
lookup throws Symbol Not Found _on-device_ and the glance renders as a
blank system card (it compiles fine, and the simulator won't catch it
unless you run glance mode specifically). This is why the glance title is a
**property** (`glanceTitle`), read via `Application.Properties`, not a
string resource. Keep glance/background code to Properties + Storage only.

**Type checking is off** (`project.typecheck = 0` in the jungles), so
neither of the above fails at build time. Test on hardware — specifically
the glance surface and a real background fetch — not just a clean compile.

## Non-goals

Low-glucose vibration alerts are **not** reliably possible from a Connect IQ
background service — real alerting should stay with your CGM app's own
notification path. Possible future extensions (same architecture, server
grows): last dose / IOB hint, treatment flags, mini sparkline in the full
view.
