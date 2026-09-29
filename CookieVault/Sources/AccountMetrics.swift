import Foundation

// MARK: - Account Metrics
//
// Cookie-shop filenames encode per-account stats in bracket tokens, and the exact
// set differs by service ("intelligently for each cookie type"):
//   TikTok:   [0 followers] [0 videos] [0 likes] [0 coins] [$0.00] [0 cc] [2024] [TH]
//   YouTube:  [0 subs] [0 videos] [82 views] [2fa false] [verified false] [monetized false]
//   Pinterest:[MA][PER][0F_5FO][user][email]
//   Reddit:   [1 karma] [suspended false] [mod false] [gold false]
//   Netflix:  [Basic] [IN] email      Spotify: [Free] [US] [token]
//
// This parser turns a filename into typed metrics/flags/country/year so the UI can
// offer filters (followers ≥, cc ≥, verified, country, …) tailored to what's present.

public struct AccountMetrics: Equatable {
    public var country: String? = nil
    public var year: Int? = nil
    public var metrics: [String: Double] = [:]   // followers, videos, views, subs, coins, cc, karma, balance…
    public var flags: [String: Bool] = [:]       // verified, twofa, monetized, mod, gold, suspended, premium…

    public init() {}

    // Canonical numeric metric keys, in a sensible display order.
    public static let metricOrder = [
        "followers", "following", "subs", "views", "videos", "likes", "friends",
        "karma", "coins", "cc", "balance", "earn", "biz", "tracks", "playlists", "credits",
        "games", "projects", "upload", "mems", "companies"
    ]
    public static let flagOrder = [
        "verified", "twofa", "monetized", "premium", "gold", "mod", "suspended"
    ]

    public static func label(forMetric k: String) -> String {
        switch k {
        case "cc": return "CC"
        case "twofa": return "2FA"
        case "subs": return "Subs"
        case "balance": return "Balance"
        case "earn": return "Earned"
        case "biz": return "Business"
        case "mems": return "Members"
        default: return k.prefix(1).uppercased() + k.dropFirst()
        }
    }
    public static func label(forFlag k: String) -> String {
        switch k {
        case "twofa": return "2FA"
        default: return k.prefix(1).uppercased() + k.dropFirst()
        }
    }

    private static let countryCodes: Set<String> = [
        "US","GB","CA","AU","IN","PK","BD","LK","NP","ID","MY","SG","PH","TH","VN","KH","MM",
        "CN","HK","TW","JP","KR","BR","AR","CL","CO","PE","VE","EC","BO","PY","UY","MX","GT",
        "HN","SV","NI","CR","PA","DO","CU","FR","DE","ES","IT","PT","NL","BE","CH","AT","SE",
        "NO","DK","FI","IE","PL","CZ","SK","HU","RO","BG","GR","UA","RU","TR","IL","SA","AE",
        "QA","KW","EG","MA","DZ","TN","LY","NG","GH","KE","ZA","ET","UG","TZ","CM","CI","SN",
        "RS","HR","SI","LT","LV","EE","IS","LU","NZ","BY","KZ","UZ","AZ","GE","AM","IQ","IR",
        "JO","LB","OM","BH","YE","AF","MN"
    ]

    /// Normalizes a raw metric word to a canonical key.
    private static func normMetric(_ w: String) -> String {
        switch w {
        case "subscribers", "sub": return "subs"
        case "follower": return "followers"
        case "video": return "videos"
        case "view": return "views"
        case "like": return "likes"
        case "friend": return "friends"
        case "uploads": return "upload"
        case "playlist": return "playlists"
        case "track": return "tracks"
        case "bal": return "balance"
        case "earnings", "earned": return "earn"
        case "business": return "biz"
        case "members", "member", "memberships": return "mems"
        default: return w
        }
    }
    private static func normFlag(_ w: String) -> String {
        let t = w.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("2fa") || t.contains("2 fa") { return "twofa" }
        if t.hasPrefix("verif") { return "verified" }
        if t.hasPrefix("monet") { return "monetized" }
        if t.hasPrefix("suspend") { return "suspended" }
        if t.hasPrefix("prem") { return "premium" }
        if t.hasPrefix("gold") { return "gold" }
        if t.hasPrefix("mod") { return "mod" }
        return t.replacingOccurrences(of: " ", with: "")
    }

    public static func parse(name: String) -> AccountMetrics {
        var out = AccountMetrics()

        // Country from a leading "XX_" prefix (Prime Video style: "IN_Jagan").
        if let r = name.range(of: #"^[A-Z]{2}_"#, options: .regularExpression) {
            let cc = String(name[r].prefix(2))
            if countryCodes.contains(cc) { out.country = cc }
        }

        for tokenSub in regexGroups(#"\[([^\]]*)\]"#, name) {
            let token = tokenSub.trimmingCharacters(in: .whitespaces)
            let tl = token.lowercased()
            if token.isEmpty { continue }

            // "N word"  → e.g. "0 followers", "82 views", "1 karma", "0 cc"
            if let m = firstGroups(#"^(\d+)\s+([a-z][a-z ]*?)$"#, tl), let n = Double(m[0]) {
                out.metrics[normMetric(m[1].trimmingCharacters(in: .whitespaces))] = n
                continue
            }
            // Pinterest "0F_5FO" → 0 followers, 5 following
            if let m = firstGroups(#"^(\d+)f_(\d+)fo$"#, tl) {
                out.metrics["followers"] = Double(m[0])
                out.metrics["following"] = Double(m[1])
                continue
            }
            // Balance "$0.00" / "$1,234.5"
            if tl.hasPrefix("$") {
                let num = tl.dropFirst().replacingOccurrences(of: ",", with: "")
                if let v = Double(num) { out.metrics["balance"] = v }
                continue
            }
            // Flags "verified false", "2fa true", "monetized false"
            if let m = firstGroups(#"^([a-z0-9][a-z0-9 ]*?)\s+(true|false)$"#, tl) {
                out.flags[normFlag(m[0])] = (m[1] == "true")
                continue
            }
            // Year
            if let y = Int(tl), y >= 2000, y <= 2035 { out.year = y; continue }
            // Country code (2 letters)
            if token.count == 2, countryCodes.contains(token.uppercased()) {
                out.country = token.uppercased(); continue
            }
            // key=value / key:value inside a token
            if let m = firstGroups(#"^([a-z]+)\s*[=:]\s*(\d+(?:\.\d+)?)$"#, tl), let n = Double(m[1]) {
                out.metrics[normMetric(m[0])] = n
                continue
            }
        }

        // Also catch key=value pairs anywhere, incl. money with a $ and thousands separators
        // (SoundCloud "followers=30", Whop "bal=$0.00, earn=$1,234.5, mems=3").
        for m in allGroups(#"([a-z]+)\s*[=:]\s*\$?([0-9][0-9.,]*)"#, name.lowercased()) where m.count == 2 {
            let num = m[1].replacingOccurrences(of: ",", with: "")
            // Guard against a stray trailing dot ("mems=3_" already trimmed by regex).
            if let n = Double(num) { out.metrics[normMetric(m[0])] = n }
        }
        return out
    }

    // MARK: Regex helpers

    private static func regexGroups(_ pattern: String, _ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
    private static func firstGroups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }
    private static func allGroups(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
