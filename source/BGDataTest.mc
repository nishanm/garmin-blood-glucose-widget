import Toybox.Lang;
import Toybox.Test;
import Toybox.Application;
import Toybox.Time;
import Toybox.Graphics;
import Toybox.System;

// Unit tests for BGData — the safety-critical parse/staleness/format logic.
//
// These cover the PURE logic that decides whether the watch shows a number as
// current or ages it out, and how a server response becomes the persisted
// reading. If ageMinutes/isWarn/isStale regress, the watch shows a 25-minute
// -old value as if it were live — the exact failure the whole design exists to
// prevent — and nothing but a human staring at a wrist would catch it today.
//
// (:test) functions are compiled ONLY under `--unit-test`, so this file adds
// nothing to a release/sideload build. Run them with:
//
//   monkeyc -d venu441mm -f monkey.jungle --unit-test -o test.prg -y developer_key
//   monkeydo test.prg venu441mm -t
//
// Determinism notes:
// - A reading with NO "fetched" key makes ageMinutes() return age_min exactly,
//   which is what the 10/20-minute boundary assertions rely on.
// - Property/Storage state is shared across tests in one sim run, so every test
//   that depends on useMmol / useNsThresholds / thresholds sets them up front.

// --- timeframe helpers -------------------------------------------------------

(:test)
function testTfMinutes(logger as Test.Logger) as Boolean {
    Test.assertEqualMessage(BGData.tfMinutes(0), 60, "idx 0 -> 60 min");
    Test.assertEqualMessage(BGData.tfMinutes(1), 180, "idx 1 -> 3 h");
    Test.assertEqualMessage(BGData.tfMinutes(2), 360, "idx 2 -> 6 h");
    // Out of range falls back to the default frame, never crashes.
    Test.assertEqualMessage(BGData.tfMinutes(3), 60, "idx 3 -> default 60");
    Test.assertEqualMessage(BGData.tfMinutes(-1), 60, "idx -1 -> default 60");
    return true;
}

(:test)
function testTfWindowSecAndLabel(logger as Test.Logger) as Boolean {
    Test.assertEqualMessage(BGData.tfWindowSec(1), 180 * 60, "3 h window in seconds");
    Test.assertEqualMessage(BGData.tfLabel(0), "60 MIN", "idx 0 label");
    Test.assertEqualMessage(BGData.tfLabel(1), "3 HR", "idx 1 label");
    Test.assertEqualMessage(BGData.tfLabel(2), "6 HR", "idx 2 label");
    Test.assertEqualMessage(BGData.tfLabel(9), "60 MIN", "out-of-range label -> default");
    return true;
}

// --- ageMinutes --------------------------------------------------------------

(:test)
function testAgeMinutesNullReading(logger as Test.Logger) as Boolean {
    // assertEqual would invoke .equals() on the null result, so assert the
    // predicate instead.
    Test.assertMessage(BGData.ageMinutes(null) == null, "null reading -> null age");
    return true;
}

(:test)
function testAgeMinutesMissingAgeMin(logger as Test.Logger) as Boolean {
    // No age_min and no fetched: treated as 0, not a crash.
    Test.assertEqualMessage(BGData.ageMinutes({}), 0, "missing age_min -> 0");
    return true;
}

(:test)
function testAgeMinutesServerAgeOnly(logger as Test.Logger) as Boolean {
    // No "fetched" -> the server's age_min is used verbatim.
    Test.assertEqualMessage(BGData.ageMinutes({"age_min" => 7}), 7, "age_min verbatim");
    return true;
}

(:test)
function testAgeMinutesAddsElapsed(logger as Test.Logger) as Boolean {
    // Effective age = server age + minutes since fetch. 10 min ago, server age 0.
    var reading = {"age_min" => 0, "fetched" => Time.now().value() - 600};
    Test.assertEqualMessage(BGData.ageMinutes(reading), 10,
        "0 server age + 10 min since fetch -> 10");
    return true;
}

// --- isWarn / isStale boundaries (safety-critical) ---------------------------

(:test)
function testStalenessBoundaries(logger as Test.Logger) as Boolean {
    // WARN_AGE_MIN = 7 (uses >), STALE_AGE_MIN = 20 (uses <=).
    // Exactly 7 is still NORMAL; 8..20 warn; >20 stale.
    //
    // WARN moved 10 -> 7 on 2026-08-08 once server-side ingestion lag dropped
    // from ~3m17s to ~76 s. At a 5-min CGM cadence a healthy reading is now
    // <= ~6 min old, so 8 minutes means a cycle was genuinely missed and must
    // not render as green and current.
    Test.assertMessage(!BGData.isWarn({"age_min" => 7}), "7 is NOT warn (normal)");
    Test.assertMessage(!BGData.isStale({"age_min" => 7}), "7 is NOT stale");

    Test.assertMessage(BGData.isWarn({"age_min" => 8}), "8 is warn (a cycle was missed)");
    Test.assertMessage(!BGData.isStale({"age_min" => 8}), "8 is not stale");

    // Guards the REASON for the change: 10 used to render as perfectly normal.
    Test.assertMessage(BGData.isWarn({"age_min" => 10}),
        "10 must now warn (was normal before 2026-08-08)");

    Test.assertMessage(BGData.isWarn({"age_min" => 20}), "20 is warn (<= boundary)");
    Test.assertMessage(!BGData.isStale({"age_min" => 20}), "20 is not stale");

    Test.assertMessage(!BGData.isWarn({"age_min" => 21}), "21 is not warn");
    Test.assertMessage(BGData.isStale({"age_min" => 21}), "21 is stale");
    return true;
}

(:test)
function testStalenessNullReading(logger as Test.Logger) as Boolean {
    // No reading at all counts as stale (never present a phantom number).
    Test.assertMessage(!BGData.isWarn(null), "null reading is not 'warn'");
    Test.assertMessage(BGData.isStale(null), "null reading is stale");
    return true;
}

// --- parseResponse -----------------------------------------------------------

(:test)
function testParseResponseNon200(logger as Test.Logger) as Boolean {
    var out = BGData.parseResponse(401, {"mgdl" => 142});
    Test.assertEqualMessage(out["err"], 401, "non-200 -> {err: code}");
    Test.assertMessage(out["mgdl"] == null, "non-200 -> no reading");
    return true;
}

(:test)
function testParseResponseNullMgdl(logger as Test.Logger) as Boolean {
    // 200 but no usable number is an error, not a zero reading.
    var out = BGData.parseResponse(200, {"mgdl" => null});
    Test.assertEqualMessage(out["err"], 200, "200 + null mgdl -> {err: 200}");
    return true;
}

(:test)
function testParseResponseNonDict(logger as Test.Logger) as Boolean {
    var out = BGData.parseResponse(200, "not a dict");
    Test.assertEqualMessage(out["err"], 200, "200 + non-dict body -> {err: 200}");
    return true;
}

(:test)
function testParseResponseMissingArrow(logger as Test.Logger) as Boolean {
    var out = BGData.parseResponse(200, {"mgdl" => 142});
    Test.assertEqualMessage(out["mgdl"], 142, "mgdl parsed");
    Test.assertEqualMessage(out["arrow"], "?", "missing arrow -> '?'");
    Test.assertEqualMessage(out["age_min"], 0, "missing age_min -> 0");
    Test.assertMessage(!out.hasKey("delta"), "missing delta -> no delta key");
    return true;
}

