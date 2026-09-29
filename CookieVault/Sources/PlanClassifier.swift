import Foundation

// MARK: - Account State
//
// Beyond premium/free, cookie filenames encode whether the subscription is actually
// usable right now: Netflix "on_hold", HBO "nosub"/"paused", "suspended", etc.
public enum AccountState: String, Codable, Equatable {
    case active, onHold, noSub, paused, suspended, expired, unknown

    /// A short badge label, or nil when there's nothing noteworthy to show.
    public var label: String? {
        switch self {
        case .onHold:    return "On hold"
        case .noSub:     return "No sub"
        case .paused:    return "Paused"
        case .suspended: return "Suspended"
        case .expired:   return "Cancelled"
        case .active, .unknown: return nil
        }
    }
    /// True when the account looks usable (not on hold / no-sub / suspended / cancelled).
    public var isUsable: Bool { self == .active || self == .unknown }
}

// MARK: - Plan Classifier
//
// Rethought, per-service premium detection. The old approach keyword-matched the whole
// path and mislabeled a lot (Grok "free" → Premium, HBO "nosub" → Premium, …). This
// looks at the plan token in the filename with rules tuned per service.
public enum PlanClassifier {

    // Generic paid-plan signals (a token equal to, or prefixed by, one of these ⇒ premium).
    // Generic paid-plan tokens. Flag-based/ambiguous words (gold, turbo, member, fan)
    // are handled per-service instead, so they're intentionally NOT here.
    private static let premiumWords: Set<String> = [
        "premium", "plus", "pro", "prolite", "go", "ultra", "ultimate", "vip", "svip", "team",
        "max", "family", "duo", "student", "super", "supergrok", "paid", "business",
        "enterprise", "unlimited", "hifi", "megafan", "essential", "creator",
        "annual", "yearly", "monthly", "lifetime", "standard", "mobile",
        "individual", "sport", "cine", "ciné", "deluxe", "elite", "advanced"
    ]
    private static let freeWords: Set<String> = ["free", "none", "na", "n/a", "nosub", "basic", "starter", "trial"]

    /// `folderHint` is the tier subfolder the account came from in the source archive
    /// (e.g. "Premium", "Standard with ads", "Prime_NoSub_Unknown", "Semrush_Pro"). It's the
    /// most authoritative plan signal — it's exactly how the file organizes the accounts — so
    /// we fold it into the tokens the per-service rules already reason over.
    public static func classify(service: String, name: String, folderHint: String? = nil) -> (tier: AccountTier, plan: String?, state: AccountState) {
        let svc = service.lowercased()
        var lname = name.lowercased()
        var tokens = bracketTokens(name).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        if let hint = folderHint?.lowercased().trimmingCharacters(in: .whitespaces), !hint.isEmpty {
            // Drop a leading service-name component ("semrush_pro" → "pro", "grok_supergrok" →
            // "supergrok", "prime_premium" → "premium") but keep multi-word plans intact.
            let comps = hint.split(whereSeparator: { $0 == "_" }).map(String.init)
            let plan = comps.count > 1 && svc.contains(comps[0]) ? comps.dropFirst().joined(separator: "_") : hint
            // Feed the plan token whole (so "standard with ads" → firstWord "standard") and split.
            tokens.append(plan)
            tokens.append(contentsOf: plan.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init))
            lname += " " + hint
        }

        let state = detectState(tokens: tokens, lname: lname)
        var (tier, plan) = classifyPlan(svc: svc, tokens: tokens, lname: lname, state: state)

        // A recognised plan with no explicit bad state is active.
        var finalState = state
        if finalState == .unknown && tier == .premium { finalState = .active }
        // No-sub / cancelled accounts are effectively free regardless of past plan.
        if finalState == .noSub { tier = .free; if plan == nil { plan = "No sub" } }

