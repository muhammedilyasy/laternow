import Observation
import SwiftUI

enum FeedItem: Identifiable, Hashable {
    case moment(FeedMoment)
    case breather(id: Int, recap: [String], secs: Double)
    case end

    var id: String {
        switch self {
        case .moment(let m): "m\(m.id)"
        case .breather(let id, _, _): "b\(id)"
        case .end: "end"
        }
    }

    var moment: FeedMoment? { if case .moment(let m) = self { m } else { nil } }
}

/// One vertical feed: the main one, or saved moments. Same playback rules as web/app.js.
@MainActor @Observable final class FeedModel {
    let engine: Engine
    let player: YouTubePlayer
    let savedOnly: Bool

    private(set) var items: [FeedItem] = []
    var currentID: String?
    private(set) var topic: String?
    private(set) var exhausted = false
    private(set) var loaded = false
    private(set) var time: Double = 0
    private(set) var liked: Set<Int> = []
    private(set) var showVideo = false
    private(set) var paused = false
    private(set) var fast = false
    var toast: String?

    @ObservationIgnored private var cur = -1
    @ObservationIgnored private var watched: Double = 0
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var actAt = Date.distantPast
    @ObservationIgnored private var reported: Set<Int> = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var firstLoad = true
    @ObservationIgnored private var sinceBreak: [String] = []
    @ObservationIgnored private var breakSecs: Double = 0
    @ObservationIgnored private var breaks = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activateTask: Task<Void, Never>?
    @ObservationIgnored private var lastBeat = Date.distantPast
    @ObservationIgnored private var attached = false

    static let breakEvery = 10   // a breather card after this many moments

    init(engine: Engine, player: YouTubePlayer, savedOnly: Bool = false) {
        self.engine = engine; self.player = player; self.savedOnly = savedOnly
    }

    var isOwner: Bool { player.owner == ObjectIdentifier(self) }
    var current: FeedItem? { cur >= 0 && cur < items.count ? items[cur] : nil }
    var realCount: Int { items.filter { $0.moment != nil }.count }

    // MARK: - Lifecycle