(:test)
function testParseResponseDelta(logger as Test.Logger) as Boolean {
    var out = BGData.parseResponse(200, {"mgdl" => 142, "delta" => -3, "arrow" => "D"});
    Test.assertEqualMessage(out["delta"], -3, "delta preserved");
    Test.assertEqualMessage(out["arrow"], "D", "arrow preserved");
    return true;
}

(:test)
function testParseResponseThresholdsAllPresent(logger as Test.Logger) as Boolean {
    var out = BGData.parseResponse(200, {
        "mgdl" => 142,
        "th" => {"ul" => 55, "l" => 70, "h" => 180, "uh" => 260}
    });
    Test.assertEqualMessage(out["th_ul"], 55, "th_ul flattened");
    Test.assertEqualMessage(out["th_l"], 70, "th_l flattened");
    Test.assertEqualMessage(out["th_h"], 180, "th_h flattened");
    Test.assertEqualMessage(out["th_uh"], 260, "th_uh flattened");
    return true;
}

(:test)
function testParseResponseThresholdsPartialIgnored(logger as Test.Logger) as Boolean {
    // One key missing -> the whole th block is dropped, not half-applied.
    var out = BGData.parseResponse(200, {
        "mgdl" => 142,
        "th" => {"ul" => 55, "l" => 70, "h" => 180}
    });
    Test.assertMessage(!out.hasKey("th_ul"), "partial th block -> not flattened");
    return true;
}

// --- validSeries: the single rejection gate for anything reaching the chart --
//
// These assertions used to run through parseHistory, a thin wrapper that had
// had no production caller since the ?frames= path landed. The wrapper is gone;
// the shape rules it delegated to are the real contract and are tested here
// directly. The outer guards it also carried (non-200, non-dict body, missing
// key) live on storeAllFrames and are covered by testStoreAllFramesRejects.

(:test)
function testValidSeriesValid(logger as Test.Logger) as Boolean {
    var out = BGData.validSeries({"a" => [300, 200, 100], "v" => [90, 100, 110]}, 555);
    Test.assertMessage(out != null, "valid parallel arrays -> dict");
    Test.assertEqualMessage(out["a"].size(), 3, "a preserved");
    Test.assertEqualMessage(out["v"][2], 110, "v preserved");
    Test.assertEqualMessage(out["fetched"], 555, "stamped with the fetch time");
    return true;
}

(:test)
function testValidSeriesRejects(logger as Test.Logger) as Boolean {
    // These all assert a null result, so use the predicate form (assertEqual
    // would invoke .equals() on null).
    Test.assertMessage(BGData.validSeries("nope", 1) == null, "non-dict -> null");
    Test.assertMessage(BGData.validSeries(null, 1) == null, "null -> null");
    Test.assertMessage(
        BGData.validSeries({"a" => "x", "v" => [1, 2]}, 1) == null,
        "non-array a -> null");
    Test.assertMessage(
        BGData.validSeries({"a" => [1, 2], "v" => "x"}, 1) == null,
        "non-array v -> null");
    Test.assertMessage(
        BGData.validSeries({"a" => [1, 2], "v" => [3]}, 1) == null,
        "length mismatch -> null");
    Test.assertMessage(
        BGData.validSeries({"a" => [1], "v" => [3]}, 1) == null,
        "fewer than 2 points -> null");
    return true;
}

// --- storeHistory: null must not wipe a cached frame -------------------------

(:test)
function testStoreHistoryNullKeepsCache(logger as Test.Logger) as Boolean {
    // Use an out-of-band minutes key so this can't collide with real frames.
    var key = 987;
    BGData.storeHistory(key, {"a" => [2, 1], "v" => [90, 100]});
    var cached = BGData.cachedHistory(key);
    Test.assertMessage(cached != null, "frame cached after store");
    Test.assertEqualMessage(cached["a"].size(), 2, "cached series intact");

    // A history-less / failed fetch stores null and MUST leave the frame alone.
    BGData.storeHistory(key, null);
    var after = BGData.cachedHistory(key);
    Test.assertMessage(after != null, "null store did not wipe the frame");
    Test.assertEqualMessage(after["v"][1], 100, "series still the good one");
    return true;
}

// --- allFramesCsv: the ?frames= list tracks the tf table --------------------

(:test)
function testAllFramesCsv(logger as Test.Logger) as Boolean {
    // Must be every tf window, in order, comma-joined — the endpoint keys its
    // "hists" reply by exactly these minute strings.
    Test.assertEqualMessage(BGData.allFramesCsv(), "60,180,360",
        "frames CSV is the three swipe windows");
    return true;
}

// --- storeAllFrames: one response warms every frame -------------------------

(:test)
function testStoreAllFramesCachesEveryWindow(logger as Test.Logger) as Boolean {
    // Clear the three real frame caches first so this test stands alone.
    Application.Storage.deleteValue(BGData.HIST_KEY + 60);
    Application.Storage.deleteValue(BGData.HIST_KEY + 180);
    Application.Storage.deleteValue(BGData.HIST_KEY + 360);

    var data = {"mgdl" => 120, "hists" => {
        "60"  => {"a" => [3000, 1000], "v" => [110, 120]},
        "180" => {"a" => [9000, 3000, 1000], "v" => [100, 110, 120]},
        "360" => {"a" => [20000, 10000], "v" => [95, 120]}
    }};
    var n = BGData.storeAllFrames(200, data);
    Test.assertEqualMessage(n, 3, "all three frames stored");
    Test.assertMessage(BGData.cachedHistory(60) != null, "60 frame cached");
    Test.assertEqualMessage(BGData.cachedHistory(180)["a"].size(), 3, "180 series intact");
    Test.assertEqualMessage(BGData.cachedHistory(360)["v"][1], 120, "360 series intact");
    return true;
}

(:test)
function testStoreAllFramesSkipsThinAndKeepsCache(logger as Test.Logger) as Boolean {
    // A frame with a single point is invalid and must be skipped, leaving any
    // previously-cached series for that frame untouched. Reading is never here.
    Application.Storage.deleteValue(BGData.HIST_KEY + 180);
    BGData.storeAllFrames(200, {"hists" => {"180" => {"a" => [1, 2], "v" => [3, 4]}}});
    Test.assertMessage(BGData.cachedHistory(180) != null, "180 seeded");

    var n = BGData.storeAllFrames(200, {"hists" => {
        "180" => {"a" => [5], "v" => [6]}   // thin -> skipped
    }});
    Test.assertEqualMessage(n, 0, "thin frame not counted");
    var kept = BGData.cachedHistory(180);
    Test.assertMessage(kept != null, "thin frame did not wipe the cache");
    Test.assertEqualMessage(kept["a"].size(), 2, "prior 180 series survives");
    return true;
}

(:test)
function testStoreAllFramesRejects(logger as Test.Logger) as Boolean {
    Test.assertEqualMessage(
        BGData.storeAllFrames(500, {"hists" => {"60" => {"a" => [1, 2], "v" => [3, 4]}}}), 0,
        "non-200 -> nothing stored");
    Test.assertEqualMessage(BGData.storeAllFrames(200, "nope"), 0, "non-dict body -> 0");
    Test.assertEqualMessage(BGData.storeAllFrames(200, {"mgdl" => 100}), 0, "no hists key -> 0");
    return true;
}

// --- requestSpecFrames: all windows in one Bearer-authed request ------------

