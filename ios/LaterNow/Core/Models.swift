import Foundation

/// One caption line: start, duration, text. Stored as a compact [s, d, "text"] array.
struct Line: Codable, Hashable {
    var s: Double
    var d: Double
    var t: String

    init(_ s: Double, _ d: Double, _ t: String) { self.s = s; self.d = d; self.t = t }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        s = try c.decode(Double.self); d = try c.decode(Double.self); t = try c.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(s); try c.encode(d); try c.encode(t)
    }
}

enum VStatus: String, Codable {
    case queued
    case fetching = "fetching captions"
    case finding = "finding moments"
    case waiting
    case needsKey = "needs_key"
    case ready
    case failed

    var inProgress: Bool { self == .fetching || self == .finding }
    /// Queued, waiting or in progress.
    var busy: Bool { ![.ready, .failed, .needsKey].contains(self) }
}

struct Video: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var channel: String
    var status: VStatus
    var error: String?
    var added: Double
    var retryAt: Double
    var tries: Int
    var lease: Double
    var cap: Bool        // captions fetched (or known to be missing)
    var nocap: Bool      // no usable captions: Gemini watches the video
    var solo: Bool       // a batch answer skipped it: next time it goes alone
    var chars: Int       // transcript length

    init(id: String, added: Double) {
        self.id = id; title = id; channel = ""; status = .queued; error = nil; self.added = added
        retryAt = 0; tries = 0; lease = 0; cap = false; nocap = false; solo = false; chars = 0
    }
}

struct Moment: Codable, Identifiable, Hashable {
    var id: Int
    var vid: String
    var start: Double
    var end: Double
    var title: String
    var topic: String
    var hook: Double
}

struct Hist: Codable { var done: Bool; var last: Double; var skips: Int }
struct Pref: Codable { var score: Double; var n: Int }
struct Progress: Codable { var moment: Int; var t: Double }

/// A moment as the feed shows it.
struct FeedMoment: Identifiable, Hashable {
    var m: Moment
    var vtitle: String
    var channel: String
    var lines: [Line]
    var resumeT: Double?
    var id: Int { m.id }
}

struct TopicStat: Identifiable { var topic: String; var n: Int; var score: Double; var id: String { topic } }

struct AddResult {
    var found = 0
    var new = 0
    var notes: [String] = []
    var needsSignIn = false

    var message: String {
        if found > 0 {
            let dup = found - new
            return "Added \(new) video\(new == 1 ? "" : "s")" + (dup > 0 ? ", \(dup) already in" : "")
        }
        return notes.first ?? "No YouTube links found"
    }
}
