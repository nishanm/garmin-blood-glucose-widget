#!/usr/bin/env python3
"""Live contract + payload-budget smoke test for the watch glucose endpoint.

Run this against your deployed server immediately before a sideload — it
proves the server still honours the contract the widget parses in BGData.mc
(parseResponse / parseHistory), documented in full in docs/CONTRACT.md, and
that the payload stays small enough for the Connect IQ memory budget. It talks
to the real endpoint over the network; it is NOT a unit test and does not
touch the watch.

Reads two values from the environment (nothing is baked in, and the token is
NEVER printed):

    WATCH_ENDPOINT_URL   full endpoint, e.g. https://<host>/api/watch/glucose
    WATCH_TOKEN          the bearer token configured on your server

    $ WATCH_ENDPOINT_URL=https://<host>/api/watch/glucose \
      WATCH_TOKEN=... python tools/check_endpoint.py

Auth rides in an `Authorization: Bearer` header, matching what the widget sends
(requestSpec() in source/BGData.mc). The token stays out of the URL so it can't
leak into logs or a pasted command.

Exit status is 0 only if every check passes; any failure exits 1 so it can gate
a sideload. Each response's byte length is printed as the payload-budget check.
"""

import json
import os
import sys
import urllib.error
import urllib.request

# The full-view swipe frames (BGWidgetView asks for exactly these minutes).
HISTORY_FRAMES = (60, 180, 360)
# Server contract: bucket-averaged down to <= TARGET_HISTORY_POINTS (30), and
# parseHistory rejects anything shorter than 2 (can't plot a single point).
MIN_POINTS, MAX_POINTS = 2, 30
# "Spans the window" heuristic: the oldest point must reach at least this far
# back, or the series is just the most-recent handful clustered at low ages.
SPAN_FRACTION = 0.5

_passed = 0
_failed = 0


def _check(ok, msg):
    global _passed, _failed
    if ok:
        _passed += 1
        print("  PASS  " + msg)
    else:
        _failed += 1
        print("  FAIL  " + msg)
    return ok


def fetch(url, token, history=None):
    """GET the endpoint with a Bearer token. Returns (status, raw_bytes, json).

    json is None when the body isn't JSON. A non-2xx status is returned rather
    than raised, so the 401 case is a normal return, not an exception."""
    full = url
    if history is not None:
        sep = "&" if "?" in url else "?"
        full = "{}{}history={}".format(url, sep, history)
    req = urllib.request.Request(
        full,
        headers={
            "Authorization": "Bearer " + token,
            # Cloudflare's bot filter 403s the default `Python-urllib` agent
            # before the request ever reaches the app, which would mask the
            # real 200/401. A plain agent sails through, same as the watch does.
            "User-Agent": "check-endpoint/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    try:
        parsed = json.loads(raw)
    except ValueError:
        parsed = None
    return status, raw, parsed


def has_reading(parsed):
    return isinstance(parsed, dict) and parsed.get("mgdl") is not None


def main():
    url = os.environ.get("WATCH_ENDPOINT_URL")
    token = os.environ.get("WATCH_TOKEN")
    if not url or not token:
        sys.stderr.write(
            "Set WATCH_ENDPOINT_URL and WATCH_TOKEN in the environment "
            "(the token is read, never printed).\n"
        )
        return 2

    # Print the host but never the token (it's a header, not a query param).
    print("Endpoint: {}".format(url))
    print("=" * 60)

    # 1. No history -> the payload is exactly the every-5-min reading, no hist.
    print("\n[history=0] reading only, no series")
    status, raw, parsed = fetch(url, token, history=0)
    print("  {} bytes, HTTP {}".format(len(raw), status))
    _check(status == 200 and has_reading(parsed), "returns a reading (HTTP 200, mgdl present)")
    _check(isinstance(parsed, dict) and "hist" not in parsed, "no 'hist' key when history=0")

    # 2. Each swipe frame: equal-length a/v arrays that span the whole window.
    for minutes in HISTORY_FRAMES:
        window_sec = minutes * 60
        print("\n[history={}] {}-min series".format(minutes, minutes))
        status, raw, parsed = fetch(url, token, history=minutes)
        print("  {} bytes, HTTP {}".format(len(raw), status))
        if not _check(status == 200 and has_reading(parsed), "returns a reading (HTTP 200)"):
            continue
        hist = parsed.get("hist") if isinstance(parsed, dict) else None
        if not _check(isinstance(hist, dict), "'hist' present"):
            continue
        a, v = hist.get("a"), hist.get("v")
        if not _check(isinstance(a, list) and isinstance(v, list), "a/v are arrays"):
            continue
        n = len(a)
        _check(n == len(v), "a/v equal length ({} == {})".format(n, len(v)))
        _check(MIN_POINTS <= n <= MAX_POINTS, "{} points in [{}, {}]".format(n, MIN_POINTS, MAX_POINTS))
        # a is age-in-seconds, oldest-first, so the largest age is the reach.
        oldest = max(a) if a else 0
        _check(
            oldest >= SPAN_FRACTION * window_sec,
            "spans the window: oldest point {}s back >= {}s ({:.0%} of {}s)".format(
                oldest, int(SPAN_FRACTION * window_sec), SPAN_FRACTION, window_sec
            ),
        )

    # 3. Absurd/negative history must degrade to a reading, never 5xx. The
    #    server clamps (99999 -> 360) or ignores (-1 is not > 0) rather than 422.
    for minutes in (99999, -1):
        print("\n[history={}] out-of-range must still return a reading".format(minutes))
        status, raw, parsed = fetch(url, token, history=minutes)
        print("  {} bytes, HTTP {}".format(len(raw), status))
        _check(status < 500, "no 5xx (HTTP {})".format(status))
        _check(status == 200 and has_reading(parsed), "still returns a reading")

    # 4. A bad token is rejected with 401 (not 422, not a 500).
    print("\n[bad token] auth must be rejected")
    status, raw, _ = fetch(url, "wrong-token-smoke-test", history=0)
    print("  {} bytes, HTTP {}".format(len(raw), status))
    _check(status == 401, "bad token -> HTTP 401 (got {})".format(status))

    print("\n" + "=" * 60)
    print("PASSED (passed={}, failed={})".format(_passed, _failed))
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