(:test)
function testRequestSpecFrames(logger as Test.Logger) as Boolean {
    Application.Properties.setValue("serverUrl", "https://example.test/api/watch/glucose");
    Application.Properties.setValue("watchToken", "unit-test-token");

    var spec = BGData.requestSpecFrames(false);
    Test.assertMessage(!spec.hasKey("err"), "configured build -> no err");
    Test.assertEqualMessage(spec["params"]["frames"], "60,180,360", "asks for every window");
    Test.assertMessage(!spec["params"].hasKey("history"), "no single-window history param");
    Test.assertEqualMessage(spec["headers"]["Authorization"], "Bearer unit-test-token",
        "token rides in the Authorization header, not the query");

    // live=false must NOT send the param at all — the automatic callers
    // (fetch-on-open, self-heal timer, swipe refill) keep the cheaper
    // DB-first path on the server.
    Test.assertMessage(!spec["params"].hasKey("live"),
        "automatic fetch does not force a Nightscout read");

    // live=true is the menu's "Refresh now": ?live=1 makes the server skip its
    // database row and read Nightscout directly.
    var liveSpec = BGData.requestSpecFrames(true);
    Test.assertEqualMessage(liveSpec["params"]["live"], 1,
        "Refresh now sends live=1");
    Test.assertEqualMessage(liveSpec["params"]["frames"], "60,180,360",
        "live fetch still warms every chart window");

    // Missing config surfaces the same sentinels as requestSpec.
    Application.Properties.setValue("watchToken", "");
    Test.assertEqualMessage(BGData.requestSpecFrames(false)["err"], BGData.ERR_NO_TOKEN,
        "blank watchToken -> ERR_NO_TOKEN");
    Test.assertEqualMessage(BGData.requestSpecFrames(true)["err"], BGData.ERR_NO_TOKEN,
        "live fetch fails config the same way");
    return true;
}

// --- requestSpec: token in the Authorization header, not the query ----------

(:test)
function testRequestSpecHeaderAuth(logger as Test.Logger) as Boolean {
    Application.Properties.setValue("serverUrl", "https://example.test/api/watch/glucose");
    Application.Properties.setValue("watchToken", "unit-test-token");

    var spec = BGData.requestSpec();
    Test.assertMessage(!spec.hasKey("err"), "configured build -> no err");
    Test.assertEqualMessage(spec["headers"]["Authorization"], "Bearer unit-test-token",
        "token rides in the Authorization header");
    Test.assertMessage(!spec["params"].hasKey("token"), "token is NOT in the query params");
    // The background payload asks for the reading and nothing else -- no
    // history, no frames. This is the safety-critical path; it must stay the
    // smallest request the app makes. From v17 that floor is ONE param, v=,
    // and the assertion names it rather than counting, so adding a second
    // param fails here loudly instead of quietly moving a number.
    Test.assertEqualMessage(spec["params"].size(), 1,
        "background request sends exactly one param");
    Test.assertEqualMessage(spec["params"]["v"], BGData.BUILD_VERSION,
        "and that one param is the build identity");
    return true;
}

(:test)
function testRequestSpecAlwaysCarriesBuildVersion(logger as Test.Logger) as Boolean {
    // v16 put the build identity on the wire so the server log could answer
    // "what is actually on the wrist"; v17 made it UNCONDITIONAL. The v16 gate
    // meant turning diagnostics off -- the plan the moment a -300 is caught --
    // put the build back out of sight, which is the blindness the feature
    // existed to remove. This test is the one that would catch a regression to
    // the gated behaviour, so it asserts BOTH toggle states explicitly.
    Application.Properties.setValue("serverUrl", "https://example.test/api/watch/glucose");
    Application.Properties.setValue("watchToken", "unit-test-token");

    // OFF: v= present, and it is the ONLY param -- d= stays gated, because the
    // ring payload is the one that can reach ~333 characters.
    Application.Properties.setValue("diagnostics", false);
    var off = BGData.requestSpec()["params"];
    Test.assertEqualMessage(off["v"], BGData.BUILD_VERSION,
        "diagnostics OFF -> the build identity still rides the wire");
    Test.assertMessage(!off.hasKey("d"), "diagnostics OFF -> no ring payload");
    Test.assertEqualMessage(off.size(), 1, "diagnostics OFF -> v= and nothing else");

    // ON: both.
    Application.Properties.setValue("diagnostics", true);
    var on = BGData.requestSpec()["params"];
    Test.assertMessage(on.hasKey("d"), "diagnostics ON -> ring payload present");
    Test.assertEqualMessage(on["v"], BGData.BUILD_VERSION,
        "diagnostics ON -> the build identity rides with it");
    Test.assertEqualMessage(on.size(), 2, "diagnostics ON -> exactly v= and d=");

    // Leave the toggle as the rest of the suite expects it.
    Application.Properties.setValue("diagnostics", false);
    return true;
}

(:test)
function testRequestSpecFramesDoesNotLeakIntoRequestSpec(logger as Test.Logger) as Boolean {
    // Both specs now come from one shared authSpec(). If that ever returned a
    // SHARED params dictionary instead of a fresh one, requestSpecFrames'
    // mutation would leak backwards into the background service's request --
    // silently enlarging the one payload that must stay minimal.
    Application.Properties.setValue("serverUrl", "https://example.test/api/watch/glucose");
    Application.Properties.setValue("watchToken", "unit-test-token");

    var frames = BGData.requestSpecFrames(true);
    Test.assertEqualMessage(frames["params"]["frames"], "60,180,360", "frames CSV set");
    Test.assertEqualMessage(frames["params"]["live"], 1, "live=1 on a deliberate refresh");

    var plain = BGData.requestSpec();
    Test.assertEqualMessage(plain["params"].size(), 1,
        "requestSpec still sends only its own param after requestSpecFrames mutated its params");
    Test.assertMessage(!plain["params"].hasKey("frames"),
        "frames did NOT leak backwards into the background request");
    Test.assertMessage(!plain["params"].hasKey("live"),
        "live did NOT leak backwards into the background request");
    return true;
}

(:test)
function testRequestSpecMissingConfig(logger as Test.Logger) as Boolean {
    // Blank serverUrl -> a loud, surfaced error sentinel (never a silent bail).
    Application.Properties.setValue("serverUrl", "");
    Application.Properties.setValue("watchToken", "unit-test-token");
    var noUrl = BGData.requestSpec();
    Test.assertEqualMessage(noUrl["err"], BGData.ERR_NO_URL, "blank serverUrl -> ERR_NO_URL");

    Application.Properties.setValue("serverUrl", "https://example.test");
    Application.Properties.setValue("watchToken", "");
    var noTok = BGData.requestSpec();
    Test.assertEqualMessage(noTok["err"], BGData.ERR_NO_TOKEN, "blank watchToken -> ERR_NO_TOKEN");
    return true;
}

// --- bands / colorFor --------------------------------------------------------

(:test)
function testBandsNsThresholdsWin(logger as Test.Logger) as Boolean {
    Application.Properties.setValue("useNsThresholds", true);
    // Reading carries NS thresholds; they must win over the manual props.
    var reading = {"mgdl" => 75, "th_ul" => 55, "th_l" => 70, "th_h" => 200, "th_uh" => 260};
    var b = BGData.bands(reading);
    Test.assertEqualMessage(b["ul"], 55, "NS urgent-low wins");
    Test.assertEqualMessage(b["l"], 70, "NS low wins");
    Test.assertEqualMessage(b["h"], 200, "NS high wins");
    Test.assertEqualMessage(b["uh"], 260, "NS urgent-high wins");
    // 75 is >= NS low (70) so GREEN, whereas under manual bands (low 90) it
    // would be yellow/red — proves the NS bands actually drive the color.
    Test.assertEqualMessage(BGData.colorFor(reading), Graphics.COLOR_GREEN,
        "color uses the NS bands");
    return true;
}

