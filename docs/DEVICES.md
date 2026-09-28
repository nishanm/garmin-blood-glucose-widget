# Supported devices

`manifest.xml` lists only `venu441mm` and `venu445mm` — the hardware-tested
pair (identical rendering and touch input; `venu445mm` just has a larger
screen). This is deliberate: the manifest only lists what's actually been
verified, not every device the Connect IQ SDK would technically accept.

## Why the list is short

The UI makes two assumptions that not every Garmin watch satisfies:

1. **Touch, specifically swipe.** The full view's three chart windows
   (60 min / 3 h / 6 h) are changed by a horizontal swipe
   (`source/BGWidgetView.mc`). Button-only devices (the `fenix8`, `epix2`,
   `marq2`, `fenix7`, `instinct3` families and similar) have no equivalent
   gesture and were dropped for exactly this reason.
2. **Color-coded glucose bands.** The glance and full view signal glucose
   range primarily through color (green/yellow/red). MIP (memory-in-pixel)
   displays — the `fr255`/`955`, `fenix7`, `enduro3` families and similar —
   mute or wash out those color differences, especially at low brightness,
   which undermines a safety-relevant signal.

## Adding a device

Before re-adding a watch family, verify both of the above in the simulator
for that specific device:

1. **Swipe alternative.** If the device has no touchscreen, either give it
   a button-driven way to cycle chart windows (a new code path in
   `BGWidgetView.mc`) or accept that it only ever shows the default 60-min
   window.
2. **Contrast check.** Load the glance and full view in the simulator with
   the device's actual color palette (not the SDK's default) and confirm
   the three bands (green/yellow/red) plus the dimmed/stale states are
   visually distinct at low brightness. MIP screens in particular need this
   checked on-device, not just in the simulator, since simulator rendering
   doesn't always reproduce MIP color behavior accurately.

If both check out, add the `<iq:product id="..."/>` entry in `manifest.xml`
and update the comment block explaining why it's there. If you're preparing
a Connect IQ Store submission rather than a personal sideload, you'll
likely want a broader device list than the hardware-tested pair — just make
sure every added device has actually been checked against the two criteria
above, in the simulator at minimum.
