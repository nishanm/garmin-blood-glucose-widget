import Toybox.Graphics;
import Toybox.Lang;

// Palette from the Claude Design handoff ("Glucose Widget Redesign.dc.html",
// 2026-07-17), which iterated on the earlier Stitch VitalPulse mockups.
// Solid-fill approximations: Connect IQ has no alpha blending, so the
// design's translucent chips/cards are pre-blended here against the navy
// base. AMOLED devices render these exactly; MIP devices quantize to their
// nearest palette color.
//
// (:glance) so the glance row can share the same tones as the full view.
(:glance)
module BGTheme {

    const BG          = 0x0B1326;  // design surface navy, not pure black
    const CARD        = 0x141C30;  // rgba(23,31,51,.75) over BG
    const CARD_BORDER = 0x272F40;  // rgba(255,255,255,.08) over CARD
    const TEXT        = 0xDAE2FD;  // on-surface
    const SUBTEXT     = 0x9AA4C4;  // muted labels (units, timestamps)
    const DIM         = 0x9AA4C4;  // warn-value grey (BGData.WARN_AGE_MIN..STALE_AGE_MIN)
    const OFFLINE     = 0x7A8195;  // offline grey (>20 min: "---", chip)

    // Range colors. The design demos only green/red; yellow stays for the
    // mid-band warning colorFor() can still return (Nightscout thresholds
    // have a low/high band between "in range" and "urgent").
    const GREEN  = 0x4BE277;
    const RED    = 0xFF5A5F;
    const YELLOW = 0xFFC24B;
    const AMBER  = 0xE0B355;   // "Stale" chip text (design #e0b355)

    // In-range band fill behind the chart trace: GREEN at ~12% over CARD,
    // pre-blended (Connect IQ has no alpha). Deliberately dim — it has to read
    // as "the target zone" behind the dots without competing with them, since
    // the dots are the thing you actually look at.
    const BAND_IN_RANGE = 0x1B3439;

    // Chip fills: the design's 16%-alpha tints pre-blended over BG.
    const CHIP_GREEN_BG   = 0x153B2A;
    const CHIP_AMBER_BG   = 0x35301C;
    const CHIP_OFFLINE_BG = 0x1D2334;

    const ORANGE = 0xFFA94D;   // fetch-error detail line

    // NOTE: an AXIS grey lived here for chart gutter labels. Those labels have
    // been drawn in their own threshold colors (YELLOW / RED) since the v5
    // chart-honesty pass — the whole point being that a label reads as the band
    // it marks — so nothing referenced it. Removed 2026-08-16.

    // colorFor() keeps returning the Graphics built-ins (state logic stays
    // in BGData, untouched); views run the result through this to land on
    // the palette. Unknown colors pass through so nothing can go invisible.
    function themed(color as Number) as Number {
        if (color == Graphics.COLOR_GREEN)   { return GREEN; }
        if (color == Graphics.COLOR_YELLOW)  { return YELLOW; }
        if (color == Graphics.COLOR_RED)     { return RED; }
        if (color == Graphics.COLOR_LT_GRAY) { return DIM; }
        return color;
    }
}