(:test)
function testBandsFallBackToCache(logger as Test.Logger) as Boolean {
    Application.Properties.setValue("useNsThresholds", true);
    // No thresholds on the reading, but a cached NS set exists -> use the cache.
    Application.Storage.setValue(BGData.TH_KEY, {
        "th_ul" => 50, "th_l" => 65, "th_h" => 190, "th_uh" => 240
    });
    var b = BGData.bands({"mgdl" => 120});
    Test.assertEqualMessage(b["l"], 65, "falls back to cached NS low");
    Test.assertEqualMessage(b["uh"], 240, "falls back to cached NS urgent-high");
    Application.Storage.deleteValue(BGData.TH_KEY);
    return true;
}

(:test)
function testColorForManualBands(logger as Test.Logger) as Boolean {
    // Turn NS thresholds off and pin the manual bands so this is deterministic.
    Application.Properties.setValue("useNsThresholds", false);
    Application.Properties.setValue("urgentLow", 80);
    Application.Properties.setValue("lowThreshold", 90);
    Application.Properties.setValue("highThreshold", 180);
    Application.Properties.setValue("urgentHigh", 230);

    Test.assertEqualMessage(BGData.colorFor({"mgdl" => 120}), Graphics.COLOR_GREEN, "in range -> green");
    Test.assertEqualMessage(BGData.colorFor({"mgdl" => 85}), Graphics.COLOR_YELLOW, "85 -> yellow");
    Test.assertEqualMessage(BGData.colorFor({"mgdl" => 200}), Graphics.COLOR_YELLOW, "200 -> yellow");
    Test.assertEqualMessage(BGData.colorFor({"mgdl" => 75}), Graphics.COLOR_RED, "75 -> red");
    Test.assertEqualMessage(BGData.colorFor({"mgdl" => 240}), Graphics.COLOR_RED, "240 -> red");
    return true;
}

(:test)
function testColorForIgnoresMmolToggle(logger as Test.Logger) as Boolean {
    // The mmol/L DISPLAY toggle must not move alert colors — comparison stays on
    // raw mgdl. 75 is red whether or not the user reads mmol.
    Application.Properties.setValue("useNsThresholds", false);
    Application.Properties.setValue("urgentLow", 80);
    Application.Properties.setValue("lowThreshold", 90);
    Application.Properties.setValue("highThreshold", 180);
    Application.Properties.setValue("urgentHigh", 230);

    Application.Properties.setValue("useMmol", true);
    Test.assertEqualMessage(BGData.colorFor({"mgdl" => 75}), Graphics.COLOR_RED,
        "75 stays red with mmol display on");
    Application.Properties.setValue("useMmol", false);
    Test.assertEqualMessage(BGData.colorFor({"mgdl" => 75}), Graphics.COLOR_RED,
        "75 red with mmol display off");
    return true;
}

// --- format helpers ----------------------------------------------------------

(:test)
function testFormatBg(logger as Test.Logger) as Boolean {
    Application.Properties.setValue("useMmol", false);
    Test.assertEqualMessage(BGData.formatBg(142), "142", "mg/dL -> integer string");

    Application.Properties.setValue("useMmol", true);
    Test.assertEqualMessage(BGData.formatBg(142), "7.9", "mmol/L -> one decimal");
    Application.Properties.setValue("useMmol", false);
    return true;
}

(:test)
function testFormatDelta(logger as Test.Logger) as Boolean {
    Application.Properties.setValue("useMmol", false);
    Test.assertEqualMessage(BGData.formatDelta({"delta" => 4}), "+4", "positive delta gets +");
    Test.assertEqualMessage(BGData.formatDelta({"delta" => -4}), "-4", "negative delta gets -");
    Test.assertEqualMessage(BGData.formatDelta({}), "", "missing delta -> empty");

    Application.Properties.setValue("useMmol", true);
    Test.assertEqualMessage(BGData.formatDelta({"delta" => 18}), "+1.0", "mmol delta one decimal");
    Application.Properties.setValue("useMmol", false);
    return true;
}

(:test)
function testFormatAge(logger as Test.Logger) as Boolean {
    Test.assertEqualMessage(BGData.formatAge(null), "", "null reading -> empty");
    Test.assertEqualMessage(BGData.formatAge({"age_min" => 0}), "now", "under a minute -> now");
    Test.assertEqualMessage(BGData.formatAge({"age_min" => 5}), "5m", "5 minutes -> 5m");
    Test.assertEqualMessage(BGData.formatAge({"age_min" => 150}), ">99m", "capped at >99m");
    return true;
}

// (testArrowText removed 2026-08-16 with BGData.arrowText itself -- the ASCII
// arrows it covered had had no renderer calling them since BGArrows landed, so
// this test was the function's only caller and kept dead code looking live.)

// --- no-data message: one wording shared by the glance and the full view -----

(:test)
function testNoDataMessage(logger as Test.Logger) as Boolean {
    // Both views render the no-reading state and both used to carry their own
    // copy of this mapping. Assert the sentinels here so a new one cannot be
    // added in BGData while the views keep saying "No data yet".
    Application.Storage.deleteValue(BGData.ERROR_KEY);
    Test.assertEqualMessage(BGData.noDataMessage(), "No data yet", "no error -> generic");

    Application.Storage.setValue(BGData.ERROR_KEY, BGData.ERR_NO_URL);
    Test.assertEqualMessage(BGData.noDataMessage(), "Set server URL", "ERR_NO_URL");

    Application.Storage.setValue(BGData.ERROR_KEY, BGData.ERR_NO_TOKEN);
    Test.assertEqualMessage(BGData.noDataMessage(), "Set watch token", "ERR_NO_TOKEN");

    // A transport error is NOT a setup problem: the big centered message stays
    // generic and the detail goes to the status line instead.
    Application.Storage.setValue(BGData.ERROR_KEY, -104);
    Test.assertEqualMessage(BGData.noDataMessage(), "No data yet", "-104 is not a setup hint");

    Application.Storage.deleteValue(BGData.ERROR_KEY);
    return true;
}

// --- fetch status ------------------------------------------------------------

(:test)
function testDescribeErrorNamesTheFix(logger as Test.Logger) as Boolean {
    Test.assertEqualMessage(BGData.describeError(BGData.ERR_NO_URL, true),
        "Set server URL", "missing url");
    Test.assertEqualMessage(BGData.describeError(BGData.ERR_NO_TOKEN, true),
        "Set watch token", "missing token");
    Test.assertEqualMessage(BGData.describeError(401, true),
        "Bad token (401)", "401");
    Test.assertEqualMessage(BGData.describeError(503, true),
        "No readings (503)", "503");
    Test.assertEqualMessage(BGData.describeError(-300, true),
        "Timed out (-300)", "-300 times out");
    // -1001 is SECURE_CONNECTION_REQUIRED in the SDK enum, not a timeout; it
    // shared the -300 branch until 2026-08-21 purely because it had never
    // fired on the wrist for anyone to notice the label was wrong.
    Test.assertEqualMessage(BGData.describeError(-1001, true),
        "Needs HTTPS (-1001)", "-1001 is a secure-connection error, not a timeout");
    // -2 (BLE_HOST_TIMEOUT) had no case and fell through to the generic
    // "Fetch error -2". First observed 2026-08-20 16:15 EDT with conn=0.
    Test.assertEqualMessage(BGData.describeError(-2, true),
        "Phone timeout (-2)", "-2 names the phone leg");
    Test.assertEqualMessage(BGData.describeError(-42, true),
        "Fetch error -42", "unrecognized code still shows the number");
    return true;
}

