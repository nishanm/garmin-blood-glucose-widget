import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Graphics;

// Shared helpers used by the glance view, the full widget view and the
// background service, so everything here must carry both annotations.
//
// One data source: whatever server implements docs/CONTRACT.md
// (GET <serverUrl> with `Authorization: Bearer <watchToken>` -- header only),
// which returns:
//   {"mgdl": 142, "trend": "flat", "arrow": "F", "delta": 3,
//    "ts": 1751700000, "age_min": 3}
//
// The watch deliberately does NOT know about Nightscout, Dexcom, or any other
// upstream source — that logic lives entirely on the server (see server/ and
// docs/CONTRACT.md). A `dataSource` property that let the watch pick a source
// directly was tried and removed: it duplicated a failover the server already
// does, and an earlier build proved it does worse than that — a mis-set source
// made every fetch bail before the network, silently killing the on-open/
// self-heal recovery. See docs/ARCHITECTURE.md.
(:glance, :background)
module BGData {
    const STORAGE_KEY = "reading";
    const ERROR_KEY = "lastErr";
    // Background-service outcome, tracked SEPARATELY from ERROR_KEY/STORAGE_KEY
    // because those two are written by both fetch paths and so cannot answer
    // "is the every-5-min service actually running?". Opening the widget fetches
    // in the foreground and refreshes them, which makes a dead background
    // service look identical to a healthy one -- exactly the blind spot that hid
    // a disarmed temporal event on 2026-08-16.
    const BG_FETCH_KEY = "bgFetch";
    const BG_ERROR_KEY = "bgErr";
    // Diagnostic ring, written by the BACKGROUND SERVICE AT FETCH TIME --
    // deliberately not via onBackgroundData like BG_FETCH_KEY/BG_ERROR_KEY are.
    // That distinction is the whole point: those two record what the watch
    // RECEIVED, so a fetch whose reply never lands, or whose Background.exit()
    // payload is overwritten before delivery, is invisible in them. Measured
    // 2026-08-19: the server answered 200 at 00:14/00:19/00:24 UTC while the
    // menu still reported a 73-minute-old last success.
    //
    // Each entry is [epochSec, responseCode, phoneConnected]. phoneConnected is
    // sampled HERE, at fetch time -- describeError() samples it at menu-render
    // time, which is why a -104 caused by the watch simply being out of range
    // renders as "Open Garmin Connect" and sent an investigation after the wrong
    // thing for two days.
    // Build version, shown in the menu next to the variant ("v4 · personal") so a
    // sideload is identifiable on-wrist — you can confirm the new PRG actually took
    // over the old one (an overwrite-update NOT applying is a known failure mode;
    // see ARCHITECTURE.md gotchas). Bump this when cutting a release. The variant
    // half comes from the Rez.Strings.BuildVariant resource, which the personal
    // overlay flips from "generic" to "personal" — see RELEASE.md.
    //
    // v4 (2026-08-08) — freshness pass. "Refresh now" sends ?live=1 so the server
    // reads Nightscout directly instead of its own database row, and the staleness
    // warning moved 10 min -> 7 min now that ingestion lag dropped from ~3m17s to
    // ~76 s.
    //
    // v5 (2026-08-12) — chart honesty + a swipe you can actually see. The plot's
    // ceiling now clears the urgent-high band instead of sitting below it, the
    // in-range zone is shaded rather than implied by one line, each point is
    // colored by its own value, and a swipe slides the trace instead of only
    // nudging the label.
    //
    // v6 (2026-08-12) — swipe polish. A swipe landing MID-SLIDE no longer re-bases
    // the animation onto the frame the previous slide was heading for, which used
    // to snap the moving trace back to centre before sliding it again (visible
    // swiping 60m -> 3h -> 6h quickly). Reversals re-base deliberately, since the
    // in-flight target is the closer match to what is on screen.
    //
    // Bumped from v5 rather than rebuilding it: a v5 BGGlance.prg was already
    // compiled at 09:29 today from the pre-fix source, so shipping this under the
    // same string would leave two different binaries both reporting "v5" and quietly
    // break the one check that tells you a sideload took.
    //
    // v7 (2026-08-15) — tell "phone out of range" apart from "Garmin Connect
    // asleep". Both surface as -104, but only the second is fixed by opening the
    // Connect app, and it's the one iOS causes constantly; the old shared "No phone
    // link" wording pointed at a Bluetooth connection that was never the problem.
    // A v6 BGGlance.prg was built on 08-12 and never sideloaded, so this ships as
    // v7 to keep one binary per version string.
    // v8 (2026-08-16) — a "Background" row reporting the every-5-min service on its
    // own. The Refresh sublabel cannot do this: both fetch paths write it, and
    // opening the menu refreshes it in the foreground, so a background service that
    // has been dead for hours still reads "Updated now". That blind spot is what
    // made a disarmed temporal event take a server-log read to find.
    // v9 (2026-08-16) — the v8 "Background" row is gone; the menu is back to three
    // items. Its status moved into the Refresh sublabel, which was spending itself
    // on lastFetchStatus() — already drawn on the full view, so the menu was
    // repeating it. A v8 PRG was built and handed over before this, so this ships
    // as v9 to keep one binary per version string.
    // v10 (2026-08-16) — codebase audit. One user-visible fix: the fetch-error line
    // and the "updating..." line were drawn at 87%h and 90%h unconditionally, and
    // their FONT_XTINY boxes overlap by ~10 px on the 390 px venu4 — so every
    // recovery attempt after an error (the commonest case there is) rendered the
    // two on top of each other. They are now one status slot. The rest is internal:
    // the ERR_* wording was written out in three places, requestSpec/
    // requestSpecFrames had copied auth preambles, and arrowText / parseHistory /
    // BGTheme.AXIS were dead, kept alive only by their own tests.
    // If the menu still reads v9, this build did NOT take.
    // v11 (2026-08-19) — diagnostics toggle. Measured over 26 h of server log:
    // 50 of ~312 background fetches never reached the server at all (21.9% miss
    // while awake, 7.1% asleep, one 95-minute blackout with the widget never
    // opened). The menu's auto-fetch age could not show any of it, because it
    // counts fetches the watch RECEIVED, not fetches it performed. This build adds
    // an at-fetch-time ring in the background context and, when the toggle is on,
    // attaches recent outcomes to the request so the server log pairs both legs.
    // Default OFF: it appends to requestSpec(), the safety-critical path.
    // v12 (2026-08-20) — the auto-fetch row stops lying about WHY. describeError
    // picked its wording from a LIVE connectivity sample taken when the menu was
    // opened, so an out-of-range -104 read back after the phone reconnected said
    // "Open Garmin Connect" — an app that was never involved. 26 h of ring data
    // settled it: 48/48 -104s had the phone out of range at fetch time, 0 while
    // connected. It now reads the flag the background service stored at fetch time.
    // v13 (2026-08-20) — the auto-fetch row stops lying about WHEN, too. v12 fixed
    // the error wording; the AGE was still read from BG_FETCH_KEY, written only on
    // the delivery side. Connect IQ keeps one Background.exit payload while the app
    // is closed, so a run of successes overwrites itself and one later failure
    // erases the lot. Measured the same day: the row read ">99m ago" while the
    // server had logged five successful fetches in the previous hour, the newest 37
    // minutes old. Age and error now both come from the fetch-time ring; the old
    // keys are a fallback for an empty ring only.
    // v14 (2026-08-21) - error labels checked against the SDK enum instead of
    // memory. -1001 was labelled "Timed out"; it is SECURE_CONNECTION_REQUIRED.
    // -2 (BLE_HOST_TIMEOUT) had no case and rendered as "Fetch error -2" - it
    // showed up for the first time on 2026-08-20. No behaviour change beyond
    // the two strings.
    // v15 (2026-08-21) - the diagnostic ring got deep enough and talkative enough
    // to describe a real blackout. Depth 20 -> 72 (100 min -> 6 h): at 20 the
    // newest 200 rolled off during a long outage and the Auto-fetch age fell back
    // to the stale delivered key, so v13's bug came back exactly when it mattered.
    // The d= payload is now adaptive - still 6 entries when healthy, widening back
    // through the oldest failure up to 30 - because during a blackout there are no
    // requests, so the first request after it is the only chance the server ever
    // gets to hear about it.
    // v16 (2026-08-22) - the build identity now rides the wire. Nothing in the
    // request said which build was running, so "is the new PRG actually on the
    // wrist" was answerable only by a human reading the menu. That cost a real
    // test on 2026-08-22: a d= payload was set up to discriminate v13 from v15
    // and could not, because a healthy ring renders identically on both. Worse,
    // a freshly sideloaded PRG that never re-armed is SILENT, and silence looks
    // exactly like a phone-link failure. Now the server log answers it.
    //
    // v17 (2026-08-23) - v= is now UNCONDITIONAL. v16 gated it on the
    // diagnostics toggle so the every-5-min path stayed byte-for-byte unchanged
    // with the toggle off. That gate was protecting against an UNMEASURED risk,
    // URL length, and the risk is now measured and gone: on 2026-08-23 a
    // 30-entry payload - DIAG_SEND_MAX, the widest sendWidth can emit, ~333
    // characters of d= - left the watch and returned HTTP 200 three separate
    // times. Against ~8 bytes, the gate cost the very thing v16 existed to buy:
    // turn diagnostics off, which is the plan the moment a -300 is caught, and
    // the build goes invisible again - exactly the blindness that kept "is the
    // new PRG actually on the wrist" open for four sessions.
    //
    // So the background request is no longer byte-for-byte identical to v15's:
    // it carries v= and nothing else. That is a deliberate, bounded change to
    // the safety-critical path, and the three "params are empty" tests now
    // assert v= is the ONE key present rather than counting zero.
    //
    // Lives HERE, not in BGMenu.mc, because that file is foreground-only (no
    // scope annotation) and requestSpec() is called from the BACKGROUND.
    // v18 (2026-08-30) - the d= payload pages backwards. The head is unchanged;
    // what is new is that a HEALTHY head's idle character budget is spent
    // reporting history a blackout stranded on the wrist. Measured 2026-08-27: a
    // 5 h outage saturated DIAG_SEND_MAX at exactly 30 entries (oldest age
    // 9002 s) and left 2.5 h unreportable. Raising that cap was rejected -- the
    // head widens BECAUSE the ring holds failures, so a payload too long to send
    // would keep itself too long and the fetch could not recover with
    // diagnostics on. The maximum URL is therefore UNCHANGED from v17: the
    // payload is capped at DIAG_SEND_MAX entries, which is exactly what v17's
    // head could already emit. See diagTokenPaged.
    // v19 (2026-09-01) - no behaviour change; the version exists to make a
    // flash self-verifying. v18 was reflashed with a rotated watchToken and
    // NOTHING in the request could tell the two builds apart: v= was identical,
    // so the only discriminator was whether the token 401'd -- which the server
    // ALSO caused by rotating. Two hypotheses, one observation, an hour lost.
    // Bump this on every flash whose payload differs, even when no code does.
    //
    // That flash also taught the real lesson: watchToken is an
    // Application.Properties value, and persisted properties are NOT
    // re-initialised from properties.xml on an overwrite-update. A stored token
    // beats the baked-in default forever, so changing the overlay and
    // reflashing CANNOT rotate the token -- only a delete-and-reinstall (or
    // editing the setting) can. See RELEASE.md section 1.
    const BUILD_VERSION = "v19";

