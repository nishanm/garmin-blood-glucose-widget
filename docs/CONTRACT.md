# Server contract

The watch talks to exactly one endpoint. This is the full contract the
parser in `source/BGData.mc` (`parseResponse`, `storeAllFrames`,
`validSeries`) actually implements — read this before writing a server.

## Auth

`GET <serverUrl>` with header `Authorization: Bearer <watchToken>`.
**Header only** — a token in the query string ends up in access logs and
any proxy/CDN logs in front of the server, so the server must not accept
`?token=` as a fallback.

## Reading (every request)

```json
{
  "mgdl": 142,
  "trend": "flat",
  "arrow": "F",
  "delta": 3,
  "ts": 1751700000,
  "age_min": 3,
  "th": { "ul": 80, "l": 90, "h": 180, "uh": 230 }
}
```

- `mgdl` — required. Anything else missing or malformed and the widget
  treats the response as a failure.
- `arrow` — single ASCII code: `U2 U U4 F D4 D D2 ? !`. **No Unicode
  arrows** — Garmin's fonts don't reliably have the glyphs; the watch draws
  the arrow itself from this code (`source/BGArrows.mc`). `trend` (a free-form
  string like `flat` / `FortyFiveUp` / `fortyFiveUp`) rides along for
  human/debug readability but the widget does not parse it — normalize
  whatever your upstream source calls trends into the ASCII `arrow` code
  server-side.
- `age_min` — computed **server-side**, so a skewed watch clock can't lie
  about staleness. This is what drives the safety-critical staleness
  display (see below).
- `delta` — vs. the previous reading; omit or send `null` when readings
  are more than 15 minutes apart, so a sensor gap doesn't produce a
  nonsense delta.
- `th` — optional. The alert thresholds currently in effect upstream
  (e.g. your Nightscout instance's configured bands), in mg/dL. When
  present and `useNsThresholds` is on (the default), the widget colors the
  reading and chart against these instead of its own manual properties, so
  every surface agrees. Send all four sub-fields or omit the whole object —
  a partial `th` is ignored.
- Errors: `401` bad token, `503` no readings available.

## History — `?frames=60,180,360` (current)

The full view's three swipeable chart windows (60 min / 3 h / 6 h) are
requested in a single call:

```
GET <serverUrl>?frames=60,180,360
```

```json
{
  "mgdl": 142,
  "...": "...same reading fields as above...",
  "hists": {
    "60":  { "a": [58, 301, ...], "v": [142, 138, ...] },
    "180": { "a": [58, 301, ...], "v": [142, 138, ...] },
    "360": { "a": [58, 301, ...], "v": [142, 138, ...] }
  }
}
```

- Each window is two **parallel flat arrays**, not per-point objects —
  every byte matters on the watch.
- `a` — each point's age in **seconds** at response time, oldest first,
  same server-computed basis as `age_min`.
- `v` — the mg/dL value at that point.
- Bucket-average each window down to **at most 30 points** spanning the
  whole requested window, so a 6-hour frame smooths instead of truncating
  to the most recent points. The widget rejects (silently drops the chart
  for) any window with fewer than 2 points — one point can't plot.
- Empty buckets should be dropped rather than interpolated, so a sensor
  gap survives as a visible gap.
- Any frame missing or malformed just doesn't draw a chart for that
  window; it never affects the reading itself.
- The background service (the every-5-minute fetch) **never** requests
  `frames`. Only the full view does, when opened. Keep the plain-reading
  response byte-identical whether or not `frames` support exists, so the
  path that keeps the number alive can't regress because of a chart.

## History — `?history=<minutes>` (legacy, optional)

Older builds request one window at a time via `?history=<minutes>` and
expect a single top-level `hist` key with the same `{"a":[...],"v":[...]}`
shape as one entry of `hists` above. Support this if you want to stay
compatible with pre-`frames` builds; it's not required for a new
deployment. Clamp out-of-range values (e.g. `history=99999` → 360,
`history=-1` → ignored) rather than erroring — a chart is never worth a
failed reading.

## Ignore, don't error on

The watch also sends these query params. A compliant server must accept
and ignore unknown ones rather than 4xx/5xx on them:

- `v=<build>` — the widget's build string, on every request, for
  distinguishing "which build is on the wrist" in your own logs.
- `d=<diagnostics>` — only when the on-watch diagnostics toggle is on;
  a compact `code.secondsAgo.phoneConnected` history, `_`-joined. Carries
  no glucose value and no token.
- `live=1` — only on an explicit "Refresh now" press, asking the server to
  bypass any cache and read upstream directly.

## Constraints

- **Valid HTTPS required.** Garmin refuses `http://` and self-signed
  certificates outright.
- **Keep it small.** Connect IQ background services run in a tight memory
  budget (tens of KB total). Don't add fields beyond what's documented
  here without checking the impact in the simulator.
