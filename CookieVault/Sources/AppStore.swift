import Foundation
import Combine
import AppKit

// MARK: - Toast Type
public enum ToastType {
    case info, success, warning, error
}

// MARK: - Account Tier (Free vs Premium)
public enum AccountTier: String, Codable, CaseIterable {
    case premium = "Premium"
    case free = "Free"
    case unknown = "Unknown"

    public var title: String {
        switch self {
        case .premium: return "Premium"
        case .free: return "Free"
        case .unknown: return "All Tiers"
        }
    }

    public var icon: String {
        switch self {
        case .premium: return "crown.fill"
        case .free: return "tag.fill"
        case .unknown: return "tray.fill"
        }
    }

    public var colorHex: String {
        switch self {
        case .premium: return "f59e0b"
        case .free: return "38bdf8"
        case .unknown: return "9ca3af"
        }
    }
}

// MARK: - Service Brand Helper
public struct ServiceBrand {
    public var name: String
    public var icon: String
    public var colorHex: String

    public init(name: String, icon: String, colorHex: String) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
    }
}

public enum ServiceBrandHelper {
    // (matchKey, name, icon, colorHex). Keys are domains/tokens matched as substrings,
    // but checked LONGEST-KEY-FIRST so specific keys win over generic ones
    // ("hbomax.com" → "max.com" → "x.com"). Keys avoid short ambiguous words
    // (no bare "max"/"go") to stop usernames landing in the wrong service.
    private static let table: [String] = [
        // Streaming / video
        "hbomax.com|HBO Max|play.tv.fill|6366f1",
        "max.com|HBO Max|play.tv.fill|6366f1",
        "netflix|Netflix|play.tv.fill|e50914",
        "primevideo|Prime Video|play.rectangle.fill|00a8e1",
        "hotstar|Hotstar|star.fill|1f80e0",
        "crunchyroll|Crunchyroll|play.circle.fill|f47521",
        "plex.tv|Plex|play.rectangle.on.rectangle.fill|e5a00d",
        "canalplus|Canal+|tv.fill|f97316",
        "youtube|YouTube|play.rectangle.fill|ff0000",
        "twitch|Twitch|video.fill|9146ff",
        "kick.com|Kick|play.square.fill|53fc18",
        // Music
        "spotify|Spotify|music.note|1db954",
        "soundcloud|SoundCloud|cloud.fill|ff5500",
        "deezer|Deezer|waveform|a238ff",
        // AI / dev tools
        "chatgpt|ChatGPT|bubble.left.and.text.bubble.right.fill|10a37f",
        "openai|OpenAI|brain|10a37f",
        "anthropic|Claude|sparkle|d97706",
        "claude.ai|Claude|sparkle|d97706",
        "claude.com|Claude|sparkle|d97706",
        "perplexity|Perplexity|magnifyingglass.circle.fill|20b2aa",
        "grok.com|Grok|atom|22c55e",
        "openrouter|OpenRouter|arrow.triangle.branch|6467f2",
        "cursor.com|Cursor|cursorarrow.rays|38bdf8",
        "cursor.sh|Cursor|cursorarrow.rays|38bdf8",
        "replit|Replit|terminal.fill|f26207",
        "lovable|Lovable|heart.fill|ff6b6b",
        "manus.im|Manus|hand.raised.fill|6c5ce7",
        "krea.ai|Krea|paintbrush.fill|ff4d4d",
        "magnific|Magnific|sparkles|1973ff",
        "freepik|Freepik|photo.fill|1273eb",
        "heygen|HeyGen|person.crop.rectangle.fill|8b5cf6",
        "hedra|Hedra|waveform.circle.fill|8b5cf6",
        "higgsfield|Higgsfield|atom|7c3aed",
        "kling|Kling|film.fill|ff6b35",
        "venice.ai|Venice|theatermasks.fill|d4af37",
        "blackbox|Blackbox AI|cube.transparent.fill|4b5563",
        "grammarly|Grammarly|text.badge.checkmark|15c39a",
        // Dev / code hosting
        "github|GitHub|chevron.left.forwardslash.chevron.right|f0f6fc",
        "gitlab|GitLab|hexagon.fill|fc6d26",
        "bitbucket|Bitbucket|cube.box.fill|2684ff",
        // Learning
        "coursera|Coursera|graduationcap.fill|0056d2",
        "udemy|Udemy|graduationcap.fill|a435f0",
        "duolingo|Duolingo|character.book.closed.fill|58cc02",
        "scribd|Scribd|doc.text.fill|1e7b85",
        // Social
        "pinterest|Pinterest|pin.fill|e60023",
        "tiktok|TikTok|music.note|ff0050",
        "instagram|Instagram|camera.fill|e4405f",
        "facebook|Facebook|hand.thumbsup.fill|1877f2",
        "linkedin|LinkedIn|briefcase.fill|0a66c2",
        "reddit|Reddit|antenna.radiowaves.left.and.right|ff4500",
        "twitter.com|X (Twitter)|xmark.square.fill|1d9bf0",
        "x.com|X (Twitter)|xmark.square.fill|d1d5db",
        "patreon|Patreon|p.circle.fill|ff424d",
        "trustpilot|Trustpilot|star.fill|00b67a",
        // Games / stores
        "epicgames|Epic Games|gamecontroller.fill|2f2d2e",
        "g2a.com|G2A|cart.fill|f05e23",
        "gog.com|GOG|gamecontroller.fill|a855f7",
        "roblox|Roblox|gamecontroller.fill|e2231a",
        "steamcommunity|Steam|gamecontroller.fill|66c0f4",
        "steampowered|Steam|gamecontroller.fill|66c0f4",
        "supercell|Supercell|gamecontroller.fill|f9c22b",
        "minecraft|Minecraft|cube.fill|62a03f",
        "hoyolab|HoYoLAB|gamecontroller.fill|4e98e2",
        "epicgames|Epic Games|gamecontroller.fill|2f2d2e",
        "whop.com|Whop|bag.fill|ff6243",
        // Shopping / misc
        "amazon.com|Amazon|cart.fill|ff9900",
        "booking.com|Booking.com|bed.double.fill|003580",
        "ebay|eBay|tag.fill|e53238",
        "uber|Uber|car.fill|276ef1",
        "chess.com|Chess.com|square.grid.3x3.fill|7fa650",
        // Productivity / mail / marketing
        "outlook|Outlook|envelope.fill|0078d4",
        "hotmail|Outlook|envelope.fill|0078d4",
        "live.com|Outlook|envelope.fill|0078d4",
        "office.com|Outlook|envelope.fill|0078d4",
        "microsoftonline|Outlook|envelope.fill|0078d4",
        "microsoft.com|Microsoft|envelope.fill|0078d4",
        "gmail|Gmail|envelope.fill|ea4335",
        "google|Google|g.circle.fill|4285f4",
        "tradingview|TradingView|chart.xyaxis.line|2962ff",
        "semrush|Semrush|chart.bar.xaxis|ff642d",
        "sensortower|Sensor Tower|chart.bar.fill|6c5ce7",
        "2captcha|2Captcha|shield.lefthalf.filled|06b6d4",
        "patched|Patched|bandage.fill|10b981",
        "telegram|Telegram|paperplane.fill|229ed9",
        "discord|Discord|gamecontroller.fill|5865f2",
        "stripe|Stripe|creditcard.fill|635bff",
    ]

    // Pre-sorted longest-key-first so specific domains win over generic ones.
    private static let sortedTable: [(key: String, name: String, icon: String, color: String)] = {
        table.compactMap { row -> (String, String, String, String)? in
            let p = row.split(separator: "|", maxSplits: 3).map(String.init)
            return p.count == 4 ? (p[0], p[1], p[2], p[3]) : nil
        }.sorted { $0.0.count > $1.0.count }
    }()

    public static func brand(for text: String) -> ServiceBrand {
        let l = text.lowercased()
        for row in sortedTable where l.contains(row.key) {
            return ServiceBrand(name: row.name, icon: row.icon, colorHex: row.color)
        }
        return ServiceBrand(name: "Session", icon: "puzzlepiece.fill", colorHex: "7c6af7")
    }
}

// MARK: - Models

public struct CookieFile: Identifiable, Codable {
    public var id = UUID()
    public var name: String
    public var path: String
    public var format: CookieFormat
    public var cookies: [Cookie]
    public var addedAt: Date = Date()
    public var tags: [String] = []
    public var note: String = ""
    public var folderName: String? = nil
    public var tier: AccountTier = .unknown
    public var accountEmail: String? = nil
    public var planName: String? = nil
    public var serviceName: String? = nil
    public var saved: Bool = false
    public var lastOpenedURL: String? = nil   // remembered launch URL, for "reopen at same URL"
    public var planFolder: String? = nil      // the tier subfolder from the import (e.g. "Premium", "Standard with ads")

    public init(id: UUID = UUID(), name: String, path: String, format: CookieFormat, cookies: [Cookie], addedAt: Date = Date(), tags: [String] = [], note: String = "", folderName: String? = nil, tier: AccountTier = .unknown, accountEmail: String? = nil, planName: String? = nil, serviceName: String? = nil, saved: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.format = format
        self.cookies = cookies
        self.addedAt = addedAt
        self.tags = tags
        self.note = note
        self.folderName = folderName
        self.tier = tier
        self.accountEmail = accountEmail
        self.planName = planName
        self.serviceName = serviceName
        self.saved = saved
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, format, cookies, addedAt, tags, note, folderName, tier, accountEmail, planName, serviceName, saved, lastOpenedURL, planFolder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Cookie File"
        self.path = (try? c.decode(String.self, forKey: .path)) ?? ""
        self.format = (try? c.decode(CookieFormat.self, forKey: .format)) ?? .netscape
        self.cookies = (try? c.decode([Cookie].self, forKey: .cookies)) ?? []
        self.addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date()
        self.tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        self.note = (try? c.decode(String.self, forKey: .note)) ?? ""
        self.folderName = try? c.decodeIfPresent(String.self, forKey: .folderName)
        self.saved = (try? c.decodeIfPresent(Bool.self, forKey: .saved)) ?? false
        self.lastOpenedURL = try? c.decodeIfPresent(String.self, forKey: .lastOpenedURL)
        self.planFolder = try? c.decodeIfPresent(String.self, forKey: .planFolder)
        let loadedTier = (try? c.decodeIfPresent(AccountTier.self, forKey: .tier)) ?? .unknown
        let loadedEmail = try? c.decodeIfPresent(String.self, forKey: .accountEmail)
        let loadedPlan = try? c.decodeIfPresent(String.self, forKey: .planName)
        let loadedService = try? c.decodeIfPresent(String.self, forKey: .serviceName)

        if loadedTier != .unknown && loadedEmail != nil {
            self.tier = loadedTier
            self.accountEmail = loadedEmail
            self.planName = loadedPlan
            self.serviceName = loadedService
        } else {
            let meta = AppStore.extractCookieMetadata(fileName: self.name, path: self.path)
            self.tier = loadedTier != .unknown ? loadedTier : meta.tier
            self.accountEmail = loadedEmail ?? meta.email
            self.planName = loadedPlan ?? meta.plan
            self.serviceName = loadedService ?? meta.service
        }
    }
}

public enum CookieFormat: String, Codable, CaseIterable {
    case netscape = "Netscape"
    case json = "JSON"
    case unknown = "Unknown"
}

public struct Cookie: Identifiable, Codable {
    public var id = UUID()
    public var domain: String
    public var flag: Bool          // HttpOnly
    public var path: String
    public var secure: Bool
    public var expiry: Date?
    public var name: String
    public var value: String
    public var sameSite: String?   // "None" | "Lax" | "Strict" — preserved from JSON exports