    const DIAG_KEY = "diagLog";
    // Ring depth kept on-wrist. Was 20 (~100 min) and that was too shallow for
    // the thing the ring exists to survive: during a blackout there are no
    // requests, so the ring is the ONLY record, and once the last 200 rolls off
    // the auto-fetch age falls back to the stale delivered BG_FETCH_KEY -- v13's
    // bug returns exactly when a blackout is worst. Measured blackouts: 135 min
    // (27 entries) is the record, and 2026-08-21 18:50-20:20 UTC ran 90 min
    // (18 entries), two short of rolling the anchor off at depth 20. 72 is 6 h,
    // the same span as the app's longest chart frame.
    const DIAG_MAX = 72;
    // Entries attached to a normal request (~30 min of history). Kept at 6 so
    // the healthy every-5-min payload is unchanged; DIAG_SEND_MAX is what a
    // failure run widens to. See diagToken.
    const DIAG_SEND = 6;
    // Ceiling on the widened payload: ~2.5 h, which covers the 135-min record
    // with margin. Bounded by URL length, not by memory -- 30 entries is ~360
    // characters of query string (~460 for the whole URL), well inside any
    // plausible limit. Garmin publishes no makeWebRequest URL cap, so going
    // past this wants an on-wrist test rather than another guess.
    const DIAG_SEND_MAX = 30;
    // NOTE ON THE BUDGET, because a character cap was tried here first and was
    // WRONG. The obvious guard is "keep the payload under the ~333 characters
    // measured on 2026-08-23", but 333 is what a PARTICULAR payload measured,
    // not the head's maximum: 30 entries whose ages have reached five digits
    // render ~356, and a unit test caught exactly that. A character cap set to
    // 333 would therefore have throttled the HEAD -- the primary signal, and the
    // one thing that must never be constrained. The bound below is an ENTRY
    // count instead, and it is DIAG_SEND_MAX for a reason worth stating: v17's
    // head could already emit that many entries in the same format, so v18 can
    // never put a longer d= on the wire than v17 already could. That is a
    // no-regression guarantee on URL length rather than a fresh guess at a limit
    // nobody has measured. See diagTokenPaged.
    // Backfill sweep position: the timestamp of the oldest entry emitted so far
    // in the CURRENT sweep. Storage, not Properties -- and read null-safe,
    // because Storage is not re-initialized on an overwrite-update.
    const DIAG_SENT_KEY = "diagSentTo";
    const TH_KEY = "nsTh";
    const HIST_KEY = "hist";
    const MMOL_FACTOR = 18.018;