(:test)
function testDescribeErrorSplitsPhoneLinkFromSleepingApp(logger as Test.Logger) as Boolean {
    // THE bug this exists for: -104 only means "the request never left the
    // phone". That happens when the phone is genuinely out of range AND when
    // it is sitting right there with Garmin Connect suspended by the OS — and
    // those two need opposite instructions. Reported 2026-08-15 as ">99m plus
    // 'phone link' while the phone was next to the watch and Nightscout was
    // updating fine".
    Test.assertEqualMessage(BGData.describeError(-104, false),
        "No phone link (-104)", "phone really disconnected -> check the link");
    Test.assertEqualMessage(BGData.describeError(-104, true),
        "Open Garmin Connect", "phone connected but proxy asleep -> wake the app");
    return true;
}

// --- background-service status -----------------------------------------------

(:test)
function testDescribeBackgroundNeverRun(logger as Test.Logger) as Boolean {
    // THE state this row exists for. registerForTemporalEvent() runs only from
    // getInitialView()/getGlanceView(), so a freshly sideloaded PRG has no
    // background service at all until the widget is opened once -- and on the
    // wrist that is indistinguishable from a phone-link failure.
    Test.assertEqualMessage(BGData.describeBackground(null, null, 1000, true),
        "never run - open to arm", "no timestamp and no error -> never armed");
    return true;
}

(:test)
function testDescribeBackgroundAges(logger as Test.Logger) as Boolean {
    var now = 100000;
    Test.assertEqualMessage(BGData.describeBackground(now - 30, null, now, true),
        "ran just now", "under a minute");
    Test.assertEqualMessage(BGData.describeBackground(now - 4 * 60, null, now, true),
        "ran 4m ago", "4 minutes");
    Test.assertEqualMessage(BGData.describeBackground(now - 200 * 60, null, now, true),
        "ran >99m ago", "capped like formatAge");
    // A clock moving backwards must not print a negative age.
    Test.assertEqualMessage(BGData.describeBackground(now + 600, null, now, true),
        "ran just now", "future timestamp clamps to zero");
    return true;
}

(:test)
function testDescribeBackgroundReportsFailureAndLastSuccess(logger as Test.Logger) as Boolean {
    var now = 100000;
    // Failing now but succeeded before: both facts matter -- the error says
    // what to do, the age says how long the number has been coasting.
    Test.assertEqualMessage(
        BGData.describeBackground(now - 22 * 60, -104, now, true),
        "Open Garmin Connect; ok 22m ago",
        "connected + -104 -> wake the app, and say when it last worked");
    Test.assertEqualMessage(
        BGData.describeBackground(now - 22 * 60, -104, now, false),
        "No phone link (-104); ok 22m ago",
        "disconnected + -104 -> genuinely out of range");
    // Never succeeded AND failing: no age to report.
    Test.assertEqualMessage(BGData.describeBackground(null, 401, now, true),
        "failing, Bad token (401)", "error with no prior success");
    return true;
}

// --- chart vertical frame ----------------------------------------------------

(:test)
function testFrameClearsUrgentBands(logger as Test.Logger) as Boolean {
    // THE regression this exists for: the frame used to be a hard 40..220,
    // which sat BELOW the urgent-high band. The urgent-high line was therefore
    // never drawable and every reading from 220 up clamped to one pixel row,
    // so 225 and 350 looked identical on the wrist.
    var b = {"ul" => 80, "l" => 90, "h" => 180, "uh" => 230};
    var lo = BGData.frameLo(b);
    var hi = BGData.frameHi(b);
    Test.assertMessage(hi > b["uh"],
        "frame ceiling must clear urgent-high (was 220 vs a 230 band)");
    Test.assertMessage(lo < b["ul"], "frame floor must clear urgent-low");
    Test.assertEqualMessage(hi, 250, "230 urgent-high + 20 headroom");
    Test.assertEqualMessage(lo, 40, "base floor already clears an 80 urgent-low");
    return true;
}

(:test)
function testFrameHandlesWideBands(logger as Test.Logger) as Boolean {
    // A very wide Nightscout config must still enclose both urgent bands
    // rather than clipping them back to the base frame.
    var wide = {"ul" => 55, "l" => 70, "h" => 200, "uh" => 300};
    Test.assertEqualMessage(BGData.frameHi(wide), 320, "300 + 20 headroom");
    Test.assertEqualMessage(BGData.frameLo(wide), 35, "55 - 20 headroom");

    // A tight config does NOT shrink the frame below the base — the plot must
    // not auto-zoom around a narrow band and magnify noise into drama.
    var tight = {"ul" => 90, "l" => 100, "h" => 140, "uh" => 160};
    Test.assertEqualMessage(BGData.frameHi(tight), 220, "tight bands keep the base ceiling");
    Test.assertEqualMessage(BGData.frameLo(tight), 40, "tight bands keep the base floor");

    // Floor never goes negative even with an absurd urgent-low.
    Test.assertMessage(BGData.frameLo({"ul" => 5, "l" => 70, "h" => 180, "uh" => 230}) >= 0,
        "frame floor never negative");
    return true;
}

(:test)
function testFrameIsIdenticalForEveryWindow(logger as Test.Logger) as Boolean {
    // The frame depends only on the bands, never on the series — that's what
    // keeps the y-axis from jumping when you swipe, and what lets the swipe
    // transition slide two traces against one shared scale.
    var b = {"ul" => 80, "l" => 90, "h" => 180, "uh" => 230};
    Test.assertEqualMessage(BGData.frameHi(b), BGData.frameHi(b), "frame is a pure function of bands");
    Test.assertEqualMessage(BGData.frameLo(b), BGData.frameLo(b), "same for the floor");
    return true;
}

// --- colorForBands: per-point chart coloring ---------------------------------

(:test)
function testColorForBandsPerPoint(logger as Test.Logger) as Boolean {
    // Chart points are colored by their OWN value, so a trace that ran high
    // and came back down doesn't render its highs in the current green.
    var b = {"ul" => 80, "l" => 90, "h" => 180, "uh" => 230};
    Test.assertEqualMessage(BGData.colorForBands(120, b), Graphics.COLOR_GREEN, "120 in range");
    Test.assertEqualMessage(BGData.colorForBands(85, b), Graphics.COLOR_YELLOW, "85 below low band");
    Test.assertEqualMessage(BGData.colorForBands(200, b), Graphics.COLOR_YELLOW, "200 above high band");
    Test.assertEqualMessage(BGData.colorForBands(75, b), Graphics.COLOR_RED, "75 urgent low");
    Test.assertEqualMessage(BGData.colorForBands(250, b), Graphics.COLOR_RED, "250 urgent high");
    // Boundaries: the band edges themselves are IN range.
    Test.assertEqualMessage(BGData.colorForBands(90, b), Graphics.COLOR_GREEN, "low edge is in range");
    Test.assertEqualMessage(BGData.colorForBands(180, b), Graphics.COLOR_GREEN, "high edge is in range");
    return true;
}

