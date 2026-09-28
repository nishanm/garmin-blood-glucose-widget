/**
 * Reference server for the BG Glance Garmin widget. Implements
 * ../../docs/CONTRACT.md against a Nightscout instance.
 *
 * Secrets (set with `wrangler secret put <NAME>`, never in wrangler.jsonc):
 *   WATCH_TOKEN       — the bearer token the watch must present
 *   NIGHTSCOUT_URL     — e.g. https://your-site.herokuapp.com (no trailing slash)
 *   NIGHTSCOUT_TOKEN   — a Nightscout read-only API token
 */

export interface Env {
  WATCH_TOKEN: string;
  NIGHTSCOUT_URL: string;
  NIGHTSCOUT_TOKEN: string;
}

interface NightscoutEntry {
  date: number; // epoch ms
  sgv: number;
  direction?: string;
}

interface NightscoutThresholds {
  bgHigh: number;
  bgTargetTop: number;
  bgTargetBottom: number;
  bgLow: number;
}

const CACHE_TTL_SECONDS = 30;
// One fetch covers every requested window: pull enough entries for the
// widest possible frame (6 h) plus slack for the delta/gap lookback.
const MAX_LOOKBACK_MINUTES = 6 * 60 + 15;
const MAX_HISTORY_POINTS = 30;
const GAP_MINUTES = 15;

// Nightscout's direction strings -> the single ASCII arrow code the watch
// draws itself (source/BGArrows.mc). Both "FortyFiveUp"-style (Nightscout)
// and "fortyFiveUp"-style (Dexcom Share) spellings are normalized here.
const ARROW_MAP: Record<string, string> = {
  doubleup: "U2",
  singleup: "U",
  fortyfiveup: "U4",
  flat: "F",
  fortyfivedown: "D4",
  singledown: "D",
  doubledown: "D2",
  "not computable": "?",
  none: "?",
  "rate out of range": "!",
};

function arrowFor(direction: string | undefined): string {
  if (!direction) return "?";
  return ARROW_MAP[direction.toLowerCase()] ?? "?";
}

// Constant-time string comparison so a timing side-channel can't be used to
// guess the token one byte at a time.
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const bufA = enc.encode(a);
  const bufB = enc.encode(b);
  if (bufA.length !== bufB.length) {
    // Still compare something of equal length so the early return above
    // doesn't itself leak length via timing on top of the obvious length check.
    return false;
  }
  let diff = 0;
  for (let i = 0; i < bufA.length; i++) {
    diff |= bufA[i] ^ bufB[i];
  }
  return diff === 0;
}

function checkAuth(request: Request, env: Env): boolean {
  const header = request.headers.get("Authorization") ?? "";
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return false;
  return timingSafeEqual(match[1], env.WATCH_TOKEN);
}

async function fetchJson<T>(url: string): Promise<T> {
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) {
    throw new Error(`upstream ${res.status} for ${url}`);
  }
  return res.json() as Promise<T>;
}

async function fetchEntries(env: Env): Promise<NightscoutEntry[]> {
  // count is generous: a 5-min CGM cadence over MAX_LOOKBACK_MINUTES is
  // ~75 points; padded for shorter/irregular cadences.
  const count = Math.ceil(MAX_LOOKBACK_MINUTES / 4) + 10;
  const url =
    `${env.NIGHTSCOUT_URL}/api/v1/entries.json?count=${count}` +
    `&token=${encodeURIComponent(env.NIGHTSCOUT_TOKEN)}`;
  const raw = await fetchJson<NightscoutEntry[]>(url);
  // Nightscout returns newest-first; sort ascending (oldest first) so
  // history bucketing and delta lookups can walk forward.
  return raw
    .filter((e) => typeof e.sgv === "number" && typeof e.date === "number")
    .sort((a, b) => a.date - b.date);
}

async function fetchThresholds(env: Env): Promise<NightscoutThresholds | null> {
  try {
    const url = `${env.NIGHTSCOUT_URL}/api/v1/status.json?token=${encodeURIComponent(env.NIGHTSCOUT_TOKEN)}`;
    const status = await fetchJson<{ settings?: { thresholds?: NightscoutThresholds } }>(url);
    return status.settings?.thresholds ?? null;
  } catch {
    // Thresholds are a nice-to-have (useNsThresholds falls back to the
    // watch's manual properties) — never fail the whole response over them.
    return null;
  }
}

