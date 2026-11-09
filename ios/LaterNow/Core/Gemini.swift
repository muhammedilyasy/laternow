import Foundation

/// code: rateLimit (retryAt = epoch seconds when a model frees up), badKey, network, failed.
struct AIError: LocalizedError {
    enum Code { case rateLimit, badKey, network, failed }
    var code: Code
    var message: String
    var retryAt: Double = 0
    init(_ code: Code, _ message: String, retryAt: Double = 0) { self.code = code; self.message = message; self.retryAt = retryAt }
    var errorDescription: String? { message }
}

/// A moment picked by Gemini, before it gets an id.
struct Pick { var start: Double; var end: Double; var title: String; var topic: String; var hook: Double }

struct GemQuota: Codable {
    var day: String
    var used = 0
    var dayLimit = 0
    var blockedUntil: Double = 0
    var last: Double = 0
    var note = ""
}

struct GemState: Codable {
    var poolDay = ""
    var pool: [String] = []
    var quota: [String: GemQuota] = [:]
    var lastModel = ""
}

struct QuotaInfo { var models: Int; var available: Int; var usedToday: Int; var resumesAt: Double? }

/// Pacific time: Gemini's free quotas reset at midnight there.
enum Pacific {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    static func day(_ t: Double = nowS()) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Epoch seconds of the next midnight Pacific (+5s), DST-safe.
    static func nextReset(_ t: Double = nowS()) -> Double {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: t))
        return (cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)).timeIntervalSince1970 + 5
    }
}

func normTopic(_ raw: String?) -> String {
    let first = (raw ?? "misc").lowercased().components(separatedBy: " and ")[0]
        .components(separatedBy: CharacterSet(charactersIn: ",/;&|"))[0]
    let t = first.trimmingCharacters(in: CharacterSet(charactersIn: " .-_#\n\t"))
    return t.isEmpty ? "misc" : String(t.prefix(24))
}

/// Picking moments with the user's own Gemini key. Same prompts, free-tier model pool, quota learning and batching
/// as extension/src/ai.js.
///
/// Free-tier quotas are per Google project *per model* and reset at midnight Pacific. They are small and unpublished
/// (e.g. 20 requests/day on the newest Flash). So we keep a pool of every free Flash / Flash-Lite model the key can
/// use, best first, spend each model's daily allowance in turn, and learn the real limits from Google's 429 replies.
@MainActor final class Gemini {
    /// LN_GEMINI_API overrides the endpoint in debug builds (tests against a fake server).
    static let api: String = {
        #if DEBUG
        if let u = ProcessInfo.processInfo.environment["LN_GEMINI_API"] { return u }
        #endif
        return "https://generativelanguage.googleapis.com/v1beta"
    }()
    static let spacing: Double = 6        // seconds between requests to the same model
    static let poolRE = #"^gemini-(\d+(?:\.\d+)?)-flash(-lite)?(-preview)?$"#
    static let fallbackPool = ["gemini-2.5-flash", "gemini-2.5-flash-lite"]

    var state: GemState
    var onChange: () -> Void = {}

    /// Gemini can take minutes on a big batch. URLSession.shared gives up after 60 seconds without data, which
    /// counted those as timeouts and started over on the next model.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 420
        c.timeoutIntervalForResource = 900
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    /// What happened to each request, for the activity log.
    var onEvent: (String) -> Void = { _ in }

    init(state: GemState) { self.state = state }

    private func changed() { onChange() }

    /// Free-tier candidates, best first: newest full Flash models, then Flash-Lite, previews after the stable model.
    static func choices(_ names: [String]) -> [String] {
        func rank(_ n: String) -> (Int, Double, Int) {
            let m = n.firstMatch(poolRE)!
            return (m[2].isEmpty ? 0 : 1, -(Double(m[1]) ?? 0), m[3].isEmpty ? 0 : 1)
        }
        return names.filter { $0.test(poolRE) }.sorted { a, b in
            let x = rank(a), y = rank(b)
            if x.0 != y.0 { return x.0 < y.0 }
            if x.1 != y.1 { return x.1 < y.1 }
            if x.2 != y.2 { return x.2 < y.2 }
            return a < b
        }
    }