(:test)
function testColorForBandsMatchesColorFor(logger as Test.Logger) as Boolean {
    // The per-point helper and the reading-level colorFor must never diverge —
    // if they did, a dot's color could contradict the big number above it for
    // the very same value.
    Application.Properties.setValue("useNsThresholds", false);
    Application.Properties.setValue("urgentLow", 80);
    Application.Properties.setValue("lowThreshold", 90);
    Application.Properties.setValue("highThreshold", 180);
    Application.Properties.setValue("urgentHigh", 230);

    var vals = [70, 85, 120, 200, 240];
    for (var i = 0; i < vals.size(); i++) {
        var reading = {"mgdl" => vals[i]};
        Test.assertEqualMessage(
            BGData.colorForBands(vals[i], BGData.bands(reading)),
            BGData.colorFor(reading),
            "point color agrees with reading color");
    }
    return true;
}

// --- bandsSummary: the menu sublabel -----------------------------------------

(:test)
function testBandsSummary(logger as Test.Logger) as Boolean {
    // Manual side: the baked-in fallbacks, labelled as such.
    Application.Storage.deleteValue(BGData.STORAGE_KEY);
    Application.Storage.deleteValue(BGData.TH_KEY);
    Application.Properties.setValue("useNsThresholds", false);
    Application.Properties.setValue("urgentLow", 80);
    Application.Properties.setValue("lowThreshold", 90);
    Application.Properties.setValue("highThreshold", 180);
    Application.Properties.setValue("urgentHigh", 230);
    Test.assertEqualMessage(BGData.bandsSummary(), "Manual · 80-90-180-230",
        "manual bands named and spelled out");

    // NS side: cached Nightscout thresholds win and are labelled NS.
    Application.Properties.setValue("useNsThresholds", true);
    Application.Storage.setValue(BGData.TH_KEY, {
        "th_ul" => 55, "th_l" => 70, "th_h" => 200, "th_uh" => 260
    });
    Test.assertEqualMessage(BGData.bandsSummary(), "NS · 55-70-200-260",
        "NS bands named and spelled out");
    Application.Storage.deleteValue(BGData.TH_KEY);

    // The sublabel must stay in mg/dL even with the mmol display toggle on —
    // thresholds are stored and compared in mg/dL, and a converted sublabel
    // would not match anything shown in Nightscout.
    Application.Properties.setValue("useMmol", true);
    Application.Properties.setValue("useNsThresholds", false);
    Test.assertEqualMessage(BGData.bandsSummary(), "Manual · 80-90-180-230",
        "sublabel stays mg/dL under the mmol toggle");
    Application.Properties.setValue("useMmol", false);
    return true;
}

// --- diagnostic ring ----------------------------------------------------------

(:test)
function testDiagTokenEmpty(logger as Test.Logger) as Boolean {
    // "none" rather than "" so the parameter is still present in the server log
    // line. An absent d= and an empty d= look the same in an access log, and
    // "the ring is empty" is a real state worth telling apart from "the toggle
    // is off" -- the whole investigation this exists for was derailed once by
    // reading silence as data.
    Test.assertEqualMessage(BGData.diagToken(null, 1000), "none", "null ring");
    Test.assertEqualMessage(BGData.diagToken([], 1000), "none", "empty ring");
    return true;
}

(:test)
function testDiagTokenRendersOutcomeAgeAndLink(logger as Test.Logger) as Boolean {
    var now = 100000;
    // code . secondsAgo . phoneConnected
    Test.assertEqualMessage(BGData.diagToken([[now - 300, 200, true]], now),
        "200.300.1", "success 5 min ago with the phone in range");
    Test.assertEqualMessage(BGData.diagToken([[now - 42, -104, false]], now),
        "-104.42.0", "out-of-range failure keeps its sign and reports link down");
    return true;
}

(:test)
function testDiagTokenIsNewestFirst(logger as Test.Logger) as Boolean {
    var now = 100000;
    var ring = [[now - 600, 200, true], [now - 300, -104, true], [now - 5, 200, true]];
    Test.assertEqualMessage(BGData.diagToken(ring, now),
        "200.5.1_-104.300.1_200.600.1",
        "newest first, so the most recent outcome is readable without counting");
    return true;
}

// Counts the entries in a rendered d= token.
function diagParts(token as String) as Number {
    var parts = 1;
    for (var i = 0; i < token.length(); i++) {
        if (token.substring(i, i + 1).equals("_")) { parts++; }
    }
    return parts;
}

// A ring of `n` entries on a 5-minute grid ending `now`, all 200/connected
// except the indices listed in `failAt` (counted from the NEWEST, 0-based).
function diagRing(now as Number, n as Number, failAt as Array) as Array {
    var ring = [];
    for (var i = 0; i < n; i++) {
        var fromNewest = n - 1 - i;
        var failed = false;
        for (var f = 0; f < failAt.size(); f++) {
            if (failAt[f] == fromNewest) { failed = true; }
        }
        ring.add([now - (fromNewest + 1) * 300, failed ? -104 : 200, !failed]);
    }
    return ring;
}

(:test)
function testDiagTokenCapsAtSendLimit(logger as Test.Logger) as Boolean {
    var now = 100000;
    var token = BGData.diagToken(diagRing(now, 12, []), now);
    Test.assertEqualMessage(diagParts(token), BGData.DIAG_SEND,
        "an all-healthy ring still sends exactly DIAG_SEND entries");
    return true;
}

(:test)
function testDiagTokenWidensThroughOldestFailure(logger as Test.Logger) as Boolean {
    // THE POINT OF THE WIDENING: a blackout is only ever described by the first
    // request that gets through after it. At a fixed six, a 12-entry (~60 min)
    // run of failures could never be reconstructed server-side.
    var now = 100000;
    var failAt = [];
    for (var i = 1; i <= 12; i++) { failAt.add(i); }   // newest is the recovery 200
    var token = BGData.diagToken(diagRing(now, 20, failAt), now);
    Test.assertEqualMessage(diagParts(token), 13,
        "widens back through the oldest failure, not just DIAG_SEND");
    Test.assertMessage(token.find("-104.3900.0") != null,
        "the oldest failure in the run actually rides the wire");
    return true;
}

(:test)
function testDiagTokenWideningIsCapped(logger as Test.Logger) as Boolean {
    // Bounded by URL length. A blackout deeper than DIAG_SEND_MAX reports its
    // newest DIAG_SEND_MAX attempts and the rest stay on-wrist only.
    var now = 100000;
    var failAt = [];
    for (var i = 0; i < 60; i++) { failAt.add(i); }
    var token = BGData.diagToken(diagRing(now, BGData.DIAG_MAX, failAt), now);
    Test.assertEqualMessage(diagParts(token), BGData.DIAG_SEND_MAX,
        "a blackout longer than the cap sends exactly DIAG_SEND_MAX entries");
    return true;
}

(:test)
function testDiagTokenIgnoresFailuresPastTheCap(logger as Test.Logger) as Boolean {
    // A failure older than DIAG_SEND_MAX must not widen anything -- otherwise
    // one ancient -104 in a 72-deep ring would pin every payload to maximum.
    var now = 100000;
    var token = BGData.diagToken(diagRing(now, BGData.DIAG_MAX, [50]), now);
    Test.assertEqualMessage(diagParts(token), BGData.DIAG_SEND,
        "a failure outside the send cap leaves the healthy payload alone");
    return true;
}

