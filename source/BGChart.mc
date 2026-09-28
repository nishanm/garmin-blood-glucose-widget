import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;

// Sparkline for the full view's card, over the caller's chosen window (the
// swipeable 60 min / 3 h / 6 h frames). Not (:glance) — the glance row has no
// space for a plot and a tighter memory budget; it stays icon + number +
// arrow + delta.
//
// Purely additive by design: nothing here paints unless it can produce an
// honest plot (no series, too few points, no room, out-of-window data all draw
// nothing). A build with no history data therefore renders exactly as it did
// before charting existed — the chart can fail without touching the reading.
//
// Split into two halves on purpose:
//   drawBands()  — the band shading, urgent lines and gutter labels. These
//                  depend only on the thresholds, so they are IDENTICAL in all
//                  three swipe windows.
//   drawTrace()  — the series itself, the only thing a swipe actually changes.
// That split is what lets the view slide one trace out and the next in against
// a stationary rail of bands, instead of hard-cutting the whole plot.
module BGChart {

    const MIN_W = 40;
    // The card band is genuinely tight, so accept a short plot — but not one
    // so squashed that the trace is a meaningless smear.
    const MIN_H = 18;

    // Only the most recent few readings get dots in line mode — the
    // actionable points.
    const TAIL_DOTS = 4;

    // Point buffers, allocated once at module scope rather than per draw.
    // draw-time allocation was three `new [n]` arrays every render, which was
    // invisible at one frame per 30 s and is not once a swipe transition
    // redraws two traces at ~50 fps. Reused across calls, which is safe
    // because a drawTrace() call fills and consumes them before returning —
    // the two traces in a transition are drawn one after the other, never
    // interleaved. The endpoint downsamples every window to <= 30 points, so
    // 64 is ample headroom; a longer series is truncated to the newest 64
    // rather than overrunning.
    const MAX_PTS = 64;
    var _xs = new [MAX_PTS];
    var _ys = new [MAX_PTS];
    var _ages = new [MAX_PTS];
    var _cols = new [MAX_PTS];