    // Don't join two points across a sensor gap — mirrors the endpoint's own
    // rule for suppressing delta across a gap. In line mode the chart lifts the
    // pen wherever two plotted points are further apart than this.
    const HIST_GAP_SEC = 15 * 60;

    // The full view's swipeable timeframes: index 0 (default, dots) through 2.
    // Minutes go on the wire (the endpoint's ?history=), seconds drive the
    // chart's x-axis. Kept as plain helpers (no resources) so they stay safe if
    // this glance/background module is compiled into those scopes.
    function tfCount() as Number { return 3; }

    function tfMinutes(idx as Number) as Number {
        if (idx == 1) { return 180; }
        if (idx == 2) { return 360; }
        return 60;
    }

    function tfWindowSec(idx as Number) as Number {
        return tfMinutes(idx) * 60;
    }

    function tfLabel(idx as Number) as String {
        if (idx == 1) { return "3 HR"; }
        if (idx == 2) { return "6 HR"; }
        return "60 MIN";
    }

    // Every swipe window as the endpoint's ?frames= CSV ("60,180,360"), built
    // from the tf table so it can never drift from the frames the view draws.
    // One ?frames= fetch returns all of them, so the full view warms all three
    // charts in a single round trip instead of one fetch per window.
    function allFramesCsv() as String {
        var csv = "";
        for (var i = 0; i < tfCount(); i++) {
            if (i > 0) { csv += ","; }
            csv += tfMinutes(i).toString();
        }
        return csv;
    }

    // Staleness tiers (minutes): <=7 normal, 7-20 dimmed warning,
    // >20 the number is hidden entirely — an old value displayed as if
    // current is worse than an honest "no data".
    //
    // WARN dropped 10 -> 7 on 2026-08-08, because 10 was calibrated for a
    // pipeline that no longer exists. Ingestion used to lag ~3m17s behind the
    // reading, so a perfectly healthy number could be ~8 min old and 10 was the
    // earliest threshold that wouldn't cry wolf. Server-side that lag is now
    // ~76 s (1-min polling; ~24 s of it is the Dexcom->Nightscout bridge and
    // cannot be removed), so with a 5-min CGM cadence a healthy reading is
    // <= ~6 min old. Past 7 min a cycle was genuinely missed, and the whole
    // point of the tier is that a stale number must LOOK different — at 10 an
    // 8-min-old value still rendered green and confident.
    const WARN_AGE_MIN = 7;
    const STALE_AGE_MIN = 20;

    // Error sentinels for unconfigured settings (rendered as setup hints).
    const ERR_NO_URL = -100;
    const ERR_NO_TOKEN = -101;

    // --- configuration ---------------------------------------------------

    function serverUrl() as String? {
        var url = Application.Properties.getValue("serverUrl");
        if (!(url instanceof String) || url.length() == 0) {
            return null;
        }
        return url;
    }

    function watchToken() as String? {
        var token = Application.Properties.getValue("watchToken");
        if (!(token instanceof String) || token.length() == 0) {
            return null;
        }
        return token;
    }

    // Glance title is a PROPERTY, not a string resource: resources are not
    // visible in glance scope unless jungle-annotated, so loadResource from
    // the glance throws Symbol Not Found on-device — the glance crashes and
    // the system shows a blank card (learned the hard way).
    function glanceTitle() as String {
        var t = Application.Properties.getValue("glanceTitle");
        if (t instanceof String && t.length() > 0) {
            return t;
        }
        return "BG";
    }

    function useMmol() as Boolean {
        var v = Application.Properties.getValue("useMmol");
        return v instanceof Boolean ? v : false;
    }

    // Default ON: color bands come from Nightscout's own configured
    // thresholds, which the endpoint rides along with every reading, so every
    // surface (Nightscout site, watch) agrees. Turning it off falls back to
    // the manual threshold properties; turning it back on IS the "reset to
    // Nightscout" action.
    function useNsThresholds() as Boolean {
        var v = Application.Properties.getValue("useNsThresholds");
        return v instanceof Boolean ? v : true;
    }

    // Default OFF. When ON, the background request carries a compact record of
    // recent fetch outcomes (see diagToken) so the SERVER LOG becomes a
    // two-sided ledger: the request arriving proves the request leg, and its
    // d= payload reports what the watch saw for the preceding attempts. That
    // pairing is the only thing that separates "reply never came back" from
    // "reply came back but the delivery queue dropped it" -- both leave
    // identical state on the wrist.
    //
    // Off by default because it appends to requestSpec(), the every-5-min
    // safety-critical path that is otherwise byte-for-byte unchanged.
    function useDiagnostics() as Boolean {
        var v = Application.Properties.getValue("diagnostics");
        return v instanceof Boolean ? v : false;
    }

    function numberProp(key as String, fallback as Number) as Number {
        var v = Application.Properties.getValue(key);
        return v instanceof Number ? v : fallback;
    }

    // One place that knows how to ask for a reading. Returns {"url",
    // "params", "headers"} ready for makeWebRequest (headers carries the
    // Authorization: Bearer token), or {"err" => ERR_*} when the
    // baked-in settings are missing — used by both the background service and
    // the full view's on-demand refresh, so the two fetch paths can never
    // disagree. Callers MUST surface an "err" result (store it) rather than
    // returning quietly: a silent bail here is invisible on-wrist.
    //
    // requestSpec asks for the reading and NOTHING else — no history — so the
    // background service's request and response stay byte-for-byte what they
    // were before charting existed: the every-5-min path that keeps the number
    // alive cannot regress because of a chart. Only the full view (more memory,
    // and the only thing that plots) asks for series, via requestSpecFrames.
    //
    // It used to take a historyMinutes argument for a single-window fetch. The
    // ?frames= path replaced that in 2026-07-29 and nothing has passed a
    // non-zero value since, so the parameter only made the safety-critical path
    // look like it had a mode it does not have.
    // The URL + auth half of a request spec, or {"err" => ERR_*} when the
    // baked-in settings are missing. Both public spec builders below start
    // here, so there is exactly ONE place that decides how this app
    // authenticates and exactly one missing-config contract — they cannot
    // drift apart the way two copied preambles eventually would.
    //
    // Token rides in an Authorization: Bearer header, not the query string, so
    // it stays out of Cloudflare logs and any URL pasted for debugging. The
    // server is header-only (the legacy ?token= query path was removed
    // 2026-07-24).
    // (No `private` — Monkey C allows access modifiers on class members only,
    // not on module-scope functions. Treat this as internal to BGData.)
    function authSpec() as Dictionary {
        var url = serverUrl();
        if (url == null) {
            return { "err" => ERR_NO_URL };
        }
        var token = watchToken();
        if (token == null) {
            return { "err" => ERR_NO_TOKEN };
        }
        return {
            "url" => url,
            "params" => {},
            "headers" => { "Authorization" => "Bearer " + token }
        };
    }