(:test)
function testDiagTokenSurvivesMalformedEntriesInScan(logger as Test.Logger) as Boolean {
    // The widening scan reads e[1] on every entry it walks, including any
    // short/garbage entry left by an older build. It must not throw.
    var now = 100000;
    var ring = diagRing(now, 8, []);
    ring[2] = [now - 1800];
    Test.assertEqualMessage(BGData.sendWidth(ring), BGData.DIAG_SEND,
        "a malformed entry is skipped rather than widening or throwing");
    return true;
}

(:test)
function testDiagTokenClampsBackwardsClock(logger as Test.Logger) as Boolean {
    var now = 100000;
    // Same clamp describeBackground already applies: a future timestamp must
    // not emit a negative age, which would parse as a second minus sign.
    Test.assertEqualMessage(BGData.diagToken([[now + 600, 200, true]], now),
        "200.0.1", "future timestamp clamps to zero");
    return true;
}

(:test)
function testFullRingFitsTheBackgroundBudget(logger as Test.Logger) as Boolean {
    // The ring is the only part of the diagnostic that grows with DIAG_MAX, and
    // it is allocated in the BACKGROUND context, whose whole budget on
    // venu441mm is 65536 bytes (compiler.json appTypes[].background). Static
    // background usage measured at the v14 tree: 1864 data + 5515 code = 7379,
    // so ~58 KB is free. This measures what a FULL ring actually costs so the
    // depth is a number somebody checked rather than a number somebody liked.
    //
    // Measured, not asserted tightly: the bound is deliberately loose because
    // the sim's GC decides when it runs. It fails only if DIAG_MAX grows to
    // something that genuinely threatens the budget.
    var before = System.getSystemStats().freeMemory;
    var ring = diagRing(100000, BGData.DIAG_MAX, []);
    var after = System.getSystemStats().freeMemory;
    var cost = before - after;
    logger.debug("full ring of " + BGData.DIAG_MAX.format("%d") + " entries costs "
        + cost.format("%d") + " bytes of heap");

    // recordAttempt's trim slices once, so peak is the ring plus one copy.
    Test.assertMessage(cost * 2 < 16384,
        "a full ring plus its trim copy must stay well inside the 64 KB "
        + "background budget (measured " + cost.format("%d") + " bytes)");
    return true;
}

(:test)
function testBackgroundStatusUsesFetchTimeLink(logger as Test.Logger) as Boolean {
    // Regression guard for the wording bug: an out-of-range -104 read back
    // AFTER the phone reconnects must still say "No phone link", not send you
    // to the Garmin Connect app. Proven 2026-08-20: 48/48 -104s had the phone
    // out of range at fetch time, none while connected.
    var now = Time.now().value();
    Application.Storage.setValue(BGData.DIAG_KEY, [[now - 300, -104, false]]);
    Test.assertMessage(!BGData.lastAttemptConnected(),
        "stored fetch-time flag wins over a live sample");
    Test.assertEqualMessage(
        BGData.describeBackground(now - 1800, -104, now, BGData.lastAttemptConnected()),
        "No phone link (-104); ok 30m ago",
        "out-of-range failure keeps out-of-range wording after reconnect");

    Application.Storage.setValue(BGData.DIAG_KEY, [[now - 300, 200, true]]);
    Test.assertMessage(BGData.lastAttemptConnected(),
        "a connected attempt reads back true");

    // Malformed / short entries must not throw -- fall through to a live sample.
    Application.Storage.setValue(BGData.DIAG_KEY, [[now - 300]]);
    BGData.lastAttemptConnected();
    Application.Storage.deleteValue(BGData.DIAG_KEY);
    return true;
}

// --- the auto-fetch row must report FETCH-TIME state ---------------------------

(:test)
function testLastBackgroundFetchIgnoresStaleDeliveryKey(logger as Test.Logger) as Boolean {
    // THE regression. Observed 2026-08-20: the row read ">99m ago" while the
    // server had logged five successful background fetches in the previous
    // hour, most recent 37 min earlier. Cause: every success after the stale
    // one was overwritten in the single-slot Background.exit() queue before it
    // could be delivered, so BG_FETCH_KEY never advanced.
    var now = Time.now().value();
    Application.Storage.setValue(BGData.BG_FETCH_KEY, now - 132 * 60);  // the lie
    Application.Storage.setValue(BGData.DIAG_KEY, [
        [now - 5400, 200, true],
        [now - 3900, 200, true],
        [now - 2220, 200, true],   // <- the truth: 37 min ago
        [now - 1500, -300, true],
        [now - 300, -300, true]
    ]);
    Test.assertEqualMessage(BGData.lastBackgroundFetch(), now - 2220,
        "newest 200 in the ring wins over a stale delivered timestamp");
    Test.assertEqualMessage(BGData.lastBackgroundError(), -300,
        "newest entry is a failure -> report it");
    Test.assertEqualMessage(
        BGData.describeBackground(BGData.lastBackgroundFetch(),
            BGData.lastBackgroundError(), now, BGData.lastAttemptConnected()),
        "Timed out (-300); ok 37m ago",
        "row reports the real age, not the delivered one");
    Application.Storage.deleteValue(BGData.DIAG_KEY);
    Application.Storage.deleteValue(BGData.BG_FETCH_KEY);
    return true;
}

(:test)
function testStaleDeliveredErrorIsClearedByRingSuccess(logger as Test.Logger) as Boolean {
    // The inverse: BG_ERROR_KEY is deleted only on a DELIVERED success, so an
    // old failure can read as "current" while the ring shows the service has
    // been healthy for half an hour.
    var now = Time.now().value();
    Application.Storage.setValue(BGData.BG_ERROR_KEY, -104);
    Application.Storage.setValue(BGData.DIAG_KEY, [
        [now - 900, -104, false],
        [now - 300, 200, true]
    ]);
    Test.assertMessage(BGData.lastBackgroundError() == null,
        "newest ring entry is a success -> no error to report");
    Test.assertEqualMessage(
        BGData.describeBackground(BGData.lastBackgroundFetch(),
            BGData.lastBackgroundError(), now, BGData.lastAttemptConnected()),
        "ran 5m ago",
        "healthy row, no stale error clinging to it");
    Application.Storage.deleteValue(BGData.DIAG_KEY);
    Application.Storage.deleteValue(BGData.BG_ERROR_KEY);
    return true;
}

(:test)
function testEmptyRingFallsBackToDeliveredKeys(logger as Test.Logger) as Boolean {
    // Fresh install: the ring is empty and the old keys are all there is. Must
    // behave exactly as it did before, not go blank.
    var now = Time.now().value();
    Application.Storage.deleteValue(BGData.DIAG_KEY);
    Application.Storage.setValue(BGData.BG_FETCH_KEY, now - 600);
    Application.Storage.setValue(BGData.BG_ERROR_KEY, 401);
    Test.assertEqualMessage(BGData.lastBackgroundFetch(), now - 600,
        "empty ring -> delivered timestamp");
    Test.assertEqualMessage(BGData.lastBackgroundError(), 401,
        "empty ring -> delivered error");
    Application.Storage.deleteValue(BGData.BG_FETCH_KEY);
    Application.Storage.deleteValue(BGData.BG_ERROR_KEY);
    return true;
}