        return (tier, plan, finalState)
    }

    private static func detectState(tokens: [String], lname: String) -> AccountState {
        if lname.contains("on_hold") || lname.contains("on hold") || tokens.contains(where: { $0.contains("hold") }) { return .onHold }
        if tokens.contains("nosub") || lname.contains("nosub") || lname.contains("no_sub") || lname.contains("no sub") { return .noSub }
        if tokens.contains("paused") || lname.contains("paused") { return .paused }
        if tokens.contains(where: { $0.hasPrefix("suspend") }) || tokens.contains("banned") { return .suspended }
        if tokens.contains(where: { $0.hasPrefix("cancel") }) || tokens.contains("expired") { return .expired }
        return .unknown
    }

    /// A token's first word, split on spaces AND underscores ("standard with ads" → "standard",
    /// "pro_premium" → "pro"). Matching on this — not a prefix of the whole token — avoids
    /// short plan words like "go"/"pro" falsely matching usernames ("gopfil50", "profit…").
    private static func firstWord(_ t: String) -> String {
        let raw = t.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).first.map(String.init) ?? t
        // Strip trailing symbols so "premium+", "pro." etc. still match ("premium", "pro").
        var s = raw
        while let last = s.last, !last.isLetter, !last.isNumber { s.removeLast() }
        return s
    }
    private static func isPaidToken(_ t: String) -> Bool {
        premiumWords.contains(t) || premiumWords.contains(firstWord(t))
    }
    private static func isFreeToken(_ t: String) -> Bool {
        t.hasPrefix("free") || freeWords.contains(t) || freeWords.contains(firstWord(t))
    }

    private static func classifyPlan(svc: String, tokens: [String], lname: String, state: AccountState) -> (AccountTier, String?) {
        func firstPremium() -> String? { tokens.first { isPaidToken($0) } }
        func hasFree() -> Bool { tokens.contains { isFreeToken($0) } }
        // A "<word> true" boolean flag (Twitch turbo/prime, X verified, Reddit premium/gold).
        func flagTrue(_ word: String) -> Bool { tokens.contains("\(word) true") }
        func has(_ w: String) -> Bool { tokens.contains(w) }
        // Some services put the plan in the raw name (underscore-separated), not brackets.
        func nameHas(_ w: String) -> Bool { lname.contains(w) }

        // Services whose plan lives in the raw filename rather than [brackets].
        if svc.contains("crunchyroll") {
            if nameHas("premium") || nameHas("mega") || nameHas("fan") { return (.premium, "Premium") }
            if nameHas("free") { return (.free, "Free") }
            return (.unknown, nil)
        }
        if svc.contains("duolingo") {
            if nameHas("family") { return (.premium, "Family") }
            if nameHas("super") { return (.premium, "Super") }
            if nameHas("max") { return (.premium, "Max") }
            if nameHas("free") { return (.free, "Free") }
            return (.unknown, nil)
        }

        // ── Streaming / video with real paid plans ──────────────────────────────
        if svc.contains("netflix") {
            // Netflix has no free tier; any plan (or on-hold/paused state) is a paid account.
            let planTok = tokens.first { ["premium", "standard", "mobile", "basic", "ultra"].contains(firstWord($0)) }
            if let planTok { return (.premium, prettyPlan(planTok)) }
            return (state != .unknown) ? (.premium, nil) : (.unknown, nil)
        }
        if svc.contains("hbo") || svc == "max" || svc.contains("hbomax") {
            if state == .noSub { return (.free, "No sub") }
            if let p = firstPremium() { return (.premium, prettyPlan(p)) }
            return (.premium, nil)
        }
        if svc.contains("prime video") || svc.contains("primevideo") {
            if state == .noSub { return (.free, "No sub") }
            if hasFree() { return (.free, "Free") }   // the archive explicitly bucketed it as Prime_Free
            if let p = firstPremium() { return (.premium, prettyPlan(p)) }
            return (.premium, "Prime") // a live Prime Video session implies an active Prime sub
        }
        if svc.contains("plex") && !svc.contains("perplex") {   // guard: "perplexity" contains "plex"
            if has("lifetime") || has("∞") { return (.premium, "Lifetime") }
            if firstPremium() != nil || has("monthly") || has("yearly") || has("plex") { return (.premium, "Plex Pass") }
            if hasFree() { return (.free, "Free") }
            return (.unknown, nil)
        }
        if svc.contains("crunchyroll") {
            if hasFree() { return (.free, "Free") }
            if let p = firstPremium() { return (.premium, prettyPlan(p)) }
            return (.unknown, nil)
        }
        if svc.contains("canal") { return hasFree() && firstPremium() == nil ? (.free, "Free") : (firstPremium() != nil ? (.premium, "Premium") : (.unknown, nil)) }

        // ── Flag-based premium (paid perk is a boolean) ─────────────────────────
        if svc.contains("twitch") {
            if flagTrue("turbo") { return (.premium, "Turbo") }
            if flagTrue("prime") { return (.premium, "Prime") }
            if flagTrue("partnership") || flagTrue("partner") { return (.free, "Partner") }
            if flagTrue("affiliate") { return (.free, "Affiliate") }
            return (.free, nil)
        }
        if svc.contains("twitter") || svc.contains("x (twitter)") || svc == "x.com" {
            if flagTrue("verified") { return (.premium, "X Premium") }
            return (.free, nil)
        }
        if svc.contains("reddit") {
            if flagTrue("premium") { return (.premium, "Premium") }
            if flagTrue("gold") { return (.premium, "Gold") }
            return (.free, nil)
        }

        // ── Services with no premium/free subscription concept (state-only labels) ──
        if svc.contains("2captcha") || svc.contains("captcha") {
            // "LowBalance"/"Active"/"Worker" are account states, not paid tiers → never premium.
            return (.free, nil)
        }
        if svc.contains("freepik") || svc.contains("magnific") {
            if nameHas("nopay") || hasFree() { return (.free, "Free") }
            if firstPremium() != nil || has("premium") { return (.premium, "Premium") }
            return (.unknown, nil)
        }
        if svc.contains("whop") {
            if hasFree() { return (.free, "Free") }
            if has("seller") { return (.premium, "Seller") }
            if has("member") || has("paid") { return (.premium, "Member") }
            return (.unknown, nil)
        }

        // ── Free-only services (no paid subscription tier) ──────────────────────
        if svc.contains("pinterest") { return (.free, (has("biz") || has("business")) ? "Business" : "Personal") }
        if svc.contains("youtube") {
            if has("premium") || nameHas("premium") { return (.premium, "Premium") }
            return (.free, nil) // content accounts, not YouTube Premium subs
        }
        if ["tiktok", "facebook", "instagram", "outlook", "microsoft", "gmail", "google",
            "gog", "hoyolab", "amazon", "epic", "udemy", "steam", "roblox", "chess",
            "trustpilot", "ebay", "booking", "uber", "linkedin", "soundcloud"].contains(where: { svc.contains($0) }) {
            // These may still expose a clear paid plan token; honour it, else Free.
            if let p = firstPremium() { return (.premium, prettyPlan(p)) }
            return (.free, nil)
        }

        // ── Learning / tools with plan tokens ───────────────────────────────────
        if svc.contains("coursera") {
            if has("basic") || hasFree() { return (.free, "Free") }
            if let p = firstPremium() { return (.premium, prettyPlan(p)) }
            return (.unknown, nil)
        }
        if svc.contains("cursor") {
            if tokens.contains(where: { $0.hasPrefix("free") }) { return (.free, "Free") }
            if tokens.contains(where: { $0.hasPrefix("pro") || $0.contains("business") }) { return (.premium, "Pro") }
            return (.unknown, nil)
        }
        if svc.contains("patreon") {
            if has("paid") || has("creator") { return (.premium, has("creator") ? "Creator" : "Paid") }
            if hasFree() { return (.free, "Free") }
            return (.unknown, nil)
        }
        if svc.contains("krea") {
            // "monthly"/"yearly" here is the billing cycle (present even on free); check free first.
            if hasFree() { return (.free, "Free") }
            if tokens.contains(where: { ["pro", "max", "basic", "premium", "plus"].contains(firstWord($0)) || $0.hasPrefix("creator_") }) { return (.premium, "Paid") }
            return (.unknown, nil)
        }
        if svc.contains("kling") {
            if has("svip") { return (.premium, "SVIP") }
            if has("vip") { return (.premium, "VIP") }
            if hasFree() { return (.free, "Free") }
            return (.unknown, nil)
        }
        if svc.contains("openrouter") { return has("paid") ? (.premium, "Paid") : (hasFree() ? (.free, "Free") : (.unknown, nil)) }

        // ── Generic rule (Spotify, Deezer, ChatGPT, Grok, TradingView, Manus, …) ─
        if let p = firstPremium() { return (.premium, prettyPlan(p)) }
        if hasFree() { return (.free, "Free") }
        return (.unknown, nil)
    }

    private static func prettyPlan(_ token: String) -> String {
        switch token {
        case "supergrok": return "SuperGrok"
        case "prolite": return "ProLite"
        case "pro_premium": return "Pro Premium"
        case "pro_realtime": return "Pro Realtime"
        case "hifi": return "HiFi"
        case "vip": return "VIP"
        case "megafan": return "Mega Fan"
        default:
            return token.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }
}

// Shared helper: extract [bracket] tokens from a filename.
func bracketTokens(_ name: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"\[([^\]]*)\]"#) else { return [] }
    let ns = name as NSString
    return re.matches(in: name, range: NSRange(location: 0, length: ns.length)).compactMap {
        $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
    }
}