    // v= is UNCONDITIONAL (v17) - see BUILD_VERSION. With diagnostics OFF this
    // returns authSpec() plus exactly one param, v=, and nothing else; the ring
    // payload d= remains gated, since that one really can grow to ~333 chars.
    // Set AFTER the err check, so a missing-config spec is still the bare error
    // sentinel the callers expect and never a half-formed request.
    function requestSpec() as Dictionary {
        var spec = authSpec();
        if (spec["err"] != null) {
            return spec;
        }
        spec["params"]["v"] = BUILD_VERSION;
        if (useDiagnostics()) {
            // v18: the payload may now carry backfill behind the head, so the
            // sweep position is advanced HERE, at the point the entries actually
            // go on the wire. Writing it before the response comes back is
            // deliberate -- a request that is built and then fails still put
            // those entries on the wire as far as this watch can tell, and the
            // server dedupes re-reports anyway. The opposite error, never
            // advancing until a confirmed 200, would stall the sweep for exactly
            // the blackout it exists to describe.
            var paged = diagTokenPaged(diagEntries(), Time.now().value(),
                                       diagSentTo());
            spec["params"]["d"] = paged[0];
            setDiagSentTo(paged[1]);
        }
        return spec;
    }

    // The full view's fetch: like requestSpec but asks for every swipe window
    // at once (?frames=60,180,360) so a single round trip returns the reading
    // AND all three chart series. The background service deliberately does NOT
    // use this — it stays on requestSpec(0), so the every-5-min payload that
    // keeps the number alive is byte-for-byte unchanged. Same header auth and
    // the same missing-config "err" contract as requestSpec.
    // `live` maps to the endpoint's ?live=1: it forces the server to read
    // Nightscout directly instead of serving its (possibly up to ~60 s older)
    // database row. ONLY the deliberate "Refresh now" press passes true —
    // fetch-on-open, the self-heal timer and swipe refills all pass false, so
    // the extra upstream call happens when the user actually asked for it.
    // It cannot beat the ~24 s Dexcom->Nightscout bridge delay; nothing can,
    // since Nightscout has no on-demand fetch.
    function requestSpecFrames(live as Boolean) as Dictionary {
        var spec = authSpec();
        if (spec["err"] != null) {
            return spec;
        }
        var params = spec["params"];
        params["frames"] = allFramesCsv();
        if (live) {
            params["live"] = 1;
        }
        return spec;
    }

    // --- parsing / storage -------------------------------------------------

    // Turns a watch-endpoint response into the small dictionary we persist.
    // Also used verbatim as the Background.exit() payload, so values must
    // stay persistable (strings + numbers only). "fetched" records when we
    // got the data so views can age it further at render time.
    function parseResponse(code as Number, data) as Dictionary {
        if (code != 200 || !(data instanceof Dictionary) || data["mgdl"] == null) {
            return { "err" => code };
        }
        var out = {
            "mgdl" => data["mgdl"].toNumber(),
            "arrow" => data["arrow"] instanceof String ? data["arrow"] : "?",
            "age_min" => data["age_min"] == null ? 0 : data["age_min"].toNumber(),
            "ts" => data["ts"] == null ? 0 : data["ts"].toNumber(),
            "fetched" => Time.now().value()
        };
        if (data["delta"] != null) {
            out["delta"] = data["delta"].toNumber();
        }
        // Nightscout's configured alert bands ride along with each reading
        // (flattened — background payloads must stay simple persistables).
        var th = data["th"];
        if (th instanceof Dictionary && th["ul"] != null && th["l"] != null
            && th["h"] != null && th["uh"] != null) {
            out["th_ul"] = th["ul"].toNumber();
            out["th_l"] = th["l"].toNumber();
            out["th_h"] = th["h"].toNumber();
            out["th_uh"] = th["uh"].toNumber();
        }
        return out;
    }

    function cachedThresholds() as Dictionary? {
        var th = Application.Storage.getValue(TH_KEY);
        return th instanceof Dictionary ? th : null;
    }

    // --- history (full view only) -----------------------------------------
    //
    // Kept deliberately OUT of parseResponse/store: the reading is the safety
    // -critical payload and its parse path stays exactly as it was. History
    // is a nice-to-have, so every unexpected shape here just returns null and
    // the chart doesn't draw — it can never cost us a reading.

    // Validate one {"a":[...],"v":[...]} series and stamp it with the fetch
    // time (so views age the whole series forward at render time), or null if
    // the shape is wrong. The single rejection gate for every series that
    // reaches the chart: the arrays must be
    // parallel and hold at least two points (one point can't plot, and a
    // length mismatch means something changed server-side and the plot maths
    // would index off the end).
    function validSeries(series, fetched as Number) as Dictionary? {
        if (!(series instanceof Dictionary)) {
            return null;
        }
        var a = series["a"];
        var v = series["v"];
        if (!(a instanceof Array) || !(v instanceof Array)) {
            return null;
        }
        if (a.size() != v.size() || a.size() < 2) {
            return null;
        }
        return { "a" => a, "v" => v, "fetched" => fetched };
    }

    // Parse + store the multi-frame ?frames= response: each window under
    // data["hists"] (keyed by minutes, e.g. "180") is validated like a single
    // series and cached under its own frame key, so one fetch warms every swipe
    // window. Returns how many frames were stored. Best-effort by the same
    // contract as storeHistory: a missing / thin / garbled frame is skipped and
    // whatever was cached for it stands, so no chart blanks — and the reading,
    // stored separately by the caller, is never put at risk by chart parsing.
    function storeAllFrames(code as Number, data) as Number {
        if (code != 200 || !(data instanceof Dictionary)) {
            return 0;
        }
        var hists = data["hists"];
        if (!(hists instanceof Dictionary)) {
            return 0;
        }
        var fetched = Time.now().value();
        var stored = 0;
        for (var i = 0; i < tfCount(); i++) {
            var minutes = tfMinutes(i);
            var parsed = validSeries(hists[minutes.toString()], fetched);
            if (parsed != null) {
                // Through storeHistory, not a raw setValue: it owns the
                // "hist<minutes>" key layout, and having a second place build
                // that key is how the two quietly stop agreeing.
                storeHistory(minutes, parsed);
                stored++;
            }
        }
        return stored;
    }