    static func listModels(_ key: String) async throws -> [String] {
        var r = URLRequest(url: URL(string: "\(api)/models?pageSize=1000")!)
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Gemini.session.data(for: r) }
        catch { throw AIError(.network, "Couldn't reach Google (\(error.localizedDescription))") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let msg = ((d["error"] as? [String: Any])?["message"] as? String) ?? "Google returned \(status)"
            throw AIError([400, 401, 403].contains(status) ? .badKey : .failed, msg)
        }
        return (d["models"] as? [[String: Any]] ?? [])
            .filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
            .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
    }

    /// Cached model pool for this key, refreshed once per Pacific day.
    private func pool(_ key: String) async -> [String] {
        if state.poolDay != Pacific.day() || state.pool.isEmpty {
            if let names = try? await Gemini.listModels(key) {
                state.pool = Gemini.choices(names); state.poolDay = Pacific.day(); changed()
            }
        }
        return state.pool.isEmpty ? Gemini.fallbackPool : state.pool
    }

    private func quota(_ m: String) -> GemQuota {
        var q = state.quota[m] ?? GemQuota(day: Pacific.day())
        if q.day != Pacific.day() { q.day = Pacific.day(); q.used = 0 }
        return q
    }

    /// When this model can take another request (0 = now).
    private func availableAt(_ q: GemQuota, _ t: Double) -> Double {
        var at = max(q.blockedUntil, q.last + Gemini.spacing)
        if q.dayLimit > 0 && q.used >= q.dayLimit { at = max(at, Pacific.nextReset(t)) }
        return at <= t ? 0 : at
    }

    /// Pick the best model with allowance left and count the request.
    private func reserve(_ key: String, skip: Set<String>) async -> (model: String?, retryAt: Double) {
        let models = await pool(key)
        let t = nowS()
        var soonest: Double?
        for m in models {
            var q = quota(m)
            let at = availableAt(q, t)
            if skip.contains(m) { if at == 0 { continue } }   // already failed this request
            else if at == 0 {
                q.used += 1; q.last = t; state.quota[m] = q; changed()
                return (m, 0)
            }
            soonest = min(soonest ?? at, at)
        }
        return (nil, soonest ?? Pacific.nextReset(t))
    }

    /// Record what Google said about a request we reserved.
    private func report(_ model: String, _ kind: String, delay: Double = 0, limit: Int = 0, note: String = "") {
        let t = nowS()
        var q = quota(model)
        if kind != "ok" { q.used = max(0, q.used - 1) }   // rejected requests don't count against the quota
        switch kind {
        case "day":
            q.blockedUntil = delay > 0 ? t + delay : Pacific.nextReset(t)
            if limit > 0 { q.dayLimit = limit; q.used = max(q.used, limit) }
        case "minute": q.blockedUntil = t + max(delay, 30)
        case "busy": q.blockedUntil = t + 120
        case "gone", "unfree": q.blockedUntil = t + 3 * 86400
        default: state.lastModel = model
        }
        q.note = String(note.prefix(120))
        state.quota[model] = q
        changed()
    }

    /// A 429 body -> (kind, delay seconds, limit).
    static func classify429(_ raw: String) -> (String, Double, Int) {
        guard let d = parseJSON(raw) as? [String: Any], let err = d["error"] as? [String: Any] else { return ("minute", 60, 0) }
        var ids: [String] = [], limit = 0, delay: Double = 0
        for det in err["details"] as? [[String: Any]] ?? [] {
            for v in det["violations"] as? [[String: Any]] ?? [] {
                ids.append(String(describing: v["quotaId"] ?? ""))
                if let n = num(v["quotaValue"]) { limit = max(limit, Int(n)) }
            }
            if let r = num(det["retryDelay"]) { delay = r }
        }
        if ids.count >= 3 && limit == 0 { return ("unfree", 0, 0) }   // every quota without a value: no free tier
        if ids.contains(where: { $0.contains("PerDay") }) { return ("day", delay, limit) }
        return ("minute", delay > 0 ? delay : 60, 0)
    }

    private struct GemErr: Error { var kind: String; var delay: Double = 0; var limit = 0; var note = "" }

    /// One generateContent request. Returns the text; throws GemErr for quota/availability problems, AIError otherwise.
    private func call(_ key: String, _ model: String, _ parts: [[String: Any]], mediaLow: Bool, fast: Bool = true) async throws -> String {
        var cfg: [String: Any] = ["temperature": 0.3, "responseMimeType": "application/json"]
        if mediaLow { cfg["mediaResolution"] = "MEDIA_RESOLUTION_LOW" }
        // Picking moments doesn't need the model to think first, and thinking makes big batches take minutes.
        if fast {
            if model.hasPrefix("gemini-2.5") { cfg["thinkingConfig"] = ["thinkingBudget": 0] }
            else if model.hasPrefix("gemini-3") { cfg["thinkingConfig"] = ["thinkingLevel": "minimal"] }
        }
        let enc = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var r = URLRequest(url: URL(string: "\(Gemini.api)/models/\(enc):generateContent")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 420
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["contents": [["role": "user", "parts": parts]], "generationConfig": cfg])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Gemini.session.data(for: r) }
        catch {
            if Task.isCancelled { throw AIError(.failed, "Cancelled") }
            throw GemErr(kind: "busy", note: "network: \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let raw = String(decoding: data, as: UTF8.self)
        let d = parseJSON(raw) as? [String: Any] ?? [:]
        if status == 429 || raw.contains("RESOURCE_EXHAUSTED") {
            let (kind, delay, limit) = Gemini.classify429(raw)
            throw GemErr(kind: kind, delay: delay, limit: limit, note: "quota")
        }
        if [500, 502, 503, 504].contains(status) { throw GemErr(kind: "busy", note: "HTTP \(status)") }
        if status == 404 { throw GemErr(kind: "gone", note: "model not found") }
        guard status == 200 else {
            let msg = ((d["error"] as? [String: Any])?["message"] as? String) ?? String(raw.prefix(120))
            throw AIError(.failed, String("Gemini \(status): \(msg)".prefix(200)))
        }
        guard let c = (d["candidates"] as? [[String: Any]])?.first else {
            let block = ((d["promptFeedback"] as? [String: Any])?["blockReason"] as? String).map { " (\($0))" } ?? ""
            throw AIError(.failed, "Gemini returned no answer" + block)
        }
        let ps = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return ps.filter { ($0["thought"] as? Bool) != true }.map { ($0["text"] as? String) ?? "" }.joined()
    }

    /// Run a request on the best model that has free allowance left, moving down the pool on quota or overload.
    func ask(_ key: String, _ parts: [[String: Any]], mediaLow: Bool = false) async throws -> String {
        guard !key.isEmpty else { throw AIError(.badKey, "no Gemini key") }
        var tried = Set<String>()
        while true {
            let (model, retryAt) = await reserve(key, skip: tried)
            guard let model else {
                if retryAt - nowS() < 20 {   // request spacing
                    try? await Task.sleep(for: .seconds(max(0.1, retryAt - nowS())))
                    continue
                }
                throw AIError(.rateLimit, "Free Gemini quota used up for now", retryAt: retryAt)
            }
            let started = Date()
            onEvent("Asking \(model)…")
            do {
                var text: String
                do { text = try await call(key, model, parts, mediaLow: mediaLow) }
                catch let e as AIError where e.code == .failed && e.message.lowercased().contains("think") {
                    text = try await call(key, model, parts, mediaLow: mediaLow, fast: false)   // model rejects the thinking setting
                }
                report(model, "ok")
                onEvent("\(model) answered in \(Int(Date().timeIntervalSince(started)))s")
                return text
            } catch let e as GemErr {
                report(model, e.kind, delay: e.delay, limit: e.limit, note: e.note)
                tried.insert(model)
                let why = ["day": "daily free quota used up", "minute": "per-minute limit, trying the next model",
                           "busy": "busy or no answer (\(e.note))", "gone": "not available", "unfree": "no free tier"][e.kind] ?? e.kind
                onEvent("\(model): \(why)")
            } catch {
                onEvent("\(model) failed: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// For the UI: models in the pool, requests used today, and when work resumes if everything is used up.
    func quotaStatus() -> QuotaInfo {
        let t = nowS(), models = state.pool.isEmpty ? Gemini.fallbackPool : state.pool
        let qs = models.map(quota), at = qs.map { availableAt($0, t) }
        let ready = at.filter { $0 == 0 || $0 - t < 20 }.count, later = at.filter { $0 != 0 && $0 - t >= 20 }
        return QuotaInfo(models: models.count, available: ready, usedToday: qs.reduce(0) { $0 + $1.used },
                         resumesAt: ready > 0 ? nil : later.min())
    }

    var lastModel: String { state.lastModel.isEmpty ? "auto" : state.lastModel }

    /// A different key may be a different Google project with its own quotas: forget everything we learned.
    func reset(models: [String]? = nil) {
        state = GemState()
        if let models { state.pool = Gemini.choices(models); state.poolDay = Pacific.day() }
        changed()
    }
}

// MARK: - Prompts and segmentation

enum Segmenter {
    // Smaller than the extension's 12 videos / 240k: answers come back in well under a minute, which matters on a
    // phone, where iOS pauses apps soon after you leave them.
    static let batchMax = 8
    static let batchChars = 140_000
    static let soloChars = 120_000          // longer transcripts are never batched
    static let videoSegment: Double = 20 * 60
    static let videoMaxSegments = 6

    static func prompt(_ maxn: Int, _ title: String, _ text: String, _ topics: String) -> String {
        """
        You turn part of a long video transcript into a feed of short, self-contained "moments" for people with short attention spans.

        Rules:
        - Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
        - Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Up to \(maxn) moments.
        - title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
        - topic: ONE short lowercase topic (1-2 words, never a list), e.g. "startups", "fitness", "ai", "money", "mindset". Prefer these existing topics when they fit: \(topics.isEmpty ? "none yet" : topics).
        - hook: 1-10, how gripping this moment is for a general viewer.
        - start/end are seconds, taken from the [m:ss] markers.

        Video title: \(title)

        Transcript:
        \(text)

        Answer with ONLY a JSON array, no prose, no code fences:
        [{"start": 12.5, "end": 70.0, "title": "...", "topic": "...", "hook": 7}]
        """
    }

    static func batchPrompt(_ videos: [(title: String, text: String, maxn: Int)], _ topics: String) -> String {
        let body = videos.enumerated().map { i, v in
            "=== video_\(i + 1) ===\nTitle: \(v.title)\nUp to \(v.maxn) moments.\nTranscript:\n\(v.text)"
        }.joined(separator: "\n\n")
        return """
        You turn long video transcripts into a feed of short, self-contained "moments" for people with short attention spans. Below are \(videos.count) separate videos. Treat each one on its own.

        Rules:
        - Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
        - Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Stay within the maximum given for each video.
        - title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
        - topic: ONE short lowercase topic (1-2 words, never a list), e.g. "startups", "fitness", "ai", "money", "mindset". Prefer these existing topics when they fit: \(topics.isEmpty ? "none yet" : topics).
        - hook: 1-10, how gripping this moment is for a general viewer.
        - start/end are seconds from the start of THAT video, taken from its [m:ss] markers.

        \(body)

        Answer with ONLY a JSON object with one key per video (video_1 to video_\(videos.count)), each an array of moments, no prose:
        {"video_1": [{"start": 12.5, "end": 70.0, "title": "...", "topic": "...", "hook": 7}], "video_2": []}
        """
    }

    static func videoPrompt(a: Double, b: Double, title: String, topics: String) -> String {
        """
        You are watching part of a long video, from \(fmt(a)) to \(fmt(b)) (mm:ss). Turn it into short, self-contained "moments" for a feed for people with short attention spans.

        Rules:
        - Each moment is 25-90 seconds and must make sense on its own: it starts at the beginning of a thought and ends when the point is complete. Never cut mid-sentence.
        - Pick only the most interesting, insightful, funny or useful parts. Skip intros, sponsor reads, small talk and outros. Up to 10 moments.
        - title: a punchy hook of max 8 words that makes someone want to watch (honest, no clickbait lies).
        - topic: ONE short lowercase topic (1-2 words, never a list). Prefer these existing topics when they fit: \(topics.isEmpty ? "none yet" : topics).
        - hook: 1-10, how gripping this moment is for a general viewer.
        - start/end: seconds from the start of the FULL video (so between \(Int(a)) and \(Int(b))).
        - last_second_seen: the timestamp (seconds from the start of the full video) of the last moment of video you can see. If the video ends before \(fmt(b)), this is where it ends.

        Video title: \(title)

        Answer with ONLY a JSON object, no prose:
        {"moments": [{"start": \(Int(a) + 12), "end": \(Int(a) + 70), "title": "...", "topic": "...", "hook": 7}], "last_second_seen": \(Int(b))}
        """
    }

    /// Transcript -> "[m:ss] text" blocks of ~8 seconds, cut into windows of up to maxChars.
    static func windows(_ lines: [Line], _ maxChars: Int) -> [(text: String, start: Double)] {
        var out: [(String, Double)] = [], blocks: [String] = [], cur: [String] = []
        var cs: Double?, wStart: Double?, size = 0
        func flush() {
            if !blocks.isEmpty { out.append((blocks.joined(separator: "\n"), wStart ?? 0)) }
            blocks = []; size = 0; wStart = nil
        }
        for l in lines {
            if cs == nil { cs = l.s }
            if wStart == nil { wStart = l.s }
            cur.append(l.t)
            if l.s + l.d - cs! >= 8 {
                let b = "[\(fmt(cs!))] " + cur.joined(separator: " ")
                blocks.append(b); size += b.count; cur = []; cs = nil
                if size >= maxChars { flush() }
            }
        }
        if !cur.isEmpty { blocks.append("[\(fmt(cs ?? 0))] " + cur.joined(separator: " ")) }
        flush()
        return out
    }

    static func transcriptText(_ lines: [Line]) -> String { windows(lines, .max).map(\.text).joined(separator: "\n") }
    static func totalSecs(_ lines: [Line]) -> Double { lines.last.map { $0.s + $0.d } ?? 0 }
    static func maxMoments(_ secs: Double) -> Int { max(2, min(40, Int((secs / 120).rounded()))) }

    static func valid(_ arr: Any?, total: Double) -> [Pick] {
        (arr as? [Any] ?? []).compactMap { x in
            guard let o = x as? [String: Any], let s = num(o["start"]), let e = num(o["end"]),
                  e - s >= 10, e - s <= 150, s >= 0, s < total else { return nil }
            return Pick(start: s, end: min(e, total), title: String(String(describing: o["title"] ?? "").prefix(90)),
                        topic: normTopic(o["topic"] as? String), hook: num(o["hook"]) ?? 5)
        }
    }

    static func parseMoments(_ out: String, total: Double) -> [Pick] {
        guard let m = out.group(#"\[\s*\{[\s\S]*\}\s*\]"#, 0) else { return [] }
        return valid(parseJSON(m), total: total)
    }

    /// The batch answer -> one moments array per item, or nil where the model skipped or garbled a video.
    static func parseBatch(_ out: String, _ items: [[Line]]) -> [[Pick]?] {
        guard let m = out.group(#"\{[\s\S]*\}"#, 0), let d = parseJSON(m) as? [String: Any] else { return items.map { _ in nil } }
        return items.enumerated().map { i, lines in
            let ms = valid(d["video_\(i + 1)"], total: totalSecs(lines))
            return ms.isEmpty ? nil : ms
        }
    }

    /// One call for the whole transcript (Gemini has a huge context); very long ones are split.
    static func segment(_ g: Gemini, key: String, title: String, lines: [Line], topics: [String]) async throws -> [Pick] {
        let total = totalSecs(lines), maxChars = 400_000
        var res: [Pick] = []
        for w in windows(lines, maxChars) {
            let span = max(60, min(total, w.start + Double(maxChars) / 15) - w.start)
            let out = try await g.ask(key, [["text": prompt(maxMoments(span), title, w.text, topics.prefix(20).joined(separator: ", "))]])
            res += parseMoments(out, total: total)
        }
        if res.isEmpty { throw AIError(.failed, "AI returned no valid moments") }
        return res
    }

    /// Several videos in one Gemini request: vid -> moments, or nil where the model skipped one.
    static func segmentBatch(_ g: Gemini, key: String, items: [(vid: String, title: String, lines: [Line])],
                             topics: [String]) async throws -> [String: [Pick]?] {
        let videos = items.map { (title: $0.title, text: transcriptText($0.lines), maxn: maxMoments(totalSecs($0.lines))) }
        let out = try await g.ask(key, [["text": batchPrompt(videos, topics.prefix(20).joined(separator: ", "))]])
        let res = parseBatch(out, items.map(\.lines))
        var map: [String: [Pick]?] = [:]
        for (i, it) in items.enumerated() { map[it.vid] = .some(res[i]) }
        return map
    }

    /// One clip's answer -> moments and the last second seen. Some models answer relative to the clip.
    static func parseVideoMoments(_ out: String, a: Double, b: Double) -> (moments: [Pick], seen: Double) {
        var d: [String: Any] = [:]
        if let m = out.group(#"[{\[][\s\S]*[}\]]"#, 0) {
            let j = parseJSON(m)
            if let arr = j as? [Any] { d = ["moments": arr] } else if let o = j as? [String: Any] { d = o }
        }
        let rel: (Double) -> Double = { t in a > 0 && t < a - 5 ? t + a : t }
        var moments: [Pick] = []
        for x in d["moments"] as? [[String: Any]] ?? [] {
            guard let s0 = num(x["start"]), let e0 = num(x["end"]) else { continue }
            let st = rel(s0), en = rel(e0)
            if en - st >= 10 && en - st <= 150 && st >= a - 5 && st < b + 5 {
                moments.append(Pick(start: st, end: en, title: String(String(describing: x["title"] ?? "").prefix(90)),
                                    topic: normTopic(x["topic"] as? String), hook: num(x["hook"]) ?? 5))
            }
        }
        return (moments, num(d["last_second_seen"]).map(rel) ?? 0)
    }

    /// No usable captions: Gemini watches the video itself, in 20-minute clips until the video ends.
    static func segmentVideo(_ g: Gemini, key: String, vid: String, title: String, topics: [String]) async throws -> [Pick] {
        var res: [Pick] = [], a: Double = 0
        for _ in 0..<videoMaxSegments {
            let b = a + videoSegment
            let out = try await g.ask(key, [
                ["file_data": ["file_uri": "https://www.youtube.com/watch?v=\(vid)"],
                 "video_metadata": ["start_offset": "\(Int(a))s", "end_offset": "\(Int(b))s"]],
                ["text": videoPrompt(a: a, b: b, title: title, topics: topics.prefix(20).joined(separator: ", "))],
            ], mediaLow: true)
            let (ms, seen) = parseVideoMoments(out, a: a, b: b)
            res += ms
            if seen < b - 60 { break }   // the video ended inside this clip
            a = b
        }
        if res.isEmpty { throw AIError(.failed, "Gemini couldn't find moments in this video") }
        return res
    }

    /// Plain 60-second chunks, when the AI can't help.
    static func chunks(_ lines: [Line]) -> [Pick] {
        var res: [Pick] = [], s0: Double?, first = ""
        for l in lines {
            if s0 == nil { s0 = l.s; first = l.t }
            if l.s + l.d - s0! >= 60 {
                res.append(Pick(start: s0!, end: l.s + l.d, title: first.split(separator: " ").prefix(7).joined(separator: " ") + "…",
                                topic: "misc", hook: 4))
                s0 = nil
            }
        }
        return res
    }
}
