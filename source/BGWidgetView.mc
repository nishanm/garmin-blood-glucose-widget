import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.PersistedContent;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// Full-screen view shown when the glance is tapped.
//
// The 5-minute background service remains the steady fetch path, but this
// view may fetch on demand — that's the "we just walked back into phone
// range" recovery: opening it (or tapping it) refreshes immediately instead
// of waiting out the background cycle, and while it stays on screen it
// retries roughly once a minute whenever the data is overdue. The glance
// itself can never fetch (platform restriction), so it renders from Storage
// only.
class BGWidgetView extends WatchUi.View {

    private var _timer as Timer.Timer?;
    private var _requesting as Boolean = false;
    // Two most recent fetch-attempt times (epoch s) — the rolling window
    // for the rate limit in refresh().
    private var _lastAttempt as Number = 0;
    private var _prevAttempt as Number = 0;
    // Selected timeframe index (0 = 60 min default, 1 = 3 h, 2 = 6 h). Kept in
    // memory only and reset to 0 on every open — deliberately NOT a persisted
    // property, which sidesteps the "new setting doesn't initialize on a
    // sideloaded update" trap (see ARCHITECTURE.md).
    private var _tf as Number = 0;
    // Swipe-transition state: the outgoing frame's chart slides off and the
    // incoming one slides in over ANIM_DURATION_MS, with the timeframe label
    // and page dot moving in the same direction. Purely cosmetic — _tf is
    // already the live value the instant a swipe lands, so a dropped frame or
    // killed timer never leaves the wrong chart/reading on screen, just a
    // snap instead of a slide.
    //
    // The first cut of this animated ONLY the label and the page dot, and read
    // on-wrist as no animation at all: the chart — the one thing a swipe
    // actually changes — hard-cut underneath, and 180 ms of linear motion on a
    // 4 px dot is below the threshold where the eye registers movement. Now the
    // trace carries the transition, over a slightly longer ease-out.
    private var _animFromTf as Number = 0;
    private var _animStartMs as Number = 0;
    private var _animTimer as Timer.Timer?;
    const ANIM_DURATION_MS = 260;

    // Cached units font. getVectorFont() allocates, and this used to run on
    // every onUpdate — fine at one frame per 30 s, wasteful at ~50 fps for the
    // length of a swipe. The screen never changes size, so resolving it once
    // and holding it is safe.
    private var _unitsFont = null;
    private var _unitsFontResolved as Boolean = false;

    function initialize() {
        View.initialize();
    }

    function onShow() as Void {
        _tf = 0;
        _animFromTf = 0;
        _timer = new Timer.Timer();
        _timer.start(method(:onTimer), 30 * 1000, true);
        maybeRefresh();
    }