    /// Take the player and start (or continue) playing the card on screen.
    func attach() {
        guard !attached else { return }
        attached = true
        player.owner = ObjectIdentifier(self)
        player.onState = { [weak self] s in self?.stateChanged(s) }
        player.onError = { [weak self] c in self?.playerError(c) }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(125))
                self?.tick()
            }
        }
        if !loaded { reload() }
        else if cur >= 0 { activate(cur, from: time > 0 ? time : nil) }
        else if !items.isEmpty { activate(0) }
    }

    /// Saved moments: start from the top with whatever is saved now.
    func reloadOnAttach() {
        if !attached { loaded = false }
    }

    /// Stop playing (another tab or screen is in front, or the app went to the background).
    func detach() {
        guard attached else { return }
        attached = false
        ticker?.cancel()
        if let m = current?.moment {
            engine.setProgress(m.id, t: player.currentTime)
            report()
            reported.remove(m.id)   // coming back to it later counts as a new view
        }
        if isOwner { player.pause() }
        showVideo = false
    }

    func setTopic(_ t: String?) {
        guard t != topic else { return }
        topic = t
        reload()
    }

    func reload() {
        report()
        items = []; cur = -1; currentID = nil; exhausted = false; firstLoad = true
        sinceBreak = []; breakSecs = 0; showVideo = false; paused = false
        if isOwner { player.pause() }
        more()
        loaded = true
        if let first = items.first { currentID = first.id; activate(0) }
    }

    /// Called when the feed is empty and new moments become ready.
    func refreshIfEmpty() {
        if realCount == 0 { reload() }
        else if exhausted { exhausted = false; items.removeAll { $0 == .end }; more() }
    }

    func more() {
        guard !loading, !exhausted else { return }
        loading = true
        defer { loading = false }
        let exclude = Set(items.compactMap { $0.moment?.id })
        let got = engine.feed(n: 6, exclude: exclude, topic: topic, saved: savedOnly, resume: firstLoad && !savedOnly)
        firstLoad = false
        if got.isEmpty { exhausted = true }
        for m in got {
            items.append(.moment(m))
            sinceBreak.append(m.m.title); breakSecs += m.m.end - m.m.start
            if !savedOnly && sinceBreak.count >= FeedModel.breakEvery {
                breaks += 1
                items.append(.breather(id: breaks, recap: sinceBreak, secs: breakSecs))
                sinceBreak = []; breakSecs = 0
            }
        }
        if exhausted && realCount > 0 && !items.contains(.end) { items.append(.end) }
    }

    // MARK: - Scrolling

    /// The scroll view settled on a new card.
    func scrolled(to id: String?) {
        activateTask?.cancel()
        guard let id, let i = items.firstIndex(where: { $0.id == id }), i != cur else { return }
        showVideo = false
        activateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self, self.currentID == id else { return }
            self.activate(i)
        }
    }

    func go(_ i: Int) {
        guard i >= 0, i < items.count else { return }
        withAnimation(.smooth(duration: 0.35)) { currentID = items[i].id }
    }

    func next() { go(cur + 1) }

    private func activate(_ i: Int, from: Double? = nil) {
        if i != cur { report() }
        cur = i; watched = 0; settled = false; paused = false; actAt = Date()
        if i >= items.count - 3 { more() }
        guard let m = items[i].moment else {   // breather / end card: stop the video
            if isOwner { player.pause() }
            showVideo = false
            return
        }
        guard attached else { return }
        player.owner = ObjectIdentifier(self)
        // Continue at the second it was left, not at the start of the moment.
        var start = m.m.start
        if let t = from ?? m.resumeT, t > m.m.start, t < m.m.end - 2 { start = t }
        if case .moment(var mm) = items[i], mm.resumeT != nil { mm.resumeT = nil; items[i] = .moment(mm) }
        time = start
        player.load(m.m.vid, start: start, end: m.m.end, rate: fast ? 2 : 1)
        engine.setProgress(m.id, t: start)
    }

    private func report(_ action: String? = nil) {
        guard let m = current?.moment, !reported.contains(m.id) else { return }
        reported.insert(m.id)
        engine.event(m.id, watched: watched, dur: m.m.end - m.m.start, action: action ?? (watched < 3 ? "skip" : "watch"))
    }

    // MARK: - Playback

    private func stateChanged(_ s: YouTubePlayer.State) {
        guard isOwner else { return }
        if s == .playing { paused = false }
        if s == .paused, current?.moment != nil { paused = true }
        // Auto-advance only once the new moment is really playing: right after a swipe the player can still report
        // the previous video's 'ended' state.
        if s == .ended, settled, Date().timeIntervalSince(actAt) > 1.5 { next() }
    }

    private func playerError(_ code: Int) {
        guard isOwner, Date().timeIntervalSince(actAt) > 0.4 else { return }   // a late error from the video we just left
        let at = cur
        toast = code == 101 || code == 150 ? "This video can't be embedded. Skipping." : "Video failed to load. Skipping."
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if let self, self.cur == at { self.next() }
        }
    }

    private func tick() {
        guard isOwner, attached, let m = current?.moment else { return }
        let playing = player.state == .playing
        let t = player.currentTime
        if playing { watched += 0.125 * (fast ? 2 : 1) }
        if t != time { time = t }
        if playing && t >= m.m.start - 3 && t < m.m.end + 1 && Date().timeIntervalSince(actAt) > 0.6 { settled = true }
        // Paused shows the thumbnail instead: YouTube's pause screen has its title and suggestions.
        let show = settled && !paused && (playing || player.state == .buffering)
        if show != showVideo { withAnimation(.easeOut(duration: 0.25)) { showVideo = show } }
        if playing && Date().timeIntervalSince(lastBeat) > 2 { lastBeat = Date(); engine.setProgress(m.id, t: t) }
        if settled && playing && t >= m.m.end - 0.3 { next() }
    }

    func togglePlay() {
        guard current?.moment != nil else { return }
        if player.state == .playing { player.pause(); paused = true } else { player.play(); paused = false }
    }

    func setFast(_ on: Bool) {
        guard on != fast else { return }
        fast = on
        player.setRate(on ? 2 : 1)
    }

    func seek(fraction f: Double) {
        guard let m = current?.moment else { return }
        let t = m.m.start + max(0, min(1, f)) * (m.m.end - m.m.start)
        time = t
        player.seek(t)
    }

    func like() {
        guard let m = current?.moment, !liked.contains(m.id) else { return }
        liked.insert(m.id)
        engine.event(m.id, watched: watched, dur: m.m.end - m.m.start, action: "like")
    }

    func toggleSave() {
        guard let m = current?.moment else { return }
        if engine.isSaved(m.id) {
            engine.event(m.id, watched: watched, dur: m.m.end - m.m.start, action: "unsave")
            toast = "Removed from saved"
        } else {
            engine.event(m.id, watched: watched, dur: m.m.end - m.m.start, action: "save")
            toast = "Saved"
        }
    }

    func openInYouTube() {
        guard let m = current?.moment else { return }
        player.pause()
        UIApplication.shared.open(youtubeURL(m.m.vid, time > m.m.start ? time : m.m.start))
    }

    /// Progress through the current moment, 0...1.
    func fraction(for m: FeedMoment) -> Double {
        guard current?.moment?.id == m.id else { return 0 }
        return max(0, min(1, (time - m.m.start) / max(1, m.m.end - m.m.start)))
    }

    /// The caption line at the current time and how many of its words have been spoken.
    func caption(for m: FeedMoment) -> (words: [String], spoken: Int)? {
        guard current?.moment?.id == m.id, let line = m.lines.last(where: { $0.s <= time }),
              time - line.s <= line.d + 1.5 else { return nil }
        let words = line.t.rxReplace(#"\[.*?\]"#, with: "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let k = Int((min(1, (time - line.s) / max(0.5, line.d)) * Double(words.count)).rounded(.up))
        return (words, k)
    }
}