    // History is cached per timeframe (key "hist" + minutes, e.g. "hist360") so
    // swiping back to an already-loaded frame is instant and doesn't refetch.
    // null = keep whatever we already had for that frame: a failed or
    // history-less fetch must never wipe a good series out from under the chart.
    function storeHistory(minutes as Number, hist as Dictionary?) as Void {
        if (hist != null) {
            Application.Storage.setValue(HIST_KEY + minutes, hist);
        }
    }

    function cachedHistory(minutes as Number) as Dictionary? {
        var h = Application.Storage.getValue(HIST_KEY + minutes);
        return h instanceof Dictionary ? h : null;
    }

    // Successful readings replace the stored one; failures only record the
    // error, so the last good value keeps aging into the stale display
    // instead of vanishing.
    function store(parsed as Dictionary) as Void {
        if (parsed["mgdl"] != null) {
            Application.Storage.setValue(STORAGE_KEY, parsed);
            Application.Storage.deleteValue(ERROR_KEY);
            // Thresholds ridden along by the endpoint also refresh the
            // standalone cache, so colors survive periods where readings
            // arrive without them.
            if (parsed["th_ul"] != null && parsed["th_l"] != null
                && parsed["th_h"] != null && parsed["th_uh"] != null) {
                Application.Storage.setValue(TH_KEY, {
                    "th_ul" => parsed["th_ul"],
                    "th_l" => parsed["th_l"],
                    "th_h" => parsed["th_h"],
                    "th_uh" => parsed["th_uh"],
                    "fetched" => Time.now().value()
                });
            }
        } else {
            Application.Storage.setValue(ERROR_KEY, parsed["err"]);
        }
    }

    function lastReading() as Dictionary? {
        var r = Application.Storage.getValue(STORAGE_KEY);
        return r instanceof Dictionary ? r : null;
    }

    // The big centered message a view shows when there is NO reading to draw.
    // Both the glance and the full view render this state, and both used to
    // carry their own copy of the ERR_NO_URL / ERR_NO_TOKEN -> text mapping —
    // three copies in total counting describeError. A fourth sentinel would
    // have had to be added in three places and would silently have been missed
    // in two of them.
    function noDataMessage() as String {
        var err = lastError();
        if (err != null && err == ERR_NO_URL) {
            return "Set server URL";
        }
        if (err != null && err == ERR_NO_TOKEN) {
            return "Set watch token";
        }
        return "No data yet";
    }

    function lastError() as Number? {
        var e = Application.Storage.getValue(ERROR_KEY);
        return e instanceof Number ? e : null;
    }

    // One-line human summary of the most recent fetch, for the menu's
    // Refresh sublabel. Names the common failure codes and always shows the
    // raw number, so a stuck reading is diagnosable on-wrist. A stored error
    // means the LAST fetch failed even if an older reading is still shown.
    function lastFetchStatus() as String {
        var err = lastError();
        if (err != null) {
            return describeError(err, phoneConnected());
        }
        var reading = lastReading();
        if (reading == null) {
            return "No data yet";
        }
        return "Updated " + formatAge(reading) + " ago";
    }

    // Background-service bookkeeping. Called ONLY from the app's
    // onBackgroundData, so what it records is the every-5-min service's own
    // outcome, never a foreground fetch.
    //
    // The timestamp comes from parsed["fetched"], which parseResponse stamped
    // in the BACKGROUND context at the moment of the fetch -- not from
    // Time.now() here. Those differ: onBackgroundData can be delivered lazily
    // when the app next runs, so stamping here would report when you opened the
    // widget rather than when the service last succeeded, which is precisely the
    // lie this row exists to prevent.
    function storeFromBackground(parsed as Dictionary) as Void {
        store(parsed);
        if (parsed["mgdl"] != null) {
            var fetched = parsed["fetched"];
            Application.Storage.setValue(BG_FETCH_KEY,
                fetched instanceof Number ? fetched : Time.now().value());
            Application.Storage.deleteValue(BG_ERROR_KEY);
        } else {
            Application.Storage.setValue(BG_ERROR_KEY, parsed["err"]);
        }
    }

    // The newest well-formed ring entry, or null. One place that knows the
    // entry shape, so the three readers below cannot drift apart on it.
    function newestAttempt() as Array? {
        var log = diagEntries();
        if (log == null || log.size() == 0) {
            return null;
        }
        var e = log[log.size() - 1];
        if (e instanceof Array && e.size() >= 3 && e[0] instanceof Number
            && e[1] instanceof Number) {
            return e;
        }
        return null;
    }

    // --- the auto-fetch row reads FETCH-TIME state, not delivery state ------
    //
    // BG_FETCH_KEY / BG_ERROR_KEY are written by storeFromBackground, i.e. from
    // onBackgroundData -- the DELIVERY side. Connect IQ holds only the most
    // recent Background.exit() payload while the app is closed, so a run of
    // successes each overwrites the last and a single later failure erases all
    // of them. The row then reports the age of whatever success happened to be
    // delivered, which can be arbitrarily older than the truth.
    //
    // Caught exactly this 2026-08-20: the row read ">99m ago" while the server
    // had logged FIVE successful background fetches in the preceding hour, the
    // most recent 37 minutes earlier. It was counting from a success 132 min
    // old because every one after it was overwritten before delivery.
    //
    // The ring is written at fetch time and never depends on delivery, so it is
    // the authority. The old keys remain as a fallback for a fresh install
    // whose ring is still empty -- which is no worse than the old behaviour.
    function lastBackgroundFetch() as Number? {
        var log = diagEntries();
        if (log != null) {
            for (var i = log.size() - 1; i >= 0; i--) {
                var e = log[i];
                if (e instanceof Array && e.size() >= 3 && e[0] instanceof Number
                    && e[1] instanceof Number && e[1] == 200) {
                    return e[0];
                }
            }
        }
        var t = Application.Storage.getValue(BG_FETCH_KEY);
        return t instanceof Number ? t : null;
    }

    // Same reasoning inverted: BG_ERROR_KEY is deleted on success, but only on
    // a DELIVERED success -- so an old failure can sit there as "current" while
    // the ring shows the service has been fine for half an hour. The newest
    // ring entry decides: a 200 means there is no error to report.
    function lastBackgroundError() as Number? {
        var e = newestAttempt();
        if (e != null) {
            return e[1] == 200 ? null : e[1];
        }
        var v = Application.Storage.getValue(BG_ERROR_KEY);
        return v instanceof Number ? v : null;
    }

