import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.PersistedContent;
import Toybox.System;

// Runs every 5 minutes (even while the app is closed) in the constrained
// background context: minimal allocations, and the parsed result goes back
// to BGWidgetApp.onBackgroundData via Background.exit(). This is the ONLY
// place that touches the network unprompted — views render from Storage
// (the full view may also fetch on demand; see BGWidgetView).
//
// Always exactly one request: the endpoint rides Nightscout's color
// thresholds along with the reading, so there is nothing to chain.
(:background)
class BGServiceDelegate extends System.ServiceDelegate {

    function initialize() {
        ServiceDelegate.initialize();
    }

    function onTemporalEvent() as Void {
        // requestSpec asks for the reading only, no history: this payload stays
        // as small as it has always been. Charting is the full view's business.
        var spec = BGData.requestSpec();
        if (spec["err"] != null) {
            Background.exit(spec);
            return;
        }
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
    }

    // Signature must match makeWebRequest's documented callback type exactly
    // or strict type checking rejects the method reference above.
    function onReceive(responseCode as Number,
                       data as Dictionary or String or PersistedContent.Iterator or Null) as Void {
        // Recorded BEFORE Background.exit, and independently of it. Everything
        // downstream of this line depends on the payload actually being
        // delivered to onBackgroundData; this ring does not, which is what
        // makes it able to see the failures the menu's counter cannot.
        // phoneConnected is sampled HERE, at fetch time -- that is the field
        // that distinguishes a genuine out-of-range -104 from a proxy problem.
        BGData.recordAttempt(responseCode, BGData.phoneConnected());
        Background.exit(BGData.parseResponse(responseCode, data));
    }
}
