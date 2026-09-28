import Toybox.Graphics;
import Toybox.Lang;

// Trend arrows drawn as a shaft plus a head — Garmin fonts don't reliably
// include unicode arrow glyphs, and ASCII stand-ins ("-") read as minus
// signs next to a negative delta. Shared by the glance and the full view
// ((:glance) code is available to the foreground app too).
(:glance)
module BGArrows {

    // Draws the arrow for a trend code centered at (x, y) with unit size s.
    // Returns the horizontal width consumed, so callers can advance a cursor.
    function draw(dc as Graphics.Dc, x as Number, y as Number, s as Number,
                  code, color as Number) as Number {
        if (!(code instanceof String)) {
            code = "?";
        }
        // Unit direction per trend code (screen coords: +y is down).
        var dx = 0.0;
        var dy = 0.0;
        var count = 1;
        if (code.equals("U2")) { dy = -1.0; count = 2; }
        else if (code.equals("U")) { dy = -1.0; }
        else if (code.equals("U4")) { dx = 0.707; dy = -0.707; }
        else if (code.equals("F")) { dx = 1.0; }
        else if (code.equals("D4")) { dx = 0.707; dy = 0.707; }
        else if (code.equals("D")) { dy = 1.0; }
        else if (code.equals("D2")) { dy = 1.0; count = 2; }
        else {
            // "?" / "!" — no direction to draw, show the character itself.
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, Graphics.FONT_GLANCE, code,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return dc.getTextWidthInPixels(code, Graphics.FONT_GLANCE);
        }

        // Perpendicular for the head base (and for offsetting doubles).
        var px = -dy;
        var py = dx;

        // Tip and tail sit +/- half along the direction of travel; the shaft
        // runs from the tail to the head base. Head kept narrower than the
        // old solid wedge so this reads as an arrow rather than a triangle.
        var half = s * 1.2;
        var headLen = s * 0.95;
        var headHalf = s * 0.6;
        var pen = (s * 0.32).toNumber();
        if (pen < 2) {
            pen = 2;
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(pen);
        for (var i = 0; i < count; i++) {
            // Doubles sit side by side across the direction of travel.
            var off = (count == 2) ? ((i == 0 ? -0.8 : 0.8) * s) : 0.0;
            var ox = x + px * off;
            var oy = y + py * off;
            var tipX = ox + dx * half;
            var tipY = oy + dy * half;
            var baseX = tipX - dx * headLen;
            var baseY = tipY - dy * headLen;
            dc.drawLine((ox - dx * half).toNumber(), (oy - dy * half).toNumber(),
                        baseX.toNumber(), baseY.toNumber());
            dc.fillPolygon([
                [tipX.toNumber(), tipY.toNumber()],
                [(baseX + px * headHalf).toNumber(), (baseY + py * headHalf).toNumber()],
                [(baseX - px * headHalf).toNumber(), (baseY - py * headHalf).toNumber()]
            ]);
        }
        // Pen width is device state, not per-draw — leave it as we found it.
        dc.setPenWidth(1);
        return (count == 2) ? (s * 3).toNumber() : (s * 2).toNumber();
    }
}
