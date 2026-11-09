import Observation
import SwiftUI
import WebKit

/// One YouTube player for the whole app: a WKWebView running YouTube's iframe API. It moves into whichever card is
/// on screen (PlayerSlot), so swiping never creates a second player.
@MainActor @Observable final class YouTubePlayer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    enum State: Int { case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5 }

    private(set) var ready = false
    private(set) var state: State = .unstarted
    /// Which feed currently drives the player (the main feed, or the saved moments).
    var owner: ObjectIdentifier?

    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored private var time: Double = 0
    @ObservationIgnored private var timeAt = Date()
    @ObservationIgnored private var rate: Double = 1
    @ObservationIgnored private var pending: String?
    @ObservationIgnored var onState: ((State) -> Void)?
    @ObservationIgnored var onError: ((Int) -> Void)?

    /// YouTube refuses embeds without a referrer (errors 152/153), so the page gets an https origin of its own.
    static let origin = "https://com.muhammedilyasy.laternow"

    override init() {
        super.init()
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.userContentController.add(WeakHandler(self), name: "ln")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.isScrollEnabled = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.isUserInteractionEnabled = false   // our own gestures sit on top
        w.navigationDelegate = self
        webView = w
        w.loadHTMLString(Self.html, baseURL: URL(string: Self.origin))
    }

    /// The playback position, interpolated between the player's reports for smooth captions.
    var currentTime: Double {
        state == .playing ? time + Date().timeIntervalSince(timeAt) * rate : time
    }

    func load(_ vid: String, start: Double, end: Double, rate r: Double = 1) {
        time = start; timeAt = Date(); rate = r; state = .unstarted
        run("load('\(vid)', \(start), \(end), \(r))")
    }

    func play() { run("p.playVideo()") }
    func pause() { run("p.pauseVideo()") }
    func stop() { run("p.stopVideo()") }
    func seek(_ t: Double) { time = t; timeAt = Date(); run("p.seekTo(\(t), true)") }
    func setRate(_ r: Double) { rate = r; run("p.setPlaybackRate(\(r))") }

    private func run(_ js: String) {
        guard ready else {
            if js.hasPrefix("load(") { pending = js }
            return
        }
        webView.evaluateJavaScript(js) { _, _ in }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any], let e = d["e"] as? String else { return }
        switch e {
        case "ready":
            ready = true
            if let p = pending { pending = nil; webView.evaluateJavaScript(p) { _, _ in } }
        case "state":
            if let t = d["t"] as? Double { time = t; timeAt = Date() }
            let s = State(rawValue: (d["s"] as? Int) ?? -1) ?? .unstarted
            if s != state { state = s; onState?(s) }
        case "time":
            if let t = d["t"] as? Double { time = t; timeAt = Date() }
            if let r = d["r"] as? Double { rate = r }
        case "error":
            onError?((d["c"] as? Int) ?? 0)
        default: break
        }
    }

    /// The web content process can be killed in the background: reload and start over.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.loadHTMLString(Self.html, baseURL: URL(string: Self.origin))
    }

    private static let html = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:0;width:100%;height:100%}</style>
    </head><body><div id="p"></div>
    <script>
    var p, ready = false;
    function post(m){ try { webkit.messageHandlers.ln.postMessage(m) } catch(e){} }
    function onYouTubeIframeAPIReady(){
      p = new YT.Player('p', { width: '100%', height: '100%',
        playerVars: { controls: 0, playsinline: 1, rel: 0, modestbranding: 1, showinfo: 0, iv_load_policy: 3, disablekb: 1, fs: 0, cc_load_policy: 0,
                      autoplay: 1, origin: '\(origin)', widget_referrer: '\(origin)' },
        events: {
          onReady: function(){ ready = true; post({e: 'ready'}) },
          onStateChange: function(e){
            if (e.data === 1) noCC();
            post({e: 'state', s: e.data, t: p.getCurrentTime ? p.getCurrentTime() : 0}) },
          onError: function(e){ post({e: 'error', c: e.data}) }
        } });
    }
    // The app draws its own captions; YouTube's would be drawn into the (scaled up) picture.
    function noCC(){ try { p.unloadModule('captions'); p.unloadModule('cc') } catch(e){} }
    function load(v, s, e, r){
      p.loadVideoById({videoId: v, startSeconds: s, endSeconds: e, suggestedQuality: 'hd720'});
      p.unMute(); p.setVolume(100); p.setPlaybackRate(r);
    }
    setInterval(function(){
      if (ready && p.getPlayerState && p.getPlayerState() === 1) post({e: 'time', t: p.getCurrentTime(), r: p.getPlaybackRate()});
    }, 200);
    </script>
    <script src="https://www.youtube.com/iframe_api"></script>
    </body></html>
    """
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// Where the shared player appears inside a card. Only the active card hosts it; the others show the thumbnail.
struct PlayerSlot: UIViewRepresentable {
    let player: YouTubePlayer
    let active: Bool
    let visible: Bool
    /// Fill the slot's height and crop the sides (portrait), instead of fitting the slot.
    var fill = false

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ v: Host, context: Context) {
        guard active else { return }
        if v.fill != fill { v.fill = fill; v.setNeedsLayout() }
        let w = player.webView!
        if w.superview !== v {
            w.removeFromSuperview()
            w.alpha = 0
            v.addSubview(w)
            v.setNeedsLayout()
        }
        let a: CGFloat = visible ? 1 : 0
        if w.alpha != a { UIView.animate(withDuration: 0.25) { w.alpha = a } }
    }

    final class Host: UIView {
        var fill = false
        override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; clipsToBounds = true }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            // The player draws 16:9 edge to edge, so a frame that's 16:9 at full height fills a tall slot.
            let w = fill ? max(bounds.width, bounds.height * 16 / 9) : bounds.width
            // Taller than the slot, like the web app: the picture keeps its size and YouTube's title bar (top) and
            // logo (bottom) fall outside and are clipped.
            let bleed: CGFloat = 70
            for s in subviews {
                s.frame = CGRect(x: (bounds.width - w) / 2, y: -bleed, width: w, height: bounds.height + bleed * 2)
            }
        }
    }
}
