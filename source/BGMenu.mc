import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;


// Full-screen view input: a tap (or the MENU gesture) opens the pull-out
// menu below — Refresh + settings. This is the model the app has always
// used; a plain tap reliably opens it, unlike the touch-and-hold/MENU
// gesture which isn't discoverable on the Venu. Sideloaded apps can't use
// the Garmin Connect settings editor, so this is the only interactive
// config surface.
class BGWidgetDelegate extends WatchUi.BehaviorDelegate {

    private var _view as BGWidgetView;

    function initialize(view as BGWidgetView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        pushMenu();
        return true;
    }

    function onMenu() as Boolean {
        pushMenu();
        return true;
    }

    // Horizontal swipe changes the charted window: left = zoom out to a longer
    // frame, right = zoom back in. No wrap. Swiping right off the shortest
    // (60 min) frame is NOT consumed, so the system's own back gesture pops the
    // view — the user is never trapped. Tap still opens the menu; the two don't
    // collide.
    //
    // NOTE: horizontal-swipe handling on the Venu is finicky (the system can
    // claim it for back/exit) — verify on hardware. If it proves unreliable the
    // fallback is tap-to-cycle with the menu moved to a hold gesture.
    function onSwipe(evt as WatchUi.SwipeEvent) as Boolean {
        var dir = evt.getDirection();
        var tf = _view.timeframe();
        if (dir == WatchUi.SWIPE_LEFT) {
            if (tf < BGData.tfCount() - 1) {
                _view.setTimeframe(tf + 1);
            }
            return true;
        }
        if (dir == WatchUi.SWIPE_RIGHT) {
            if (tf > 0) {
                _view.setTimeframe(tf - 1);
                return true;
            }
            return false; // let the system go back from the default frame
        }
        return false;
    }

    private function pushMenu() as Void {
        var title = WatchUi.loadResource(Rez.Strings.AppName);
        var menu = new WatchUi.Menu2({
            :title => title instanceof String ? title : "BG Glance"
        });
        // Refresh is the primary action; its sublabel doubles as a status
        // line — the last fetch result, including the error code when a
        // fetch failed, so problems are legible without pulling device logs.
        // Sublabel reports the AUTOMATIC every-5-min service, not the last
        // fetch by either path.
        //
        // Two reasons it is this and not lastFetchStatus(). First, the full
        // view already draws lastFetchStatus() on screen (BGWidgetView, the
        // line under the chart), so putting it here too spends a row saying
        // something already visible. Second, it actively misleads: both fetch
        // paths write it and opening this menu refreshes it in the foreground,
        // so a background service dead for hours still reads "Updated now" --
        // which is why a disarmed temporal event took a server-log read to
        // find on 2026-08-16. The automatic fetcher is the one thing the watch
        // could not otherwise tell you about, and this is the row that owns it.
        menu.addItem(new WatchUi.MenuItem(
            "Refresh now", "Auto-fetch: " + BGData.backgroundStatus(), :refresh, null));
        // ON = color bands inherited from Nightscout with every reading
        // (the default, and the "reset to Nightscout" action).
        // OFF = the manual thresholds baked into this build.
        //
        // The sublabel is the LIVE band values, not a static description, so
        // what this toggle actually controls is legible on-wrist: source plus
        // urgent-low / low / high / urgent-high in mg/dL. The old fixed
        // "Bands from Nightscout" text couldn't show that the two sides
        // currently resolve to the same numbers (Nightscout is configured
        // 80/90/180/230, identical to this build's manual fallbacks), which
        // made the toggle look broken — it flips, and nothing on screen moves.
        menu.addItem(new WatchUi.ToggleMenuItem(
            "Nightscout colors",
            BGData.bandsSummary(),
            :nsColors,
            BGData.useNsThresholds(),
            null
        ));
        // Informational footer: version + build variant, so a sideload can be
        // identified on-wrist. Loaded here in widget scope (glance/background
        // scope can't load resources); non-interactive — tapping it is a no-op.
        // Diagnostics: default OFF. Sublabel states the cost plainly rather
        // than just "on"/"off" -- this one adds a query parameter to every
        // background request, so it should be switched on for an investigation
        // window and back off afterwards, not left running.
        menu.addItem(new WatchUi.ToggleMenuItem(
            "Diagnostics",
            BGData.useDiagnostics() ? "Reporting fetch outcomes" : "Off (normal)",
            :diagnostics,
            BGData.useDiagnostics(),
            null
        ));
        var variant = WatchUi.loadResource(Rez.Strings.BuildVariant);
        menu.addItem(new WatchUi.MenuItem(
            "Build",
            BGData.BUILD_VERSION + " · " + (variant instanceof String ? variant : "generic"),
            :version,
            null));
        WatchUi.pushView(menu, new BGMenuDelegate(_view), WatchUi.SLIDE_UP);
    }
}

class BGMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _view as BGWidgetView;

    function initialize(view as BGWidgetView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :refresh) {
            // Fetch, then drop back to the view to watch it land.
            // true = ?live=1: the one deliberate press, so read Nightscout
            // directly rather than the server's database row.
            _view.refresh(true);
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        } else if (id == :nsColors && item instanceof WatchUi.ToggleMenuItem) {
            Application.Properties.setValue("useNsThresholds", item.isEnabled());
            WatchUi.requestUpdate();
        } else if (id == :diagnostics && item instanceof WatchUi.ToggleMenuItem) {
            Application.Properties.setValue("diagnostics", item.isEnabled());
            WatchUi.requestUpdate();
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
