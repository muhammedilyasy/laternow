import BackgroundTasks
import Foundation
import Observation
import UIKit

/// Everything Later Now stores: the same model as the extension's background.js, on the phone.
private struct Snapshot: Codable {
    var videos: [String: Video]
    var moments: [Moment]
    var nextId: Int
    var prefs: [String: Pref]
    var hist: [Int: Hist]
    var saved: [Int: Double]
    var progress: Progress?
    var gem: GemState
    var activity: [LogLine]?   // optional: older saves don't have it
}

struct LogLine: Codable, Identifiable { var id = UUID(); var t: Double; var text: String }

/// The whole "server", running on the phone: storage, the processing queue, the feed and settings.
/// Same behaviour as extension/background.js, so the three versions stay in step.
@MainActor @Observable final class Engine {
    private(set) var videos: [String: Video] = [:]
    private(set) var moments: [Moment] = []
    private var nextId = 1
    private(set) var prefs: [String: Pref] = [:]
    private(set) var hist: [Int: Hist] = [:]
    private(set) var saved: [Int: Double] = [:]
    private(set) var progress: Progress?
    private(set) var keyHint = ""
    private(set) var hasKey = false
    /// Recent queue events, newest first, shown in Library.
    private(set) var activity: [LogLine] = []
    /// What the queue is doing right now, and since when.
    private(set) var working: (text: String, since: Date)?
    /// Bumped when Gemini's quota state changes, so status views refresh.
    private(set) var quotaTick = 0

    @ObservationIgnored let gemini: Gemini
    @ObservationIgnored private var geminiKey: String? { didSet { hasKey = !(geminiKey ?? "").isEmpty; keyHint = geminiKey.map { "…" + $0.suffix(4) } ?? "" } }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var ytLast: Double = 0
    @ObservationIgnored private var lineCache: [String: [Line]] = [:]