    public init(id: UUID = UUID(), domain: String, flag: Bool, path: String, secure: Bool, expiry: Date?, name: String, value: String, sameSite: String? = nil) {
        self.id = id
        self.domain = domain
        self.flag = flag
        self.path = path
        self.secure = secure
        self.expiry = expiry
        self.name = name
        self.value = value
        self.sameSite = sameSite
    }

    public var isExpired: Bool {
        guard let expiry else { return false }
        return expiry < Date()
    }
}

public struct APIKeyFile: Identifiable, Codable {
    public var id = UUID()
    public var service: String          // e.g. "openai"
    public var displayName: String      // e.g. "OpenAI"
    public var icon: String             // SF Symbol
    public var keys: [APIKey]
    public var addedAt: Date = Date()
    public var checkEndpoint: String?
    public var checkStatus: CheckStatus = .idle
    public var folderName: String? = nil

    public init(id: UUID = UUID(), service: String, displayName: String, icon: String, keys: [APIKey], addedAt: Date = Date(), checkEndpoint: String? = nil, checkStatus: CheckStatus = .idle, folderName: String? = nil) {
        self.id = id
        self.service = service
        self.displayName = displayName
        self.icon = icon
        self.keys = keys
        self.addedAt = addedAt
        self.checkEndpoint = checkEndpoint
        self.checkStatus = checkStatus
        self.folderName = folderName
    }
}

public struct APIKey: Identifiable, Codable {
    public var id = UUID()
    public var value: String
    public var status: CheckStatus = .idle
    public var note: String = ""
    public var checkedAt: Date?
    public var responseSnippet: String?
    public var details: KeyDetails? = nil

    public init(id: UUID = UUID(), value: String, status: CheckStatus = .idle, note: String = "", checkedAt: Date? = nil, responseSnippet: String? = nil, details: KeyDetails? = nil) {
        self.id = id
        self.value = value
        self.status = status
        self.note = note
        self.checkedAt = checkedAt
        self.responseSnippet = responseSnippet
        self.details = details
    }
}

public enum CheckStatus: String, Codable, CaseIterable {
    case idle = "idle"
    case checking = "checking"
    case valid = "valid"
    case invalid = "invalid"
    case quotaExceeded = "quotaExceeded"
    case rateLimited = "rateLimited"
    case permissionDenied = "permissionDenied"
    case error = "error"

    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .checking: return "Checking"
        case .valid: return "Valid"
        case .invalid: return "Invalid"
        case .quotaExceeded: return "Quota Exceeded"
        case .rateLimited: return "Rate Limited"
        case .permissionDenied: return "Restricted"
        case .error: return "Error"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? "idle"
        switch raw {
        case "valid": self = .valid
        case "invalid": self = .invalid
        case "checking": self = .checking
        case "quotaexceeded", "quota_exceeded", "quota": self = .quotaExceeded
        case "ratelimited", "rate_limited": self = .rateLimited
        case "permissiondenied", "permission_denied": self = .permissionDenied
        case "error": self = .error
        default: self = .idle
        }
    }
}

public struct KeyDetails: Codable {
    public var accountName: String?
    public var email: String?
    public var planOrTier: String?
    public var balanceOrQuota: String?
    public var permissions: [String]?
    public var models: [String]?
    public var latencyMs: Int?
    public var httpCode: Int?
    public var rawSnippet: String?
    public var checkedAt: Date = Date()

    public init(accountName: String? = nil, email: String? = nil, planOrTier: String? = nil, balanceOrQuota: String? = nil, permissions: [String]? = nil, models: [String]? = nil, latencyMs: Int? = nil, httpCode: Int? = nil, rawSnippet: String? = nil, checkedAt: Date = Date()) {
        self.accountName = accountName
        self.email = email
        self.planOrTier = planOrTier
        self.balanceOrQuota = balanceOrQuota
        self.permissions = permissions
        self.models = models
        self.latencyMs = latencyMs
        self.httpCode = httpCode
        self.rawSnippet = rawSnippet
        self.checkedAt = checkedAt
    }
}

// MARK: - Navigation Tabs
public enum AppTab: String, CaseIterable, Codable {
    case cookies = "Cookies"
    case apiKeys = "API Keys"

    public var icon: String {
        switch self {
        case .cookies: return "puzzlepiece.fill"
        case .apiKeys: return "key.fill"
        }
    }
}

// MARK: - Reusable UI State
public final class HoverState: ObservableObject {
    @Published public var on = false
    public init() {}
}

// MARK: - App Store (Global State)

public class AppStore: ObservableObject {
    // Cookies State
    @Published public var cookieFiles: [CookieFile] = []
    @Published public var selectedCookieFile: CookieFile?
    @Published public var selectedCookie: Cookie?
    @Published public var selectedCookieFolder: String? = nil
    @Published public var selectedCookieTier: AccountTier? = nil
    // One-shot tier to pre-apply when a folder/site overview opens (e.g. "Pinterest → Premium").
    @Published public var pendingCookieTier: AccountTier? = nil
    @Published public var showImportCookies = false

    // API Keys State
    @Published public var apiKeyFiles: [APIKeyFile] = []
    @Published public var selectedAPIFile: APIKeyFile?
    @Published public var selectedAPIFolder: String? = nil
    @Published public var inspectedKey: APIKey? = nil
    @Published public var showImportAPIKeys = false
    // Global "filter for all valids" smart view — shows every valid key across every file/type.
    @Published public var showAllValidKeys: Bool = false

