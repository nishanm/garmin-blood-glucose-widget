import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// The row shown in the glance carousel (the swipe-up stack alongside
// calendar / weather / steps). Renders purely from Storage; never touches
// the network.
//
// Layout per the Claude Design handoff (meta small on top, vitals below):
//   BG · 7m                   (small, grey — title + reading age)
//   ● 117 ▶ -4                (drop icon, value, arrow, delta — one line,
//                              all in the range color; dimmed 10-20 min)
// Stale (>20 min): --- STALE Xm.
//
// No background fill anywhere: the system composites glances onto its own
// card background, so painting black would leave a mismatched slab.
(:glance)
class BGGlanceView extends WatchUi.GlanceView {

    function initialize() {
        GlanceView.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        var h = dc.getHeight();
        var titleY = h / 4;
        var mainY = (h * 3) / 4;

        var reading = BGData.lastReading();

        // Title row: "name · age" in a quiet grey, per the design. Title is
        // read per-render so a settings change shows up without a restart.
        var title = BGData.glanceTitle();
        var age = BGData.formatAge(reading);
        if (!age.equals("")) {
            title += " · " + age;
        }
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, titleY, Graphics.FONT_GLANCE, title,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        if (reading == null) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(0, mainY, Graphics.FONT_GLANCE, BGData.noDataMessage(),
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        if (BGData.isStale(reading)) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(0, mainY, Graphics.FONT_GLANCE,
                        "---  STALE " + age,
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var warn = BGData.isWarn(reading);
        var valueColor = warn ? BGTheme.DIM
                              : BGTheme.themed(BGData.colorFor(reading));

        // Drop icon leading the line, in the range color. The design's
        // teardrop (circle with a sharp top corner) drawn as a filled
        // circle plus a triangle tip.
        var r = h / 8;
        var ix = r + 2;
        var icy = mainY + r / 3;
        dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(ix, icy, r);
        dc.fillPolygon([
            [ix, icy - (r * 18) / 10],
            [ix - (r * 8) / 10, icy - (r * 5) / 10],
            [ix + (r * 8) / 10, icy - (r * 5) / 10]
        ]);
        var x = ix + r + 10;

        // Big value
        var valueStr = BGData.formatBg(reading["mgdl"]);
        dc.drawText(x, mainY, Graphics.FONT_GLANCE_NUMBER, valueStr,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        x += dc.getTextWidthInPixels(valueStr, Graphics.FONT_GLANCE_NUMBER) + 12;

        // Drawn trend arrow in the same state color
        var s = h / 7;
        x += BGArrows.draw(dc, x + s, mainY, s, reading["arrow"], valueColor) + 14;

        // Delta rides in the range color too — the design keeps the whole
        // vitals line one color (the warn state dims all of it together).
        var delta = BGData.formatDelta(reading);
        if (!delta.equals("")) {
            dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, mainY, Graphics.FONT_GLANCE, delta,
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}