    static let ytGap: Double = 3        // seconds between caption fetches
    static let lease: Double = 90       // in-progress items whose lease is older are recovered

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LaterNow", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("tr"), withIntermediateDirectories: true)
        return d
    }()
    private static var stateURL: URL { dir.appendingPathComponent("state.json") }
    private static func trURL(_ vid: String) -> URL { dir.appendingPathComponent("tr/\(vid).json") }

    init() {
        var gem = GemState()
        if let d = try? Data(contentsOf: Engine.stateURL) {
            if let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
                videos = s.videos; moments = s.moments; nextId = s.nextId; prefs = s.prefs; hist = s.hist
                saved = s.saved; progress = s.progress; gem = s.gem; activity = s.activity ?? []
            } else {
                // Never overwrite data we couldn't read: keep it aside.
                let aside = Engine.dir.appendingPathComponent("state-unreadable-\(Int(nowS())).json")
                try? FileManager.default.moveItem(at: Engine.stateURL, to: aside)
            }
        }
        gemini = Gemini(state: gem)
        var k = Keychain.get("gemini_key")
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["LN_GEMINI_KEY"] { k = t }   // tests only, never stored
        #endif
        geminiKey = k
        hasKey = !(k ?? "").isEmpty
        keyHint = k.map { "…" + $0.suffix(4) } ?? ""
        gemini.onChange = { [weak self] in self?.quotaTick += 1; self?.save() }
        gemini.onEvent = { [weak self] in self?.log($0) }
    }

    // MARK: - Storage

    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    func writeNow() {
        saveTask?.cancel()
        let s = Snapshot(videos: videos, moments: moments, nextId: nextId, prefs: prefs, hist: hist, saved: saved,
                         progress: progress, gem: gemini.state, activity: activity)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: Engine.stateURL, options: .atomic) }
    }

    func log(_ text: String) {
        activity.insert(LogLine(t: nowS(), text: text), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
        save()
    }

    private func title(_ id: String) -> String {
        let t = videos[id]?.title ?? id
        return t.count > 48 ? String(t.prefix(47)) + "…" : t
    }

    func lines(_ vid: String) -> [Line]? {
        if let l = lineCache[vid] { return l }
        guard let d = try? Data(contentsOf: Engine.trURL(vid)), let l = try? JSONDecoder().decode([Line].self, from: d) else { return nil }
        if lineCache.count > 60 { lineCache.removeAll() }
        lineCache[vid] = l
        return l
    }

    private func storeLines(_ vid: String, _ l: [Line]) {
        lineCache[vid] = l
        if let d = try? JSONEncoder().encode(l) { try? d.write(to: Engine.trURL(vid), options: .atomic) }
    }

    // MARK: - Feed

    private func isDone(_ act: String, _ w: Double, _ dur: Double) -> Bool { act == "like" || act == "save" || w >= 0.8 * dur }
    private func cooldown(_ k: Int) -> Double { min(7 * 86400, 6 * 3600 * pow(2, Double(max(0, max(k, 1) - 1)))) }
    var readyVids: Set<String> { Set(videos.values.filter { $0.status == .ready }.map(\.id)) }

    /// The next moments, best first. Same ranking as the extension: per-topic moving average, an exploration bonus
    /// for topics seen less, the hook score, a little randomness, and skip cooldowns. Finished moments never repeat.
    func feed(n: Int, exclude: Set<Int>, topic: String?, saved onlySaved: Bool, resume: Bool) -> [FeedMoment] {
        let t = nowS(), ready = readyVids
        let rows = moments.filter { ready.contains($0.vid) && (topic == nil || $0.topic == topic) &&
            (!onlySaved || saved[$0.id] != nil) && !exclude.contains($0.id) }
        var pool = onlySaved ? rows : rows.filter { m in
            guard let h = hist[m.id] else { return true }
            return !h.done && t - h.last >= cooldown(h.skips)
        }
        var sc: [Int: Double] = [:]
        for r in pool {
            if onlySaved { sc[r.id] = saved[r.id] ?? 0; continue }   // newest saved first
            let p = prefs[r.topic] ?? Pref(score: 0.5, n: 0)
            sc[r.id] = p.score + 0.35 / (1 + Double(p.n)).squareRoot() + 0.04 * r.hook + Double.random(in: 0..<0.15)
                - 0.08 * Double(hist[r.id]?.skips ?? 0)
        }
        pool.sort { sc[$0.id]! > sc[$1.id]! }
        var out: [Moment] = [], last: String?, taken = Set<Int>()
        for r in pool {
            if out.count >= n { break }
            if r.vid == last && pool.contains(where: { $0.vid != last && !taken.contains($0.id) }) { continue }   // vary videos
            out.append(r); taken.insert(r.id); last = r.vid
        }
        // resume: the moment that was on screen when the app was left comes first, unless it has been finished since.
        var resumeT: Double?
        if resume, !onlySaved, let p = progress, !exclude.contains(p.moment), hist[p.moment]?.done != true,
           let r = rows.first(where: { $0.id == p.moment }) {
            out.removeAll { $0.id == r.id }
            out.insert(r, at: 0)
            if out.count > n { out.removeLast() }
            resumeT = p.t
        }
        return out.map { r in
            let v = videos[r.vid]
            let ls = (lines(r.vid) ?? []).filter { $0.s >= r.start - 2 && $0.s < r.end }
            return FeedMoment(m: r, vtitle: v?.title ?? r.vid, channel: v?.channel ?? "", lines: ls,
                              resumeT: r.id == progress?.moment ? resumeT : nil)
        }
    }

    /// Teaches the feed: action is watch, skip, like, save or unsave.
    func event(_ id: Int, watched: Double, dur: Double, action: String) {
        guard let m = moments.first(where: { $0.id == id }) else { return }
        let dur = max(1, dur), w = max(0, watched)
        if action == "unsave" { saved[id] = nil; save(); return }
        let signal = (action == "like" || action == "save") ? 1 : (action == "skip" && w < 3 ? 0 : min(1, w / dur))
        let p = prefs[m.topic] ?? Pref(score: 0.5, n: 0)
        prefs[m.topic] = Pref(score: p.score + max(0.15, 1 / Double(p.n + 2)) * (signal - p.score), n: p.n + 1)
        let h = hist[id] ?? Hist(done: false, last: 0, skips: 0), d = isDone(action, w, dur)
        hist[id] = Hist(done: h.done || d, last: nowS(), skips: h.skips + (d ? 0 : 1))
        if action == "save" && saved[id] == nil { saved[id] = nowS() }
        save()
    }

    func isSaved(_ id: Int) -> Bool { saved[id] != nil }

    func setProgress(_ moment: Int?, t: Double) {
        progress = moment.map { Progress(moment: $0, t: t) }
        save()
    }

    // MARK: - Status

    var counts: [VStatus: Int] { videos.values.reduce(into: [:]) { $0[$1.status, default: 0] += 1 } }
    var busyCount: Int { videos.values.filter { $0.status.busy }.count }
    var liveMoments: [Moment] { let r = readyVids; return moments.filter { r.contains($0.vid) } }

    var topics: [TopicStat] {
        var tn: [String: Int] = [:]
        for m in liveMoments { tn[m.topic, default: 0] += 1 }
        return tn.map { TopicStat(topic: $0.key, n: $0.value, score: prefs[$0.key]?.score ?? 0.5) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.n > $1.n }
    }

    /// (finished, skipped and coming back later) among live moments.
    var doneLater: (done: Int, later: Int) {
        var done = 0, later = 0
        for m in liveMoments { if let h = hist[m.id] { if h.done { done += 1 } else { later += 1 } } }
        return (done, later)
    }

    var quota: QuotaInfo? { _ = quotaTick; return hasKey ? gemini.quotaStatus() : nil }
    var model: String { _ = quotaTick; return gemini.lastModel }

    var videoList: [Video] { videos.values.sorted { $0.added > $1.added } }
    func momentCount(_ vid: String) -> Int { moments.filter { $0.vid == vid }.count }

    // MARK: - Adding videos

    @discardableResult func addIds(_ ids: [String]) -> Int {
        var added = 0
        let t = nowS()
        for (j, id) in ids.enumerated() where videos[id] == nil {
            videos[id] = Video(id: id, added: t + Double(j) / 1000)
            added += 1
        }
        if added > 0 { Notifier.shared.ask(); save(); pump() }
        return added
    }

    func add(_ text: String) async -> AddResult {
        let (ids, notes) = await YouTube.expand(text)
        return AddResult(found: ids.count, new: addIds(ids), notes: notes)
    }

    func importWatchLater() async -> AddResult {
        guard await YouTube.isSignedIn() else { return AddResult(notes: ["Sign in to YouTube to import your Watch Later."], needsSignIn: true) }
        do {
            let r = try await YouTube.playlist("WL", requireLogin: true)
            if r.signedOut { return AddResult(notes: r.notes, needsSignIn: true) }
            return AddResult(found: r.ids.count, new: addIds(r.ids), notes: r.notes.isEmpty && r.ids.isEmpty ? ["Your Watch Later is empty"] : r.notes)
        } catch {
            return AddResult(notes: [error.localizedDescription])
        }
    }

    func remove(_ vid: String) {
        let ids = Set(moments.filter { $0.vid == vid }.map(\.id))
        moments.removeAll { $0.vid == vid }
        for id in ids { hist[id] = nil; saved[id] = nil }
        videos[vid] = nil
        lineCache[vid] = nil
        try? FileManager.default.removeItem(at: Engine.trURL(vid))
        save()
    }

    @discardableResult func retry() -> Int {
        var n = 0
        for (id, v) in videos where ((v.status == .failed || v.status == .waiting) && (hasKey || !(v.error ?? "").hasPrefix("No captions")))
            || (v.status == .needsKey && hasKey) {
            videos[id]?.status = .queued; videos[id]?.retryAt = 0; videos[id]?.solo = false
            n += 1
        }
        if n > 0 { save(); pump() }
        return n
    }

    // MARK: - Settings

    /// Validates the key with Google, stores it in the Keychain, and requeues videos that were waiting for it.
    func setKey(_ raw: String) async throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError(.badKey, "Add your Gemini key first.") }
        let models: [String]
        do { models = try await Gemini.listModels(key) }
        catch let e as AIError where e.code == .badKey { throw AIError(.badKey, "That key didn't work. Check it and try again.") }
        let isNew = key != geminiKey
        Keychain.set("gemini_key", key)
        geminiKey = key
        if isNew {
            gemini.reset(models: models)   // a different key may be a different Google project with its own quotas
            requeueForKey()
        }
    }

    func removeKey() {
        Keychain.set("gemini_key", nil)
        geminiKey = nil
        gemini.reset()
    }

    /// Videos held back for a key or quota (or settled for plain 60s chunks) get another go with a new key.
    private func requeueForKey() {
        var n = 0
        for (id, v) in videos {
            let e = v.error ?? ""
            if v.status == .needsKey || (v.status == .waiting && e.hasPrefix("Free Gemini")) ||
                (v.status == .ready && e.hasPrefix("Used 60s chunks")) || (v.status == .failed && e.hasPrefix("No captions") && hasKey) {
                videos[id]?.status = .queued; videos[id]?.retryAt = 0; videos[id]?.tries = 0; videos[id]?.error = nil
                if v.chars == 0 { videos[id]?.cap = false }   // no transcript stored: (re)check captions first
                n += 1
            }
        }
        if n > 0 { save(); pump() }
    }

    // MARK: - Processing queue
    //
    // 1. Captions: one video at a time, ytGap apart. The transcript is stored and the video marked cap.
    // 2. Moments: videos with captions go to Gemini together (up to batchMax videos / batchChars in one request).
    //    Long videos, and videos a batch answer skipped (solo), go alone. Videos without captions are watched by Gemini.
    // When the free quota is used up, videos wait (status waiting, retryAt) and continue automatically.

    private func set(_ id: String, _ f: (inout Video) -> Void) {
        guard var v = videos[id] else { return }
        f(&v); v.lease = nowS()
        videos[id] = v
        save()
    }

    private func backoff(_ id: String, base: Double, cap: Double, _ msg: String) {
        set(id) { v in
            v.tries += 1
            v.status = .waiting; v.retryAt = nowS() + min(cap, base * pow(2, Double(v.tries - 1))); v.error = msg
        }
    }

    private func isDue(_ v: Video, _ t: Double) -> Bool {
        v.status == .queued || (v.status == .waiting && v.retryAt < t) || (v.status.inProgress && v.lease < t - Engine.lease)
    }

    private var topicList: [String] {
        moments.reduce(into: [String: Int]()) { $0[$1.topic, default: 0] += 1 }.sorted { $0.value > $1.value }.map(\.key)
    }

    private func store(_ id: String, _ picks: [Pick], err: String?) {
        moments.removeAll { $0.vid == id }
        for p in picks {
            moments.append(Moment(id: nextId, vid: id, start: p.start, end: p.end, title: p.title, topic: normTopic(p.topic), hook: p.hook))
            nextId += 1
        }
        set(id) { $0.status = .ready; $0.error = err; $0.tries = 0; $0.retryAt = 0; $0.solo = false }
    }

    private func rateLimited(_ id: String, _ e: AIError) {
        set(id) { v in
            v.tries += 1
            v.status = .waiting
            v.retryAt = e.retryAt > 0 ? e.retryAt : nowS() + min(6 * 3600, 1800 * pow(2, Double(v.tries - 1)))
            v.error = "\(e.message). Continues automatically."
        }
    }

    private func failed(_ id: String, _ e: Error) {
        if let a = e as? AIError, a.code == .rateLimit { return rateLimited(id, a) }
        if let y = e as? YTError {
            if y.code == .rateLimit || y.code == .consent { ytLast = nowS() + 300; return backoff(id, base: 600, cap: 6 * 3600, y.message) }
            if y.code == .network || y.code == .http { return backoff(id, base: 120, cap: 3600, y.message) }
        }
        if let a = e as? AIError, a.code == .network { return backoff(id, base: 120, cap: 3600, a.message) }
        set(id) { $0.status = .failed; $0.error = String(e.localizedDescription.prefix(200)) }
    }

    /// Step 1 for one video: title and captions.
    private func fetchCaptions(_ id: String) async {
        set(id) { $0.status = .fetching }
        do {
            if let v = videos[id], v.channel.isEmpty && v.title == v.id {
                let (title, channel) = await YouTube.meta(id)
                set(id) { $0.title = title; $0.channel = channel }
            }
            if lines(id) == nil {
                let wait = ytLast + Engine.ytGap - nowS()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                let ls: [Line]
                do {
                    defer { ytLast = nowS() }
                    ls = try await YouTube.transcript(id)
                } catch let e as YTError {
                    // No captions, or YouTube blocks caption requests: Gemini can watch the video instead.
                    let usable = e.code == .noCaptions || e.code == .rateLimit || e.message.contains("PO token")
                    if !usable { throw e }
                    log("No captions from YouTube for \(title(id)) (\(e.message)). Gemini will watch it instead.")
                    if !hasKey { throw e.code == .noCaptions ? YTError(.fatal, "No captions (a Gemini key lets Later Now watch it instead)") : e }
                    set(id) { $0.status = .queued; $0.cap = true; $0.nocap = true; $0.chars = 0 }
                    return
                }
                storeLines(id, ls)
                set(id) { $0.chars = Segmenter.transcriptText(ls).count }
                log("Captions: \(title(id)) (\((videos[id]?.chars ?? 0) / 1000)k characters)")
            }
            if videos[id]?.chars == 0, let ls = lines(id) { set(id) { $0.chars = Segmenter.transcriptText(ls).count } }
            set(id) { $0.status = .queued; $0.cap = true; $0.nocap = false }
        } catch {
            log("Captions failed for \(title(id)): \(error.localizedDescription)")
            failed(id, error)
        }
    }

    /// Step 2: moments for a group of captioned videos (one Gemini request if there's more than one).
    private func findMoments(_ group: [String]) async {
        var list: [(id: String, lines: [Line])] = []
        for id in group {
            if let l = lines(id), !l.isEmpty { list.append((id, l)) } else { set(id) { $0.status = .queued; $0.cap = false } }   // transcript lost
        }
        guard !list.isEmpty else { return }
        for x in list { set(x.id) { $0.status = .finding; $0.error = nil } }
        guard let key = geminiKey, !key.isEmpty else {
            for x in list { set(x.id) { $0.status = .needsKey; $0.error = "Add your Gemini key in Library" } }
            return
        }
        let chars = list.reduce(0) { $0 + (videos[$1.id]?.chars ?? 0) }
        working = (list.count == 1 ? "Finding moments in \(title(list[0].id))" : "Finding moments in \(list.count) videos at once", Date())
        log(list.count == 1 ? "Gemini: finding moments in \(title(list[0].id)) (\(chars / 1000)k characters)"
                            : "Gemini: \(list.count) videos in one request (\(chars / 1000)k characters)")
        defer { working = nil }
        do {
            if list.count == 1 {
                let (id, l) = list[0]
                var picks: [Pick], err: String?
                do { picks = try await Segmenter.segment(gemini, key: key, title: videos[id]?.title ?? id, lines: l, topics: topicList) }
                catch let e as AIError where e.code != .rateLimit && e.code != .network && e.code != .badKey {
                    picks = Segmenter.chunks(l); err = String("Used 60s chunks (\(e.message))".prefix(200))
                    log("Gemini couldn't pick moments (\(e.message)); used plain 60-second chunks")
                }
                log("\(picks.count) moments from \(title(id))")
                store(id, picks, err: err)
                Notifier.shared.found(moments: picks.count, videos: 1, left: pendingCount, title: title(id))
                return
            }
            let res = try await Segmenter.segmentBatch(gemini, key: key,
                                                       items: list.map { (vid: $0.id, title: videos[$0.id]?.title ?? $0.id, lines: $0.lines) },
                                                       topics: topicList)
            var got = 0, skipped = 0
            for x in list {
                if let ms = res[x.id] ?? nil { store(x.id, ms, err: nil); got += ms.count }
                else { skipped += 1; set(x.id) { $0.status = .queued; $0.solo = true } }   // the model skipped it: try it on its own
            }
            log("\(got) moments from \(list.count - skipped) videos" + (skipped > 0 ? "; \(skipped) skipped, retrying them one by one" : ""))
            Notifier.shared.found(moments: got, videos: list.count - skipped, left: pendingCount, title: list.count - skipped == 1 ? title(list[0].id) : nil)
        } catch let e as AIError where e.code == .rateLimit {
            log("Free Gemini quota used up. Continues \(when(e.retryAt)).")
            for x in list { rateLimited(x.id, e) }
            Notifier.shared.paused(until: when(e.retryAt), left: pendingCount)
        } catch let e as AIError where e.code == .badKey {
            log("Gemini didn't accept the key")
            for x in list { set(x.id) { $0.status = .needsKey; $0.error = "Gemini didn't accept the key" } }
            _ = e
        } catch {
            log("Gemini request failed: \(error.localizedDescription)")
            // A broken batch answer: every video gets its own request next time.
            for x in list { if list.count > 1 { set(x.id) { $0.status = .queued; $0.solo = true } } else { failed(x.id, error) } }
        }
    }

    /// No captions: Gemini watches the video.
    private func watchVideo(_ id: String) async {
        guard let key = geminiKey, !key.isEmpty else {
            return set(id) { $0.status = .failed; $0.error = "No captions (a Gemini key lets Later Now watch it instead)" }
        }
        set(id) { $0.status = .finding; $0.error = nil }
        working = ("Gemini is watching \(title(id))", Date())
        log("Gemini: watching \(title(id)) (no captions)")
        defer { working = nil }
        do {
            let picks = try await Segmenter.segmentVideo(gemini, key: key, vid: id, title: videos[id]?.title ?? id, topics: topicList)
            store(id, picks, err: "No captions: Gemini watched the video to pick these")
            Notifier.shared.found(moments: picks.count, videos: 1, left: pendingCount, title: title(id))
        } catch { failed(id, error) }
    }

    /// One unit of work, or false when there is nothing to do right now.
    private func step() async -> Bool {
        let t = nowS()
        let due = videos.values.filter { isDue($0, t) }.sorted {
            ($0.status == .waiting ? 1 : 0, $0.added) < ($1.status == .waiting ? 1 : 0, $1.added)
        }
        guard !due.isEmpty else { return false }
        for v in due where v.status.inProgress { videos[v.id]?.status = .queued }   // recovered after a restart
        let capped = due.filter(\.cap), uncapped = due.filter { !$0.cap }
        let batchable: (Video) -> Bool = { !$0.nocap && !$0.solo && $0.chars <= Segmenter.soloChars }
        // Gather a full batch of captions before asking the AI, so one request covers as many videos as possible.
        if let u = uncapped.first, capped.filter(batchable).count < Segmenter.batchMax {
            await fetchCaptions(u.id)
            return true
        }
        guard hasKey else {
            for v in capped { set(v.id) { $0.status = .needsKey; $0.error = "Add your Gemini key in Library" } }
            return !capped.isEmpty
        }
        guard let v0 = capped.first else { return false }
        if v0.nocap { await watchVideo(v0.id); return true }
        if !batchable(v0) { await findMoments([v0.id]); return true }
        var group: [String] = [], size = 0
        for v in capped where batchable(v) {
            if group.count >= Segmenter.batchMax || (!group.isEmpty && size + v.chars > Segmenter.batchChars) { break }
            group.append(v.id); size += v.chars
        }
        await findMoments(group)
        return true
    }

    /// Videos still to be processed, including ones waiting for quota.
    var pendingCount: Int { videos.values.filter { $0.status == .queued || $0.status == .waiting || $0.status.inProgress }.count }

    /// Works through the queue until nothing is due. Safe to call any time.
    func pump() {
        guard !running else { return }
        let t = nowS()
        guard videos.values.contains(where: { isDue($0, t) }) else { return }
        running = true
        startContinued()
        Task {
            defer { running = false; finishContinued(); endBackground() }
            while await step() { updateContinued() }
        }
    }

    // MARK: - Running in the background
    //
    // iOS suspends an app soon after you leave it. When work starts while the app is open, the queue asks iOS 26 for a
    // continued processing task: the work keeps going in the background, with its progress shown by the system (you
    // can stop it from there). If iOS says no, it falls back to the ~30 seconds every app gets.

    @ObservationIgnored private var continued: BGContinuedProcessingTask?
    @ObservationIgnored private var continuedAsked = false
    @ObservationIgnored private var runIds: Set<String> = []
    @ObservationIgnored private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private var pendingIds: Set<String> {
        Set(videos.values.filter { $0.status == .queued || $0.status == .waiting || $0.status.inProgress }.map(\.id))
    }

    private func startContinued() {
        guard continued == nil, !continuedAsked, UIApplication.shared.applicationState == .active else { return }
        let id = "\(Bundle.main.bundleIdentifier ?? "LaterNow").queue.\(UUID().uuidString.prefix(8))"
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
                self?.began(task)
            }
        }
        guard ok else { return }
        let n = pendingCount
        let r = BGContinuedProcessingTaskRequest(identifier: id, title: "Finding moments",
                                                 subtitle: "\(n) video\(n == 1 ? "" : "s") in the queue")
        r.strategy = .fail
        do { try BGTaskScheduler.shared.submit(r); continuedAsked = true }
        catch { log("Background work not available (\(error.localizedDescription)). Keep Later Now open while it works.") }
    }

    private func began(_ task: BGContinuedProcessingTask) {
        continuedAsked = false
        guard running else { return task.setTaskCompleted(success: true) }
        continued = task
        runIds = pendingIds
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.log("Paused: iOS stopped background work. Continues when you open Later Now.")
                self?.continued?.setTaskCompleted(success: false)
                self?.continued = nil
            }
        }
        updateContinued()
    }

    private func updateContinued() {
        guard let task = continued else { return }
        let pending = pendingIds
        runIds.formUnion(pending)
        let total = runIds.count, done = runIds.subtracting(pending).count
        task.progress.totalUnitCount = Int64(max(1, total))
        task.progress.completedUnitCount = Int64(done)
        let found = moments.filter { runIds.contains($0.vid) }.count
        task.updateTitle("Finding moments", subtitle: "\(done) of \(total) videos · \(found) moment\(found == 1 ? "" : "s")")
    }

    private func finishContinued() {
        guard let task = continued else { return }
        updateContinued()
        task.setTaskCompleted(success: true)
        continued = nil
    }

    /// The app went to the background: without a continued task, ask for time to finish the current request.
    func enteredBackground() {
        writeNow()
        guard running, continued == nil, bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "LaterNow queue") { [weak self] in
            Task { @MainActor in
                self?.log("Paused: iOS stopped Later Now in the background. Continues when you open it.")
                self?.endBackground()
            }
        }
    }

    func endBackground() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    /// Wakes the queue for videos whose wait is over.
    func heartbeat() async {
        while !Task.isCancelled {
            pump()
            try? await Task.sleep(for: .seconds(30))
        }
    }
}