    // Append one background fetch outcome to the ring. Called from the
    // BACKGROUND context, immediately on the web-request callback -- before
    // Background.exit(), so an entry exists even when the payload it would have
    // carried is never delivered.
    function recordAttempt(code as Number, connected as Boolean) as Void {
        var log = Application.Storage.getValue(DIAG_KEY);
        if (!(log instanceof Array)) {
            log = [];
        }
        log.add([Time.now().value(), code, connected]);
        // One slice, not one per surplus entry. At depth 20 the while-loop cost
        // one whole-array copy per fetch and that was already the steady state;
        // it also degrades badly against a ring left oversized by a build that
        // lowered DIAG_MAX, which is precisely when you least want N copies in
        // a 64 KB background context.
        if (log.size() > DIAG_MAX) {
            log = log.slice(log.size() - DIAG_MAX, null);
        }
        Application.Storage.setValue(DIAG_KEY, log);
    }

    function diagEntries() as Array? {
        var log = Application.Storage.getValue(DIAG_KEY);
        return log instanceof Array ? log : null;
    }

    // How many of the newest entries diagToken should emit: DIAG_SEND normally,
    // or far enough back to include the oldest failure within DIAG_SEND_MAX.
    // Split out from diagToken so the widening rule is testable on its own.
    function sendWidth(entries as Array) as Number {
        var n = entries.size();
        var limit = n < DIAG_SEND_MAX ? n : DIAG_SEND_MAX;
        var width = DIAG_SEND;
        for (var i = 0; i < limit; i++) {
            var e = entries[n - 1 - i];   // i-th newest
            if (e instanceof Array && e.size() >= 2 && e[1] instanceof Number
                && e[1] != 200) {
                width = i + 1;            // ascending, so the last hit is the oldest
            }
        }
        return width < DIAG_SEND ? DIAG_SEND : width;
    }

    // Pure, so it is unit-testable without a background context.
    //
    // Renders the newest entries NEWEST-FIRST as
    // "<code>.<secondsAgo>.<phoneConnected>" joined by "_".
    //
    // ADAPTIVE WIDTH. An entry is only ever reported by a LATER request, and
    // during a blackout there is no later request -- so everything the server
    // will ever learn about a blackout has to fit in the payload of the first
    // request that gets through after it. A fixed six entries covers ~30 min,
    // which means a blackout longer than that could never be reconstructed
    // server-side no matter how deep the on-wrist ring got. That was the actual
    // limit on the -300 hunt, not DIAG_MAX.
    //
    // So: six when everything in range is a 200 (the healthy payload is
    // unchanged), and otherwise widen back through the OLDEST non-200 still
    // inside DIAG_SEND_MAX. Failures keep being re-reported until they roll out
    // of that window, which is deliberate -- re-reporting is what makes the
    // record survive a request that itself never lands, and the server-side
    // decode already dedupes on requestTime-minus-secondsAgo.
    //
    // Carries no glucose value and no token, by construction: a response code,
    // an integer, and a boolean. That must stay true -- this rides in the query
    // string, which is exactly why the auth token does not (it uses a header so
    // it stays out of Cloudflare logs).
    function diagToken(entries as Array?, nowTs as Number) as String {
        if (entries == null || entries.size() == 0) {
            return "none";
        }
        var start = entries.size() - sendWidth(entries);
        if (start < 0) {
            start = 0;
        }
        var out = "";
        for (var i = entries.size() - 1; i >= start; i--) {
            if (out.length() > 0) {
                out += "_";
            }
            out += diagEntry(entries[i], nowTs);
        }
        return out;
    }

    // Head plus as much older history as the character budget still allows.
    // Returns [token, newSweepPosition]; PURE, so the caller owns the cursor and
    // this stays unit-testable without a background context.
    //
    // THE GAP THIS CLOSES. Every entry normally reaches the server the moment it
    // is recorded, because the head always carries the newest sendWidth()
    // entries and a new entry is therefore in the very next request. Except
    // during a blackout, when there IS no next request. The recovery request
    // widens to DIAG_SEND_MAX and describes the newest 2.5 h of the outage;
    // anything older was never reported and never would be, because every later
    // head slides forward past it. Measured 2026-08-27: a 5 h outage produced a
    // recovery payload of exactly 30 entries with the oldest at age 9002 s --
    // the cap, saturated, with 2.5 h of the outage stranded on the wrist.
    //
    // WHY NOT JUST RAISE DIAG_SEND_MAX. Because the head widens precisely
    // BECAUSE the ring holds failures. If a widened payload were itself too long
    // for the watch leg to send, that failure would land in the ring, keep the
    // ring wide, and the fetch could not recover while diagnostics were on --
    // the diagnostic would break the path it exists to diagnose. So the maximum
    // must not move: this emits no more entries than v17's head already could.
    //
    // WHAT THIS DOES INSTEAD. The head is unchanged. A HEALTHY head is 6 entries
    // and leaves 24 of DIAG_SEND_MAX's 30 slots unused; the sweep spends those
    // idle slots paging backwards through what the blackout stranded. A ring
    // still holding failures widens the head and leaves no slack, so no backfill
    // happens -- correct, because a live outage outranks an old one.
    //
    // THE SWEEP RESETS ON A NEW INCIDENT. The cursor only moves backwards, so
    // once a sweep has reached the oldest entry, entries from a LATER blackout
    // would be newer than the cursor and would never qualify. Widening the head
    // is exactly the signal that a fresh incident exists, so that restarts the
    // sweep from behind the head.
    function diagTokenPaged(entries as Array?, nowTs as Number,
                            sentToTs as Number?) as Array {
        var token = diagToken(entries, nowTs);
        if (entries == null || entries.size() == 0) {
            return [token, sentToTs];
        }
        var width = sendWidth(entries);
        if (width > DIAG_SEND) {
            sentToTs = null;        // fresh incident: restart the sweep
        }
        var headStart = entries.size() - width;
        if (headStart < 0) {
            headStart = 0;
        }
        var oldest = entries[headStart][0];
        var emitted = width;        // the head already spent this many slots
        for (var i = headStart - 1; i >= 0; i--) {
            if (emitted >= DIAG_SEND_MAX) {
                break;              // never more entries than v17's head could
            }
            var e = entries[i];
            if (!(e instanceof Array) || e.size() < 3) {
                continue;
            }
            if (sentToTs != null && e[0] >= sentToTs) {
                continue;
            }
            token += "_" + diagEntry(e, nowTs);
            emitted++;
            oldest = e[0];
        }
        if (sentToTs != null && sentToTs < oldest) {
            oldest = sentToTs;      // the cursor only ever moves backwards
        }
        return [token, oldest];
    }

