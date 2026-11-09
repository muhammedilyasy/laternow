import CryptoKit
import Foundation
import WebKit

/// Error codes the queue understands.
struct YTError: LocalizedError {
    enum Code { case network, rateLimit, http, consent, fatal, noCaptions }
    var code: Code
    var message: String
    init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

/// YouTube access from the phone: metadata, captions, playlists, Watch Later. Same flow as extension/src/youtube.js.
///
/// Captions follow youtube-transcript-api: watch page -> INNERTUBE_API_KEY -> POST youtubei/v1/player as the ANDROID
/// client -> captionTracks -> timedtext XML (without fmt=srv3).
enum YouTube {
    static let videoRE = #"(?:v=|youtu\.be/|shorts/|embed/|live/)([A-Za-z0-9_-]{11})"#
    static let listRE = #"[?&]list=([A-Za-z0-9_-]+)"#
    static let idRE = #"^[A-Za-z0-9_-]{11}$"#
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Our own session: no shared cookie jar. Cookies are added per request (consent, and the YouTube sign-in for Watch Later).
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    struct Resp { var data: Data; var http: HTTPURLResponse; var text: String { String(decoding: data, as: UTF8.self) } }

    static func get(_ url: String, method: String = "GET", headers: [String: String] = [:], body: Any? = nil,
                    cookies: String = "") async throws -> Resp {
        guard let u = URL(string: url) else { throw YTError(.fatal, "Bad URL") }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        // In the EU a client without a consent cookie is redirected to consent.youtube.com.
        r.setValue(cookies.isEmpty ? "SOCS=CAI" : cookies + "; SOCS=CAI", forHTTPHeaderField: "Cookie")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) }
        catch { throw YTError(.network, "Couldn't reach YouTube (\(error.localizedDescription))") }
        guard let http = resp as? HTTPURLResponse else { throw YTError(.network, "Couldn't reach YouTube") }
        if http.statusCode == 429 { throw YTError(.rateLimit, "YouTube is rate-limiting this device. Retrying automatically.") }
        return Resp(data: data, http: http)
    }

    private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
    static func unescapeHtml(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let e = String(after[..<semi])
                var rep: String?
                if e.hasPrefix("#x") || e.hasPrefix("#X") { rep = UInt32(e.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if e.hasPrefix("#") { rep = UInt32(e.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { rep = entities[e.lowercased()] }
                if let rep { out += rep; rest = after[after.index(after: semi)...]; continue }
            }
            out += "&"; rest = after
        }
        return out + rest
    }

    static func meta(_ vid: String) async -> (String, String) {
        let u = "https://www.youtube.com/oembed?format=json&url=" +
            ("https://www.youtube.com/watch?v=" + vid).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        if let r = try? await get(u), r.http.statusCode == 200, let d = parseJSON(r.text) as? [String: Any] {
            return ((d["title"] as? String) ?? vid, (d["author_name"] as? String) ?? "")
        }
        return (vid, "")
    }

    private static func isConsent(_ r: Resp) -> Bool {
        r.http.url?.host?.hasPrefix("consent.") == true || r.text.contains("action=\"https://consent.youtube.com/s\"")
    }

    private static func checkPlayability(_ ps: [String: Any]?) throws {
        guard let st = ps?["status"] as? String, st != "OK" else { return }
        let reason = (ps?["reason"] as? String) ?? ""
        if st == "LOGIN_REQUIRED" {
            if reason.test("(?i)not a bot") { throw YTError(.rateLimit, "YouTube asked to confirm this device is not a bot. Retrying automatically.") }
            if reason.test("(?i)age") { throw YTError(.fatal, "Age-restricted video") }
        }
        if st == "ERROR" && reason.test("(?i)unavailable") { throw YTError(.fatal, "Video unavailable") }
        throw YTError(.fatal, String("Video can't be played\(reason.isEmpty ? "" : ": " + reason)".prefix(160)))
    }

    private static func pickTrack(_ tracks: [[String: Any]]) -> [String: Any]? {
        let langs = ["en", "en-US", "en-GB"]
        let manual = tracks.filter { ($0["kind"] as? String) != "asr" }, auto = tracks.filter { ($0["kind"] as? String) == "asr" }
        let isEn: ([String: Any]) -> Bool = { t in
            let l = (t["languageCode"] as? String) ?? ""
            return langs.contains(l) || l.test(#"(?i)^en\b"#)
        }
        return manual.first(where: isEn) ?? auto.first(where: isEn) ?? manual.first ?? auto.first
    }

    static func parseTimedText(_ xml: String) -> [Line] {
        var out: [Line] = []
        for m in xml.allMatches(#"<text\b([^>]*)>([\s\S]*?)</text>"#) {
            let a = m[1], raw = m[2]
            guard let start = a.group(#"\bstart="([^"]*)""#).flatMap(Double.init) else { continue }
            let dur = a.group(#"\bdur="([^"]*)""#).flatMap(Double.init) ?? 0
            // XML entities first, then the HTML inside the caption text (same as the Python library).
            let text = unescapeHtml(unescapeHtml(raw)).rxReplace("<[^>]*>", with: "").rxReplace(#"\s+"#, with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(Line(start, dur, text)) }
        }
        return out
    }

    static func transcript(_ vid: String) async throws -> [Line] {
        let page = try await get("https://www.youtube.com/watch?v=\(vid)")
        guard page.http.statusCode == 200 else { throw YTError(.http, "YouTube returned \(page.http.statusCode)") }
        let html = page.text
        if isConsent(page) { throw YTError(.consent, "YouTube asked for cookie consent. Retrying later.") }
        guard let key = html.group(#""INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)""#) else {
            if html.contains("class=\"g-recaptcha\"") { throw YTError(.rateLimit, "YouTube is showing a captcha. Retrying automatically.") }
            throw YTError(.fatal, "Couldn't read the YouTube page")
        }
        let r = try await get("https://www.youtube.com/youtubei/v1/player?key=\(key)", method: "POST",
                              headers: ["Origin": "https://www.youtube.com"],
                              body: ["context": ["client": ["clientName": "ANDROID", "clientVersion": "20.10.38"]], "videoId": vid])
        guard r.http.statusCode == 200 else { throw YTError(.http, "YouTube player API returned \(r.http.statusCode)") }
        let data = parseJSON(r.text) as? [String: Any] ?? [:]
        try checkPlayability(data["playabilityStatus"] as? [String: Any])
        let tracks = ((data["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any])?["captionTracks"] as? [[String: Any]] ?? []
        guard let t = pickTrack(tracks), let base = t["baseUrl"] as? String else { throw YTError(.noCaptions, "No captions on this video") }
        let url = base.replacingOccurrences(of: "&fmt=srv3", with: "")
        if url.contains("&exp=xpe") { throw YTError(.fatal, "YouTube requires a PO token for these captions") }
        let tr = try await get(url)
        guard tr.http.statusCode == 200 else { throw YTError(.http, "Caption download returned \(tr.http.statusCode)") }
        let lines = parseTimedText(tr.text)
        if lines.isEmpty { throw YTError(.noCaptions, "No captions on this video") }
        return lines
    }

    // MARK: - Playlists (incl. Watch Later)

    /// The JSON object that follows `marker` in a page, found by brace matching.
    static func extractJSON(_ html: String, _ marker: String) -> Any? {
        guard let i = html.range(of: marker) else { return nil }
        let bytes = Array(html.utf8[i.upperBound...])
        guard let j = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0, inStr = false, esc = false
        for k in j..<bytes.count {
            let c = bytes[k]
            if inStr {
                if esc { esc = false } else if c == UInt8(ascii: "\\") { esc = true } else if c == UInt8(ascii: "\"") { inStr = false }
                continue
            }
            if c == UInt8(ascii: "\"") { inStr = true }
            else if c == UInt8(ascii: "{") { depth += 1 }
            else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return try? JSONSerialization.jsonObject(with: Data(bytes[j...k])) }
            }
        }
        return nil
    }

    private static func token(_ o: Any?) -> String? {
        if let d = o as? [String: Any] {
            if let t = (d["continuationCommand"] as? [String: Any])?["token"] as? String { return t }
            for v in d.values { if let t = token(v) { return t } }
        } else if let a = o as? [Any] {
            for v in a { if let t = token(v) { return t } }
        }
        return nil
    }

    /// Collects video ids and continuation tokens (classic playlistVideoRenderer and the newer lockupViewModel layouts).
    private static func walk(_ o: Any?, _ ids: inout [String], _ conts: inout [String]) {
        if let a = o as? [Any] { for x in a { walk(x, &ids, &conts) }; return }
        guard let d = o as? [String: Any] else { return }
        if let v = d["playlistVideoRenderer"] as? [String: Any], let id = v["videoId"] as? String {
            if (v["isPlayable"] as? Bool) != false { ids.append(id) }
            return
        }
        if let l = d["lockupViewModel"] as? [String: Any] {
            if (l["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO", let id = l["contentId"] as? String, id.test(idRE) { ids.append(id) }
            return
        }
        if let c = d["continuationItemRenderer"] ?? d["continuationItemViewModel"] {
            if let t = token(c) { conts.append(t) }
            return
        }
        for v in d.values { walk(v, &ids, &conts) }
    }

    /// YouTube cookies from the in-app sign-in (Watch Later needs them).
    static func signInCookies() async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { $0.domain.hasSuffix("youtube.com") }
    }

    static func isSignedIn() async -> Bool {
        await signInCookies().contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
    }

    struct PlaylistResult { var ids: [String] = []; var notes: [String] = []; var signedOut = false }

    static func playlist(_ listId: String, requireLogin: Bool = false) async throws -> PlaylistResult {
        var notes: [String] = []
        let jar = requireLogin ? await signInCookies() : []
        let cookies = jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let enc = listId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? listId
        let r = try await get("https://www.youtube.com/playlist?list=\(enc)", cookies: cookies)
        guard r.http.statusCode == 200 else { return PlaylistResult(notes: ["Playlist failed: YouTube returned \(r.http.statusCode)"]) }
        let html = r.text
        if isConsent(r) { return PlaylistResult(notes: ["YouTube asked for cookie consent. Try again in a minute."]) }
        let loggedIn = html.test(#""LOGGED_IN":\s*true"#)
        if requireLogin && !loggedIn { return PlaylistResult(notes: ["Sign in to YouTube to import your Watch Later."], signedOut: true) }
        guard let data = extractJSON(html, "ytInitialData") as? [String: Any] else { return PlaylistResult(notes: ["Couldn't read that playlist"]) }
        var ids: [String] = [], conts: [String] = []
        walk(data["contents"] ?? data, &ids, &conts)
        if ids.isEmpty && conts.isEmpty {
            let alerts = (try? JSONSerialization.data(withJSONObject: data["alerts"] ?? [])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let alert = alerts.group(#""text":"([^"]+)""#)
            return PlaylistResult(notes: [alert.map { "Playlist: \($0)" } ?? "That playlist is empty or private"])
        }
        let key = html.group(#""INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)""#)
        let ver = html.group(#""INNERTUBE_CLIENT_VERSION":\s*"([^"]+)""#) ?? "2.20250101.00.00"
        // Signed-in continuation requests need a SAPISIDHASH, like youtube.com sends.
        var auth: [String: String] = [:]
        if let sap = jar.first(where: { $0.name == "SAPISID" })?.value ?? jar.first(where: { $0.name == "__Secure-3PAPISID" })?.value {
            let ts = Int(nowS()), origin = "https://www.youtube.com"
            let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sap) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
            auth = ["Authorization": "SAPISIDHASH \(ts)_\(hash)", "X-Origin": origin, "X-Goog-AuthUser": "0"]
        }
        var pages = 0, stuck = false
        while !conts.isEmpty, let key, pages < 60 {
            let tok = conts.removeFirst(); pages += 1
            do {
                let c = try await get("https://www.youtube.com/youtubei/v1/browse?key=\(key)&prettyPrint=false", method: "POST",
                                      headers: ["Origin": "https://www.youtube.com", "X-YouTube-Client-Name": "1", "X-YouTube-Client-Version": ver]
                                          .merging(auth) { a, _ in a },
                                      body: ["context": ["client": ["clientName": "WEB", "clientVersion": ver, "hl": "en"]], "continuation": tok],
                                      cookies: cookies)
                guard c.http.statusCode == 200 else { stuck = true; break }
                let before = ids.count
                walk(parseJSON(c.text), &ids, &conts)
                if ids.count == before { conts.removeAll(); break }   // nothing more: end of the list
            } catch { stuck = true; break }
        }
        // The header says how many videos there are; hidden/unavailable ones account for small differences.
        let header = (try? JSONSerialization.data(withJSONObject: data["header"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let total = Int((header.group(#""text":"([\d,.]+)"\},\{"text":" videos?""#) ?? "")
            .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")) ?? 0
        let short = total > 0 ? (Double(ids.count) < Double(total) * 0.95 && total - ids.count > 2) : (stuck || !conts.isEmpty)
        if short { notes.append("Imported the first \(ids.count)\(total > 0 ? " of \(total)" : "") videos. YouTube didn't return the rest.") }
        var seen = Set<String>()
        return PlaylistResult(ids: ids.filter { seen.insert($0).inserted }, notes: notes)
    }

    /// Links, bare ids and playlist links -> unique video ids.
    static func expand(_ text: String) async -> (ids: [String], notes: [String]) {
        var ids: [String] = [], notes: [String] = []
        let parts = text.components(separatedBy: CharacterSet(charactersIn: " \n\t\r,")).filter { !$0.isEmpty }
        for u in parts {
            let pl = u.group(listRE), v = u.group(videoRE)
            if let pl, v == nil {
                do {
                    let r = try await playlist(pl, requireLogin: pl == "WL" || pl == "LL")
                    ids += r.ids; notes += r.notes
                } catch { notes.append("Playlist failed: \(error.localizedDescription)") }
            } else if let v { ids.append(v) }
            else if u.test(idRE) { ids.append(u) }
        }
        var seen = Set<String>()
        return (ids.filter { seen.insert($0).inserted }, notes)
    }
}
