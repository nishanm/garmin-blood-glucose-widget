import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

(:glance, :background)
class BGWidgetApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() {
        registerTemporalEvent();
        var view = new BGWidgetView();
        return [view, new BGWidgetDelegate(view)];
    }

    (:glance)
    function getGlanceView() {
        registerTemporalEvent();
        return [new BGGlanceView()];
    }

    function getServiceDelegate() {
        return [new BGServiceDelegate()];
    }

    // Delivered by the system when the background service exits; runs in the
    // main app context, so Storage and WatchUi are both safe here.
    function onBackgroundData(data) as Void {
        if (data instanceof Dictionary) {
            // storeFromBackground, not store: it does the same thing and ALSO
            // records that the every-5-min service is the one that produced
            // this, which is what the menu's Background row reports. A
            // foreground fetch must never touch that bookkeeping.
            BGData.storeFromBackground(data);
        }
        WatchUi.requestUpdate();
    }

    function onSettingsChanged() as Void {
        WatchUi.requestUpdate();
    }

    // 5 minutes is the minimum interval Connect IQ allows for temporal
    // events, and conveniently matches the Dexcom reading cadence.
    private function registerTemporalEvent() as Void {
        if (Toybox.System has :ServiceDelegate) {
            Background.registerForTemporalEvent(new Time.Duration(5 * 60));
        }
    }
}