    // Null on a fresh install, and null on an overwrite-update that has not
    // written it yet -- Storage is NOT re-initialized from the manifest on an
    // upgrade, so this must read null-safe. Null means "no sweep in progress",
    // which makes the whole ring eligible; that is both the correct default and
    // a safe one, because the sweep is bounded by DIAG_SEND_MAX regardless.
    function diagSentTo() as Number? {
        var v = Application.Storage.getValue(DIAG_SENT_KEY);
        return v instanceof Number ? v : null;
    }

    function setDiagSentTo(ts as Number?) as Void {
        if (ts != null) {
            Application.Storage.setValue(DIAG_SENT_KEY, ts);
        }
    }

    // One ring entry as it goes on the wire. Extracted from diagToken so the
    // head and the backfill below cannot drift apart in format -- the decoder
    // parses both with one regex and would silently drop whichever diverged.
    function diagEntry(e as Array, nowTs as Number) as String {
        var age = nowTs - e[0];
        if (age < 0) {
            age = 0;   // clock moved backwards; don't emit junk
        }
        return e[1].format("%d") + "." + age.format("%d") + "." + (e[2] ? "1" : "0");
    }

    // Connectivity AS OF the most recent recorded attempt, not as of now.
    //
    // THE BUG this fixes: describeError() decides between "Open Garmin Connect"
    // and "No phone link" from `connected`, and backgroundStatus() used to
    // sample that LIVE, at menu-render time. A -104 caused by the watch being
    // out of range therefore rendered "Open Garmin Connect" as soon as the
    // phone came back -- naming an app that was never involved. That single
    // wrong word sent a two-day investigation after iOS background suspension.
    //
    // Settled 2026-08-20 by 26 h of on-wrist data: 48 of 48 `-104`s had
    // phoneConnected FALSE at fetch time, and zero occurred while connected.
    // The ring records the flag at fetch time, so read it from there.
    //
    // Falls back to a live sample only when the ring is empty (fresh install,
    // or storage cleared) -- which is the old behaviour, and no worse than it.
    function lastAttemptConnected() as Boolean {
        var e = newestAttempt();
        if (e != null && e[2] instanceof Boolean) {
            return e[2];
        }
        return phoneConnected();
    }

    function backgroundStatus() as String {
        return describeBackground(lastBackgroundFetch(), lastBackgroundError(),
            Time.now().value(), lastAttemptConnected());
    }

    // Pure, so the wording is testable without a background context.
    //
    // "Never run" is the important state, not a cosmetic one: registering the
    // temporal event happens in getInitialView()/getGlanceView(), so a freshly
    // sideloaded PRG has NO background service until the widget is opened once.
    // Until then the number simply sits there aging, which on the wrist is
    // indistinguishable from a phone-link failure.
    function describeBackground(lastTs as Number?, lastErr as Number?,
                                nowTs as Number, connected as Boolean) as String {
        // Phrased to read after the menu's "Auto-fetch: " prefix, so these are
        // sentence fragments rather than sentences.
        if (lastTs == null) {
            if (lastErr != null) {
                return "failing, " + describeError(lastErr, connected);
            }
            return "never run - open to arm";
        }
        var mins = (nowTs - lastTs) / 60;
        if (mins < 0) { mins = 0; }   // clock moved backwards; don't print junk
        var age;
        if (mins < 1) {
            age = "just now";
        } else if (mins > 99) {
            age = ">99m ago";
        } else {
            age = mins.format("%d") + "m ago";
        }
        if (lastErr != null) {
            return describeError(lastErr, connected) + "; ok " + age;
        }
        return "ran " + age;
    }

    // Is the phone paired AND in range right now? Split out so describeError
    // below can stay pure: getDeviceSettings() can't be faked from a unit test,
    // and the interesting logic is the branch, not the lookup.
    function phoneConnected() as Boolean {
        var s = System.getDeviceSettings();
        return s != null && s.phoneConnected;
    }

    // Error code -> the shortest sentence that points at the actual fix.
    //
    // -104 (BLE_CONNECTION_UNAVAILABLE) is the only one that needs `connected`,
    // and it's the reason this split exists. Every Connect IQ web request is
    // proxied by the Garmin Connect app on the phone — the watch has no network
    // of its own — so a request fails with -104 whenever that app is suspended,
    // EVEN THOUGH the BLE link is up and the watch still shows the phone as
    // connected. Calling that "No phone link" sends you to check a Bluetooth
    // connection that is perfectly fine, instead of to the app that actually
    // needs waking.
    //
    // On iOS this is the common case, not the exotic one. Measured 2026-08-15:
    // only 2 of the ~12 expected background fetches reached the server in an
    // hour, and both landed within seconds of the Connect app being opened by
    // hand. `connected == false` is the genuinely-out-of-range case and keeps
    // the original wording.
    //
    // Codes verified against SDK 9.2.0's Communications enum table rather
    // than memory (doc/Toybox/Communications.html), because two of them were
    // wrong here. They fall into two families, and the split is the watch's
    // two network legs:
    //
    //   -1..-5, -101..-104   BLE_*      watch <-> phone
    //   -200..-403           NETWORK_*  phone <-> internet
    //
    // So -104 (BLE_CONNECTION_UNAVAILABLE) and -2 (BLE_HOST_TIMEOUT) mean the
    // request never got off the wrist, while -300 (NETWORK_REQUEST_TIMED_OUT)
    // means it reached the phone and died beyond it. That matches the
    // evidence: neither kind ever reaches the server log, but only the BLE
    // ones carry conn=0. -300's wording stays neutral until the
    // phone-has-no-internet hypothesis is actually reproduced -- an attempt
    // on 2026-08-20 with WiFi and cellular off did not trigger one.
    function describeError(err as Number, connected as Boolean) as String {
        if (err == ERR_NO_URL) { return "Set server URL"; }
        if (err == ERR_NO_TOKEN) { return "Set watch token"; }
        if (err == 401) { return "Bad token (401)"; }
        if (err == 503) { return "No readings (503)"; }
        if (err == -104) {
            return connected ? "Open Garmin Connect" : "No phone link (-104)";
        }
        // -2 (BLE_HOST_TIMEOUT) is the same leg as -104: the phone did not
        // answer over BLE in time. First seen 2026-08-20 16:15 EDT, one
        // attempt, conn=0 -- it had no case at all until then and rendered
        // as the bare "Fetch error -2".
        if (err == -2) { return "Phone timeout (-2)"; }
        if (err == -300) { return "Timed out (-300)"; }
        // -1001 is SECURE_CONNECTION_REQUIRED, NOT a timeout. It was lumped
        // in with -300 from the start and has never fired, so the wrong
        // label was never caught on the wrist -- only by reading the SDK.
        if (err == -1001) { return "Needs HTTPS (-1001)"; }
        return "Fetch error " + err;
    }

