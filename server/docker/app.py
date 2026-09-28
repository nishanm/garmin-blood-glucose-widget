"""Reference server for the BG Glance Garmin widget — Docker/FastAPI variant.

Implements ../../docs/CONTRACT.md against a Nightscout instance. See
../README.md for the Cloudflare Worker variant, which is the recommended
default (free HTTPS with a valid cert, no host to run).

Config comes from environment variables (see .env.example):
    WATCH_TOKEN        the bearer token the watch must present
    NIGHTSCOUT_URL      e.g. https://your-site.herokuapp.com (no trailing slash)
    NIGHTSCOUT_TOKEN    a Nightscout read-only API token

Run: uvicorn app:app --host 0.0.0.0 --port 8000
Note: .env changes need a container rebuild/recreate, not a stop/start —
uvicorn reads the environment once at process start.
"""

import hmac
import os
import time
from typing import Optional

import httpx
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse

WATCH_TOKEN = os.environ["WATCH_TOKEN"]
NIGHTSCOUT_URL = os.environ["NIGHTSCOUT_URL"].rstrip("/")
NIGHTSCOUT_TOKEN = os.environ["NIGHTSCOUT_TOKEN"]

CACHE_TTL_SECONDS = 30
MAX_LOOKBACK_MINUTES = 6 * 60 + 15
MAX_HISTORY_POINTS = 30
GAP_MINUTES = 15

ARROW_MAP = {
    "doubleup": "U2",
    "singleup": "U",
    "fortyfiveup": "U4",
    "flat": "F",
    "fortyfivedown": "D4",
    "singledown": "D",
    "doubledown": "D2",
    "not computable": "?",
    "none": "?",
    "rate out of range": "!",
}

app = FastAPI()

_cache: dict = {}  # {"ts": float, "entries": [...], "thresholds": {...} | None}


def arrow_for(direction: Optional[str]) -> str:
    if not direction:
        return "?"
    return ARROW_MAP.get(direction.lower(), "?")


async def fetch_entries() -> list:
    count = MAX_LOOKBACK_MINUTES // 4 + 10
    url = f"{NIGHTSCOUT_URL}/api/v1/entries.json"
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(url, params={"count": count, "token": NIGHTSCOUT_TOKEN})
        resp.raise_for_status()
        raw = resp.json()
    entries = [e for e in raw if isinstance(e.get("sgv"), (int, float)) and isinstance(e.get("date"), (int, float))]
    entries.sort(key=lambda e: e["date"])
    return entries


async def fetch_thresholds() -> Optional[dict]:
    try:
        url = f"{NIGHTSCOUT_URL}/api/v1/status.json"
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(url, params={"token": NIGHTSCOUT_TOKEN})
            resp.raise_for_status()
            status = resp.json()
        return status.get("settings", {}).get("thresholds")
    except Exception:
        # Thresholds are a nice-to-have (useNsThresholds falls back to the
        # watch's manual properties) — never fail the whole response over them.
        return None


async def cached_upstream() -> dict:
    now = time.monotonic()
    if _cache and now - _cache["ts"] < CACHE_TTL_SECONDS:
        return _cache
    entries = await fetch_entries()
    thresholds = await fetch_thresholds()
    _cache.update(ts=now, entries=entries, thresholds=thresholds)
    return _cache


def bucket_history(entries: list, window_minutes: int, now_ms: float) -> Optional[dict]:
    window_start = now_ms - window_minutes * 60_000
    windowed = [e for e in entries if e["date"] >= window_start]
    if len(windowed) < 2:
        return None
    bucket_ms = (window_minutes * 60_000) / MAX_HISTORY_POINTS
    buckets: dict = {}
    for e in windowed:
        idx = int((e["date"] - window_start) // bucket_ms)
        b = buckets.setdefault(idx, {"sum": 0, "n": 0, "last": 0})
        b["sum"] += e["sgv"]
        b["n"] += 1
        b["last"] = e["date"]
    a, v = [], []
    for idx in sorted(buckets):
        b = buckets[idx]
        a.append(round((now_ms - b["last"]) / 1000))
        v.append(round(b["sum"] / b["n"]))
    if len(a) < 2:
        return None
    return {"a": a, "v": v}


def parse_frames(param: Optional[str]) -> list:
    if not param:
        return []
    out = []
    for part in param.split(","):
        try:
            n = int(part.strip())
        except ValueError:
            continue
        if n > 0:
            out.append(min(n, MAX_LOOKBACK_MINUTES))
    return out


@app.get("/api/watch/glucose")
async def glucose(
    request: Request,
    authorization: str = Header(default=""),
    frames: Optional[str] = Query(default=None),
    history: Optional[str] = Query(default=None),
):
    prefix = "Bearer "
    token = authorization[len(prefix):] if authorization.startswith(prefix) else ""
    # Constant-time comparison so a timing side-channel can't be used to
    # guess the token one byte at a time.
    if not hmac.compare_digest(token, WATCH_TOKEN):
        return JSONResponse({"error": "bad token"}, status_code=401)

    try:
        state = await cached_upstream()
    except httpx.HTTPError:
        return JSONResponse({"error": "upstream error"}, status_code=503)

    entries = state["entries"]
    if not entries:
        return JSONResponse({"error": "no readings"}, status_code=503)

    now_ms = time.time() * 1000
    latest = entries[-1]
    previous = entries[-2] if len(entries) >= 2 else None

    age_min = max(0, round((now_ms - latest["date"]) / 60_000))
    delta = None
    if previous and (latest["date"] - previous["date"]) / 60_000 <= GAP_MINUTES:
        delta = latest["sgv"] - previous["sgv"]

    body: dict = {
        "mgdl": latest["sgv"],
        "trend": latest.get("direction", "NOT COMPUTABLE"),
        "arrow": arrow_for(latest.get("direction")),
        "delta": delta,
        "ts": round(latest["date"] / 1000),
        "age_min": age_min,
    }

    th = state.get("thresholds")
    if th:
        body["th"] = {
            "ul": th.get("bgLow"),
            "l": th.get("bgTargetBottom"),
            "h": th.get("bgTargetTop"),
            "uh": th.get("bgHigh"),
        }

    frame_list = parse_frames(frames)
    if frame_list:
        hists = {}
        for minutes in frame_list:
            hist = bucket_history(entries, minutes, now_ms)
            if hist:
                hists[str(minutes)] = hist
        body["hists"] = hists
    elif history:
        try:
            minutes = int(history)
        except ValueError:
            minutes = 0
        if minutes > 0:
            hist = bucket_history(entries, min(minutes, MAX_LOOKBACK_MINUTES), now_ms)
            if hist:
                body["hist"] = hist

    return JSONResponse(body, headers={"Cache-Control": f"public, max-age={CACHE_TTL_SECONDS}"})