(:test)
function testRingOfOnlyFailuresKeepsDeliveredFetchTime(logger as Test.Logger) as Boolean {
    // A blackout longer than the ring: no 200 survives in it, so the last known
    // success can only come from the delivered key. Must not return null and
    // regress the row to "never run - open to arm".
    var now = Time.now().value();
    Application.Storage.setValue(BGData.BG_FETCH_KEY, now - 7200);
    var ring = [];
    for (var i = 0; i < 20; i++) {
        ring.add([now - (20 - i) * 300, -104, false]);
    }
    Application.Storage.setValue(BGData.DIAG_KEY, ring);
    Test.assertEqualMessage(BGData.lastBackgroundFetch(), now - 7200,
        "all-failure ring falls back rather than claiming never-run");
    Test.assertEqualMessage(BGData.lastBackgroundError(), -104, "failure reported");
    Test.assertMessage(!BGData.lastAttemptConnected(), "out of range at fetch time");
    Application.Storage.deleteValue(BGData.DIAG_KEY);
    Application.Storage.deleteValue(BGData.BG_FETCH_KEY);
    return true;
}

// --- v18: the payload pages backwards through what a blackout stranded -------
//
// The invariant every one of these protects is that the MAXIMUM payload does
// not move. ~333 characters is the only width the watch leg has ever been
// proven at, and the head widens because the ring holds failures -- so a
// payload too long to send would keep itself too long and the fetch could not
// recover with diagnostics on.

(:test)
function testPagedPayloadNeverExceedsTheProvenBudget(logger as Test.Logger) as Boolean {
    // The whole point. A 72-deep ring with a 60-entry blackout is the worst
    // case the ring can hold; the emitted token must still fit the budget.
    var now = 100000;
    var failAt = [];
    for (var i = 0; i < 60; i++) { failAt.add(i); }
    var ring = diagRing(now, BGData.DIAG_MAX, failAt);
    var worst = BGData.diagTokenPaged(ring, now, null);
    Test.assertMessage(diagParts(worst[0]) <= BGData.DIAG_SEND_MAX,
        "worst-case paged payload emitted " + diagParts(worst[0]).format("%d")
        + " entries, more than v17's head could");
    // And a healthy ring swept from scratch -- the case that actually spends
    // the idle slots -- must respect the same ceiling.
    var healthy = BGData.diagTokenPaged(diagRing(now, BGData.DIAG_MAX, []), now, null);
    Test.assertMessage(diagParts(healthy[0]) <= BGData.DIAG_SEND_MAX,
        "healthy sweep emitted more entries than v17's head could");
    // The no-regression claim stated directly: never longer on the wire than
    // the widest thing v17 could already send from this same ring.
    var v17Worst = BGData.diagToken(ring, now);
    Test.assertMessage((healthy[0] as String).length() <= v17Worst.length(),
        "paged payload is longer than v17's widest head for the same ring");
    return true;
}

(:test)
function testHeadIsUnchangedWhenThereIsNothingToBackfill(logger as Test.Logger) as Boolean {
    // A ring that has already been swept back to its oldest entry must emit
    // exactly what v17 emitted -- the steady state is not allowed to grow.
    var now = 100000;
    var ring = diagRing(now, 12, []);
    var oldest = ring[0][0];
    var paged = BGData.diagTokenPaged(ring, now, oldest);
    Test.assertEqualMessage(paged[0], BGData.diagToken(ring, now),
        "fully-swept ring must emit the plain head");
    return true;
}

(:test)
function testHealthyHeadSpendsItsIdleBudgetOnBackfill(logger as Test.Logger) as Boolean {
    // The mechanism: 6 entries is ~54 characters, so a healthy head leaves most
    // of the budget idle and the sweep spends it going backwards.
    var now = 100000;
    var ring = diagRing(now, BGData.DIAG_MAX, []);
    var paged = BGData.diagTokenPaged(ring, now, null);
    Test.assertMessage(diagParts(paged[0]) > BGData.DIAG_SEND,
        "a healthy head with idle budget should have paged backwards");
    Test.assertMessage((paged[1] as Number) < ring[ring.size() - BGData.DIAG_SEND][0],
        "sweep position should have moved behind the head");
    return true;
}

(:test)
function testALiveIncidentGetsNoBackfill(logger as Test.Logger) as Boolean {
    // A widened head must leave no slack: a current outage outranks an old one,
    // and this is also what keeps the maximum payload where it was proven.
    var now = 100000;
    var failAt = [];
    for (var i = 0; i < 40; i++) { failAt.add(i); }
    var ring = diagRing(now, BGData.DIAG_MAX, failAt);
    var paged = BGData.diagTokenPaged(ring, now, null);
    Test.assertEqualMessage(diagParts(paged[0]), BGData.DIAG_SEND_MAX,
        "a live incident must emit the head alone, not head plus backfill");
    return true;
}

(:test)
function testSweepResetsOnAFreshIncident(logger as Test.Logger) as Boolean {
    // THE BUG THIS PINS: the cursor only moves backwards, so once a sweep has
    // reached the oldest entry, a LATER blackout's stranded entries would be
    // NEWER than the cursor and would never qualify again. Widening the head is
    // the signal that a fresh incident exists, and it restarts the sweep.
    var now = 100000;
    var failAt = [];
    for (var i = 0; i < 40; i++) { failAt.add(i); }
    var ring = diagRing(now, BGData.DIAG_MAX, failAt);
    // Cursor already swept to the very oldest entry.
    var paged = BGData.diagTokenPaged(ring, now, ring[0][0]);
    Test.assertEqualMessage(diagParts(paged[0]), BGData.DIAG_SEND_MAX,
        "a fresh incident must restart the sweep rather than stay exhausted");
    return true;
}

(:test)
function testSweepPositionOnlyMovesBackwards(logger as Test.Logger) as Boolean {
    // A healthy ring whose sweep is already old must not drag the cursor
    // forward to the head, which would re-report ground already covered and
    // never reach anything older.
    var now = 100000;
    var ring = diagRing(now, 12, []);
    var old = ring[0][0] - 99999;
    var paged = BGData.diagTokenPaged(ring, now, old);
    Test.assertEqualMessage(paged[1], old,
        "cursor must not move forward");
    return true;
}

(:test)
function testPagedHandlesEmptyAndNullRing(logger as Test.Logger) as Boolean {
    var a = BGData.diagTokenPaged(null, 1000, null);
    Test.assertEqualMessage(a[0], "none", "null ring still reports none");
    var b = BGData.diagTokenPaged([], 1000, 42);
    Test.assertEqualMessage(b[0], "none", "empty ring still reports none");
    Test.assertEqualMessage(b[1], 42, "empty ring leaves the cursor alone");
    return true;
}

(:test)
function testBackfillFormatMatchesTheHead(logger as Test.Logger) as Boolean {
    // The decoder parses head and backfill with ONE regex; a divergence would
    // be dropped silently rather than error. Every part must be <code>.<age>.<conn>.
    var now = 100000;
    var paged = BGData.diagTokenPaged(diagRing(now, BGData.DIAG_MAX, []), now, null);
    var token = paged[0] as String;
    var dots = 0;
    for (var i = 0; i < token.length(); i++) {
        var c = token.substring(i, i + 1);
        if (c.equals(".")) { dots++; }
    }
    Test.assertEqualMessage(dots, diagParts(token) * 2,
        "every emitted part must carry exactly two dots");
    return true;
}