    // Effective age = server-reported age at fetch time + time since fetch,
    // so a dead phone connection makes the reading age out naturally.
    function ageMinutes(reading as Dictionary?) as Number? {
        if (reading == null) {
            return null;
        }
        var age = reading["age_min"];
        if (age == null) {
            age = 0;
        }
        var fetched = reading["fetched"];
        if (fetched != null) {
            var since = Time.now().value() - fetched;
            if (since > 0) {
                age += since / 60;
            }
        }
        return age.toNumber();
    }

    function isWarn(reading as Dictionary?) as Boolean {
        var age = ageMinutes(reading);
        return age != null && age > WARN_AGE_MIN && age <= STALE_AGE_MIN;
    }

    function isStale(reading as Dictionary?) as Boolean {
        var age = ageMinutes(reading);
        return age == null || age > STALE_AGE_MIN;
    }

    // --- display helpers ---------------------------------------------------

    function formatBg(mgdl as Number) as String {
        if (useMmol()) {
            return (mgdl / MMOL_FACTOR).format("%.1f");
        }
        return mgdl.format("%d");
    }

    function formatDelta(reading as Dictionary) as String {
        var delta = reading["delta"];
        if (delta == null) {
            return "";
        }
        if (useMmol()) {
            var d = delta / MMOL_FACTOR;
            return (d >= 0 ? "+" : "-") + d.abs().format("%.1f");
        }
        return (delta >= 0 ? "+" : "-") + delta.abs().format("%d");
    }

    function formatAge(reading as Dictionary?) as String {
        var age = ageMinutes(reading);
        if (age == null) {
            return "";
        }
        if (age < 1) {
            return "now";
        }
        if (age > 99) {
            return ">99m";
        }
        return age.format("%d") + "m";
    }

    // NOTE: arrowText() lived here — ASCII stand-in arrows for the glance row.
    // Both the glance and the full view have drawn real polygon arrows via
    // BGArrows since 2026-07-18, so nothing but its own unit test had called it
    // for months. Removed 2026-08-16; BGArrows.draw is the only arrow renderer.
    //
    // The alert bands currently in effect, as {"ul","l","h","uh"} in mg/dL.
    // Bands come from Nightscout's thresholds when available (default) —
    // ridden along with the reading or from the standalone cache — else the
    // manual properties (green 90-180, yellow 80-89/181-230, red <80 / >230).
    // Shared by colorFor and the chart's target band so the number's color
    // and the band it's plotted against can never disagree.
    function bands(reading as Dictionary?) as Dictionary {
        var src = null;
        if (useNsThresholds()) {
            if (reading != null && reading["th_ul"] != null
                && reading["th_l"] != null && reading["th_h"] != null
                && reading["th_uh"] != null) {
                src = reading;
            } else {
                src = cachedThresholds();
            }
        }
        if (src != null && src["th_ul"] != null && src["th_l"] != null
            && src["th_h"] != null && src["th_uh"] != null) {
            return {
                "ul" => src["th_ul"],
                "l" => src["th_l"],
                "h" => src["th_h"],
                "uh" => src["th_uh"]
            };
        }
        return {
            "ul" => numberProp("urgentLow", 80),
            "l" => numberProp("lowThreshold", 90),
            "h" => numberProp("highThreshold", 180),
            "uh" => numberProp("urgentHigh", 230)
        };
    }

    // Thresholds are always in mg/dL; comparison happens on the raw mgdl
    // value so the mmol/L display toggle doesn't affect alert colors.
    function colorFor(reading as Dictionary) as Number {
        return colorForBands(reading["mgdl"], bands(reading));
    }

    // The same range logic against an explicit band set, so the chart can color
    // each plotted point by ITS OWN value instead of painting the whole series
    // with the current reading's color. That mattered: a 6 h trace running
    // 250 -> 110 used to render the 250s in green, which reads as "the last six
    // hours were fine" when they were not.
    function colorForBands(mgdl as Number, b as Dictionary) as Number {
        if (mgdl < b["ul"] || mgdl > b["uh"]) {
            return Graphics.COLOR_RED;
        }
        if (mgdl < b["l"] || mgdl > b["h"]) {
            return Graphics.COLOR_YELLOW;
        }
        return Graphics.COLOR_GREEN;
    }

    // --- chart vertical frame ----------------------------------------------
    //
    // The plot's mg/dL frame. Still FIXED per render — deliberately never
    // auto-fit to the data, because a scale that tightens around a flat trace
    // magnifies noise into fake drama — but derived from the bands rather than
    // hardcoded, so the alert lines are always drawable inside it.
    //
    // The old constant ceiling of 220 sat BELOW the urgent-high band (230 from
    // Nightscout), which had two consequences: the urgent-high line could never
    // be drawn at all, and every reading from 220 upward clamped to the same
    // pixel row — 225 and 350 looked identical on the wrist. FRAME_PAD of
    // headroom past each urgent band fixes both. Anything still outside clamps,
    // but it now clamps visibly BEYOND a drawn urgent line, so the chart can no
    // longer under-report a high.
    //
    // Identical for all three swipe windows (it depends only on the bands), so
    // the y-axis never jumps when you swipe and the two traces in a swipe
    // transition share one scale.
    const FRAME_LO_BASE = 40;
    const FRAME_HI_BASE = 220;
    const FRAME_PAD = 20;

    function frameLo(b as Dictionary) as Number {
        var lo = FRAME_LO_BASE;
        if (b["ul"] - FRAME_PAD < lo) {
            lo = b["ul"] - FRAME_PAD;
        }
        return lo < 0 ? 0 : lo;
    }

    function frameHi(b as Dictionary) as Number {
        var hi = FRAME_HI_BASE;
        if (b["uh"] + FRAME_PAD > hi) {
            hi = b["uh"] + FRAME_PAD;
        }
        return hi;
    }

    // One-line description of the bands currently in force, for the menu
    // toggle's sublabel. The toggle used to read "Bands from Nightscout",
    // which said where the numbers come from but never what they ARE — so
    // there was no way to tell on-wrist what flipping it would change (and,
    // when the manual fallbacks happen to match Nightscout exactly, that it
    // would change nothing at all). Raw mg/dL even under the mmol display
    // toggle: thresholds are always stored and compared in mg/dL.
    function bandsSummary() as String {
        var b = bands(lastReading());
        return (useNsThresholds() ? "NS" : "Manual") + " · "
            + b["ul"].format("%d") + "-" + b["l"].format("%d") + "-"
            + b["h"].format("%d") + "-" + b["uh"].format("%d");
    }
}