    function onHide() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        if (_animTimer != null) {
            _animTimer.stop();
            _animTimer = null;
        }
    }

    // Every 30 s: redraw so the age readout stays honest, and self-heal —
    // if the reading is overdue and we haven't tried lately, try again.
    function onTimer() as Void {
        var reading = BGData.lastReading();
        var age = BGData.ageMinutes(reading);
        // Also refetch if the current frame has no series yet — e.g. a swipe's
        // fetch was dropped by the rate limit — so an empty frame fills within
        // a minute instead of staying blank behind a fresh reading.
        var haveHist = BGData.cachedHistory(BGData.tfMinutes(_tf)) != null;
        if ((age == null || age >= 6 || !haveHist)
            && Time.now().value() - _lastAttempt > 55) {
            refresh(false);
        }
        WatchUi.requestUpdate();
    }

    // Fetch now unless the stored reading is already fresh.
    function maybeRefresh() as Void {
        var reading = BGData.lastReading();
        var age = BGData.ageMinutes(reading);
        if (age != null && age < 1) {
            return;
        }
        refresh(false);
    }

    // One immediate fetch (tap / on open / self-heal). Single request, no
    // loops — repeated failures just wait for the next tap or timer tick.
    // Asks for ALL swipe windows at once (requestSpecFrames): the one response
    // carries the reading (parsed exactly as the background service parses it)
    // plus every chart series, so a single fetch refreshes the number and warms
    // all three frames — swiping between them then never waits on the network.
    //
    // Rate limit: at most 2 fetches per rolling 10 s across ALL triggers
    // (taps included) — a third attempt inside the window is dropped
    // silently. Protects the phone link and the server from tap-spamming,
    // and new data only lands every ~5 min anyway.
    //
    // `live` is passed straight through to the endpoint's ?live=1 and is true
    // ONLY for the menu's "Refresh now" press — a deliberate press means "the
    // newest value that exists", so the server skips its database row and reads
    // Nightscout. Every automatic caller here (fetch-on-open, the self-heal
    // timer, a swipe refill) passes false and keeps the cheaper DB-first path.
    function refresh(live as Boolean) as Void {
        if (_requesting) {
            return;
        }
        var now = Time.now().value();
        if (now - _prevAttempt < 10) {
            return;
        }
        var spec = BGData.requestSpecFrames(live);
        if (spec["err"] != null) {
            // Missing baked-in config. Record it rather than returning
            // quietly: an earlier build bailed silently here, which made
            // "Refresh now", fetch-on-open and the self-heal timer all no-op
            // with nothing on screen to say why.
            BGData.store(spec);
            WatchUi.requestUpdate();
            return;
        }
        _requesting = true;
        _prevAttempt = _lastAttempt;
        _lastAttempt = now;
        Communications.makeWebRequest(
            spec["url"],
            spec["params"],
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :headers => spec["headers"]
            },
            method(:onReceive)
        );
        WatchUi.requestUpdate();
    }

    function onReceive(responseCode as Number,
                       data as Dictionary or String or PersistedContent.Iterator or Null) as Void {
        _requesting = false;
        BGData.store(BGData.parseResponse(responseCode, data));
        // Separate, and second: the reading is already safely stored by the
        // line above no matter what the charts look like. storeAllFrames caches
        // each window from data["hists"] and skips any that's missing or thin,
        // so a partial or history-less response keeps the last good series
        // rather than blanking a chart — and never endangers the reading. The
        // response is frame-agnostic (it carries all windows), so unlike the
        // old single-window path there's nothing to key against the live _tf.
        BGData.storeAllFrames(responseCode, data);
        WatchUi.requestUpdate();
    }

    // Switch the charted window (called by the delegate on a horizontal swipe).
    // Normally instant: the single ?frames= fetch on open already cached every
    // window, so this just redraws. It only refetches as a fallback — when this
    // frame somehow has no series yet (an open fetch that was dropped or failed)
    // or the reading is overdue — and one frames fetch refills all three at
    // once. The rate limit in refresh() is the backstop against swipe-spam.
    function setTimeframe(idx as Number) as Void {
        if (idx < 0 || idx >= BGData.tfCount() || idx == _tf) {
            return;
        }
        // A swipe landing MID-SLIDE must not re-base _animFromTf to _tf. During
        // an animation _tf is where the slide is heading, not what is on screen,
        // so re-basing snaps the moving trace back to centre and then slides it
        // again — visible as a stutter when you swipe 60m -> 3h -> 6h quickly.
        // Keep the frame the slide actually started from, so the second swipe
        // continues the motion instead of restarting it.
        //
        // The exception is a reversal (swiping back to the frame we are sliding
        // away from): there the in-flight target is the closer approximation of
        // what the eye currently sees, so re-base to it. That also keeps
        // _animFromTf != _tf, which is load-bearing — equal values make
        // animProgress() return 1.0 and skip the slide entirely, so without this
        // branch a reverse swipe would snap with no animation at all.
        if (animProgress() >= 1.0 || idx == _animFromTf) {
            _animFromTf = _tf;
        }
        _tf = idx;
        startAnim();
        var age = BGData.ageMinutes(BGData.lastReading());
        if (BGData.cachedHistory(BGData.tfMinutes(_tf)) == null
            || age == null || age >= 6) {
            refresh(false);
        }
    }

    function timeframe() as Number {
        return _tf;
    }

    // Drives the slide: a short fast timer just to redraw at ~50fps until
    // the duration elapses, then stops itself — nothing to leak or reset
    // wrong, since animProgress() below clamps once elapsed >= duration
    // even if this fires late or is killed by onHide mid-swipe.
    private function startAnim() as Void {
        _animStartMs = System.getTimer();
        if (_animTimer == null) {
            _animTimer = new Timer.Timer();
        } else {
            _animTimer.stop();
        }
        _animTimer.start(method(:onAnimTick), 20, true);
    }

    // Null-guarded because onHide can stop and clear the timer between a tick
    // being queued and it running; without this that race calls stop() on
    // null. Cleared once settled so nothing keeps ticking behind a static
    // screen — startAnim() allocates a fresh one on the next swipe.
    function onAnimTick() as Void {
        if (_animTimer == null) {
            return;
        }
        if (System.getTimer() - _animStartMs >= ANIM_DURATION_MS) {
            _animTimer.stop();
            _animTimer = null;
        }
        WatchUi.requestUpdate();
    }

    // 0.0 at swipe start, 1.0 once settled (and forever after, until the
    // next swipe moves _animFromTf again).
    //
    // Eased (cubic ease-out: fast departure, soft landing) rather than linear.
    // Linear motion over a short distance reads as a glitch; the deceleration
    // is most of what makes this look like a page turning rather than a
    // redraw. Clamps at 1.0 on its own, so a late or killed timer degrades to
    // the settled frame instead of freezing mid-slide.
    private function animProgress() as Float {
        if (_animFromTf == _tf) {
            return 1.0;
        }
        var elapsed = System.getTimer() - _animStartMs;
        if (elapsed >= ANIM_DURATION_MS) {
            return 1.0;
        }
        var t = elapsed.toFloat() / ANIM_DURATION_MS;
        var inv = 1.0 - t;
        return 1.0 - (inv * inv * inv);
    }

    // Layout follows the Claude Design handoff ("Glucose Widget
    // Redesign.dc.html"): GLUCOSE title, a navy card holding units / big
    // value / trend stack / range-colored sparkline, then the age line and a
    // freshness chip below the card. The design's date/battery status strip
    // was dropped — it crowded the top arc and the system already surfaces
    // both elsewhere; the card and title take that space instead.
    //
    // The design's freshness states map onto BGData's existing age logic:
    //   fresh (<=7 min)    -> range colors, green SYNCED chip
    //   isWarn (7-20 min)  -> everything muted grey, amber STALE chip
    //   isStale (>20 min)  -> "---", dashed flat trace, grey OFFLINE chip
    // (The warn boundary moved 10 -> 7 with the v4 freshness pass; the tiers
    // are BGData.WARN_AGE_MIN / STALE_AGE_MIN, never repeated as literals.)
    //
    // All positions are screen fractions — font-box math burned us before
    // (see the sparkline note in git history: FONT_NUMBER metrics include
    // enormous invisible padding).
    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        dc.setColor(BGTheme.BG, BGTheme.BG);
        dc.clear();

        var reading = BGData.lastReading();

        if (reading == null) {
            // Setup hints stay on-screen; the wording is BGData's so the
            // glance and this view can never disagree about them.
            dc.setColor(BGTheme.TEXT, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h / 2, Graphics.FONT_MEDIUM, BGData.noDataMessage(),
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            drawStatusLine(dc, cx, h, false);
            drawPageIndicator(dc, cx, h);
            return;
        }

        var offline = BGData.isStale(reading);   // design's "Offline" (>20m)
        var warn = BGData.isWarn(reading);       // design's "Stale" (7-20m)
        var valueColor;
        if (offline) {
            valueColor = BGTheme.OFFLINE;
        } else if (warn) {
            valueColor = BGTheme.DIM;
        } else {
            valueColor = BGTheme.themed(BGData.colorFor(reading));
        }

        // Top label doubles as the timeframe readout for the swipeable frames
        // ("60 MIN" / "3 HR" / "6 HR"). It replaces the old static "GLUCOSE"
        // title: the big number + mg/dL caption already say what this is, and
        // the active window is the more useful thing to surface up here. The
        // page-indicator dots at the bottom show which of the three it is.
        drawTfLabel(dc, cx, w, h);

        // The card. Rounded navy slab with a hairline border; the border
        // goes range-red as a static stand-in for the design's pulsing
        // urgent-low glow (a 1.6s animation loop isn't worth the battery
        // on a widget that should mostly be glanced at).
        var cardX = (w * 11) / 100;
        var cardW = (w * 78) / 100;
        var cardY = (h * 130) / 1000;
        var cardH = (h * 540) / 1000;
        var cardR = (h * 5) / 100;
        dc.setColor(BGTheme.CARD, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cardX, cardY, cardW, cardH, cardR);
        dc.setColor(valueColor == BGTheme.RED ? BGTheme.RED : BGTheme.CARD_BORDER,
                    Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(cardX, cardY, cardW, cardH, cardR);
        dc.setPenWidth(1);

        // Units label at the card's top. A vector font drops it well below
        // FONT_XTINY (the smallest bitmap font) so the units read as a quiet
        // caption rather than a second headline. Falls back to XTINY on any
        // device without vector-font support.
        dc.setColor(BGTheme.SUBTEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cardY + (h * 40) / 1000, unitsFont(h),
                    BGData.useMmol() ? "mmol/L" : "mg/dL",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Big value with the trend stack (arrow over delta) to its right,
        // everything in the range color — the design keeps delta here and
        // only here ("the row below is freshness + connectivity, not a
        // repeat of it"). Offline hides the number entirely: an old value
        // shown big and confident is the dangerous failure mode.
        // FONT_NUMBER_MEDIUM, down from HOT: the reading stays the hero but
        // cedes a band of card height to the chart, which was hard to read.
        var valueStr = offline ? "---" : BGData.formatBg(reading["mgdl"]);
        var valueFont = Graphics.FONT_NUMBER_MEDIUM;
        var valueY = (h * 315) / 1000;
        var valueW = dc.getTextWidthInPixels(valueStr, valueFont);
        var arrowSize = h / 22;
        var arrowSpace = offline ? 0 : (arrowSize * 3 + 10);
        var startX = cx - (valueW + arrowSpace) / 2;

        dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, valueY, valueFont, valueStr,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        if (!offline) {
            var stackX = startX + valueW + 10 + arrowSize;
            BGArrows.draw(dc, stackX, valueY - (h * 22) / 1000, arrowSize,
                          reading["arrow"], valueColor);
            // FONT_XTINY is the smallest font on the platform, so the
            // breathing room comes from distance instead: clear of the
            // arrow's (heavily padded) font box.
            var delta = BGData.formatDelta(reading);
            if (!delta.equals("")) {
                dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(stackX, valueY + (h * 52) / 1000, Graphics.FONT_XTINY,
                            delta,
                            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }

        // Sparkline across the card's lower third, trace in the range color
        // with fixed-frame axis ticks in a left gutter. Offline replaces the
        // trace with a dashed flat line (the design's honest "no data"
        // placeholder) — an old trace shown as current is the dangerous
        // failure.
        // Gutter sized for three digits of FONT_XTINY on the 41mm's 390px
        // screen — at 9% the labels straddled the card border.
        var gutter = (w * 11) / 100;
        var chartX = cardX + gutter + (w * 15) / 1000;
        var chartW = cardX + cardW - (w * 25) / 1000 - chartX;
        var chartTop = (h * 450) / 1000;
        var chartBottom = (h * 650) / 1000;
        if (offline) {
            drawDashedFlat(dc, chartX, (chartTop + chartBottom) / 2, chartW);
        } else {
            drawChart(dc, chartX, chartTop, chartW, chartBottom - chartTop,
                      reading, warn);
        }

        // Age line under the card.
        dc.setColor(BGTheme.SUBTEXT, Graphics.COLOR_TRANSPARENT);
        var age = BGData.formatAge(reading);
        dc.drawText(cx, (h * 725) / 1000, Graphics.FONT_XTINY,
                    age.equals("") ? "" : age + " ago",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Freshness chip, exactly the design's syncChip() ladder. Fetch
        // errors stay on the orange detail line below — the chip is about
        // data freshness, not transport.
        if (offline) {
            drawChip(dc, cx, h, "OFFLINE", BGTheme.OFFLINE, BGTheme.CHIP_OFFLINE_BG);
        } else if (warn) {
            drawChip(dc, cx, h, "STALE", BGTheme.AMBER, BGTheme.CHIP_AMBER_BG);
        } else {
            drawChip(dc, cx, h, "SYNCED", BGTheme.GREEN, BGTheme.CHIP_GREEN_BG);
        }

        drawStatusLine(dc, cx, h, true);
        drawPageIndicator(dc, cx, h);
    }

    // Resolve the units font once and hold it. See _unitsFont.
    private function unitsFont(h as Number) {
        if (!_unitsFontResolved) {
            _unitsFontResolved = true;
            _unitsFont = Graphics.FONT_XTINY;
            if (Graphics has :getVectorFont) {
                var vf = Graphics.getVectorFont({
                    :face => ["RobotoCondensedBold", "RobotoCondensed", "RobotoRegular"],
                    :size => (h * 42) / 1000
                });
                if (vf != null) {
                    _unitsFont = vf;
                }
            }
        }
        return _unitsFont;
    }

    // The plot, including the swipe transition.
    //
    // The bands (shaded in-range zone, urgent lines, gutter labels) draw ONCE
    // and stay put: they're identical in all three windows, so they're the
    // fixed rail the traces move against — which is what sells the motion as
    // one chart being replaced rather than the whole plot flickering. Only the
    // traces slide, clipped to the plot box so nothing smears across the card.
    //
    // Frame 0 (60 min) draws dots; the longer frames draw a line with the
    // recent readings dotted (lineMode = tf != 0). Each series comes from its
    // own cache and is scaled to its own window.
    //
    // warn forces the whole trace grey rather than per-point range colors: at
    // 8-20 minutes old the feed itself is suspect, and coloring each point by
    // range would claim more confidence than the data has earned.
    private function drawChart(dc as Dc, x as Number, y as Number, w as Number,
                               ch as Number, reading as Dictionary,
                               warn as Boolean) as Void {
        var bands = BGData.bands(reading);
        var mono = warn ? BGTheme.DIM : null;
        BGChart.drawBands(dc, x, y, w, ch, bands, true);

        var progress = animProgress();
        if (progress >= 1.0) {
            BGChart.drawTrace(dc, x, y, w, ch,
                              BGData.cachedHistory(BGData.tfMinutes(_tf)),
                              mono, bands, BGData.tfWindowSec(_tf), _tf != 0);
            return;
        }

        // Slide far enough that the outgoing trace fully clears the box. The
        // clip is a few pixels proud of the plot on three sides so the newest
        // -point ring isn't shaved, but stops at x on the left so a sliding
        // trace can never paint over the gutter labels drawn above.
        var dist = w + 10;
        var dir = _tf > _animFromTf ? 1 : -1;
        dc.setClip(x, y - 6, w + 6, ch + 12);
        BGChart.drawTrace(dc, x - (dir * dist * progress).toNumber(), y, w, ch,
                          BGData.cachedHistory(BGData.tfMinutes(_animFromTf)),
                          mono, bands, BGData.tfWindowSec(_animFromTf),
                          _animFromTf != 0);
        BGChart.drawTrace(dc, x + (dir * dist * (1.0 - progress)).toNumber(),
                          y, w, ch,
                          BGData.cachedHistory(BGData.tfMinutes(_tf)),
                          mono, bands, BGData.tfWindowSec(_tf), _tf != 0);
        dc.clearClip();
    }

    // Timeframe label ("60 MIN" / "3 HR" / "6 HR"), sliding out/in on a swipe.
    // Direction follows the swipe: moving to a longer window (tf increasing,
    // a left swipe) slides the old label out to the left and the new one in
    // from the right, and the reverse for a right swipe — matching the same
    // left/right the page dot below moves.
    private function drawTfLabel(dc as Dc, cx as Number, w as Number,
                                 h as Number) as Void {
        var y = (h * 9) / 100;
        dc.setColor(BGTheme.TEXT, Graphics.COLOR_TRANSPARENT);
        var progress = animProgress();
        if (progress >= 1.0) {
            dc.drawText(cx, y, Graphics.FONT_XTINY, BGData.tfLabel(_tf),
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }
        var dist = (w * 28) / 100;
        var dir = _tf > _animFromTf ? 1 : -1;
        var oldX = cx - (dir * dist * progress).toNumber();
        var newX = cx + (dir * dist * (1.0 - progress)).toNumber();
        dc.drawText(oldX, y, Graphics.FONT_XTINY, BGData.tfLabel(_animFromTf),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(newX, y, Graphics.FONT_XTINY, BGData.tfLabel(_tf),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // The offline placeholder: a dashed horizontal line where the trace
    // would be, so "no plot" is clearly deliberate rather than broken.
    private function drawDashedFlat(dc as Dc, x as Number, y as Number,
                                    w as Number) as Void {
        dc.setColor(BGTheme.OFFLINE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        var seg = 8;
        var gap = 7;
        var end = x + w;
        var sx = x;
        while (sx < end) {
            var ex = sx + seg;
            if (ex > end) { ex = end; }
            dc.drawLine(sx, y, ex, y);
            sx = ex + gap;
        }
        dc.setPenWidth(1);
    }

    // Pill-shaped status chip centered below the age line.
    private function drawChip(dc as Dc, cx as Number, h as Number,
                              label as String, fg as Number,
                              bg as Number) as Void {
        var font = Graphics.FONT_XTINY;
        var tw = dc.getTextWidthInPixels(label, font);
        var th = dc.getFontHeight(font);
        var padX = (h * 3) / 100;
        var chipW = tw + padX * 2;
        var chipH = th + (h * 1) / 100;
        var chipY = (h * 785) / 1000 - chipH / 2;
        dc.setColor(bg, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - chipW / 2, chipY, chipW, chipH, chipH / 2);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, chipY + chipH / 2, font, label,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ONE status line, at STATUS_Y: "updating..." while a fetch is in flight,
    // otherwise the last failed fetch. This is what makes a stuck/stale feed
    // diagnosable on-wrist — a failed fetch keeps the previous reading, so
    // without it the error hides behind the old value.
    //
    // These used to be two separate lines, an orange error at 87%h and a blue
    // "updating..." at 90%h, both drawn unconditionally. Their FONT_XTINY boxes
    // OVERLAP by roughly ten pixels on the 390 px venu4, so any fetch made while
    // an error was stored — i.e. every recovery attempt after a -104, the single
    // most common case this app has — rendered the two on top of each other.
    // They are mutually exclusive in meaning anyway: a fetch is in flight, so
    // the stored error is about to be superseded. One slot, one message.
    //
    // The setup sentinels are skipped ONLY when there's no reading to hide
    // behind, because there they already have a big centered message; with a
    // reading on screen nothing is filtered.
    const STATUS_Y_PCT = 87;

    private function statusY(h as Number) as Number {
        return (h * STATUS_Y_PCT) / 100;
    }

    private function drawStatusLine(dc as Dc, cx as Number, h as Number,
                                    hasReading as Boolean) as Void {
        if (_requesting) {
            dc.setColor(0x82ABFF, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, statusY(h), Graphics.FONT_XTINY, "updating...",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }
        var err = BGData.lastError();
        if (err == null) {
            return;
        }
        if (!hasReading
            && (err == BGData.ERR_NO_URL || err == BGData.ERR_NO_TOKEN)) {
            return;
        }
        dc.setColor(BGTheme.ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, statusY(h), Graphics.FONT_XTINY, BGData.lastFetchStatus(),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Page-position dots near the bottom: one per timeframe, the active frame
    // brightened and enlarged. Now that the view has three horizontal pages
    // this is a literal position indicator (and the "swipe horizontally"
    // affordance); the menu is still one tap away.
    // All dots dim, then one brightened "active" dot drawn on top that slides
    // between slots during a swipe instead of jumping — since it's just this
    // one extra circle interpolated by animProgress(), it collapses to the
    // exact old behavior once the swipe settles (progress == 1.0).
    //
    // These used to be suppressed entirely while a fetch was in flight, to
    // keep clear of the "updating..." line. That hid them on precisely the
    // swipes most worth an indicator — landing on a frame whose series isn't
    // cached triggers a refetch — so half the transition disappeared exactly
    // when it was new. Now they always draw, and sit below the fetch line
    // instead of being hidden by it.
    //
    // That clearance is DERIVED from the fetch line's own font box rather than
    // assumed: a hardcoded offset only clears FONT_XTINY at one particular
    // metric, and the two would overlap by a pixel or two on any device or SDK
    // whose XTINY is taller. Anchoring to getFontHeight makes the gap hold
    // whatever the font measures.
    private function drawPageIndicator(dc as Dc, cx as Number, h as Number) as Void {
        // Anchored to the status line's own font box, so the dots keep their
        // clearance whatever XTINY measures on a given device or SDK.
        var y = statusY(h) + dc.getFontHeight(Graphics.FONT_XTINY) / 2 + 6;
        var gap = 14;
        var n = BGData.tfCount();
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < n; i++) {
            var dx = cx + (i * 2 - (n - 1)) * gap / 2;
            dc.fillCircle(dx, y, 3);
        }
        var progress = animProgress();
        var fromX = cx + (_animFromTf * 2 - (n - 1)) * gap / 2;
        var toX = cx + (_tf * 2 - (n - 1)) * gap / 2;
        var activeX = fromX + ((toX - fromX) * progress).toNumber();
        dc.setColor(BGTheme.TEXT, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(activeX, y, 4);
    }
}