// Bucket-average a window of entries down to at most MAX_HISTORY_POINTS,
// returned as parallel arrays {a: ageSeconds[], v: mgdl[]}, oldest first.
// Empty buckets are dropped so a sensor gap survives as a visible gap.
function bucketHistory(entries: NightscoutEntry[], windowMinutes: number, nowMs: number) {
  const windowStart = nowMs - windowMinutes * 60_000;
  const windowed = entries.filter((e) => e.date >= windowStart);
  if (windowed.length < 2) {
    return null;
  }
  const bucketMs = (windowMinutes * 60_000) / MAX_HISTORY_POINTS;
  const buckets = new Map<number, { sum: number; n: number; lastDate: number }>();
  for (const e of windowed) {
    const idx = Math.floor((e.date - windowStart) / bucketMs);
    const b = buckets.get(idx);
    if (b) {
      b.sum += e.sgv;
      b.n += 1;
      b.lastDate = e.date;
    } else {
      buckets.set(idx, { sum: e.sgv, n: 1, lastDate: e.date });
    }
  }
  const idxs = [...buckets.keys()].sort((x, y) => x - y);
  const a: number[] = [];
  const v: number[] = [];
  for (const idx of idxs) {
    const b = buckets.get(idx)!;
    a.push(Math.round((nowMs - b.lastDate) / 1000));
    v.push(Math.round(b.sum / b.n));
  }
  if (a.length < 2) {
    return null;
  }
  return { a, v };
}

function parseFrames(param: string | null): number[] {
  if (!param) return [];
  return param
    .split(",")
    .map((s) => parseInt(s.trim(), 10))
    .filter((n) => Number.isFinite(n) && n > 0)
    .map((n) => Math.min(n, MAX_LOOKBACK_MINUTES));
}

async function buildResponse(request: Request, env: Env): Promise<unknown> {
  const url = new URL(request.url);
  const nowMs = Date.now();

  const entries = await fetchEntries(env);
  if (entries.length === 0) {
    throw new HttpError(503, "no readings");
  }
  const latest = entries[entries.length - 1];
  const previous = entries.length >= 2 ? entries[entries.length - 2] : null;

  const age_min = Math.max(0, Math.round((nowMs - latest.date) / 60_000));
  let delta: number | null = null;
  if (previous && (latest.date - previous.date) / 60_000 <= GAP_MINUTES) {
    delta = latest.sgv - previous.sgv;
  }

  const body: Record<string, unknown> = {
    mgdl: latest.sgv,
    trend: latest.direction ?? "NOT COMPUTABLE",
    arrow: arrowFor(latest.direction),
    delta,
    ts: Math.round(latest.date / 1000),
    age_min,
  };

  const thresholds = await fetchThresholds(env);
  if (thresholds) {
    body.th = {
      ul: thresholds.bgLow,
      l: thresholds.bgTargetBottom,
      h: thresholds.bgTargetTop,
      uh: thresholds.bgHigh,
    };
  }

  const frames = parseFrames(url.searchParams.get("frames"));
  if (frames.length > 0) {
    const hists: Record<string, unknown> = {};
    for (const minutes of frames) {
      const hist = bucketHistory(entries, minutes, nowMs);
      if (hist) {
        hists[String(minutes)] = hist;
      }
    }
    body.hists = hists;
  } else {
    // Legacy single-window path: ?history=<minutes>, clamped rather than
    // erroring on out-of-range values (99999 -> max, -1 -> ignored).
    const historyParam = url.searchParams.get("history");
    if (historyParam) {
      const minutes = parseInt(historyParam, 10);
      if (Number.isFinite(minutes) && minutes > 0) {
        const hist = bucketHistory(entries, Math.min(minutes, MAX_LOOKBACK_MINUTES), nowMs);
        if (hist) {
          body.hist = hist;
        }
      }
    }
  }

  return body;
}

class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/api/watch/glucose") {
      return new Response("not found", { status: 404 });
    }
    if (request.method !== "GET") {
      return new Response("method not allowed", { status: 405 });
    }
    if (!checkAuth(request, env)) {
      return new Response(JSON.stringify({ error: "bad token" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }

    // Cache key deliberately excludes the Authorization header — the
    // response doesn't depend on it (there's only one valid token per
    // deployment) and Cache API can't vary on header values anyway.
    const cache = caches.default;
    const cacheKey = new Request(url.toString(), { method: "GET" });
    const cached = await cache.match(cacheKey);
    if (cached) {
      return cached;
    }

    try {
      const body = await buildResponse(request, env);
      const response = new Response(JSON.stringify(body), {
        status: 200,
        headers: {
          "content-type": "application/json",
          "cache-control": `public, max-age=${CACHE_TTL_SECONDS}`,
        },
      });
      ctx.waitUntil(cache.put(cacheKey, response.clone()));
      return response;
    } catch (err) {
      if (err instanceof HttpError) {
        return new Response(JSON.stringify({ error: err.message }), {
          status: err.status,
          headers: { "content-type": "application/json" },
        });
      }
      // Never leak upstream error detail (could include the Nightscout URL
      // or token) into the response body.
      return new Response(JSON.stringify({ error: "upstream error" }), {
        status: 503,
        headers: { "content-type": "application/json" },
      });
    }
  },
} satisfies ExportedHandler<Env>;