    // The stationary part of the plot: a shaded in-range band plus a line at
    // each urgent threshold, with values in the left gutter.
    //
    // The shaded band (low..high) replaced a lone yellow line at `high`. With
    // only the high and urgent-low lines drawn, the two thresholds in between
    // were invisible, so a reading of 85 — colored YELLOW up in the card,
    // because it is under the low band of 90 — plotted above the red line and
    // below the yellow one, i.e. looked in range. The number and the chart
    // disagreed about the same reading. Shading the actual in-range band means
    // a point is inside it or it is not, which is the same question the
    // color answers.
    //
    // Returns nothing; the caller owns the layout and decides there's room.
    function drawBands(dc as Graphics.Dc, x as Number, y as Number, w as Number,
                       h as Number, bands as Dictionary,
                       labels as Boolean) as Void {
        if (w < MIN_W || h < MIN_H) {
            return;
        }
        var lo = BGData.frameLo(bands);
        var span = BGData.frameHi(bands) - lo;
        if (span <= 0) {
            return;
        }

        // In-range band first, underneath everything.
        var lowT = bands["l"];
        var highT = bands["h"];
        if (lowT < highT) {
            var yTop = yFor(highT, lo, span, y, h);
            var yBot = yFor(lowT, lo, span, y, h);
            dc.setColor(BGTheme.BAND_IN_RANGE, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, yTop, w, yBot - yTop);
        }

        // Urgent lines. Both are inside the frame by construction now that
        // BGData.frameHi/frameLo pad past them, but the bounds check stays:
        // a hand-edited manual threshold can still be anything.
        var yUrgentLow = -1;
        var yUrgentHigh = -1;
        dc.setPenWidth(2);
        dc.setColor(BGTheme.RED, Graphics.COLOR_TRANSPARENT);
        if (bands["ul"] >= lo && bands["ul"] <= lo + span) {
            yUrgentLow = yFor(bands["ul"], lo, span, y, h);
            dc.drawLine(x, yUrgentLow, x + w, yUrgentLow);
        }
        if (bands["uh"] >= lo && bands["uh"] <= lo + span) {
            yUrgentHigh = yFor(bands["uh"], lo, span, y, h);
            dc.drawLine(x, yUrgentHigh, x + w, yUrgentHigh);
        }
        dc.setPenWidth(1);

        if (!labels) {
            return;
        }

        // Gutter labels, most-actionable first, each skipped if it would
        // collide with one already drawn. Font boxes are ~40% padding, so
        // glyphs stay clear well below a full font-height of separation.
        // Priority order matters: the band top and the urgent low are what
        // you read on a wrist; the urgent high is nice to have if it fits.
        var fh = dc.getFontHeight(Graphics.FONT_XTINY);
        var minGap = (fh * 2) / 3;
        var drawnY = [-1000, -1000, -1000];
        var drawnN = 0;
        var candV = [highT, bands["ul"], bands["uh"]];
        var candC = [BGTheme.YELLOW, BGTheme.RED, BGTheme.RED];
        for (var i = 0; i < 3; i++) {
            var val = candV[i];
            if (val < lo || val > lo + span) {
                continue;
            }
            var ly = yFor(val, lo, span, y, h);
            var clear = true;
            for (var j = 0; j < drawnN; j++) {
                if ((ly - drawnY[j]).abs() < minGap) {
                    clear = false;
                }
            }
            if (!clear) {
                continue;
            }
            dc.setColor(candC[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(x - 5, ly, Graphics.FONT_XTINY, BGData.formatBg(val),
                        Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            drawnY[drawnN] = ly;
            drawnN++;
        }
    }

    // The moving part: the series for one window. Returns true if a trace was
    // drawn. x/y is the top-left of the plot box — the swipe transition passes
    // an x offset from the real box and clips, which is the whole reason this
    // is separate from drawBands.
    //
    // windowSec is the selected timeframe's span (60/180/360 min in seconds):
    // it scales the x-axis and filters out anything older than the frame.
    // lineMode false = the 60-min frame, drawn as one dot per reading.
    // lineMode true = the 3 h / 6 h frames, drawn as a connected line (broken
    // across sensor gaps) with only the most recent few readings marked as
    // dots, so the smoothed history reads as a trend and the actionable recent
    // points still stand out.
    //
    // monoColor null = every point colored by its own value against `bands`
    // (the normal, Nightscout-like rendering). Non-null forces the whole trace
    // to that one color, which is how the stale/warn state paints everything
    // grey: when the feed itself is suspect, per-point range colors would be
    // claiming more confidence than the data deserves.
    function drawTrace(dc as Graphics.Dc, x as Number, y as Number, w as Number,
                       h as Number, hist as Dictionary?, monoColor as Number?,
                       bands as Dictionary, windowSec as Number,
                       lineMode as Boolean) as Boolean {
        if (hist == null || w < MIN_W || h < MIN_H) {
            return false;
        }
        var a = hist["a"];
        var v = hist["v"];
        if (!(a instanceof Array) || !(v instanceof Array)) {
            return false;
        }
        var n = a.size();
        if (n < 2 || v.size() != n) {
            return false;
        }

        // Age the whole series forward by how long ago we fetched it, so the
        // trace slides left in real time instead of freezing at fetch time.
        var drift = 0;
        var fetched = hist["fetched"];
        if (fetched instanceof Number) {
            var since = Time.now().value() - fetched;
            if (since > 0) {
                drift = since;
            }
        }

        var lo = BGData.frameLo(bands);
        var hi = BGData.frameHi(bands);
        var span = hi - lo;
        if (span <= 0) {
            return false;
        }

        // Collect the in-window points once (oldest-first, as the series is),
        // clamped to the fixed vertical frame. Out-of-window / drifted-past
        // points drop out so the trace slides left honestly. Colors are
        // resolved from the UNCLAMPED value, so a reading past the frame edge
        // still paints as the urgent it is.
        var first = n > MAX_PTS ? n - MAX_PTS : 0;
        var m = 0;
        for (var i = first; i < n; i++) {
            var age = a[i] + drift;
            if (age > windowSec || age < 0) {
                continue;
            }
            var raw = v[i];
            var val = raw;
            if (val < lo) { val = lo; }
            if (val > hi) { val = hi; }
            _xs[m] = xFor(age, x, w, windowSec);
            _ys[m] = yFor(val, lo, span, y, h);
            _ages[m] = age;
            _cols[m] = monoColor != null
                ? monoColor
                : BGTheme.themed(BGData.colorForBands(raw, bands));
            m++;
        }
        if (m == 0) {
            return false;
        }

        if (lineMode) {
            // Connected line for the trend, but lift the pen wherever two
            // consecutive plotted points straddle a sensor gap — no faked
            // continuity, same rule the dots imply. Ages are oldest-first, so
            // the older point's age is the larger one. Each segment takes the
            // NEWER endpoint's color, so a run climbing out of range turns at
            // the point that crossed rather than a segment early.
            dc.setPenWidth(2);
            for (var i = 1; i < m; i++) {
                if (_ages[i - 1] - _ages[i] <= BGData.HIST_GAP_SEC) {
                    dc.setColor(_cols[i], Graphics.COLOR_TRANSPARENT);
                    dc.drawLine(_xs[i - 1], _ys[i - 1], _xs[i], _ys[i]);
                }
            }
            dc.setPenWidth(1);
            // Mark only the most recent few readings as dots on top of the
            // line — the actionable points.
            var tail = m < TAIL_DOTS ? m : TAIL_DOTS;
            for (var i = m - tail; i < m; i++) {
                dc.setColor(_cols[i], Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(_xs[i], _ys[i], 3);
            }
        } else {
            // 60-min frame: one dot per reading, the Dexcom rendering —
            // honest about the 5-minute cadence, gaps show as gaps.
            for (var i = 0; i < m; i++) {
                dc.setColor(_cols[i], Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(_xs[i], _ys[i], 3);
            }
        }

        // Newest point becomes a hollow ring (Dexcom's "now" marker) so the
        // eye lands on the reading shown above it. Series is oldest-first, so
        // the last point is the newest; redraw over the card color first so a
        // filled dot underneath doesn't peek through.
        var nx = _xs[m - 1];
        var ny = _ys[m - 1];
        dc.setColor(BGTheme.CARD, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(nx, ny, 5);
        dc.setColor(_cols[m - 1], Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(nx, ny, 5);
        dc.setPenWidth(1);
        return true;
    }

    // Newest at the right edge, oldest at the left; windowSec sets the scale.
    function xFor(age as Number, x as Number, w as Number,
                  windowSec as Number) as Number {
        var frac = age.toFloat() / windowSec.toFloat();
        return (x + w - (frac * w)).toNumber();
    }

    function yFor(mgdl as Number, lo as Number, span as Number,
                  y as Number, h as Number) as Number {
        var frac = (mgdl - lo).toFloat() / span.toFloat();
        return (y + h - (frac * h)).toNumber();
    }
}
