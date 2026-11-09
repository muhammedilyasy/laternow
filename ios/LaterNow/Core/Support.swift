import Foundation

func nowS() -> Double { Date().timeIntervalSince1970 }

/// "m:ss", the timestamp format used in transcripts sent to Gemini and on the cards.
func fmt(_ s: Double) -> String {
    let n = max(0, Int(s))
    return "\(n / 60):" + String(format: "%02d", n % 60)
}

/// Like JavaScript's parseFloat: the leading number of a value, if any.
func num(_ x: Any?) -> Double? {
    switch x {
    case let n as NSNumber: return n.doubleValue
    case let s as String:
        guard let g = s.trimmingCharacters(in: .whitespaces).firstMatch(#"^[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?"#)?[0] else { return nil }
        return Double(g)
    default: return nil
    }
}

// MARK: - Regex helpers (NSRegularExpression, cached)

private var regexCache: [String: NSRegularExpression] = [:]
private func rx(_ p: String) -> NSRegularExpression {
    if let r = regexCache[p] { return r }
    let r = try! NSRegularExpression(pattern: p, options: [])
    regexCache[p] = r
    return r
}

extension String {
    func test(_ pattern: String) -> Bool {
        rx(pattern).firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }

    /// Groups of the first match: [whole, group1, ...] ("" for a group that didn't take part); nil when there is no match.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let m = rx(pattern).firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return groups(m)
    }

    /// Group `i` of the first match.
    func group(_ pattern: String, _ i: Int = 1) -> String? { firstMatch(pattern)?[i] }

    func allMatches(_ pattern: String) -> [[String]] {
        rx(pattern).matches(in: self, range: NSRange(startIndex..., in: self)).map(groups)
    }

    private func groups(_ m: NSTextCheckingResult) -> [String] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: self).map { String(self[$0]) } ?? "" }
    }

    func rxReplace(_ pattern: String, with template: String) -> String {
        rx(pattern).stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}

func parseJSON(_ s: String) -> Any? {
    guard let d = s.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
}

/// "in 3 min", "at 9:30 AM", "tomorrow 12:00 AM"
func when(_ ts: Double) -> String {
    let d = Date(timeIntervalSince1970: ts), mins = Int(((ts - nowS()) / 60).rounded())
    if mins < 1 { return "in a moment" }
    if mins < 60 { return "in \(mins) min" }
    let t = d.formatted(date: .omitted, time: .shortened)
    return Calendar.current.isDateInToday(d) ? "at \(t)" : "tomorrow \(t)"
}

func thumbURL(_ vid: String, _ q: String = "hqdefault") -> URL {
    URL(string: "https://i.ytimg.com/vi/\(vid)/\(q).jpg")!
}

func youtubeURL(_ vid: String, _ start: Double) -> URL {
    URL(string: "https://www.youtube.com/watch?v=\(vid)&t=\(Int(start))s")!
}