    // Navigation & Folder Fold State
    @Published public var currentTab: AppTab = .cookies {
        didSet { UserDefaults.standard.set(currentTab.rawValue, forKey: "cv_tab") }
    }
    @Published public var searchQuery: String = ""
    @Published public var expandedFolders: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(expandedFolders), forKey: "cv_expanded") }
    }
    private let restoredExpanded: [String]

    // Progress State for Batch Checking
    @Published public var isBatchChecking = false
    @Published public var batchCheckProgress: Double = 0.0
    @Published public var batchCheckCurrentTask: String = ""

    // Launch/index state
    @Published public var isIndexing = false

    // Browser Launch State (Chromium injection / download)
    @Published public var isLaunching = false
    @Published public var launchStatus: String = ""
    @Published public var launchProgress: Double = 0.0

    // Toast State
    @Published public var toastMessage: String? = nil
    @Published public var toastType: ToastType = .info
    private var toastTimer: AnyCancellable?

    // Bump when service/tier derivation logic changes, to force a one-time re-index.
    private static let indexVersion = 1

    public init() {
        ChromiumLauncher.sweepOldSessions() // clear any leftover browser session profiles
        // Capture saved fold state before any auto-expand overwrites it.
        restoredExpanded = UserDefaults.standard.stringArray(forKey: "cv_expanded") ?? []
        // Restore lightweight UI prefs immediately (no data needed).
        if let raw = UserDefaults.standard.string(forKey: "cv_tab"), let t = AppTab(rawValue: raw) {
            currentTab = t
        }
        // Decode + index the (potentially huge) data set OFF the main thread so the
        // window appears instantly instead of freezing on launch.
        loadPersistedDataAsync()
    }

    private func restoreExpandedState() {
        for k in restoredExpanded { expandedFolders.insert(k) }
    }

    private func loadPersistedDataAsync() {
        isIndexing = true
        let url = saveURL
        // Skip the expensive domain re-derivation when the data was already indexed
        // with the current logic — only the cheap in-memory caches get rebuilt.
        let alreadyIndexed = UserDefaults.standard.integer(forKey: "cv_index_version") == Self.indexVersion
        Task.detached(priority: .userInitiated) {
            var cookies: [CookieFile] = []
            var apis: [APIKeyFile] = []
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(AppData.self, from: data) {
                cookies = decoded.cookieFiles
                apis = decoded.apiKeyFiles
            }
            var changed = false
            var stateCache: [UUID: AccountState] = [:]
            var cache: [UUID: AccountMetrics] = [:]
            stateCache.reserveCapacity(cookies.count)
            cache.reserveCapacity(cookies.count)

            for i in cookies.indices {
                if !alreadyIndexed {
                    // One-time heavy pass: backfill + authoritative domain-derived service.
                    let meta = AppStore.extractCookieMetadata(fileName: cookies[i].name, path: cookies[i].path)
                    if cookies[i].tier == .unknown || cookies[i].accountEmail == nil {
                        cookies[i].tier = meta.tier; cookies[i].accountEmail = meta.email
                        cookies[i].planName = meta.plan; changed = true
                    }
                    // Prefer the archive-folder service (reliable) over cookie-domain derivation.
                    let folderSvc = cookies[i].folderName.flatMap { AppStore.serviceFromHitsFolder($0) }
                    if let chosen = folderSvc ?? AppStore.deriveSite(from: cookies[i].cookies) ?? meta.service,
                       cookies[i].serviceName != chosen {
                        cookies[i].serviceName = chosen; changed = true
                    }
                    let r = PlanClassifier.classify(service: cookies[i].serviceName ?? "", name: cookies[i].name, folderHint: cookies[i].planFolder)
                    if cookies[i].tier != r.tier { cookies[i].tier = r.tier; changed = true }
                    if let p = r.plan, cookies[i].planName != p { cookies[i].planName = p; changed = true }
                    stateCache[cookies[i].id] = r.state
                } else {
                    // Fast path: trust persisted tier/service; only compute the transient state.
                    stateCache[cookies[i].id] = PlanClassifier.classify(service: cookies[i].serviceName ?? "", name: cookies[i].name, folderHint: cookies[i].planFolder).state
                }
                cache[cookies[i].id] = AccountMetrics.parse(name: cookies[i].name)
            }

            let finalCookies = cookies, finalApis = apis, finalCache = cache, finalStates = stateCache, didChange = changed
            await MainActor.run {
                self.cookieFiles = finalCookies
                self.apiKeyFiles = finalApis
                self.metricsCache = finalCache
                self.stateCache = finalStates
                self.rebuildSiteIndex()
                for f in self.cookieFolders where self.cookieFilesInFolder(f).count <= 30 { self.expandedFolders.insert("c_\(f)") }
                for f in self.apiKeyFolders where self.apiKeyFilesInFolder(f).count <= 30 { self.expandedFolders.insert("a_\(f)") }
                self.restoreExpandedState()
                self.isIndexing = false
                if didChange { self.save() }
                UserDefaults.standard.set(Self.indexVersion, forKey: "cv_index_version")
            }
        }
    }

    // MARK: - Metadata Extractor for Accounts
    public static func extractCookieMetadata(fileName: String, path: String) -> (tier: AccountTier, plan: String?, email: String?, service: String?) {
        let full = (path + "/" + fileName).lowercased()

        // 1. Tier Detection
        var tier: AccountTier = .unknown
        let premiumKeywords = [
            "/premium", "[premium", "[plus", "[pro", "[go", "[prolite",
            "[worker", "[yearly", "[monthly", "[vip", "[team", "premium/"
        ]
        let freeKeywords = [
            "/free", "[free", "[basic", "free/"
        ]

        if premiumKeywords.contains(where: { full.contains($0) }) {
            tier = .premium
        } else if freeKeywords.contains(where: { full.contains($0) }) {
            tier = .free
        }

        // 2. Email Detection
        var email: String? = nil
        if let emailMatch = fileName.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) {
            email = String(fileName[emailMatch])
        }

        // 3. Plan Name Detection
        var plan: String? = nil
        if let planRange = fileName.range(of: #"(?i)\[(Plus|Pro|Go|Prolite|Worker|Premium|Free|Basic|Yearly|Monthly|Enterprise)\]"#, options: .regularExpression) {
            let matched = String(fileName[planRange])
            plan = matched.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).capitalized
        } else if tier == .premium {
            plan = "Premium"
        } else if tier == .free {
            plan = "Free"
        }

        // 4. Service Detection
        let brand = ServiceBrandHelper.brand(for: full)
        let service = brand.name

        return (tier, plan, email, service)
    }

    // MARK: - Folder & Tier Accessors

    public var cookieFolders: [String] {
        let set = Set(cookieFiles.compactMap { $0.folderName })
        return set.sorted()
    }

    public var premiumCookieFiles: [CookieFile] {
        cookieFiles.filter { $0.tier == .premium }
    }

    public var freeCookieFiles: [CookieFile] {
        cookieFiles.filter { $0.tier == .free }
    }

    public var standaloneCookieFiles: [CookieFile] {
        cookieFiles.filter { $0.folderName == nil }
    }

    // MARK: - Saved ("good") accounts

    public var savedCookieFiles: [CookieFile] { cookieFiles.filter { $0.saved } }

    public func toggleSaved(_ file: CookieFile) {
        guard let idx = cookieFiles.firstIndex(where: { $0.id == file.id }) else { return }
        cookieFiles[idx].saved.toggle()
        let nowSaved = cookieFiles[idx].saved
        if selectedCookieFile?.id == file.id { selectedCookieFile = cookieFiles[idx] }
        save()
        showToast(nowSaved ? "Saved \(file.accountEmail ?? file.name)" : "Removed from Saved", type: nowSaved ? .success : .info)
    }

    /// Auto-save every "good" account (premium + usable state + live session) in scope.
    @discardableResult
    public func saveGoodCookies(in scope: [CookieFile]? = nil, scopeLabel: String = "") -> Int {
        let source = scope ?? cookieFiles
        let good = source.filter { isGoodCookie($0) && !$0.saved }
        guard !good.isEmpty else { showToast("No new good accounts to save", type: .info); return 0 }
        let ids = Set(good.map { $0.id })
        for i in cookieFiles.indices where ids.contains(cookieFiles[i].id) { cookieFiles[i].saved = true }
        save()
        showToast("Saved \(good.count) good account\(good.count == 1 ? "" : "s")\(scopeLabel.isEmpty ? "" : " from \(scopeLabel)")", type: .success)
        return good.count
    }

    public func cookieFilesInFolder(_ folder: String, tier: AccountTier? = nil) -> [CookieFile] {
        cookieFiles.filter {
            $0.folderName == folder && (tier == nil || tier == .unknown || $0.tier == tier)
        }
    }

    // MARK: - Site (Service) grouping — organize accounts by detected website

    /// Normalized site name for a file, falling back to "Other" when unknown.
    public func siteName(for file: CookieFile) -> String {
        let s = (file.serviceName ?? "").trimmingCharacters(in: .whitespaces)
        return (s.isEmpty || s == "Session") ? "Other" : s
    }

    /// Derives a human site name from a file's cookie domains (e.g. hbomax.com → "HBO Max",
    /// otherwise the registrable domain). Used to enrich accounts whose filename doesn't
    /// name the service, so they don't all collapse into "Other".
    static func deriveSite(from cookies: [Cookie]) -> String? {
        guard let host = bestTargetHost(cookies: cookies) else { return nil }
        let brand = ServiceBrandHelper.brand(for: host)
        if brand.name != "Session" { return brand.name }
        let parts = host.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : host
    }

    /// Maps a checker-style service archive folder ("netflix_hits", "mihoyo_hoyolab_hits",
    /// "hbo_max_hits", "steam_cookie_hits") to its section name. This is the most reliable
    /// service signal for these dumps — more so than cookie domains, which can scatter across
    /// CDNs/analytics — so every service gets its own clean section.
    static func serviceFromHitsFolder(_ folder: String) -> String? {
        var key = (folder.split(separator: "/").last.map(String.init) ?? folder).lowercased()
        for suffix in ["_cookie_hits", "_hits", "_cookies", "_hit"] where key.hasSuffix(suffix) {
            key = String(key.dropLast(suffix.count)); break
        }
        key = key.trimmingCharacters(in: .whitespaces)
        let map: [String: String] = [
            "2captcha": "2Captcha", "amazon": "Amazon", "canalplus": "Canal+", "chatgpt": "ChatGPT",
            "claude": "Claude", "coursera": "Coursera", "crunchyroll": "Crunchyroll", "cursor": "Cursor",
            "deezer": "Deezer", "duolingo": "Duolingo", "epicgames": "Epic Games", "facebook": "Facebook",
            "freepik": "Freepik", "g2a": "G2A", "gog": "GOG", "google": "Google", "gmail": "Gmail",
            "grammarly": "Grammarly", "grok": "Grok", "hbo_max": "HBO Max", "hbomax": "HBO Max",
            "hedra": "Hedra", "heygen": "HeyGen", "higgsfield": "Higgsfield", "hotstar": "Hotstar",
            "instagram": "Instagram", "kick": "Kick", "kling": "Kling", "krea_ai": "Krea", "krea": "Krea",
            "linkedin": "LinkedIn", "lovable": "Lovable", "manus": "Manus", "mihoyo_hoyolab": "HoYoLAB",
            "hoyolab": "HoYoLAB", "netflix": "Netflix", "openrouter": "OpenRouter", "outlook": "Outlook",
            "patreon": "Patreon", "perplexity": "Perplexity", "pinterest": "Pinterest", "plextv": "Plex",
            "plex": "Plex", "primevideo": "Prime Video", "reddit": "Reddit", "replit": "Replit",
            "semrush": "Semrush", "sensortower": "Sensor Tower", "scribd": "Scribd", "soundcloud": "SoundCloud",
            "spotify": "Spotify", "steam": "Steam", "steam_cookie": "Steam", "tiktok": "TikTok",
            "tradingview": "TradingView", "twitch": "Twitch", "twitter": "X (Twitter)", "uber": "Uber",
            "udemy": "Udemy", "venice": "Venice", "whop": "Whop", "youtube": "YouTube", "chess": "Chess.com",
            "blackbox": "Blackbox AI", "booking": "Booking.com", "ebay": "eBay", "trustpilot": "Trustpilot",
            "patched": "Patched", "minecraft": "Minecraft", "supercell": "Supercell", "magnific": "Magnific",
            "hotmail": "Outlook", "roblox": "Roblox"
        ]
        if let exact = map[key] { return exact }
        // Fall back to a contains match for compound names ("mihoyo_hoyolab" already keyed).
        for (k, v) in map where key.contains(k) { return v }
        return nil
    }

    /// Fills in serviceName from cookie domains for accounts with no/weak service,
    /// then persists. Cheap no-op once everything is labelled.
    public func enrichServiceNames() {
        var changed = false
        for i in cookieFiles.indices {
            // Domain-derived service wins over the filename (which may hold a @gmail address).
            if let site = Self.deriveSite(from: cookieFiles[i].cookies), cookieFiles[i].serviceName != site {
                cookieFiles[i].serviceName = site
                changed = true
            }
        }
        if changed { save() }
        reclassifyAllCookies()
        buildMetricsCache()
        rebuildSiteIndex()
    }

    /// Fast import finalize: derive/classify/parse ONLY the newly-added accounts
    /// (instead of re-processing the entire library on every import).
    public func indexNewCookies(_ newFiles: [CookieFile]) {
        let ids = Set(newFiles.map { $0.id })
        for i in cookieFiles.indices where ids.contains(cookieFiles[i].id) {
            let meta = AppStore.extractCookieMetadata(fileName: cookieFiles[i].name, path: cookieFiles[i].path)
            let folderSvc = cookieFiles[i].folderName.flatMap { AppStore.serviceFromHitsFolder($0) }
            if let chosen = folderSvc ?? AppStore.deriveSite(from: cookieFiles[i].cookies) ?? meta.service {
                cookieFiles[i].serviceName = chosen
            }
            let r = PlanClassifier.classify(service: cookieFiles[i].serviceName ?? "", name: cookieFiles[i].name, folderHint: cookieFiles[i].planFolder)
            cookieFiles[i].tier = r.tier
            if let p = r.plan { cookieFiles[i].planName = p }
            stateCache[cookieFiles[i].id] = r.state
            metricsCache[cookieFiles[i].id] = AccountMetrics.parse(name: cookieFiles[i].name)
        }
        rebuildSiteIndex()
        save()
    }

    // Cached site grouping — rebuilt only when the cookie set changes, so the sidebar
    // and overviews don't re-scan tens of thousands of accounts on every render.
    private var siteGroupsCache: [String: [CookieFile]] = [:]
    private var cookieSitesCache: [String] = []

    /// Rebuilds the site → files index. Call after any change to `cookieFiles`.
    public func rebuildSiteIndex() {
        var groups: [String: [CookieFile]] = [:]
        for f in cookieFiles { groups[siteName(for: f), default: []].append(f) }
        siteGroupsCache = groups
        cookieSitesCache = groups.keys.sorted {
            let a = groups[$0]?.count ?? 0, b = groups[$1]?.count ?? 0
            return a == b ? $0 < $1 : a > b
        }
    }

    /// All distinct sites, most-populated first (cached).
    public var cookieSites: [String] { cookieSitesCache }

    public func cookieFilesForSite(_ site: String, tier: AccountTier? = nil) -> [CookieFile] {
        let base = siteGroupsCache[site] ?? []
        if let tier, tier != .unknown { return base.filter { $0.tier == tier } }
        return base
    }

    // MARK: - Per-account metrics (parsed from filenames; followers, cc, views, …)

    private var metricsCache: [UUID: AccountMetrics] = [:]

    /// Parsed stats for a file (lazily cached on first access).
    public func metrics(for file: CookieFile) -> AccountMetrics {
        if let c = metricsCache[file.id] { return c }
        let m = AccountMetrics.parse(name: file.name)
        metricsCache[file.id] = m
        return m
    }

    public func buildMetricsCache() {
        var cache: [UUID: AccountMetrics] = [:]
        cache.reserveCapacity(cookieFiles.count)
        for f in cookieFiles { cache[f.id] = AccountMetrics.parse(name: f.name) }
        metricsCache = cache
    }

    // MARK: - Account state (active / on-hold / no-sub …) from the plan classifier

    private var stateCache: [UUID: AccountState] = [:]

    public func state(for file: CookieFile) -> AccountState {
        if let c = stateCache[file.id] { return c }
        let s = PlanClassifier.classify(service: file.serviceName ?? "", name: file.name).state
        stateCache[file.id] = s
        return s
    }

    /// True when an account is worth keeping: premium plan, a usable state, and a live session.
    public func isGoodCookie(_ file: CookieFile) -> Bool {
        guard file.tier == .premium, state(for: file).isUsable else { return false }
        return !file.cookies.isEmpty && !file.cookies.allSatisfy { $0.isExpired }
    }

    /// Re-run tier/plan/state classification across all accounts (used after imports).
    public func reclassifyAllCookies() {
        var states: [UUID: AccountState] = [:]
        states.reserveCapacity(cookieFiles.count)
        var changed = false
        for i in cookieFiles.indices {
            let r = PlanClassifier.classify(service: cookieFiles[i].serviceName ?? "", name: cookieFiles[i].name)
            if cookieFiles[i].tier != r.tier { cookieFiles[i].tier = r.tier; changed = true }
            if let p = r.plan, cookieFiles[i].planName != p { cookieFiles[i].planName = p; changed = true }
            states[cookieFiles[i].id] = r.state
        }
        stateCache = states
        if changed { save() }
    }

    /// The distinct metric keys, flag keys, and countries present across a set of files,
    /// so the UI can show only the filters that make sense ("intelligent per cookie type").
    public func availableFacets(in files: [CookieFile]) -> (metrics: [String], flags: [String], countries: [String], years: [Int]) {
        var metricSet = Set<String>(), flagSet = Set<String>(), countrySet = Set<String>(), yearSet = Set<Int>()
        for f in files {
            let m = metrics(for: f)
            metricSet.formUnion(m.metrics.keys)
            flagSet.formUnion(m.flags.keys)
            if let c = m.country { countrySet.insert(c) }
            if let y = m.year { yearSet.insert(y) }
        }
        let orderedMetrics = AccountMetrics.metricOrder.filter { metricSet.contains($0) } + metricSet.subtracting(AccountMetrics.metricOrder).sorted()
        let orderedFlags = AccountMetrics.flagOrder.filter { flagSet.contains($0) } + flagSet.subtracting(AccountMetrics.flagOrder).sorted()
        return (orderedMetrics, orderedFlags, countrySet.sorted(), yearSet.sorted(by: >))
    }

    public func selectTierFilter(_ tier: AccountTier?) {
        selectedCookieTier = tier
        selectedCookieFolder = nil
        selectedCookieFile = nil
        selectedCookie = nil
    }

    public func selectCookieFolder(_ folder: String, tier: AccountTier? = nil) {
        selectedCookieFolder = folder
        selectedCookieTier = tier
        selectedCookieFile = nil
        selectedCookie = nil
    }

    public var apiKeyFolders: [String] {
        let set = Set(apiKeyFiles.compactMap { $0.folderName })
        return set.sorted()
    }

    public var standaloneAPIKeyFiles: [APIKeyFile] {
        apiKeyFiles.filter { $0.folderName == nil }
    }

    public func apiKeyFilesInFolder(_ folder: String) -> [APIKeyFile] {
        apiKeyFiles.filter { $0.folderName == folder }
    }

    // MARK: - Global valid-keys aggregation ("filter for all valids")

    /// Total valid keys across every file/type.
    public var totalValidKeyCount: Int {
        apiKeyFiles.reduce(0) { $0 + $1.keys.filter { $0.status == .valid }.count }
    }

    /// Total keys that have been checked at least once (not idle/checking).
    public var totalCheckedKeyCount: Int {
        apiKeyFiles.reduce(0) { $0 + $1.keys.filter { $0.status != .idle && $0.status != .checking }.count }
    }

    /// Every file that currently has at least one valid key, paired with its valid keys.
    /// Sorted by valid-count descending so the richest types surface first.
    public func filesWithValidKeys() -> [(file: APIKeyFile, valid: [APIKey])] {
        apiKeyFiles.compactMap { f -> (APIKeyFile, [APIKey])? in
            let valid = f.keys.filter { $0.status == .valid }
            return valid.isEmpty ? nil : (f, valid)
        }
        .sorted { $0.1.count > $1.1.count }
        .map { (file: $0.0, valid: $0.1) }
    }

    public func toggleFolderExpansion(key: String) {
        if expandedFolders.contains(key) {
            expandedFolders.remove(key)
        } else {
            expandedFolders.insert(key)
        }
    }

    // MARK: - Toast Message
    public func showToast(_ message: String, type: ToastType = .info) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.toastMessage = message
            self.toastType = type
            self.toastTimer?.cancel()
            self.toastTimer = Just(())
                .delay(for: .seconds(2.8), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.toastMessage = nil
                }
        }
    }

    // MARK: - Persistence
    private var saveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CookieVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    // Serial queue so overlapping saves can't reorder and lose the newer snapshot.
    private static let saveQueue = DispatchQueue(label: "com.cookievault.save")

    public func save() {
        let cookies = cookieFiles
        let keys = apiKeyFiles
        let url = saveURL
        Self.saveQueue.async {
            let data = AppData(cookieFiles: cookies, apiKeyFiles: keys)
            if let encoded = try? JSONEncoder().encode(data) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
    }


    // MARK: - Native Open Panel File / Folder Pickers
    public func chooseFiles(tab: AppTab) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.text, .json, .plainText, .zip]
        panel.title = tab == .cookies ? "Import Cookie Files" : "Import API Key Files"

        if panel.runModal() == .OK {
            for url in panel.urls {
                if url.pathExtension.lowercased() == "zip" {
                    importZip(from: url, targetTab: tab)
                } else if tab == .cookies {
                    importCookieFile(from: url)
                } else {
                    importAPIKeyFile(from: url)
                }
            }
        }
    }

    public func chooseFolder(tab: AppTab) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = tab == .cookies ? "Import Cookies Folder" : "Import API Keys Folder"

        if panel.runModal() == .OK, let folderURL = panel.url {
            importFolder(from: folderURL, targetTab: tab)
        }
    }

    /// Parse a batch of file URLs concurrently off the main thread. Pure w.r.t. app state —
    /// reads + parses only, returning the built models to commit on the main actor.
    struct ParsedBatch {
        var cookies: [CookieFile] = []
        var apis: [APIKeyFile] = []
        var states: [UUID: AccountState] = [:]
        var metrics: [UUID: AccountMetrics] = [:]
    }

    private func parseFilesConcurrently(_ urls: [URL], folderName: String, tab: AppTab, rootDir: URL? = nil) async -> ParsedBatch {
        // The service archive name (e.g. "netflix_hits") is the most reliable service signal here.
        let folderService = AppStore.serviceFromHitsFolder(folderName)
        // Parse + fully classify one file off the main thread (all pure work).
        func parseOne(_ fileURL: URL) -> (CookieFile?, APIKeyFile?, AccountState?, AccountMetrics?) {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return (nil, nil, nil, nil) }
            let isCookie = isCookieContent(content)
            if tab == .cookies || isCookie {
                let format = detectFormat(content)
                let cookies = parseCookies(content: content, format: format)
                guard !cookies.isEmpty else { return (nil, nil, nil, nil) }
                let baseName = fileURL.deletingPathExtension().lastPathComponent
                let meta = AppStore.extractCookieMetadata(fileName: baseName, path: fileURL.path)
                // Tier subfolder: the top-level directory the account sits in under the archive
                // root (e.g. "Premium", "Standard with ads", "Prime_NoSub_Unknown").
                var planFolder: String? = nil
                if let root = rootDir {
                    let rel = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                    let comps = rel.split(separator: "/")
                    if comps.count >= 2 { planFolder = String(comps.first!) }
                }
                // Service: the archive folder name (most reliable), then cookie domains, then filename.
                let service = folderService ?? AppStore.deriveSite(from: cookies) ?? meta.service
                let r = PlanClassifier.classify(service: service ?? "", name: baseName, folderHint: planFolder)
                var file = CookieFile(name: baseName, path: fileURL.path, format: format, cookies: cookies,
                                      folderName: folderName, tier: r.tier, accountEmail: meta.email,
                                      planName: r.plan ?? meta.plan, serviceName: service)
                file.planFolder = planFolder
                let metrics = AccountMetrics.parse(name: baseName)
                return (file, nil, r.state, metrics)
            } else {
                var keys: [APIKey] = []
                content.enumerateLines { line, _ in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { keys.append(APIKey(value: t)) }
                }
                guard !keys.isEmpty else { return (nil, nil, nil, nil) }
                let serviceName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                let info = serviceInfo(for: serviceName)
                return (nil, APIKeyFile(service: serviceName, displayName: info.displayName, icon: info.icon,
                                        keys: keys, checkEndpoint: info.endpoint, folderName: folderName), nil, nil)
            }
        }
        // Bounded concurrency so a folder with thousands of files can't spawn thousands of
        // simultaneous reads (memory/thread blowup). Keep a fixed window in flight.
        let maxConcurrent = 12
        var batch = ParsedBatch()
        return await withTaskGroup(of: (CookieFile?, APIKeyFile?, AccountState?, AccountMetrics?).self) { group in
            var next = 0
            func launch() {
                guard next < urls.count else { return }
                let u = urls[next]; next += 1
                group.addTask { parseOne(u) }
            }
            for _ in 0..<min(maxConcurrent, urls.count) { launch() }
            while let (c, a, st, m) = await group.next() {
                if let c {
                    batch.cookies.append(c)
                    if let st { batch.states[c.id] = st }
                    if let m { batch.metrics[c.id] = m }
                }
                if let a { batch.apis.append(a) }
                launch()
            }
            return batch
        }
    }

    // MARK: - Folder Import Engine (Recursive, off-main + concurrent)
    public func importFolder(from folderURL: URL, targetTab: AppTab? = nil) {
        let folderName = folderURL.lastPathComponent
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let tab = targetTab ?? currentTab

        // Enumerate quickly on the calling thread; parse heavy content in the background.
        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isRegular else { continue }
            let ext = fileURL.pathExtension.lowercased()
            if ext == "zip" { importZip(from: fileURL, parentFolder: folderName, targetTab: tab); continue }
            guard ext == "txt" || ext == "json" else { continue }
            fileURLs.append(fileURL)
        }
        guard !fileURLs.isEmpty else { return }

        isIndexing = true
        Task.detached(priority: .userInitiated) { [self] in
            let batch = await parseFilesConcurrently(fileURLs, folderName: folderName, tab: tab, rootDir: folderURL)
            await MainActor.run {
                commitImportedBatch(batch, folderName: folderName)
                isIndexing = false
                let totalFiles = batch.cookies.count + batch.apis.count
                if totalFiles > 0 {
                    showToast("Imported folder \"\(folderName)\": \(totalFiles) files", type: .success)
                } else {
                    showToast("No text or JSON files found in \"\(folderName)\"", type: .warning)
                }
            }
        }
    }

    /// Commit a background-parsed batch on the main actor: append models, merge the
    /// precomputed caches (no re-classification on main), reindex once, select, save.
    @MainActor
    private func commitImportedBatch(_ batch: ParsedBatch, folderName: String) {
        if !batch.cookies.isEmpty {
            cookieFiles.append(contentsOf: batch.cookies)
            for (id, st) in batch.states { stateCache[id] = st }
            for (id, m) in batch.metrics { metricsCache[id] = m }
            rebuildSiteIndex()
            selectedCookieFolder = folderName
            selectedCookieFile = batch.cookies.first
            expandedFolders.insert("c_\(folderName)")
        }
        if !batch.apis.isEmpty {
            apiKeyFiles.append(contentsOf: batch.apis)
            selectedAPIFolder = folderName
            selectedAPIFile = batch.apis.first
            expandedFolders.insert("a_\(folderName)")
        }
        save()
    }

    // MARK: - Zip Import Engine (Recursive, off-main + concurrent)
    public func importZip(from url: URL, parentFolder: String? = nil, targetTab: AppTab? = nil) {
        let zipName = parentFolder ?? url.deletingPathExtension().lastPathComponent
        let tab = targetTab ?? currentTab
        isIndexing = true

        Task.detached(priority: .userInitiated) { [self] in
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("cv_zip_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            task.arguments = ["-q", "-o", url.path, "-d", tmpDir.path]
            try? task.run()
            task.waitUntilExit()

            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: tmpDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                try? fm.removeItem(at: tmpDir)
                await MainActor.run { isIndexing = false }
                return
            }

            var fileURLs: [URL] = []
            var nestedZips: [(URL, String)] = []
            while let obj = enumerator.nextObject() {
                guard let fileURL = obj as? URL else { continue }
                guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isRegular else { continue }
                let ext = fileURL.pathExtension.lowercased()
                if ext == "zip" {
                    nestedZips.append((fileURL, "\(zipName)/\(fileURL.deletingPathExtension().lastPathComponent)"))
                    continue
                }
                guard ext == "txt" || ext == "json" else { continue }
                fileURLs.append(fileURL)
            }

            let batch = await parseFilesConcurrently(fileURLs, folderName: zipName, tab: tab, rootDir: tmpDir)

            await MainActor.run {
                commitImportedBatch(batch, folderName: zipName)
                isIndexing = false
                let totalFiles = batch.cookies.count + batch.apis.count
                if totalFiles > 0 { showToast("Imported \"\(zipName)\": \(totalFiles) files", type: .success) }
            }

            // Copy nested zips out to their own temp files BEFORE deleting tmpDir, so the
            // (async) nested imports don't race the cleanup below and read a deleted file.
            for (nz, name) in nestedZips {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cv_nested_\(UUID().uuidString).zip")
                if (try? fm.copyItem(at: nz, to: copy)) != nil {
                    await MainActor.run { importZip(from: copy, parentFolder: name, targetTab: tab) }
                }
            }
            try? fm.removeItem(at: tmpDir)
        }
    }

    // Helper to distinguish cookie files from key files
    private func isCookieContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("# Netscape") || trimmed.contains("#HttpOnly_") { return true }
        if trimmed.contains("\t") {
            let firstLines = content.components(separatedBy: .newlines).prefix(5)
            for line in firstLines {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 6 { return true }
            }
        }
        if (trimmed.hasPrefix("[") || trimmed.hasPrefix("{")) && trimmed.contains("\"expirationDate\"") {
            return true
        }
        return false
    }

    // MARK: - Individual File Imports
    public func importCookieFile(from url: URL, folderName: String? = nil) {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let format = detectFormat(content)
        let cookies = parseCookies(content: content, format: format)
        let baseName = url.deletingPathExtension().lastPathComponent
        let meta = AppStore.extractCookieMetadata(fileName: baseName, path: url.path)
        let file = CookieFile(
            name: baseName,
            path: url.path,
            format: format,
            cookies: cookies,
            folderName: folderName,
            tier: meta.tier,
            accountEmail: meta.email,
            planName: meta.plan,
            serviceName: meta.service
        )
        cookieFiles.append(file)
        indexNewCookies([file])
        selectedCookieFile = file
        selectedCookie = nil
        selectedCookieFolder = nil
        save()
        showToast("Imported \(file.name) (\(cookies.count) cookies)", type: .success)
    }

    public func importAPIKeyFile(from url: URL, folderName: String? = nil) {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let serviceName = url.deletingPathExtension().lastPathComponent.lowercased()
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let keys = lines.map { APIKey(value: $0) }

        let info = serviceInfo(for: serviceName)
        let file = APIKeyFile(
            service: serviceName,
            displayName: info.displayName,
            icon: info.icon,
            keys: keys,
            checkEndpoint: info.endpoint,
            folderName: folderName
        )
        apiKeyFiles.append(file)
        selectedAPIFile = file
        selectedAPIFolder = nil
        save()
        showToast("Imported \(file.displayName) (\(keys.count) keys)", type: .success)
    }

    public func importAPIKeyZip(from url: URL) {
        importZip(from: url, targetTab: .apiKeys)
    }

    // MARK: - Deletion Helpers
    public func deleteCookieFile(_ file: CookieFile) {
        cookieFiles.removeAll { $0.id == file.id }
        rebuildSiteIndex()
        if selectedCookieFile?.id == file.id {
            selectedCookieFile = cookieFiles.first
            selectedCookie = nil
        }
        save()
        showToast("Deleted \(file.name)", type: .info)
    }

    /// Delete a single cookie entry (one row, e.g. a `sessionid`) from within an account.
    public func deleteCookie(_ cookie: Cookie, from file: CookieFile) {
        guard let idx = cookieFiles.firstIndex(where: { $0.id == file.id }) else { return }
        cookieFiles[idx].cookies.removeAll { $0.id == cookie.id }
        // Keep the open detail selection in sync.
        if selectedCookieFile?.id == file.id { selectedCookieFile = cookieFiles[idx] }
        if selectedCookie?.id == cookie.id { selectedCookie = nil }
        save()
        showToast("Deleted cookie “\(cookie.name)”", type: .info)
    }

    /// Delete one specific cookie account, asking for confirmation first (guards a saved/starred one too).
    public func deleteCookieFileConfirmed(_ file: CookieFile) {
        let label = file.accountEmail ?? file.name
        let extra = file.saved ? "\n\nNote: this account is starred (Saved)." : ""
        guard confirmDestructive(title: "Delete this account?",
                                 info: "Permanently removes “\(label)” (\(file.cookies.count) cookies).\(extra)",
                                 confirmTitle: "Delete") else { return }
        deleteCookieFile(file)
    }

    public func deleteCookieFolder(_ folderName: String) {
        let n = cookieFilesInFolder(folderName).count
        guard confirmDestructive(title: "Delete folder “\(folderName)”?",
                                 info: "This permanently removes \(n) cookie account\(n == 1 ? "" : "s").",
                                 confirmTitle: "Delete") else { return }
        cookieFiles.removeAll { $0.folderName == folderName }
        rebuildSiteIndex()
        if selectedCookieFolder == folderName {
            selectedCookieFolder = nil
            selectedCookieFile = cookieFiles.first
            selectedCookie = nil
        }
        expandedFolders.remove("c_\(folderName)")
        save()
        showToast("Deleted folder \"\(folderName)\"", type: .info)
    }

    public func deleteAPIKeyFile(_ file: APIKeyFile) {
        apiKeyFiles.removeAll { $0.id == file.id }
        if selectedAPIFile?.id == file.id {
            selectedAPIFile = apiKeyFiles.first
        }
        save()
        showToast("Deleted \(file.displayName)", type: .info)
    }

    // MARK: - Selected-key actions (interact with specific keys)

    public func deleteKeys(_ ids: Set<UUID>, in file: APIKeyFile) {
        guard !ids.isEmpty, let idx = apiKeyFiles.firstIndex(where: { $0.id == file.id }) else { return }
        apiKeyFiles[idx].keys.removeAll { ids.contains($0.id) }
        save()
        showToast("Deleted \(ids.count) key\(ids.count == 1 ? "" : "s")", type: .info)
    }

    @MainActor
    public func checkKeys(_ ids: Set<UUID>, in file: APIKeyFile) async {
        guard let idx = apiKeyFiles.firstIndex(where: { $0.id == file.id }) else { return }
        let targets = apiKeyFiles[idx].keys.filter { ids.contains($0.id) }.map {
            CheckTarget(id: $0.id, value: $0.value, service: file.service, endpoint: file.checkEndpoint)
        }
        guard !targets.isEmpty else { return }
        isBatchChecking = true
        batchCheckProgress = 0
        batchCheckCurrentTask = "Checking \(targets.count) selected…"

        let locations = makeKeyLocationMap()
        await streamCheck(targets) { [weak self] kid, res, done, total in
            self?.applyResult(kid, res, locations)
            self?.batchCheckProgress = Double(done) / Double(total)
        }
        isBatchChecking = false
        batchCheckProgress = 1
        save()
        showToast("Checked \(targets.count) selected key\(targets.count == 1 ? "" : "s")", type: .success)
    }

    /// QoL: check only keys that have never been checked (idle) in a file — much faster on re-runs.
    @MainActor
    public func checkUncheckedKeys(in file: APIKeyFile) async {
        guard let idx = apiKeyFiles.firstIndex(where: { $0.id == file.id }) else { return }
        let ids = Set(apiKeyFiles[idx].keys.filter { $0.status == .idle }.map { $0.id })
        guard !ids.isEmpty else { showToast("No unchecked keys — all keys already tested", type: .info); return }
        await checkKeys(ids, in: file)
    }

    /// QoL: copy every valid key in a file to the clipboard.
    public func copyValidKeys(in file: APIKeyFile) {
        guard let f = apiKeyFiles.first(where: { $0.id == file.id }) else { return }
        let valid = f.keys.filter { $0.status == .valid }
        guard !valid.isEmpty else { showToast("No valid keys to copy", type: .warning); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(valid.map { $0.value }.joined(separator: "\n"), forType: .string)
        showToast("Copied \(valid.count) valid key\(valid.count == 1 ? "" : "s")", type: .success)
    }

    // MARK: - Account interaction (act on the account behind a key)

    /// Open the provider's dashboard where this key's account is managed.
    public func openProviderDashboard(service: String) {
        guard let s = APIKeyChecker.dashboardURL(service: service), let url = URL(string: s) else {
            showToast("No known dashboard for this provider", type: .warning); return
        }
        NSWorkspace.shared.open(url)
    }

    /// Send a harmless test message through a webhook key (Discord/Slack/Teams).
    @MainActor
    public func sendWebhookTest(_ key: APIKey, service: String) async {
        let (ok, msg) = await APIKeyChecker.sendWebhookTest(key: key.value, service: service,
                                                            text: "✅ CookieVault test message")
        showToast(ok ? msg : "Webhook test failed: \(msg)", type: ok ? .success : .error)
    }

    /// QoL: copy every valid key across ALL files to the clipboard.
    public func copyAllValidKeys() {
        let all = apiKeyFiles.flatMap { $0.keys.filter { $0.status == .valid } }
        guard !all.isEmpty else { showToast("No valid keys to copy", type: .warning); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(all.map { $0.value }.joined(separator: "\n"), forType: .string)
        showToast("Copied \(all.count) valid key\(all.count == 1 ? "" : "s")", type: .success)
    }

    public func deleteAPIFolder(_ folderName: String) {
        let n = apiKeyFilesInFolder(folderName).count
        guard confirmDestructive(title: "Delete folder “\(folderName)”?",
                                 info: "This permanently removes \(n) API-key file\(n == 1 ? "" : "s").",
                                 confirmTitle: "Delete") else { return }
        apiKeyFiles.removeAll { $0.folderName == folderName }
        if selectedAPIFolder == folderName {
            selectedAPIFolder = nil
            selectedAPIFile = apiKeyFiles.first
        }
        expandedFolders.remove("a_\(folderName)")
        save()
        showToast("Deleted folder \"\(folderName)\"", type: .info)
    }

    // MARK: - Bulk deletion & maintenance

    /// Shared confirmation dialog for destructive actions.
    private func confirmDestructive(title: String, info: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info + "\n\nThis cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal().rawValue == 1000 // .alertFirstButtonResponse
    }

    /// Deletes every account belonging to a site group (e.g. all Netflix accounts).
    public func deleteCookieSite(_ site: String) {
        let files = cookieFilesForSite(site)
        guard !files.isEmpty else { return }
        guard confirmDestructive(title: "Delete all \(site) accounts?",
                                 info: "This permanently removes \(files.count) \(site) account\(files.count == 1 ? "" : "s").",
                                 confirmTitle: "Delete") else { return }
        let ids = Set(files.map { $0.id })
        cookieFiles.removeAll { ids.contains($0.id) }
        rebuildSiteIndex()
        if selectedCookieFolder == "SITE::\(site)" {
            selectedCookieFolder = nil; selectedCookieTier = nil
            selectedCookieFile = nil; selectedCookie = nil
        }
        expandedFolders.remove("s_\(site)")
        save()
        showToast("Deleted \(files.count) \(site) accounts", type: .info)
    }

    /// Wipes ALL cookie accounts.
    public func deleteAllCookies() {
        let deletable = cookieFiles.filter { !$0.saved }
        let savedCount = cookieFiles.count - deletable.count
        guard !deletable.isEmpty else { showToast("Only saved ⭐ accounts remain", type: .info); return }
        guard confirmDestructive(title: "Delete all cookies?",
                                 info: "This removes \(deletable.count) accounts\(savedCount > 0 ? " and keeps \(savedCount) saved ⭐" : "").",
                                 confirmTitle: "Delete") else { return }
        cookieFiles.removeAll { !$0.saved }   // keep starred accounts
        rebuildSiteIndex()
        selectedCookieFile = nil; selectedCookie = nil
        selectedCookieFolder = savedCount > 0 ? "SAVED" : nil
        selectedCookieTier = nil
        expandedFolders = expandedFolders.filter { !$0.hasPrefix("c_") && !$0.hasPrefix("s_") }
        save()
        showToast(savedCount > 0 ? "Deleted \(deletable.count); kept \(savedCount) saved" : "Deleted all cookies", type: .info)
    }

    /// Wipes ALL API-key files.
    public func deleteAllAPIKeys() {
        guard !apiKeyFiles.isEmpty else { return }
        guard confirmDestructive(title: "Delete ALL API keys?",
                                 info: "This permanently removes all \(apiKeyFiles.count) API-key files.",
                                 confirmTitle: "Delete All") else { return }
        apiKeyFiles.removeAll()
        selectedAPIFile = nil; selectedAPIFolder = nil; inspectedKey = nil
        expandedFolders = expandedFolders.filter { !$0.hasPrefix("a_") }
        save()
        showToast("Deleted all API keys", type: .info)
    }

    /// QoL: drop every fully-expired cookie account.
    /// Deletes a specific set of accounts after confirmation.
    private func bulkDeleteCookies(_ files: [CookieFile], title: String, info: String, confirmTitle: String = "Delete") {
        let files = files.filter { !$0.saved }   // never delete starred accounts
        guard !files.isEmpty else { showToast("Nothing to delete (saved ⭐ kept)", type: .info); return }
        guard confirmDestructive(title: title, info: info, confirmTitle: confirmTitle) else { return }
        let ids = Set(files.map { $0.id })
        cookieFiles.removeAll { ids.contains($0.id) }
        rebuildSiteIndex()
        if let sel = selectedCookieFile, ids.contains(sel.id) { selectedCookieFile = nil; selectedCookie = nil }
        save()
        showToast("Deleted \(files.count) account\(files.count == 1 ? "" : "s")", type: .info)
    }

    private func isFullyExpired(_ f: CookieFile) -> Bool {
        !f.cookies.isEmpty && f.cookies.allSatisfy { $0.isExpired }
    }

    /// Delete all fully-expired accounts, optionally scoped to a category (site/folder/tier view).
    public func deleteExpiredCookies(in scope: [CookieFile]? = nil, scopeLabel: String = "") {
        let source = scope ?? cookieFiles
        let expired = source.filter { isFullyExpired($0) }
        let inText = scopeLabel.isEmpty ? "" : " in \(scopeLabel)"
        bulkDeleteCookies(expired,
                          title: "Delete expired accounts\(scopeLabel.isEmpty ? "" : " in \(scopeLabel)")?",
                          info: "Removes \(expired.count) account\(expired.count == 1 ? "" : "s") whose cookies are all expired\(inText).",
                          confirmTitle: "Delete")
    }

    /// Delete all Free-tier accounts, optionally scoped to a category.
    public func deleteFreeCookies(in scope: [CookieFile]? = nil, scopeLabel: String = "") {
        let source = scope ?? cookieFiles
        let free = source.filter { $0.tier == .free }
        let inText = scopeLabel.isEmpty ? "" : " in \(scopeLabel)"
        bulkDeleteCookies(free,
                          title: "Delete free accounts\(scopeLabel.isEmpty ? "" : " in \(scopeLabel)")?",
                          info: "Removes \(free.count) free-tier account\(free.count == 1 ? "" : "s")\(inText).",
                          confirmTitle: "Delete")
    }

    // Backwards-compatible alias used by the sidebar.
    public func removeExpiredCookieAccounts() { deleteExpiredCookies() }

    // MARK: - Cookie Parsing
    private func detectFormat(_ content: String) -> CookieFormat {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return .json }
        if trimmed.hasPrefix("# Netscape") || trimmed.contains("\t") || trimmed.contains("#HttpOnly_") { return .netscape }
        return .netscape
    }

    public func parseCookies(content: String, format: CookieFormat) -> [Cookie] {
        switch format {
        case .netscape: return parseNetscapeCookies(content)
        case .json: return parseJSONCookies(content)
        case .unknown: return parseNetscapeCookies(content)
        }
    }

    private func parseNetscapeCookies(_ content: String) -> [Cookie] {
        var cookies: [Cookie] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            var isHttpOnly = false
            // Handle #HttpOnly_ prefix standard Netscape cookie
            if trimmed.hasPrefix("#HttpOnly_") {
                isHttpOnly = true
                trimmed = String(trimmed.dropFirst("#HttpOnly_".count))
            } else if trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }
            let expiry = Double(parts[4]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let cookie = Cookie(
                domain: parts[0],
                flag: isHttpOnly || parts[1].uppercased() == "TRUE",
                path: parts[2],
                secure: parts[3].uppercased() == "TRUE",
                expiry: expiry,
                name: parts[5],
                value: parts[6]
            )
            cookies.append(cookie)
        }
        return cookies
    }

    private func parseJSONCookies(_ content: String) -> [Cookie] {
        guard let data = content.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj -> Cookie? in
            guard let name = obj["name"] as? String,
                  let value = obj["value"] as? String else { return nil }
            let domain = (obj["domain"] as? String) ?? ""
            let path = (obj["path"] as? String) ?? "/"
            let secure = (obj["secure"] as? Bool) ?? false
            let httpOnly = (obj["httpOnly"] as? Bool) ?? false
            let expiry: Date?
            if let exp = obj["expirationDate"] as? Double, exp > 0 {
                expiry = Date(timeIntervalSince1970: exp)
            } else {
                expiry = nil
            }
            // Normalize the exported sameSite value (e.g. "no_restriction" → "None", "lax" → "Lax").
            var sameSite: String? = nil
            if let ss = (obj["sameSite"] as? String)?.lowercased() {
                switch ss {
                case "no_restriction", "none": sameSite = "None"
                case "lax": sameSite = "Lax"
                case "strict": sameSite = "Strict"
                default: sameSite = nil
                }
            }
            return Cookie(domain: domain, flag: httpOnly, path: path, secure: secure, expiry: expiry, name: name, value: value, sameSite: sameSite)
        }
    }

    /// Picks the most representative first-party host from a cookie set, ignoring
    /// common analytics/CDN third parties so "Launch" lands on the real site.
    static func bestTargetHost(cookies: [Cookie]) -> String? {
        let thirdParty: Set<String> = [
            "google.com", "google-analytics.com", "googletagmanager.com", "doubleclick.net",
            "gstatic.com", "googleapis.com", "googlesyndication.com", "facebook.com",
            "cloudflare.com", "cloudflareinsights.com", "bing.com", "hotjar.com",
            "segment.io", "sentry.io", "recaptcha.net", "cloudfront.net", "akamaihd.net"
        ]
        func registrable(_ h: String) -> String {
            let parts = h.split(separator: ".")
            return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : h
        }
        var counts: [String: Int] = [:]
        for c in cookies {
            var d = c.domain
            if d.hasPrefix(".") { d.removeFirst() }
            d = d.lowercased()
            guard !d.isEmpty, d.contains(".") else { continue }
            if thirdParty.contains(d) || thirdParty.contains(registrable(d)) { continue }
            counts[d, default: 0] += 1
        }
        // Most frequent host wins; ties break toward the shorter (apex-nearer) host.
        return counts.max { a, b in a.value == b.value ? a.key.count > b.key.count : a.value < b.value }?.key
    }

    // MARK: - Standalone Chromium Launcher (DevTools Protocol cookie injection)
    //
    // Cookies are injected over the DevTools Protocol after launching the browser
    // with a dedicated profile and a remote-debugging port. This works on modern
    // Chrome/Chromium, unlike writing the Cookies SQLite file directly (which recent
    // versions discard because cookies must be Keychain-encrypted). If no Chromium
    // browser is installed, the user is offered an open-source Chromium download.
    /// Default landing URL for a session: the remembered last URL, else the session's main site.
    func defaultTargetURLString(for file: CookieFile) -> String {
        if let last = file.lastOpenedURL, !last.isEmpty { return last }
        let host = Self.bestTargetHost(cookies: file.cookies)
            ?? (file.cookies.first.map { $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain } ?? "")
        return host.isEmpty ? "" : "https://\(host)/"
    }

    /// Reopen a session at the exact URL it was last opened at (or its main site) — same cookies,
    /// same page. Useful when a session times out and you want to land right back where you were.
    public func reopenLastURL(cookie: Cookie, file: CookieFile) {
        openInBrowser(cookie: cookie, file: file, explicitURLString: defaultTargetURLString(for: file))
    }

    /// Prompt for a specific URL (prefilled with the remembered/main URL) and open the session there.
    @MainActor
    public func openAtCustomURL(cookie: Cookie, file: CookieFile) {
        let alert = NSAlert()
        alert.messageText = "Open “\(file.accountEmail ?? file.name)” at URL"
        alert.informativeText = "Injects this account's cookies and navigates the isolated browser to this URL."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultTargetURLString(for: file)
        field.placeholderString = "https://example.com/path"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal().rawValue == 1000 else { return }
        var urlStr = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !urlStr.isEmpty else { return }
        if !urlStr.lowercased().hasPrefix("http://") && !urlStr.lowercased().hasPrefix("https://") {
            urlStr = "https://" + urlStr
        }
        openInBrowser(cookie: cookie, file: file, explicitURLString: urlStr)
    }

    public func openInBrowser(cookie: Cookie, file: CookieFile, explicitURLString: String? = nil) {
        guard !file.cookies.isEmpty else {
            showToast("No cookies to inject for \(file.name)", type: .warning)
            return
        }
        // Use an explicit URL when provided (reopen / custom URL); otherwise pick the site the
        // session actually belongs to — the most common registrable domain across all cookies,
        // falling back to the clicked cookie's domain.
        let targetURL: URL
        if let explicit = explicitURLString, let u = URL(string: explicit) {
            targetURL = u
        } else {
            let host = Self.bestTargetHost(cookies: file.cookies)
                ?? (cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain)
            guard !host.isEmpty, let u = URL(string: "https://" + host + "/") else {
                showToast("No valid domain to open for \(file.name)", type: .error)
                return
            }
            targetURL = u
        }

        // Remember the URL so "Reopen" lands on the same page next time.
        if let fi = cookieFiles.firstIndex(where: { $0.id == file.id }) {
            cookieFiles[fi].lastOpenedURL = targetURL.absoluteString
            save()
        }

        let label = file.accountEmail ?? file.name
        let profileKey = "\(file.serviceName ?? "session")_\(label)"
        let cookies = file.cookies
        let launcher = ChromiumLauncher.shared

        Task { @MainActor in
            // Ensure a browser is available; offer to download one if not.
            if launcher.anyBinary() == nil {
                guard promptDownloadChromium() else {
                    showToast("Launch cancelled — no Chromium available", type: .warning)
                    return
                }
                isLaunching = true
                do {
                    _ = try await launcher.downloadChromium { frac, msg in
                        Task { @MainActor in
                            self.launchStatus = msg
                            self.launchProgress = frac
                        }
                    }
                } catch {
                    isLaunching = false
                    launchStatus = ""
                    showToast("Chromium download failed: \(error.localizedDescription)", type: .error)
                    return
                }
            }

            isLaunching = true
            launchProgress = 0
            launchStatus = "Launching \(label)…"
            do {
                try await launcher.launch(cookies: cookies, targetURL: targetURL, profileKey: profileKey) { msg in
                    Task { @MainActor in self.launchStatus = msg }
                }
                showToast("Launched \(label) in Chromium (\(cookies.count) cookies)", type: .success)
            } catch {
                showToast("Launch failed: \(error.localizedDescription)", type: .error)
            }
            isLaunching = false
            launchStatus = ""
            launchProgress = 0
        }
    }

    @MainActor
    private func promptDownloadChromium() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download Chromium?"
        alert.informativeText = """
        No Chromium-based browser was found on this Mac. CookieVault can download an \
        open-source Chromium build (~170 MB) from Google's official Chromium snapshot \
        storage and use it to open sessions in an isolated window.
        """
        alert.addButton(withTitle: "Download Chromium")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal().rawValue == 1000 // .alertFirstButtonResponse
    }

    // MARK: - API Key Checking (Single & Concurrent Batch)

    struct CheckTarget { let id: UUID; let value: String; let service: String; let endpoint: String? }

    /// Streaming bounded-concurrency runner: keeps `maxConcurrent` checks in flight at all times
    /// (no per-chunk barrier, so one slow/dead key never stalls the rest). `onEach` runs on the
    /// main actor as each result lands.
    @MainActor
    private func streamCheck(_ targets: [CheckTarget], maxConcurrent: Int = 64,
                             onEach: @escaping (UUID, APIKeyChecker.CheckResult, _ done: Int, _ total: Int) -> Void) async {
        let total = targets.count
        guard total > 0 else { return }
        await withTaskGroup(of: (UUID, APIKeyChecker.CheckResult).self) { group in
            var next = 0                                  // index of the next target to launch
            func launch() {
                guard next < targets.count else { return }
                let t = targets[next]; next += 1
                let id = t.id, value = t.value, service = t.service, endpoint = t.endpoint
                group.addTask { (id, await APIKeyChecker.check(key: value, service: service, endpoint: endpoint)) }
            }
            for _ in 0..<min(maxConcurrent, total) { launch() }
            var done = 0
            while let (id, res) = await group.next() {
                done += 1
                onEach(id, res, done, total)
                launch()                                  // keep the window full
            }
        }
    }

    @MainActor
    public func checkKey(_ key: APIKey, in file: APIKeyFile) async {
        guard let idx = apiKeyFiles.firstIndex(where: { $0.id == file.id }),
              let keyIdx = apiKeyFiles[idx].keys.firstIndex(where: { $0.id == key.id }) else { return }

        apiKeyFiles[idx].keys[keyIdx].status = .checking
        apiKeyFiles[idx].keys[keyIdx].checkedAt = Date()

        let result = await APIKeyChecker.check(key: key.value, service: file.service, endpoint: file.checkEndpoint)

        if let updatedIdx = apiKeyFiles.firstIndex(where: { $0.id == file.id }),
           let updatedKeyIdx = apiKeyFiles[updatedIdx].keys.firstIndex(where: { $0.id == key.id }) {
            apiKeyFiles[updatedIdx].keys[updatedKeyIdx].status = result.status
            apiKeyFiles[updatedIdx].keys[updatedKeyIdx].responseSnippet = result.snippet
            apiKeyFiles[updatedIdx].keys[updatedKeyIdx].details = result.details
            apiKeyFiles[updatedIdx].keys[updatedKeyIdx].checkedAt = Date()
        }
        save()
    }

    // Concurrent check across an entire file
    @MainActor
    public func checkAllKeys(in file: APIKeyFile, limit: Int = Int.max) async {
        guard let fIdx = apiKeyFiles.firstIndex(where: { $0.id == file.id }) else { return }
        let fileId = file.id
        let targets = apiKeyFiles[fIdx].keys.prefix(limit).map {
            CheckTarget(id: $0.id, value: $0.value, service: file.service, endpoint: file.checkEndpoint)
        }
        guard !targets.isEmpty else { return }

        isBatchChecking = true
        batchCheckProgress = 0.0
        batchCheckCurrentTask = "Checking \(file.displayName)..."

        let locations = makeKeyLocationMap()
        await streamCheck(Array(targets)) { [weak self] id, res, done, total in
            self?.applyResult(id, res, locations)
            self?.batchCheckProgress = Double(done) / Double(total)
        }

        isBatchChecking = false
        batchCheckProgress = 1.0
        save()

        let validCount = apiKeyFiles.first(where: { $0.id == fileId })?.keys.filter { $0.status == .valid }.count ?? 0
        showToast("Checked \(targets.count) keys in \(file.displayName) (\(validCount) valid)", type: .success)
    }

    // Concurrent check across ALL files in a Folder
    @MainActor
    public func checkAllKeysInFolder(_ folderName: String) async {
        let files = apiKeyFilesInFolder(folderName)
        guard !files.isEmpty else { return }

        isBatchChecking = true
        batchCheckProgress = 0.0
        batchCheckCurrentTask = "Checking folder \"\(folderName)\"…"

        // Flatten every key across the folder's files into one stream — a slow provider
        // no longer blocks the others, and all hosts saturate in parallel.
        let targets: [CheckTarget] = files.flatMap { f in
            f.keys.map { CheckTarget(id: $0.id, value: $0.value, service: f.service, endpoint: f.checkEndpoint) }
        }
        let locations = makeKeyLocationMap()
        await streamCheck(targets) { [weak self] id, res, done, total in
            self?.applyResult(id, res, locations)
            self?.batchCheckProgress = Double(done) / Double(total)
        }

        isBatchChecking = false
        batchCheckProgress = 1.0
        save()
        let valid = files.compactMap { f in apiKeyFiles.first(where: { $0.id == f.id }) }
            .reduce(0) { $0 + $1.keys.filter { $0.status == .valid }.count }
        showToast("Folder \"\(folderName)\" checked (\(targets.count) keys · \(valid) valid)", type: .success)
    }

    /// keyId → (owning fileId, key index). Key order within a file never changes during a
    /// check, so the index stays valid; we still verify the id at that slot before writing.
    @MainActor
    private func makeKeyLocationMap() -> [UUID: (UUID, Int)] {
        var map: [UUID: (UUID, Int)] = [:]
        for f in apiKeyFiles {
            for (ki, k) in f.keys.enumerated() { map[k.id] = (f.id, ki) }
        }
        return map
    }

    /// Apply a check result in O(1)-ish time using the prebuilt location map.
    @MainActor
    private func applyResult(_ id: UUID, _ res: APIKeyChecker.CheckResult, _ map: [UUID: (UUID, Int)]) {
        guard let (fileId, ki) = map[id],
              let fi = apiKeyFiles.firstIndex(where: { $0.id == fileId }),
              ki < apiKeyFiles[fi].keys.count,
              apiKeyFiles[fi].keys[ki].id == id else { return }
        apiKeyFiles[fi].keys[ki].status = res.status
        apiKeyFiles[fi].keys[ki].responseSnippet = res.snippet
        apiKeyFiles[fi].keys[ki].details = res.details
        apiKeyFiles[fi].keys[ki].checkedAt = Date()
    }

    // Concurrent check across EVERY API-key file (all flattened into one stream).
    @MainActor
    public func checkAllAPIKeys(limitPerFile: Int = Int.max) async {
        guard !apiKeyFiles.isEmpty else { return }
        isBatchChecking = true
        batchCheckProgress = 0.0
        batchCheckCurrentTask = "Checking all keys…"

        let targets: [CheckTarget] = apiKeyFiles.flatMap { f in
            f.keys.prefix(limitPerFile).map { CheckTarget(id: $0.id, value: $0.value, service: f.service, endpoint: f.checkEndpoint) }
        }
        let locations = makeKeyLocationMap()
        await streamCheck(targets, maxConcurrent: 128) { [weak self] id, res, done, total in
            self?.applyResult(id, res, locations)
            self?.batchCheckProgress = Double(done) / Double(total)
        }

        isBatchChecking = false
        batchCheckProgress = 1.0
        save()
        let valid = apiKeyFiles.reduce(0) { $0 + $1.keys.filter { $0.status == .valid }.count }
        showToast("Checked \(targets.count) keys across \(apiKeyFiles.count) files (\(valid) valid)", type: .success)
    }

    /// Export every valid key across all files to one .txt.
    public func exportAllValidKeys() {
        var lines: [String] = []
        for f in apiKeyFiles {
            let valid = f.keys.filter { $0.status == .valid }
            if !valid.isEmpty {
                lines.append("# --- \(f.displayName) (\(valid.count) valid) ---")
                lines.append(contentsOf: valid.map { $0.value })
                lines.append("")
            }
        }
        guard !lines.isEmpty else { showToast("No valid keys to export", type: .warning); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "all_valid_keys.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            showToast("Exported all valid keys", type: .success)
        }
    }

    // MARK: - Export Valid Keys in Folder
    public func exportValidKeysInFolder(_ folderName: String) {
        let files = apiKeyFilesInFolder(folderName)
        var lines: [String] = []
        for f in files {
            let valid = f.keys.filter { $0.status == .valid }
            if !valid.isEmpty {
                lines.append("# --- \(f.displayName) (\(valid.count) valid keys) ---")
                lines.append(contentsOf: valid.map { $0.value })
                lines.append("")
            }
        }
        guard !lines.isEmpty else {
            showToast("No valid keys found in \"\(folderName)\" to export", type: .warning)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(folderName)_valid_keys.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            let content = lines.joined(separator: "\n")
            try? content.write(to: url, atomically: true, encoding: .utf8)
            showToast("Exported valid keys from \"\(folderName)\"", type: .success)
        }
    }

    // MARK: - Service Metadata
    public struct ServiceInfo {
        public var displayName: String
        public var icon: String
        public var endpoint: String?
    }

    public func serviceInfo(for service: String) -> ServiceInfo {
        let s = service.lowercased()
            .replacingOccurrences(of: ".txt", with: "")
            .replacingOccurrences(of: ".json", with: "")

        let map: [String: ServiceInfo] = [
            // AI & LLM
            "openai":               .init(displayName: "OpenAI",              icon: "brain", endpoint: nil),
            "openai_org":           .init(displayName: "OpenAI Org",          icon: "building.2.fill", endpoint: nil),
            "sk_all":               .init(displayName: "OpenAI (All Keys)",   icon: "brain.head.profile", endpoint: nil),
            "anthropic":            .init(displayName: "Anthropic",           icon: "sparkles", endpoint: nil),
            "google_ai":            .init(displayName: "Google AI / Gemini",  icon: "sparkle", endpoint: nil),
            "groq":                 .init(displayName: "Groq",                icon: "bolt.fill", endpoint: nil),
            "openrouter":           .init(displayName: "OpenRouter",          icon: "arrow.triangle.branch", endpoint: nil),
            "deepseek":             .init(displayName: "DeepSeek",            icon: "scope", endpoint: nil),
            "huggingface":          .init(displayName: "HuggingFace",         icon: "face.smiling.fill", endpoint: nil),
            "cohere":               .init(displayName: "Cohere",              icon: "c.circle.fill", endpoint: nil),
            "replicate":            .init(displayName: "Replicate",           icon: "arrow.2.circlepath", endpoint: nil),
            "mistral":              .init(displayName: "Mistral AI",          icon: "wind", endpoint: nil),
            "together":             .init(displayName: "Together AI",         icon: "person.3.fill", endpoint: nil),
            "fireworks":            .init(displayName: "Fireworks AI",        icon: "flame.circle.fill", endpoint: nil),
            "cerebras":             .init(displayName: "Cerebras",            icon: "cpu", endpoint: nil),
            "xai":                  .init(displayName: "xAI (Grok)",          icon: "atom", endpoint: nil),
            "perplexity":           .init(displayName: "Perplexity",          icon: "magnifyingglass.circle.fill", endpoint: nil),
            "you_com":              .init(displayName: "You.com",             icon: "magnifyingglass", endpoint: nil),
            "tavily":               .init(displayName: "Tavily AI",           icon: "location.fill", endpoint: nil),
            "fal":                  .init(displayName: "Fal.ai",              icon: "wand.and.stars", endpoint: nil),
            "anyscale":             .init(displayName: "Anyscale",            icon: "chart.bar.fill", endpoint: nil),
            "aimlapi":              .init(displayName: "AI ML API",           icon: "cpu.fill", endpoint: nil),
            "runpod":               .init(displayName: "RunPod",              icon: "server.rack", endpoint: nil),
            "voyage":               .init(displayName: "Voyage AI",           icon: "paperplane.circle.fill", endpoint: nil),
            "exa":                  .init(displayName: "Exa AI",              icon: "magnifyingglass.sparkles", endpoint: nil),
            "langsmith":            .init(displayName: "LangSmith",           icon: "wrench.and.screwdriver.fill", endpoint: nil),

            // Cloud Infrastructure
            "aws_access_key":       .init(displayName: "AWS IAM Key",         icon: "cloud.fill", endpoint: nil),
            "alibaba_cloud":        .init(displayName: "Alibaba Cloud",       icon: "cloud.sun.fill", endpoint: nil),
            "tencent_cloud":        .init(displayName: "Tencent Cloud",       icon: "cloud.bold.fill", endpoint: nil),
            "flyio":                .init(displayName: "Fly.io",              icon: "airplane", endpoint: nil),
            "scaleway":             .init(displayName: "Scaleway",            icon: "server.rack", endpoint: nil),
            "render":               .init(displayName: "Render",              icon: "square.stack.3d.up.fill", endpoint: nil),
            "hyperbrowser":         .init(displayName: "Hyperbrowser",        icon: "globe", endpoint: nil),
            "browserbase":          .init(displayName: "Browserbase",         icon: "macwindow", endpoint: nil),

            // Dev Platforms & Repos
            "github":               .init(displayName: "GitHub",              icon: "chevron.left.forwardslash.chevron.right", endpoint: nil),
            "gitlab":               .init(displayName: "GitLab",              icon: "app.connected.to.app.below.fill", endpoint: nil),
            "bitbucket":            .init(displayName: "Bitbucket",           icon: "tray.2.fill", endpoint: nil),
            "atlassian":            .init(displayName: "Atlassian",           icon: "checklist", endpoint: nil),
            "docker":               .init(displayName: "Docker Hub",          icon: "shippingbox.fill", endpoint: nil),
            "cargo_crates":         .init(displayName: "Cargo Crates.io",     icon: "cube.fill", endpoint: nil),
            "vercel":               .init(displayName: "Vercel",              icon: "triangle.fill", endpoint: nil),
            "netlify":              .init(displayName: "Netlify",             icon: "diamond.fill", endpoint: nil),
            "sonarqube":            .init(displayName: "SonarQube",           icon: "checkmark.shield.fill", endpoint: nil),
            "grafana":              .init(displayName: "Grafana",             icon: "chart.xyaxis.line", endpoint: nil),
            "hashicorp_vault":      .init(displayName: "HashiCorp Vault",     icon: "lock.shield.fill", endpoint: nil),
            "infisical":            .init(displayName: "Infisical",           icon: "key.viewfinder", endpoint: nil),
            "onepassword":          .init(displayName: "1Password",           icon: "lock.fill", endpoint: nil),
            "pipedream":            .init(displayName: "Pipedream",           icon: "flowchart.fill", endpoint: nil),

            // Messaging, Emails, Bots & Webhooks
            "telegram_bot":         .init(displayName: "Telegram Bot",        icon: "paperplane.fill", endpoint: nil),
            "1635646211_@pkbtv_@sackion_@sakione_bot": .init(displayName: "Telegram Bot (@sakione)", icon: "paperplane.fill", endpoint: nil),
            "discord_bot":          .init(displayName: "Discord Bot",         icon: "gamecontroller.fill", endpoint: nil),
            "discord_webhook":      .init(displayName: "Discord Webhook",     icon: "link.circle.fill", endpoint: nil),
            "slack":                .init(displayName: "Slack Token",         icon: "message.fill", endpoint: nil),
            "slack_webhook":        .init(displayName: "Slack Webhook",       icon: "link", endpoint: nil),
            "teams_webhook":        .init(displayName: "MS Teams Webhook",     icon: "person.2.wave.2.fill", endpoint: nil),
            "twilio":               .init(displayName: "Twilio",              icon: "phone.fill", endpoint: nil),
            "sendgrid":             .init(displayName: "SendGrid",            icon: "envelope.fill", endpoint: nil),
            "mailchimp":            .init(displayName: "Mailchimp",           icon: "envelope.badge.fill", endpoint: nil),
            "mailgun":              .init(displayName: "Mailgun",             icon: "envelope.open.fill", endpoint: nil),
            "postmark":             .init(displayName: "Postmark",            icon: "envelope.arrow.triangle.branch.fill", endpoint: nil),
            "brevo":                .init(displayName: "Brevo",               icon: "paperplane.circle", endpoint: nil),
            "resend":               .init(displayName: "Resend",              icon: "envelope.badge.shield.half.filled", endpoint: nil),
            "klaviyo":              .init(displayName: "Klaviyo",             icon: "tray.full.fill", endpoint: nil),
            "intercom":             .init(displayName: "Intercom",            icon: "bubble.left.and.bubble.right.fill", endpoint: nil),

            // Databases, URIs & Vector
            "pinecone":             .init(displayName: "Pinecone Vector DB",  icon: "tree.fill", endpoint: nil),
            "mongodb_uri":          .init(displayName: "MongoDB Connection",  icon: "leaf.fill", endpoint: nil),
            "postgres_uri":         .init(displayName: "PostgreSQL Connection", icon: "cylinder.split.1x2.fill", endpoint: nil),
            "mysql_uri":            .init(displayName: "MySQL Connection",    icon: "cylinder.fill", endpoint: nil),
            "redis_uri":            .init(displayName: "Redis Connection",    icon: "bolt.horizontal.fill", endpoint: nil),
            "amqp_uri":             .init(displayName: "AMQP RabbitMQ",       icon: "arrow.triangle.pull", endpoint: nil),
            "elasticsearch_uri":   .init(displayName: "Elasticsearch",       icon: "magnifyingglass.square.fill", endpoint: nil),
            "neon":                 .init(displayName: "Neon Postgres",       icon: "bolt.square.fill", endpoint: nil),
            "supabase":             .init(displayName: "Supabase",            icon: "bolt.ring.closed", endpoint: nil),
            "airtable":             .init(displayName: "Airtable",            icon: "tablecells.fill", endpoint: nil),
            "notion":               .init(displayName: "Notion",              icon: "doc.text.fill", endpoint: nil),

            // Payments & E-Comm
            "stripe":               .init(displayName: "Stripe",              icon: "creditcard.fill", endpoint: nil),
            "razorpay":             .init(displayName: "Razorpay",            icon: "indianrupeesign.circle.fill", endpoint: nil),
            "shopify":              .init(displayName: "Shopify",             icon: "bag.fill", endpoint: nil),
            "square":               .init(displayName: "Square",              icon: "square.fill", endpoint: nil),
            "checkout":             .init(displayName: "Checkout.com",        icon: "creditcard.circle.fill", endpoint: nil),
            "flutterwave":          .init(displayName: "Flutterwave",         icon: "wave.3.forward.circle.fill", endpoint: nil),

            // Media, Speech, Maps
            "elevenlabs":           .init(displayName: "ElevenLabs",          icon: "waveform", endpoint: nil),
            "deepl":                .init(displayName: "DeepL Translation",   icon: "globe", endpoint: nil),
            "mapbox":               .init(displayName: "Mapbox",              icon: "map.fill", endpoint: nil),
            "mux":                  .init(displayName: "Mux Video",           icon: "play.tv.fill", endpoint: nil),
            "sentry":               .init(displayName: "Sentry API",          icon: "shield.trianglebadge.exclamationmark.fill", endpoint: nil),
            "sentry_dsn":           .init(displayName: "Sentry DSN",          icon: "exclamationmark.shield.fill", endpoint: nil),
            "launchdarkly":         .init(displayName: "LaunchDarkly",        icon: "flag.fill", endpoint: nil),
            "pagerduty":            .init(displayName: "PagerDuty",           icon: "bell.badge.fill", endpoint: nil),
            "livekit":              .init(displayName: "LiveKit",             icon: "video.fill", endpoint: nil),
            "figma":                .init(displayName: "Figma",               icon: "paintpalette.fill", endpoint: nil),

            // Tools, Productivity, Social
            "clickup":              .init(displayName: "ClickUp",             icon: "checkmark.circle.fill", endpoint: nil),
            "trello":               .init(displayName: "Trello",              icon: "rectangle.grid.1x2.fill", endpoint: nil),
            "typeform":             .init(displayName: "Typeform",            icon: "list.bullet.rectangle.fill", endpoint: nil),
            "dropbox":              .init(displayName: "Dropbox",             icon: "archivebox.fill", endpoint: nil),
            "facebook":             .init(displayName: "Facebook Graph",      icon: "person.2.fill", endpoint: nil),
            "firebase_fcm":         .init(displayName: "Firebase FCM",        icon: "flame.fill", endpoint: nil),
            "apify":                .init(displayName: "Apify",               icon: "gearshape.2.fill", endpoint: nil),
            "capsolver":            .init(displayName: "CapSolver",           icon: "shield.lefthalf.filled", endpoint: nil),
            "riot":                 .init(displayName: "Riot Games",          icon: "gamecontroller", endpoint: nil),
            "spotify":              .init(displayName: "Spotify API",         icon: "music.note.list", endpoint: nil),

            // Observability / misc (were falling back to a generic icon)
            "datadog":              .init(displayName: "Datadog",             icon: "pawprint.fill", endpoint: nil),
            "digitalocean":         .init(displayName: "DigitalOcean",        icon: "drop.fill", endpoint: nil),
            "heroku":               .init(displayName: "Heroku",              icon: "square.stack.3d.up.fill", endpoint: nil),
            "newrelic":             .init(displayName: "New Relic",           icon: "chart.line.uptrend.xyaxis", endpoint: nil),
            "npm":                  .init(displayName: "npm",                 icon: "shippingbox.fill", endpoint: nil),
            "firecrawl":            .init(displayName: "Firecrawl",           icon: "flame", endpoint: nil),
            "jina":                 .init(displayName: "Jina AI",             icon: "j.circle.fill", endpoint: nil),
            "openai_asst":          .init(displayName: "OpenAI Assistants",   icon: "brain.head.profile", endpoint: nil),
            "all_discord_tokens":   .init(displayName: "Discord Tokens",      icon: "gamecontroller.fill", endpoint: nil),
            "valid_discord_tokens": .init(displayName: "Discord Tokens (Valid)", icon: "gamecontroller.fill", endpoint: nil),
            "discord_user":         .init(displayName: "Discord User Token",  icon: "person.crop.circle.fill", endpoint: nil),

            // New batch
            "cloudflare":           .init(displayName: "Cloudflare",          icon: "cloud.bolt.fill", endpoint: nil),
            "databricks":           .init(displayName: "Databricks",          icon: "square.grid.3x3.fill", endpoint: nil),
            "azure_storage":        .init(displayName: "Azure Storage",       icon: "externaldrive.fill.badge.icloud", endpoint: nil),
            "brightdata":           .init(displayName: "Bright Data",         icon: "network", endpoint: nil),
            "mongodb_atlas":        .init(displayName: "MongoDB Atlas",       icon: "leaf.circle.fill", endpoint: nil),
            "nuget":                .init(displayName: "NuGet",               icon: "cube.box.fill", endpoint: nil),
            "pubnub":               .init(displayName: "PubNub",              icon: "dot.radiowaves.left.and.right", endpoint: nil),
            "pypi":                 .init(displayName: "PyPI",                icon: "cube.transparent.fill", endpoint: nil)
        ]

        return map[s] ?? .init(displayName: s.replacingOccurrences(of: "_", with: " ").capitalized, icon: "key.fill", endpoint: nil)
    }
}

// MARK: - Persistence Wrapper
private struct AppData: Codable {
    var cookieFiles: [CookieFile]
    var apiKeyFiles: [APIKeyFile]
}

// MARK: - Array Chunk Helper
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
