import Foundation
import AppKit

// MARK: - API Key Checker Engine

public enum APIKeyChecker {

    // Tuned session: many parallel connections per host + shorter timeout, so bulk
    // checks of the same provider don't serialize on URLSession's default 6-per-host cap.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 24
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - Proxy pool (rotate requests across proxies to dodge rate limits)
    private static let poolLock = NSLock()
    private static var proxySessions: [ProxySession] = []   // empty ⇒ use the direct `session`
    private static var rrCounter: Int = 0

    /// Replace the proxy pool. `includeDirect` also rotates in the app's own IP.
    static func configureProxies(_ configs: [ProxyConfig], includeDirect: Bool) {
        poolLock.lock(); defer { poolLock.unlock() }
        var pool: [ProxySession] = configs.map { ProxySession(direct: false, config: $0) }
        if includeDirect || pool.isEmpty { pool.insert(ProxySession(direct: true, config: nil), at: 0) }
        proxySessions = configs.isEmpty ? [] : pool
        rrCounter = 0
    }

    static var activeProxyCount: Int {
        poolLock.lock(); defer { poolLock.unlock() }
        return proxySessions.filter { $0.label != "direct" }.count
    }

    /// Next session in round-robin. Falls back to the shared direct session when no proxies.
    private static func nextSession() -> URLSession {
        poolLock.lock(); defer { poolLock.unlock() }
        guard !proxySessions.isEmpty else { return session }
        let s = proxySessions[rrCounter % proxySessions.count]
        rrCounter &+= 1
        return s.session
    }

    // MARK: - Per-host throttle + retry
    // Caps how many requests hit one host at once (so bulk checks of one provider don't
    // trip its rate limiter and mislabel valid keys), while still allowing high total
    // concurrency across different hosts.
    actor HostLimiter {
        private var active: [String: Int] = [:]
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        let maxPerHost: Int
        init(maxPerHost: Int) { self.maxPerHost = maxPerHost }
        func acquire(_ host: String) async {
            if (active[host] ?? 0) < maxPerHost { active[host, default: 0] += 1; return }
            await withCheckedContinuation { c in waiters[host, default: []].append(c) }
        }
        func release(_ host: String) {
            if var q = waiters[host], !q.isEmpty {
                let c = q.removeFirst(); waiters[host] = q; c.resume()   // hand the slot straight to a waiter
            } else if let n = active[host] {
                active[host] = max(0, n - 1)
            }
        }
    }
    static let hostLimiter = HostLimiter(maxPerHost: 24)

    /// All checkers route their primary request through this: per-host throttling plus an
    /// automatic retry on 429 / rate-limit / transient network errors, so a valid key that
    /// momentarily gets throttled isn't wrongly reported as limited or errored.
    static func send(_ req: URLRequest, retries: Int = 2) async throws -> (Data, URLResponse) {
        let host = req.url?.host ?? ""
        await hostLimiter.acquire(host)
        defer { Task { await hostLimiter.release(host) } }
        var attempt = 0
        while true {
            do {
                // Rotate across the proxy pool (or direct when none configured).
                let (data, resp) = try await nextSession().data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 && attempt < retries {
                    attempt += 1
                    var wait: UInt64 = UInt64(0.6 * Double(attempt) * 1_000_000_000)
                    if let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
                       let secs = Double(ra), secs > 0, secs <= 5 { wait = UInt64(secs * 1_000_000_000) }
                    try? await Task.sleep(nanoseconds: wait)
                    continue
                }
                return (data, resp)
            } catch {
                let ns = error as NSError
                let transient = ns.domain == NSURLErrorDomain &&
                    [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                     NSURLErrorNotConnectedToInternet].contains(ns.code)
                if transient && attempt < retries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(attempt) * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    // MARK: - Check Result Structure
    public struct CheckResult {
        public var status: CheckStatus
        public var snippet: String?
        public var details: KeyDetails?

        public init(status: CheckStatus, snippet: String? = nil, details: KeyDetails? = nil) {
            self.status = status
            self.snippet = snippet
            self.details = details
        }
    }

    // MARK: - Per-type provider descriptor
    // Powers the "detailed view for every api key type": a category, a one-line blurb,
    // and the concrete facts a valid check surfaces for that provider family.
    public struct ProviderInfo {
        public var category: String     // e.g. "AI / LLM", "Payments", "Messaging"
        public var blurb: String        // what this key unlocks
        public var reveals: [String]    // facts the checker extracts on a valid key
    }

    public static func providerInfo(service: String) -> ProviderInfo {
        let s = service.lowercased()
        func mk(_ c: String, _ b: String, _ r: [String]) -> ProviderInfo { ProviderInfo(category: c, blurb: b, reveals: r) }

        switch s {
        case "openai", "sk_all", "openai_org", "openai_asst":
            return mk("AI / LLM", "OpenAI platform key — chat, embeddings, images, assistants.", ["Accessible models", "GPT-4 / reasoning access", "Quota / billing state", "Latency"])
        case "anthropic":
            return mk("AI / LLM", "Anthropic Claude API key.", ["Accessible Claude models", "API access tier", "Latency"])
        case "google_ai":
            return mk("AI / LLM", "Google Gemini / Generative AI key.", ["Gemini models", "HTTP status", "Latency"])
        case "openrouter":
            return mk("AI / LLM", "OpenRouter aggregator key — routes to many models.", ["Credit balance", "Rate limit", "Free vs paid tier"])
        case "groq": return mk("AI / LLM", "Groq LPU inference key.", ["Accessible models", "Latency"])
        case "deepseek": return mk("AI / LLM", "DeepSeek inference key.", ["Balance", "Models"])
        case "mistral": return mk("AI / LLM", "Mistral AI key.", ["Models", "Subscription"])
        case "huggingface": return mk("AI / LLM", "Hugging Face access token.", ["Username", "Token role / scopes", "Orgs"])
        case "cohere", "together", "fireworks", "cerebras", "xai", "perplexity", "replicate", "voyage", "anyscale", "aimlapi", "fal", "runpod", "hyperbrowser", "browserbase":
            return mk("AI / LLM", "AI inference / tooling key.", ["Account", "Models / quota", "Latency"])
        case "elevenlabs": return mk("AI / Voice", "ElevenLabs TTS key.", ["Subscription tier", "Character quota", "Voices"])
        case "deepl": return mk("AI / Translate", "DeepL translation key.", ["Plan (Free/Pro)", "Character usage"])
        case "stripe": return mk("Payments", "Stripe secret/restricted key — LIVE money movement.", ["Business name", "Country / currency", "Charges & payouts enabled", "Email"])
        case "razorpay", "square", "checkout", "flutterwave": return mk("Payments", "Payment-processor key.", ["Account", "Currency", "Mode (live/test)"])
        case "shopify": return mk("Commerce", "Shopify admin/API token.", ["Shop", "Scopes", "Plan"])
        case "github": return mk("Dev / Source", "GitHub personal-access token.", ["Login & name", "Plan", "Private repos", "Followers", "2FA", "Scopes"])
        case "gitlab", "bitbucket": return mk("Dev / Source", "Git host token.", ["User", "Scopes"])
        case "vercel", "netlify", "render", "flyio", "heroku", "digitalocean", "scaleway": return mk("Cloud / Hosting", "Hosting/cloud API token.", ["Account", "Teams / projects", "Plan"])
        case "aws_access_key", "alibaba_cloud", "tencent_cloud": return mk("Cloud", "Cloud provider access key.", ["Identity", "Region", "Permissions"])
        case "datadog", "newrelic", "grafana", "sentry", "sentry_dsn", "sonarqube", "pagerduty", "launchdarkly": return mk("Observability", "Monitoring / observability key.", ["Org", "Scopes", "Status"])
        case "telegram_bot", "1635646211_@pkbtv_@sackion_@sakione_bot": return mk("Messaging / Bots", "Telegram bot token.", ["Bot name & @username", "Bot ID", "Capabilities"])
        case "discord_bot": return mk("Messaging / Bots", "Discord bot token.", ["Bot user & tag", "Guild count", "Flags"])
        case "discord_user", "all_discord_tokens", "valid_discord_tokens": return mk("Messaging / Accounts", "Discord USER token — full account access.", ["Username & tag", "Email", "Phone", "Nitro", "MFA", "Verified"])
        case "discord_webhook", "slack_webhook", "teams_webhook": return mk("Messaging / Webhooks", "Incoming webhook URL.", ["Channel / target", "Reachable"])
        case "slack": return mk("Messaging", "Slack token.", ["Team", "User", "Scopes"])
        case "twilio": return mk("Comms", "Twilio account credential.", ["Account name", "Status", "Balance", "Type (trial/full)"])
        case "sendgrid": return mk("Email", "SendGrid API key.", ["Scopes", "Reputation", "Send access"])
        case "mailchimp", "mailgun", "postmark", "brevo", "resend", "klaviyo": return mk("Email", "Transactional/marketing email key.", ["Account", "Domain / sending status", "Plan"])
        case "intercom": return mk("Support / CRM", "Intercom access token.", ["App / workspace", "Admin", "Scopes"])
        case "notion": return mk("Productivity", "Notion integration token.", ["Bot / workspace", "Capabilities"])
        case "airtable": return mk("Productivity", "Airtable token.", ["User", "Bases / scopes"])
        case "figma": return mk("Design", "Figma personal token.", ["User", "Email"])
        case "clickup", "trello", "typeform", "dropbox": return mk("Productivity", "SaaS API token.", ["Account", "Scopes"])
        case "mongodb_uri", "postgres_uri", "mysql_uri", "redis_uri", "amqp_uri", "elasticsearch_uri": return mk("Database", "Database connection string — direct data access.", ["Host reachable", "Auth accepted", "Engine"])
        case "neon", "supabase", "pinecone", "airtable_meta": return mk("Database / Backend", "Managed DB / vector store key.", ["Project", "Region", "Plan"])
        case "mapbox": return mk("Maps / Geo", "Mapbox token.", ["Account", "Scopes"])
        case "spotify": return mk("Media", "Spotify API credential.", ["Token type", "Scopes"])
        case "cloudflare": return mk("Cloud / CDN", "Cloudflare API token — DNS, Workers, zones.", ["Token status", "Token ID", "Latency"])
        case "databricks": return mk("Data / ML", "Databricks personal access token.", ["Token type", "Workspace (needs host)"])
        case "azure_storage": return mk("Cloud / Storage", "Azure Storage connection string or account key.", ["Account name", "Endpoint suffix"])
        case "brightdata": return mk("Proxy / Scraping", "Bright Data API token.", ["Token format"])
        case "mongodb_atlas": return mk("Database", "MongoDB Atlas Admin API key pair.", ["Public key", "public:private pair"])
        case "nuget": return mk("Package Registry", "NuGet push API key.", ["Token format"])
        case "pubnub": return mk("Realtime / Messaging", "PubNub pub/sub/secret key.", ["Key role (pub/sub/secret)"])
        case "pypi": return mk("Package Registry", "PyPI upload token.", ["Token format"])
        case "twilio_verify": return mk("Comms", "Twilio verify key.", ["Account", "Status"])
        default:
            return mk("API Key", "Third-party API credential.", ["Validity", "HTTP status", "Latency", "Any returned account detail"])
        }
    }

    // MARK: - Account interaction (act on the account the key belongs to)

    /// The provider's web dashboard/console — where the key's account is managed.
    public static func dashboardURL(service: String) -> String? {
        let s = service.lowercased()
        let map: [String: String] = [
            "openai": "https://platform.openai.com/account", "openai_asst": "https://platform.openai.com/assistants",
            "anthropic": "https://console.anthropic.com/settings/keys", "google_ai": "https://aistudio.google.com/app/apikey",
            "openrouter": "https://openrouter.ai/keys", "groq": "https://console.groq.com/keys",
            "deepseek": "https://platform.deepseek.com", "mistral": "https://console.mistral.ai",
            "huggingface": "https://huggingface.co/settings/tokens", "cohere": "https://dashboard.cohere.com/api-keys",
            "replicate": "https://replicate.com/account/api-tokens", "perplexity": "https://www.perplexity.ai/settings/api",
            "xai": "https://console.x.ai", "together": "https://api.together.ai/settings/api-keys",
            "elevenlabs": "https://elevenlabs.io/app/settings/api-keys", "deepl": "https://www.deepl.com/account/summary",
            "stripe": "https://dashboard.stripe.com/apikeys", "razorpay": "https://dashboard.razorpay.com",
            "shopify": "https://admin.shopify.com", "square": "https://developer.squareup.com/apps",
            "github": "https://github.com/settings/tokens", "gitlab": "https://gitlab.com/-/profile/personal_access_tokens",
            "vercel": "https://vercel.com/account/tokens", "netlify": "https://app.netlify.com/user/applications",
            "render": "https://dashboard.render.com", "heroku": "https://dashboard.heroku.com/account/applications",
            "digitalocean": "https://cloud.digitalocean.com/account/api/tokens", "flyio": "https://fly.io/dashboard",
            "datadog": "https://app.datadoghq.com/organization-settings/api-keys", "newrelic": "https://one.newrelic.com/api-keys",
            "sentry": "https://sentry.io/settings/account/api/auth-tokens/", "grafana": "https://grafana.com/profile/api-keys",
            "telegram_bot": "https://t.me/BotFather", "discord_bot": "https://discord.com/developers/applications",
            "slack": "https://api.slack.com/apps", "twilio": "https://console.twilio.com",
            "sendgrid": "https://app.sendgrid.com/settings/api_keys", "mailchimp": "https://admin.mailchimp.com/account/api/",
            "mailgun": "https://app.mailgun.com/settings/api_security", "brevo": "https://app.brevo.com/settings/keys/api",
            "resend": "https://resend.com/api-keys", "postmark": "https://account.postmarkapp.com", "klaviyo": "https://www.klaviyo.com/settings/account/api-keys",
            "intercom": "https://app.intercom.com/a/apps/_/developer-hub", "notion": "https://www.notion.so/my-integrations",
            "airtable": "https://airtable.com/create/tokens", "figma": "https://www.figma.com/developers/api#access-tokens",
            "clickup": "https://app.clickup.com/settings/apps", "trello": "https://trello.com/power-ups/admin",
            "dropbox": "https://www.dropbox.com/developers/apps", "typeform": "https://admin.typeform.com/account#/section/tokens",
            "mapbox": "https://account.mapbox.com/access-tokens/", "spotify": "https://developer.spotify.com/dashboard",
            "supabase": "https://supabase.com/dashboard/project/_/settings/api", "neon": "https://console.neon.tech",
            "pinecone": "https://app.pinecone.io", "apify": "https://console.apify.com/account/integrations",
            "aws_access_key": "https://console.aws.amazon.com/iam/home#/security_credentials",
            "cloudflare": "https://dash.cloudflare.com/profile/api-tokens", "pagerduty": "https://app.pagerduty.com",
            "docker": "https://hub.docker.com/settings/security", "npm": "https://www.npmjs.com/settings/~/tokens",
            "facebook": "https://developers.facebook.com/tools/accesstoken/", "riot": "https://developer.riotgames.com",
            "databricks": "https://accounts.cloud.databricks.com", "azure_storage": "https://portal.azure.com",
            "brightdata": "https://brightdata.com/cp/setting", "mongodb_atlas": "https://cloud.mongodb.com",
            "nuget": "https://www.nuget.org/account/apikeys", "pubnub": "https://admin.pubnub.com",
            "pypi": "https://pypi.org/manage/account/token/"
        ]
        return map[s]
    }

    /// True when this provider is an incoming webhook we can post a test message to using only the key/URL.
    public static func isWebhook(service: String) -> Bool {
        ["discord_webhook", "slack_webhook", "teams_webhook"].contains(service.lowercased())
    }

    /// Post a harmless test message to a webhook the user owns (Discord/Slack/Teams). Returns (ok, message).
    public static func sendWebhookTest(key: String, service: String, text: String) async -> (Bool, String) {
        let s = service.lowercased()
        let urlStr: String
        var body: [String: Any]
        switch s {
        case "discord_webhook":
            urlStr = key.hasPrefix("http") ? key : "https://discord.com/api/webhooks/\(key)"
            body = ["content": text]
        case "slack_webhook", "teams_webhook":
            urlStr = key
            body = ["text": text]
        default:
            return (false, "Not a webhook provider")
        }
        guard let url = URL(string: urlStr) else { return (false, "Invalid webhook URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await APIKeyChecker.send(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) { return (true, "Test message delivered (HTTP \(code))") }
            return (false, "Webhook returned HTTP \(code)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Main Check Dispatcher
    public static func check(key: String, service: String, endpoint: String?) async -> CheckResult {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return CheckResult(status: .invalid, snippet: "Empty key")
        }

        // Auto-detect service if generic or mismatch
        let detectedService = detectService(key: trimmedKey, declaredService: service)

        switch detectedService {
        // --- AI & LLM Services ---
        case "openai", "sk_all", "openai_org":
            return await checkOpenAI(key: trimmedKey)
        case "anthropic":
            return await checkAnthropic(key: trimmedKey)
        case "google_ai":
            return await checkGoogleAI(key: trimmedKey)
        case "openrouter":
            return await checkOpenRouter(key: trimmedKey)
        case "groq":
            return await checkGroq(key: trimmedKey)
        case "deepseek":
            return await checkDeepSeek(key: trimmedKey)
        case "huggingface":
            return await checkHuggingFace(key: trimmedKey)
        case "cohere":
            return await checkCohere(key: trimmedKey)
        case "replicate":
            return await checkReplicate(key: trimmedKey)
        case "mistral":
            return await checkMistral(key: trimmedKey)
        case "together":
            return await checkTogetherAI(key: trimmedKey)
        case "fireworks":
            return await checkFireworksAI(key: trimmedKey)
        case "cerebras":
            return await checkCerebras(key: trimmedKey)
        case "xai":
            return await checkXAI(key: trimmedKey)
        case "perplexity":
            return await checkPerplexity(key: trimmedKey)
        case "you_com":
            return await checkYouCom(key: trimmedKey)
        case "tavily":
            return await checkTavily(key: trimmedKey)
        case "fal":
            return await checkFalAI(key: trimmedKey)
        case "anyscale":
            return await checkAnyscale(key: trimmedKey)
        case "aimlapi":
            return await checkAIMLAPI(key: trimmedKey)
        case "runpod":
            return await checkRunPod(key: trimmedKey)
        case "voyage":
            return await checkVoyageAI(key: trimmedKey)
        case "exa":
            return await checkExaAI(key: trimmedKey)
        case "langsmith":
            return await checkLangSmith(key: trimmedKey)

        // --- Cloud Infrastructure & Hostings ---
        case "aws_access_key":
            return await checkAWSAccessKey(key: trimmedKey)
        case "alibaba_cloud":
            return await checkAlibabaCloud(key: trimmedKey)
        case "tencent_cloud":
            return await checkTencentCloud(key: trimmedKey)
        case "flyio":
            return await checkFlyIO(key: trimmedKey)
        case "scaleway":
            return await checkScaleway(key: trimmedKey)
        case "render":
            return await checkRender(key: trimmedKey)
        case "hyperbrowser":
            return await checkHyperbrowser(key: trimmedKey)
        case "browserbase":
            return await checkBrowserbase(key: trimmedKey)

        // --- Developer Platforms & Repos ---
        case "github":
            return await checkGitHub(key: trimmedKey)
        case "gitlab":
            return await checkGitLab(key: trimmedKey)
        case "bitbucket":
            return await checkBitbucket(key: trimmedKey)
        case "atlassian":
            return await checkAtlassian(key: trimmedKey)
        case "docker":
            return await checkDockerHub(key: trimmedKey)
        case "cargo_crates":
            return await checkCargoCrates(key: trimmedKey)
        case "vercel":
            return await checkVercel(key: trimmedKey)
        case "netlify":
            return await checkNetlify(key: trimmedKey)
        case "sonarqube":
            return await checkSonarQube(key: trimmedKey)
        case "grafana":
            return await checkGrafana(key: trimmedKey)
        case "hashicorp_vault":
            return await checkHashiCorpVault(key: trimmedKey)
        case "infisical":
            return await checkInfisical(key: trimmedKey)
        case "onepassword":
            return await check1Password(key: trimmedKey)
        case "pipedream":
            return await checkPipedream(key: trimmedKey)

        // --- Messaging, Chatbots & Email ---
        case "telegram_bot", "1635646211_@pkbtv_@sackion_@sakione_bot":
            return await checkTelegramBot(key: trimmedKey)
        case "discord_bot":
            return await checkDiscordBot(key: trimmedKey)
        case "discord_webhook":
            return await checkDiscordWebhook(key: trimmedKey)
        case "slack":
            return await checkSlack(key: trimmedKey)
        case "slack_webhook":
            return await checkSlackWebhook(key: trimmedKey)
        case "teams_webhook":
            return await checkTeamsWebhook(key: trimmedKey)
        case "twilio":
            return await checkTwilio(key: trimmedKey)
        case "sendgrid":
            return await checkSendGrid(key: trimmedKey)
        case "mailchimp":
            return await checkMailchimp(key: trimmedKey)
        case "mailgun":
            return await checkMailgun(key: trimmedKey)
        case "postmark":
            return await checkPostmark(key: trimmedKey)
        case "brevo":
            return await checkBrevo(key: trimmedKey)
        case "resend":
            return await checkResend(key: trimmedKey)
        case "klaviyo":
            return await checkKlaviyo(key: trimmedKey)
        case "intercom":
            return await checkIntercom(key: trimmedKey)

        // --- Databases, URIs & Vector Engines ---
        case "pinecone":
            return await checkPinecone(key: trimmedKey)
        case "mongodb_uri":
            return checkURIString(trimmedKey, dbType: "MongoDB", defaultPort: 27017)
        case "postgres_uri":
            return checkURIString(trimmedKey, dbType: "PostgreSQL", defaultPort: 5432)
        case "mysql_uri":
            return checkURIString(trimmedKey, dbType: "MySQL", defaultPort: 3306)
        case "redis_uri":
            return checkURIString(trimmedKey, dbType: "Redis", defaultPort: 6379)
        case "amqp_uri":
            return checkURIString(trimmedKey, dbType: "AMQP RabbitMQ", defaultPort: 5672)
        case "elasticsearch_uri":
            return checkURIString(trimmedKey, dbType: "Elasticsearch", defaultPort: 9200)
        case "neon":
            return await checkNeon(key: trimmedKey)
        case "supabase":
            return await checkSupabase(key: trimmedKey)
        case "airtable":
            return await checkAirtable(key: trimmedKey)
        case "notion":
            return await checkNotion(key: trimmedKey)

        // --- Payments & E-Commerce ---
        case "stripe":
            return await checkStripe(key: trimmedKey)
        case "razorpay":
            return await checkRazorpay(key: trimmedKey)
        case "shopify":
            return await checkShopify(key: trimmedKey)
        case "square":
            return await checkSquare(key: trimmedKey)
        case "checkout":
            return await checkCheckout(key: trimmedKey)
        case "flutterwave":
            return await checkFlutterwave(key: trimmedKey)

        // --- Audio, Speech, Maps & Monitoring ---
        case "elevenlabs":
            return await checkElevenLabs(key: trimmedKey)
        case "deepl":
            return await checkDeepL(key: trimmedKey)
        case "mapbox":
            return await checkMapbox(key: trimmedKey)
        case "mux":
            return await checkMux(key: trimmedKey)
        case "sentry":
            return await checkSentry(key: trimmedKey)
        case "sentry_dsn":
            return checkSentryDSN(trimmedKey)
        case "launchdarkly":
            return await checkLaunchDarkly(key: trimmedKey)
        case "pagerduty":
            return await checkPagerDuty(key: trimmedKey)
        case "livekit":
            return await checkLiveKit(key: trimmedKey)
        case "figma":
            return await checkFigma(key: trimmedKey)

        // --- Tools, Productivity & Social ---
        case "clickup":
            return await checkClickUp(key: trimmedKey)
        case "trello":
            return await checkTrello(key: trimmedKey)
        case "typeform":
            return await checkTypeform(key: trimmedKey)
        case "dropbox":
            return await checkDropbox(key: trimmedKey)
        case "facebook":
            return await checkFacebook(key: trimmedKey)
        case "firebase_fcm":
            return await checkFirebaseFCM(key: trimmedKey)
        case "apify":
            return await checkApify(key: trimmedKey)
        case "capsolver":
            return await checkCapSolver(key: trimmedKey)
        case "riot":
            return await checkRiot(key: trimmedKey)
        case "spotify":
            return await checkSpotify(key: trimmedKey)

        case "datadog":       return await checkDatadog(key: trimmedKey)
        case "digitalocean":  return await checkDigitalOcean(key: trimmedKey)
        case "heroku":        return await checkHeroku(key: trimmedKey)
        case "newrelic":      return await checkNewRelic(key: trimmedKey)
        case "npm":           return await checkNPM(key: trimmedKey)
        case "firecrawl":     return await checkFirecrawl(key: trimmedKey)
        case "jina":          return await checkJina(key: trimmedKey)
        case "openai_asst":   return await checkOpenAI(key: trimmedKey)

        // --- New types (this batch) ---
        case "cloudflare":    return await checkCloudflare(key: trimmedKey)
        case "databricks":    return checkDatabricks(key: trimmedKey)
        case "azure_storage": return checkAzureStorage(key: trimmedKey)
        case "brightdata":    return checkBrightData(key: trimmedKey)
        case "mongodb_atlas": return checkMongoAtlas(key: trimmedKey)
        case "nuget":         return checkNuGet(key: trimmedKey)
        case "pubnub":        return checkPubNub(key: trimmedKey)
        case "pypi":          return checkPyPI(key: trimmedKey)
        case "all_discord_tokens", "valid_discord_tokens", "discord_user":
            return await checkDiscordUser(key: trimmedKey)

        default:
            if let endpoint, let url = URL(string: endpoint) {
                return await genericHTTPCheck(key: trimmedKey, url: url)
            }
            return checkGenericTokenFormat(key: trimmedKey, service: service)
        }
    }

    // MARK: - Added service checkers (gap coverage)

    // Datadog — API key validation endpoint.
    private static func checkDatadog(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.datadoghq.com/api/v1/validate") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "DD-API-KEY")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var d = KeyDetails(); d.latencyMs = latency; d.httpCode = code; d.rawSnippet = String(data: data.prefix(600), encoding: .utf8)
            if code == 200 { d.planOrTier = "Datadog API"; return CheckResult(status: .valid, snippet: "Valid Datadog API key", details: d) }
            if code == 403 { return CheckResult(status: .invalid, snippet: "Invalid Datadog API key") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // DigitalOcean — account endpoint.
    private static func checkDigitalOcean(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.digitalocean.com/v2/account") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var d = KeyDetails(); d.latencyMs = latency; d.httpCode = 200; d.rawSnippet = String(data: data.prefix(800), encoding: .utf8)
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let acc = j["account"] as? [String: Any] {
                    d.email = acc["email"] as? String
                    d.planOrTier = (acc["status"] as? String)?.capitalized
                    if let limit = acc["droplet_limit"] as? Int { d.balanceOrQuota = "Droplet limit: \(limit)" }
                }
                return CheckResult(status: .valid, snippet: "Valid DigitalOcean token (\(d.email ?? "account"))", details: d)
            }
            if code == 401 { return CheckResult(status: .invalid, snippet: "Invalid DigitalOcean token") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // Heroku — account endpoint (needs the versioned Accept header).
    private static func checkHeroku(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.heroku.com/account") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.heroku+json; version=3", forHTTPHeaderField: "Accept")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var d = KeyDetails(); d.latencyMs = latency; d.httpCode = 200; d.rawSnippet = String(data: data.prefix(800), encoding: .utf8)
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    d.email = j["email"] as? String
                    d.accountName = j["name"] as? String
                    d.planOrTier = (j["verified"] as? Bool) == true ? "Verified" : "Unverified"
                }
                return CheckResult(status: .valid, snippet: "Valid Heroku token (\(d.email ?? "account"))", details: d)
            }
            if code == 401 { return CheckResult(status: .invalid, snippet: "Invalid Heroku token") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // New Relic — REST API key via X-Api-Key.
    private static func checkNewRelic(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.newrelic.com/v2/applications.json") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "X-Api-Key")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var d = KeyDetails(); d.latencyMs = latency; d.httpCode = code; d.rawSnippet = String(data: data.prefix(600), encoding: .utf8)
            if code == 200 { d.planOrTier = "New Relic REST API"; return CheckResult(status: .valid, snippet: "Valid New Relic API key", details: d) }
            if code == 401 || code == 403 { return CheckResult(status: .invalid, snippet: "Invalid New Relic API key") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // npm — whoami.
    private static func checkNPM(key: String) async -> CheckResult {
        guard let url = URL(string: "https://registry.npmjs.org/-/whoami") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var d = KeyDetails(); d.latencyMs = latency; d.httpCode = 200; d.rawSnippet = String(data: data.prefix(400), encoding: .utf8)
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { d.accountName = j["username"] as? String }
                return CheckResult(status: .valid, snippet: "Valid npm token (@\(d.accountName ?? "user"))", details: d)
            }
            if code == 401 { return CheckResult(status: .invalid, snippet: "Invalid npm token") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // Firecrawl — credit usage.
    private static func checkFirecrawl(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.firecrawl.dev/v1/team/credit-usage") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var d = KeyDetails(); d.latencyMs = latency; d.httpCode = 200; d.rawSnippet = String(data: data.prefix(600), encoding: .utf8)
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dd = j["data"] as? [String: Any], let credits = dd["remaining_credits"] {
                    d.balanceOrQuota = "Credits: \(credits)"
                }
                return CheckResult(status: .valid, snippet: d.balanceOrQuota ?? "Valid Firecrawl key", details: d)
            }
            if code == 401 { return CheckResult(status: .invalid, snippet: "Invalid Firecrawl key") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // Jina AI — minimal embeddings probe (200/402 valid, 401 invalid).
    private static func checkJina(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.jina.ai/v1/embeddings") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": "jina-embeddings-v3", "input": ["ping"]])
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var d = KeyDetails(); d.latencyMs = latency; d.httpCode = code; d.rawSnippet = String(data: data.prefix(500), encoding: .utf8)
            if code == 200 || code == 402 { d.planOrTier = "Jina AI"; return CheckResult(status: code == 402 ? .quotaExceeded : .valid, snippet: code == 402 ? "Valid but out of tokens" : "Valid Jina AI key", details: d) }
            if code == 401 { return CheckResult(status: .invalid, snippet: "Invalid Jina AI key") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // Discord user token (not a bot token).
    private static func checkDiscordUser(key: String) async -> CheckResult {
        guard let url = URL(string: "https://discord.com/api/v10/users/@me") else { return CheckResult(status: .error, snippet: "Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var d = KeyDetails(); d.latencyMs = latency; d.httpCode = 200; d.rawSnippet = String(data: data.prefix(800), encoding: .utf8)
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let uname = j["username"] as? String ?? "user"
                    let disc = j["discriminator"] as? String ?? "0"
                    let global = j["global_name"] as? String
                    let id = j["id"] as? String ?? ""
                    // New-style @username, or legacy name#1234.
                    let handle = (disc == "0" || disc.isEmpty) ? "@\(uname)" : "\(uname)#\(disc)"
                    d.accountName = global != nil && !global!.isEmpty ? "\(global!) (\(handle))" : handle
                    d.email = j["email"] as? String

                    // Nitro tier from premium_type (0 none, 1 Classic, 2 Nitro, 3 Basic).
                    let premium = j["premium_type"] as? Int ?? 0
                    let nitro = ["No Nitro", "Nitro Classic", "Nitro", "Nitro Basic"]
                    d.planOrTier = premium < nitro.count ? nitro[premium] : "No Nitro"
                    d.balanceOrQuota = "ID \(id)"

                    // Account facts as chips.
                    var facts: [String] = []
                    if let phone = j["phone"] as? String, !phone.isEmpty { facts.append("phone verified") }
                    facts.append((j["verified"] as? Bool) == true ? "email verified" : "email unverified")
                    facts.append((j["mfa_enabled"] as? Bool) == true ? "2FA on" : "2FA off")
                    if let locale = j["locale"] as? String { facts.append("locale \(locale)") }
                    // Decode a few notable public badges from the flags bitfield.
                    let flags = (j["public_flags"] as? Int) ?? (j["flags"] as? Int) ?? 0
                    let badges: [(Int,String)] = [(1<<0,"Staff"),(1<<1,"Partner"),(1<<2,"HypeSquad"),
                        (1<<3,"Bug Hunter"),(1<<6,"Bravery"),(1<<7,"Brilliance"),(1<<8,"Balance"),
                        (1<<9,"Early Supporter"),(1<<14,"Bug Hunter 2"),(1<<17,"Early Verified Bot Dev"),(1<<22,"Active Developer")]
                    for (bit,label) in badges where flags & bit != 0 { facts.append(label) }
                    d.permissions = facts
                }
                let extra = d.planOrTier.map { " · \($0)" } ?? ""
                return CheckResult(status: .valid, snippet: "Valid Discord: \(d.accountName ?? "user")\(extra)", details: d)
            }
            if code == 401 { return CheckResult(status: .invalid, snippet: "Invalid or expired Discord token") }
            if code == 403 { return CheckResult(status: .permissionDenied, snippet: "Discord token locked/flagged (HTTP 403)") }
            if code == 429 { return CheckResult(status: .rateLimited, snippet: "Discord rate limited (HTTP 429)") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // MARK: - New-batch checkers

    // Cloudflare — official token-verify endpoint (live check).
    private static func checkCloudflare(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var d = KeyDetails(); d.latencyMs = latency; d.httpCode = code
            d.rawSnippet = String(data: data.prefix(600), encoding: .utf8)
            if code == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (j["success"] as? Bool) == true, let res = j["result"] as? [String: Any] {
                let status = (res["status"] as? String ?? "active").capitalized
                d.planOrTier = "Token \(status)"
                if let id = res["id"] as? String { d.accountName = "Token \(id.prefix(8))…" }
                let expired = status.lowercased() != "active"
                return CheckResult(status: expired ? .invalid : .valid,
                                   snippet: "Cloudflare token \(status)", details: d)
            }
            if code == 401 || code == 403 { return CheckResult(status: .invalid, snippet: "Invalid Cloudflare token (HTTP \(code))") }
            return CheckResult(status: .error, snippet: "HTTP \(code)")
        } catch { return CheckResult(status: .error, snippet: error.localizedDescription) }
    }

    // Databricks — needs the workspace host for a live call, so format-only (dapi… PAT).
    private static func checkDatabricks(key: String) -> CheckResult {
        let type = key.hasPrefix("dapi") ? "Personal Access Token" : "Token"
        return formatOnly("Databricks \(type)", key: key, minLen: 20,
                          extra: "Databricks \(type) (needs workspace host for live check)")
    }

    // Azure Storage — connection string or account key; parse the account name out.
    private static func checkAzureStorage(key: String) -> CheckResult {
        var details = KeyDetails()
        if key.contains("AccountName=") {
            let parts = key.components(separatedBy: ";")
            let name = parts.first(where: { $0.hasPrefix("AccountName=") })?.replacingOccurrences(of: "AccountName=", with: "")
            let suffix = parts.first(where: { $0.hasPrefix("EndpointSuffix=") })?.replacingOccurrences(of: "EndpointSuffix=", with: "")
            details.accountName = name
            details.planOrTier = "Storage Connection String"
            details.balanceOrQuota = suffix.map { "Endpoint: \($0)" }
            return CheckResult(status: .valid, snippet: "Valid Azure Storage connection (\(name ?? "account"))", details: details)
        }
        // Bare account key (base64, typically 88 chars ending "==").
        return formatOnly("Azure Storage Account Key", key: key, minLen: 40)
    }

    // Bright Data — proxy/API token (UUID-shaped); no reliable public verify endpoint.
    private static func checkBrightData(key: String) -> CheckResult {
        return formatOnly("Bright Data API Token", key: key, minLen: 20)
    }

    // MongoDB Atlas — Admin API uses HTTP-Digest with a public:private key pair.
    private static func checkMongoAtlas(key: String) -> CheckResult {
        let parts = key.components(separatedBy: ":")
        var details = KeyDetails()
        details.planOrTier = "Atlas Admin API Key"
        if parts.count == 2 {
            details.accountName = "Public: \(parts[0])"
            details.balanceOrQuota = "public:private pair"
            return CheckResult(status: .valid, snippet: "Valid Atlas API key pair (\(parts[0].prefix(8))…)", details: details)
        }
        return formatOnly("MongoDB Atlas Key", key: key, minLen: 8)
    }

    // NuGet — API key used only on push; no validation endpoint.
    private static func checkNuGet(key: String) -> CheckResult {
        return formatOnly("NuGet API Key", key: key, minLen: 16)
    }

    // PubNub — pub-c-… / sub-c-… key set.
    private static func checkPubNub(key: String) -> CheckResult {
        var details = KeyDetails()
        details.planOrTier = "PubNub Key"
        if key.hasPrefix("pub-c-") { details.planOrTier = "Publish Key" }
        else if key.hasPrefix("sub-c-") { details.planOrTier = "Subscribe Key" }
        else if key.hasPrefix("sec-c-") { details.planOrTier = "Secret Key" }
        return formatOnly("PubNub \(details.planOrTier ?? "Key")", key: key, minLen: 20)
    }

    // PyPI — upload token (pypi-…); validated only on publish.
    private static func checkPyPI(key: String) -> CheckResult {
        return formatOnly("PyPI Upload Token", key: key, minLen: 16)
    }

    // MARK: - Auto-Detection
    public static func detectService(key: String, declaredService: String) -> String {
        let s = declaredService.lowercased()
            .replacingOccurrences(of: ".txt", with: "")
            .replacingOccurrences(of: ".json", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s != "unknown" && s != "generic" && !s.isEmpty && s != "keys" {
            return s
        }
        if key.hasPrefix("sk-ant-") { return "anthropic" }
        if key.hasPrefix("sk-or-") { return "openrouter" }
        if key.hasPrefix("ghp_") || key.hasPrefix("gho_") || key.hasPrefix("github_pat_") { return "github" }
        if key.hasPrefix("sk_live_") || key.hasPrefix("rk_live_") || key.hasPrefix("pk_live_") { return "stripe" }
        if key.hasPrefix("AKIA") || key.hasPrefix("ASIA") { return "aws_access_key" }
        if key.hasPrefix("mongodb://") || key.hasPrefix("mongodb+srv://") { return "mongodb_uri" }
        if key.hasPrefix("postgres://") || key.hasPrefix("postgresql://") { return "postgres_uri" }
        if key.hasPrefix("mysql://") { return "mysql_uri" }
        if key.hasPrefix("redis://") || key.hasPrefix("rediss://") { return "redis_uri" }
        if key.hasPrefix("amqp://") || key.hasPrefix("amqps://") { return "amqp_uri" }
        if key.contains("discord.com/api/webhooks") { return "discord_webhook" }
        if key.contains("hooks.slack.com/services") { return "slack_webhook" }
        if key.contains("office.com/webhook") { return "teams_webhook" }
        if key.hasPrefix("gsk_") { return "groq" }
        if key.hasPrefix("hf_") { return "huggingface" }
        if key.hasPrefix("r8_") { return "replicate" }
        if key.hasPrefix("re_") { return "resend" }
        if key.hasPrefix("SG.") { return "sendgrid" }
        if key.hasPrefix("AIza") { return "google_ai" }
        if key.hasPrefix("ydc_") { return "you_com" }
        if key.hasPrefix("xai-") { return "xai" }
        if key.hasPrefix("secret_") { return "notion" }
        if key.hasPrefix("pat.") { return "airtable" }
        if key.hasPrefix("xoxb-") || key.hasPrefix("xoxp-") || key.hasPrefix("xapp-") { return "slack" }
        if key.hasPrefix("dapi") { return "databricks" }
        if key.hasPrefix("pypi-") { return "pypi" }
        if key.hasPrefix("pub-c-") || key.hasPrefix("sub-c-") || key.hasPrefix("sec-c-") { return "pubnub" }
        if key.contains("AccountName=") && key.contains("AccountKey=") { return "azure_storage" }
        if key.contains(":") && key.split(separator: ":").first?.allSatisfy({ $0.isNumber }) == true {
            return "telegram_bot"
        }
        if key.hasPrefix("sk-") { return "openai" }
        return s
    }

    // MARK: - Individual Service Implementations

    // 1. OpenAI
    private static func checkOpenAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if code == 200 {
                var models: [String] = []
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArr = json["data"] as? [[String: Any]] {
                    models = dataArr.compactMap { $0["id"] as? String }.sorted()
                }
                var details = KeyDetails()
                details.models = models
                details.latencyMs = latency
                details.httpCode = 200
                details.rawSnippet = snippet
                details.planOrTier = models.contains(where: { $0.contains("gpt-4") || $0.contains("o1") }) ? "GPT-4 / Reasoning Tier" : "Standard"
                details.balanceOrQuota = "\(models.count) models available"

                // Secondary: /v1/me reveals the user + organizations this key belongs to.
                if let meURL = URL(string: "https://api.openai.com/v1/me") {
                    var meReq = URLRequest(url: meURL, timeoutInterval: 6)
                    meReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    if let (md, mResp) = try? await APIKeyChecker.send(meReq),
                       (mResp as? HTTPURLResponse)?.statusCode == 200,
                       let mj = try? JSONSerialization.jsonObject(with: md) as? [String: Any] {
                        details.accountName = (mj["name"] as? String) ?? (mj["email"] as? String)
                        details.email = mj["email"] as? String
                        if let orgs = (mj["orgs"] as? [String: Any])?["data"] as? [[String: Any]] {
                            let names = orgs.compactMap { ($0["title"] as? String) ?? ($0["id"] as? String) }
                            if !names.isEmpty { details.permissions = names.map { "org: \($0)" } }
                        }
                    }
                }

                let who = details.accountName.map { " · \($0)" } ?? ""
                let summary = "Valid (\(models.count) models)\(who)"
                return CheckResult(status: .valid, snippet: summary, details: details)
            } else if code == 429 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 429
                details.rawSnippet = snippet
                details.balanceOrQuota = "Quota Exceeded (Add credits)"
                return CheckResult(status: .quotaExceeded, snippet: "Insufficient quota / billing exhausted", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid or revoked key (HTTP 401)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code): \(snippet.prefix(100))")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 2. Anthropic
    private static func checkAnthropic(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if code == 200 {
                var models: [String] = []
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArr = json["data"] as? [[String: Any]] {
                    models = dataArr.compactMap { $0["id"] as? String }
                }
                var details = KeyDetails()
                details.models = models
                details.latencyMs = latency
                details.httpCode = 200
                details.rawSnippet = snippet
                details.planOrTier = "Claude API Access"
                details.balanceOrQuota = "\(models.count) models available"

                return CheckResult(status: .valid, snippet: "Valid (\(models.count) models)", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Anthropic API key (HTTP 401)")
            } else if code == 429 {
                return CheckResult(status: .rateLimited, snippet: "Rate limited or credit exhausted (HTTP 429)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 3. Google AI / Gemini
    private static func checkGoogleAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        let req = URLRequest(url: url, timeoutInterval: 10)
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if code == 200 {
                var models: [String] = []
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = json["models"] as? [[String: Any]] {
                    models = arr.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                }
                var details = KeyDetails()
                details.models = models
                details.latencyMs = latency
                details.httpCode = 200
                details.rawSnippet = snippet
                details.planOrTier = "Gemini API"
                details.balanceOrQuota = "\(models.count) models available"

                return CheckResult(status: .valid, snippet: "Valid (\(models.count) Gemini models)", details: details)
            } else if code == 400 || code == 403 {
                return CheckResult(status: .invalid, snippet: "Invalid Google AI key (HTTP \(code))")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 4. OpenRouter
    private static func checkOpenRouter(key: String) async -> CheckResult {
        guard let url = URL(string: "https://openrouter.ai/api/v1/auth/key") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                details.rawSnippet = snippet

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = json["data"] as? [String: Any] {
                    let label = d["label"] as? String
                    let usage = d["usage"] as? Double ?? 0.0
                    let limit = d["limit"] as? Double
                    let remaining = d["limit_remaining"] as? Double
                    let isFree = d["is_free_tier"] as? Bool ?? false
                    let tier = d["tier"] as? String

                    details.accountName = label ?? "OpenRouter Key"
                    details.planOrTier = (tier?.capitalized).map { "\($0) tier" } ?? (isFree ? "Free Tier" : "Paid Tier")
                    if let limit {
                        let rem = remaining.map { String(format: " · $%.2f left", $0) } ?? ""
                        details.balanceOrQuota = String(format: "Usage $%.3f / Limit $%.2f", usage, limit) + rem
                    } else {
                        details.balanceOrQuota = String(format: "Usage $%.3f (no limit)", usage)
                    }
                    // Surface rate-limit + provisioning-key facts as structured chips.
                    var extra: [String] = []
                    if let rl = d["rate_limit"] as? [String: Any] {
                        let r = rl["requests"] as? Double ?? 0
                        let interval = rl["interval"] as? String ?? ""
                        if r > 0 { extra.append("rate \(Int(r))/\(interval)") }
                    }
                    if (d["is_provisioning_key"] as? Bool) == true { extra.append("provisioning key") }
                    if !extra.isEmpty { details.permissions = extra }
                }
                return CheckResult(status: .valid, snippet: details.balanceOrQuota ?? "Valid OpenRouter key", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid OpenRouter key")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 5. Groq
    private static func checkGroq(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "Groq")
    }

    // 6. DeepSeek
    private static func checkDeepSeek(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.deepseek.com/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (_, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                details.planOrTier = "DeepSeek API"

                if let balUrl = URL(string: "https://api.deepseek.com/user/balance") {
                    var balReq = URLRequest(url: balUrl, timeoutInterval: 5)
                    balReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    if let (balData, _) = try? await APIKeyChecker.send(balReq),
                       let balJson = try? JSONSerialization.jsonObject(with: balData) as? [String: Any],
                       let balInfo = balJson["balance_infos"] as? [[String: Any]],
                       let firstBal = balInfo.first {
                        let cur = firstBal["currency"] as? String ?? "CNY"
                        let tot = firstBal["total_balance"] as? String ?? "0"
                        details.balanceOrQuota = "Balance: \(tot) \(cur)"
                    }
                }
                return CheckResult(status: .valid, snippet: details.balanceOrQuota ?? "Valid DeepSeek API key", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid DeepSeek key")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 7. HuggingFace — whoami-v2 (modern hf_ tokens 401 on the old /api/whoami).
    private static func checkHuggingFace(key: String) async -> CheckResult {
        guard let url = URL(string: "https://huggingface.co/api/whoami-v2") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    details.accountName = json["name"] as? String ?? json["fullname"] as? String
                    details.email = json["email"] as? String
                    let type = (json["type"] as? String)?.capitalized ?? "User"
                    // Token role (read/write/fine-grained) lives under auth.accessToken.role.
                    let role = ((json["auth"] as? [String: Any])?["accessToken"] as? [String: Any])?["role"] as? String
                    details.planOrTier = role != nil ? "\(type) · \(role!) token" : type
                    if let plan = (json["plan"] as? String) { details.balanceOrQuota = "Plan: \(plan)" }
                    if let orgs = json["orgs"] as? [[String: Any]] {
                        let names = orgs.compactMap { $0["name"] as? String }
                        if !names.isEmpty { details.permissions = names.map { "org: \($0)" } }
                    }
                }
                return CheckResult(status: .valid, snippet: "Valid HuggingFace: @\(details.accountName ?? "user")", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid HuggingFace token")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 8. Cohere
    private static func checkCohere(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.cohere.ai/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "Cohere")
    }

    // 9. Replicate
    private static func checkReplicate(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.replicate.com/v1/account") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    details.accountName = json["username"] as? String
                    details.planOrTier = json["type"] as? String
                }
                return CheckResult(status: .valid, snippet: "Valid Replicate: @\(details.accountName ?? "user")", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Replicate Token")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 10. Mistral
    private static func checkMistral(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.mistral.ai/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "Mistral")
    }

    // 11. Together AI
    private static func checkTogetherAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.together.xyz/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "Together AI")
    }

    // 12. Fireworks AI
    private static func checkFireworksAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.fireworks.ai/inference/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "Fireworks AI")
    }

    // 13. Cerebras
    private static func checkCerebras(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.cerebras.ai/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "Cerebras")
    }

    // 14. xAI (Grok)
    private static func checkXAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.x.ai/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "xAI (Grok)")
    }

    // 15. Perplexity
    private static func checkPerplexity(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.perplexity.ai/chat/completions") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "sonar",
            "messages": [["role": "user", "content": "ping"]]
        ])
        let start = Date()
        do {
            let (_, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                return CheckResult(status: .valid, snippet: "Valid Perplexity API Key", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Perplexity Key")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 16. You.com
    private static func checkYouCom(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.ydc-index.io/search?query=test") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        return await httpCheckGenericBearer(req: req, provider: "You.com")
    }

    // 17. Tavily
    private static func checkTavily(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.tavily.com/search") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": key, "query": "ping"])
        return await httpCheckGenericBearer(req: req, provider: "Tavily")
    }

    // 18. Fal.ai
    private static func checkFalAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://rest.fal.ai/tokens") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Fal.ai")
    }

    // 19. Anyscale
    private static func checkAnyscale(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.endpoints.anyscale.com/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "Anyscale")
    }

    // 20. AIMLAPI
    private static func checkAIMLAPI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.aimlapi.com/v1/models") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckModels(req: req, provider: "AI ML API")
    }

    // 21. RunPod
    private static func checkRunPod(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.runpod.io/graphql?api_key=\(key)") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": "{ myself { id email } }"])
        return await httpCheckGenericBearer(req: req, provider: "RunPod")
    }

    // 22. Voyage AI
    private static func checkVoyageAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.voyageai.com/v1/embeddings") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": "voyage-2", "input": ["test"]])
        return await httpCheckGenericBearer(req: req, provider: "Voyage AI")
    }

    // 23. Exa AI
    private static func checkExaAI(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.exa.ai/search") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": "test"])
        return await httpCheckGenericBearer(req: req, provider: "Exa AI")
    }

    // 24. LangSmith
    private static func checkLangSmith(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.smith.langchain.com/info") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        return await httpCheckGenericBearer(req: req, provider: "LangSmith")
    }

    // 25. AWS Access Key
    private static func checkAWSAccessKey(key: String) async -> CheckResult {
        var details = KeyDetails()
        details.planOrTier = "AWS IAM Credential"
        let isAccessKey = key.hasPrefix("AKIA") || key.hasPrefix("ASIA")
        if isAccessKey && key.count >= 16 && key.count <= 128 {
            details.accountName = String(key.prefix(12))
            details.balanceOrQuota = key.hasPrefix("AKIA") ? "Permanent Key" : "Temporary Session Key"
            return CheckResult(status: .valid, snippet: "Valid AWS Key (\(details.balanceOrQuota ?? ""))", details: details)
        } else {
            return CheckResult(status: .invalid, snippet: "Invalid AWS Access Key format")
        }
    }

    // 26. Alibaba Cloud
    private static func checkAlibabaCloud(key: String) async -> CheckResult {
        var details = KeyDetails()
        details.planOrTier = "Alibaba Cloud AccessKey"
        if key.hasPrefix("LTAI") && key.count >= 16 {
            return CheckResult(status: .valid, snippet: "Valid Alibaba AccessKey ID (\(key.prefix(8))...)", details: details)
        } else if key.count >= 12 {
            return CheckResult(status: .valid, snippet: "Valid Alibaba Cloud Credential", details: details)
        }
        return CheckResult(status: .invalid, snippet: "Invalid Alibaba Cloud Key format")
    }

    // 27. Tencent Cloud
    private static func checkTencentCloud(key: String) async -> CheckResult {
        var details = KeyDetails()
        details.planOrTier = "Tencent Cloud SecretID"
        if key.hasPrefix("AKID") && key.count >= 20 {
            return CheckResult(status: .valid, snippet: "Valid Tencent SecretId", details: details)
        } else if key.count >= 16 {
            return CheckResult(status: .valid, snippet: "Valid Tencent Cloud Key", details: details)
        }
        return CheckResult(status: .invalid, snippet: "Invalid Tencent SecretId format")
    }

    // 28. Fly.io
    private static func checkFlyIO(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.fly.io/graphql") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": "{ viewer { email } }"])
        return await httpCheckGenericBearer(req: req, provider: "Fly.io")
    }

    // 29. Scaleway
    private static func checkScaleway(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.scaleway.com/account/v1/regions") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "X-Auth-Token")
        return await httpCheckGenericBearer(req: req, provider: "Scaleway")
    }

    // 30. Render
    private static func checkRender(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.render.com/v1/owners") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Render")
    }

    // 31. Hyperbrowser
    private static func checkHyperbrowser(key: String) async -> CheckResult {
        return formatOnly("Hyperbrowser API Key", key: key, minLen: 16)
    }

    // 32. Browserbase
    private static func checkBrowserbase(key: String) async -> CheckResult {
        guard let url = URL(string: "https://www.browserbase.com/v1/sessions") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "X-BB-API-Key")
        return await httpCheckGenericBearer(req: req, provider: "Browserbase")
    }

    // 33. GitHub
    private static func checkGitHub(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.github.com/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("CookieVault/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let httpResp = response as? HTTPURLResponse
            let code = httpResp?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                details.rawSnippet = snippet

                if let scopesHeader = httpResp?.value(forHTTPHeaderField: "X-OAuth-Scopes") {
                    let scopes = scopesHeader.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    details.permissions = scopes
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let login = json["login"] as? String
                    let name = json["name"] as? String
                    details.accountName = login ?? name
                    details.email = json["email"] as? String
                    if let plan = json["plan"] as? [String: Any], let planName = plan["name"] as? String {
                        details.planOrTier = "GitHub \(planName.capitalized)"
                    }
                    // Pack the useful profile facts into extra "permission" chips + balance line.
                    var facts: [String] = []
                    if let repos = json["public_repos"] as? Int { facts.append("\(repos) public repos") }
                    if let priv = json["total_private_repos"] as? Int, priv > 0 { facts.append("\(priv) private repos") }
                    if let followers = json["followers"] as? Int { facts.append("\(followers) followers") }
                    if let company = json["company"] as? String, !company.isEmpty { facts.append(company) }
                    if let loc = json["location"] as? String, !loc.isEmpty { facts.append(loc) }
                    if let tfa = json["two_factor_authentication"] as? Bool { facts.append(tfa ? "2FA on" : "2FA off") }
                    if let created = json["created_at"] as? String { facts.append("since \(created.prefix(4))") }
                    details.balanceOrQuota = facts.prefix(3).joined(separator: " · ")
                    // Append remaining facts to the scopes list so they surface as chips.
                    if facts.count > 3 { details.permissions = (details.permissions ?? []) + Array(facts.dropFirst(3)) }
                }

                let summary = "Valid: @\(details.accountName ?? "user") — \(details.planOrTier ?? "GitHub") (\(details.permissions?.count ?? 0) scopes)"
                return CheckResult(status: .valid, snippet: summary, details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Bad GitHub credentials (HTTP 401)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 34. GitLab
    private static func checkGitLab(key: String) async -> CheckResult {
        guard let url = URL(string: "https://gitlab.com/api/v4/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "GitLab")
    }

    // 35. Bitbucket
    private static func checkBitbucket(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.bitbucket.org/2.0/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Bitbucket")
    }

    // 36. Atlassian (needs the account email for Basic auth, so format-only here)
    private static func checkAtlassian(key: String) async -> CheckResult {
        let type = key.hasPrefix("ATATT") ? "API Token (v2)" : key.hasPrefix("ATCTT") ? "Scoped Token" : "API Token"
        return formatOnly("Atlassian \(type)", key: key, minLen: 20)
    }

    // 37. Docker Hub
    private static func checkDockerHub(key: String) async -> CheckResult {
        guard let url = URL(string: "https://hub.docker.com/v2/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Docker Hub")
    }

    // 38. Cargo Crates.io
    private static func checkCargoCrates(key: String) async -> CheckResult {
        guard let url = URL(string: "https://crates.io/api/v1/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "Authorization")
        req.setValue("CookieVault/1.0", forHTTPHeaderField: "User-Agent")
        return await httpCheckGenericBearer(req: req, provider: "Cargo Crates.io")
    }

    // 39. Vercel
    private static func checkVercel(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.vercel.com/v2/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let user = json["user"] as? [String: Any] {
                    details.accountName = user["username"] as? String ?? user["name"] as? String
                    details.email = user["email"] as? String
                }
                return CheckResult(status: .valid, snippet: "Valid Vercel User (@\(details.accountName ?? "user"))", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Vercel Token")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 40. Netlify
    private static func checkNetlify(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.netlify.com/api/v1/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Netlify")
    }

    // 41. SonarQube
    private static func checkSonarQube(key: String) async -> CheckResult {
        let type = key.hasPrefix("squ_") ? "User Token" : key.hasPrefix("sqp_") ? "Project Token" : key.hasPrefix("sqa_") ? "Global Analysis Token" : "Token"
        return formatOnly("SonarQube \(type)", key: key, minLen: 20)
    }

    // 42. Grafana
    private static func checkGrafana(key: String) async -> CheckResult {
        let type = key.hasPrefix("glsa_") ? "Service Account Token" : key.hasPrefix("glc_") ? "Cloud Token" : key.hasPrefix("eyJ") ? "JWT API Key" : "API Key"
        return formatOnly("Grafana \(type)", key: key, minLen: 24)
    }

    // 43. HashiCorp Vault
    private static func checkHashiCorpVault(key: String) async -> CheckResult {
        let type = key.hasPrefix("hvs.") ? "Service Token" : key.hasPrefix("hvb.") ? "Batch Token" : key.hasPrefix("s.") ? "Legacy Token" : "Token"
        return formatOnly("Vault \(type)", key: key, minLen: 20)
    }

    // 44. Infisical
    private static func checkInfisical(key: String) async -> CheckResult {
        let type = key.hasPrefix("st.") ? "Service Token" : "Secret Token"
        return formatOnly("Infisical \(type)", key: key, minLen: 20)
    }

    // 45. 1Password — service-account tokens are JWT-shaped after the ops_ prefix.
    private static func check1Password(key: String) async -> CheckResult {
        return formatOnly("1Password Service Account Token", key: key, minLen: 30)
    }

    // 46. Pipedream
    private static func checkPipedream(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.pipedream.com/v1/users/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Pipedream")
    }

    // 47. Telegram Bot
    private static func checkTelegramBot(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.telegram.org/bot\(key)/getMe") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        let req = URLRequest(url: url, timeoutInterval: 10)
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let res = json["result"] as? [String: Any] {
                    let username = res["username"] as? String ?? ""
                    let firstName = res["first_name"] as? String ?? ""
                    let botId = res["id"] as? Int ?? 0

                    details.accountName = firstName.isEmpty ? "@\(username)" : "@\(username) (\(firstName))"
                    details.planOrTier = "Telegram Bot (ID: \(botId))"
                    var caps: [String] = []
                    if (res["can_join_groups"] as? Bool) == true { caps.append("join groups") }
                    if (res["can_read_all_group_messages"] as? Bool) == true { caps.append("read all msgs") }
                    if (res["supports_inline_queries"] as? Bool) == true { caps.append("inline queries") }
                    if !caps.isEmpty { details.permissions = caps }
                }

                return CheckResult(status: .valid, snippet: "Valid Bot: \(details.accountName ?? "Bot")", details: details)
            } else if code == 401 || code == 404 {
                return CheckResult(status: .invalid, snippet: "Unauthorized bot token")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 48. Discord Bot
    private static func checkDiscordBot(key: String) async -> CheckResult {
        guard let url = URL(string: "https://discord.com/api/v10/users/@me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bot \(key)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let username = json["username"] as? String ?? "Discord Bot"
                    let disc = json["discriminator"] as? String ?? "0"
                    let id = json["id"] as? String ?? ""
                    let tag = (disc == "0" || disc.isEmpty) ? username : "\(username)#\(disc)"
                    details.accountName = tag
                    details.planOrTier = "Discord Bot (ID: \(id))"
                    var flags: [String] = []
                    if (json["verified"] as? Bool) == true { flags.append("verified") }
                    let pf = (json["public_flags"] as? Int) ?? (json["flags"] as? Int) ?? 0
                    if pf & (1 << 16) != 0 { flags.append("verified-bot") }        // VERIFIED_BOT
                    if pf & (1 << 19) != 0 { flags.append("active-developer") }     // ACTIVE_DEVELOPER
                    if !flags.isEmpty { details.permissions = flags }
                }
                // Guild reach (best-effort) — how many servers the bot is in.
                if let gUrl = URL(string: "https://discord.com/api/v10/users/@me/guilds") {
                    var gReq = URLRequest(url: gUrl, timeoutInterval: 5)
                    gReq.setValue("Bot \(key)", forHTTPHeaderField: "Authorization")
                    if let (gd, gResp) = try? await APIKeyChecker.send(gReq),
                       (gResp as? HTTPURLResponse)?.statusCode == 200,
                       let guilds = try? JSONSerialization.jsonObject(with: gd) as? [[String: Any]] {
                        details.balanceOrQuota = "In \(guilds.count) server\(guilds.count == 1 ? "" : "s")"
                    }
                }
                let extra = details.balanceOrQuota.map { " · \($0)" } ?? ""
                return CheckResult(status: .valid, snippet: "Valid: \(details.accountName ?? "Discord Bot")\(extra)", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Discord bot token")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 49. Discord Webhook
    private static func checkDiscordWebhook(key: String) async -> CheckResult {
        let urlStr = key.hasPrefix("http") ? key : "https://discord.com/api/webhooks/\(key)"
        guard let url = URL(string: urlStr) else {
            return CheckResult(status: .error, snippet: "Invalid Webhook URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    details.accountName = json["name"] as? String
                    details.planOrTier = "Discord Webhook"
                }
                return CheckResult(status: .valid, snippet: "Valid Discord Webhook (\(details.accountName ?? "Active"))", details: details)
            } else if code == 404 || code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Discord Webhook (HTTP \(code))")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 50. Slack Token
    private static func checkSlack(key: String) async -> CheckResult {
        guard let url = URL(string: "https://slack.com/api/auth.test") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, ok {
                    let team = json["team"] as? String ?? ""
                    let user = json["user"] as? String ?? ""
                    details.accountName = "\(user) @ \(team)"
                    details.planOrTier = "Slack API Token"
                    return CheckResult(status: .valid, snippet: "Valid Slack Token (\(details.accountName ?? "Active"))", details: details)
                } else {
                    return CheckResult(status: .invalid, snippet: "Invalid Slack Token")
                }
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Slack Token")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 51. Slack Webhook — extract the workspace/team segment from the URL.
    private static func checkSlackWebhook(key: String) async -> CheckResult {
        guard key.contains("hooks.slack.com/services") else {
            return key.count >= 24 ? formatOnly("Slack Webhook", key: key, minLen: 24)
                                   : CheckResult(status: .invalid, snippet: "Invalid Slack Webhook format")
        }
        var details = KeyDetails()
        details.planOrTier = "Slack Incoming Webhook"
        let segs = key.components(separatedBy: "/services/").last?.components(separatedBy: "/") ?? []
        if let team = segs.first { details.accountName = "Team \(team)" }
        details.permissions = segs.prefix(2).map { "id=\($0)" }
        return CheckResult(status: .valid, snippet: "Valid Slack Webhook (\(details.accountName ?? "active"))", details: details)
    }

    // 52. Teams Webhook — pull the tenant/host from the URL.
    private static func checkTeamsWebhook(key: String) async -> CheckResult {
        guard let comp = URLComponents(string: key), let host = comp.host,
              key.contains("webhook") || host.contains("office") || host.contains("azure") else {
            return key.count >= 30 ? formatOnly("Teams Webhook", key: key, minLen: 30)
                                   : CheckResult(status: .invalid, snippet: "Invalid Teams Webhook format")
        }
        var details = KeyDetails()
        details.planOrTier = "MS Teams Incoming Webhook"
        details.accountName = host
        return CheckResult(status: .valid, snippet: "Valid Teams Webhook (\(host))", details: details)
    }

    // 53. Twilio — live check when the token is provided as "SID:token".
    private static func checkTwilio(key: String) async -> CheckResult {
        let parts = key.components(separatedBy: ":")
        let sid = parts.first ?? key
        guard sid.hasPrefix("AC") || sid.hasPrefix("SK") else {
            return CheckResult(status: .invalid, snippet: "Invalid Twilio Account SID format")
        }
        // Without the auth token we can only validate the SID shape.
        guard parts.count >= 2, !parts[1].isEmpty else {
            var details = KeyDetails()
            details.accountName = sid
            details.planOrTier = "Twilio SID (token not supplied — format only)"
            return CheckResult(status: .valid, snippet: "Valid Twilio SID format (\(sid.prefix(10))…) — provide SID:token for a live check", details: details)
        }
        let token = parts[1]
        // The auth SID for Basic auth must be an Account SID (AC…); SK keys authenticate under their AC.
        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(sid).json") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let auth = Data("\(sid):\(token)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency; details.httpCode = 200
                details.accountName = sid
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let name = json["friendly_name"] as? String { details.accountName = name }
                    let status = (json["status"] as? String ?? "").capitalized
                    let type = (json["type"] as? String ?? "").capitalized  // Trial / Full
                    details.planOrTier = [type, status].filter { !$0.isEmpty }.joined(separator: " · ")
                }
                // Fetch balance (best-effort).
                if let balUrl = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(sid)/Balance.json") {
                    var balReq = URLRequest(url: balUrl, timeoutInterval: 5)
                    balReq.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
                    if let (bd, _) = try? await APIKeyChecker.send(balReq),
                       let bj = try? JSONSerialization.jsonObject(with: bd) as? [String: Any],
                       let bal = bj["balance"] as? String {
                        let cur = bj["currency"] as? String ?? "USD"
                        details.balanceOrQuota = "Balance: \(bal) \(cur)"
                    }
                }
                let extra = details.balanceOrQuota.map { " · \($0)" } ?? ""
                return CheckResult(status: .valid, snippet: "Valid Twilio (\(details.planOrTier ?? "active"))\(extra)", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Twilio SID/token pair (HTTP 401)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 54. SendGrid
    private static func checkSendGrid(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.sendgrid.com/v3/scopes") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let scopes = json["scopes"] as? [String] {
                    details.permissions = scopes
                }
                // Secondary: /v3/user/account (type + reputation) and /v3/user/credits (balance).
                if let accURL = URL(string: "https://api.sendgrid.com/v3/user/account") {
                    var accReq = URLRequest(url: accURL, timeoutInterval: 6)
                    accReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    if let (ad, aResp) = try? await APIKeyChecker.send(accReq),
                       (aResp as? HTTPURLResponse)?.statusCode == 200,
                       let aj = try? JSONSerialization.jsonObject(with: ad) as? [String: Any] {
                        let type = (aj["type"] as? String)?.capitalized ?? "Account"
                        let rep = aj["reputation"] as? Double
                        details.planOrTier = rep != nil ? "\(type) · reputation \(Int(rep!))%" : type
                    }
                }
                if details.email == nil, let pURL = URL(string: "https://api.sendgrid.com/v3/user/profile") {
                    var pReq = URLRequest(url: pURL, timeoutInterval: 6)
                    pReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    if let (pd, pResp) = try? await APIKeyChecker.send(pReq),
                       (pResp as? HTTPURLResponse)?.statusCode == 200,
                       let pj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] {
                        details.email = pj["email"] as? String
                        if let u = pj["username"] as? String { details.accountName = u }
                    }
                }
                let sc = details.permissions?.count ?? 0
                let mailSend = (details.permissions ?? []).contains("mail.send") ? " · can send mail" : " · cannot send"
                return CheckResult(status: .valid, snippet: "Valid SendGrid (\(sc) scopes\(mailSend))", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid SendGrid Key")
            } else if code == 403 {
                return CheckResult(status: .permissionDenied, snippet: "SendGrid key valid but restricted (HTTP 403)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 55. Mailchimp
    private static func checkMailchimp(key: String) async -> CheckResult {
        let parts = key.components(separatedBy: "-")
        let dc = parts.count > 1 ? parts.last! : "us1"
        guard let url = URL(string: "https://\(dc).api.mailchimp.com/3.0/ping") else {
            return CheckResult(status: .error, snippet: "Invalid Mailchimp DC URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let authStr = Data("anystring:\(key)".utf8).base64EncodedString()
        req.setValue("Basic \(authStr)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Mailchimp (\(dc))")
    }

    // 56. Mailgun
    private static func checkMailgun(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.mailgun.net/v3/domains") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let authStr = Data("api:\(key)".utf8).base64EncodedString()
        req.setValue("Basic \(authStr)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Mailgun")
    }

    // 57. Postmark
    private static func checkPostmark(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.postmarkapp.com/server") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "X-Postmark-Server-Token")
        return await httpCheckGenericBearer(req: req, provider: "Postmark")
    }

    // 58. Brevo
    private static func checkBrevo(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.brevo.com/v3/account") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "api-key")
        return await httpCheckGenericBearer(req: req, provider: "Brevo")
    }

    // 59. Resend
    private static func checkResend(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.resend.com/api-keys") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Resend")
    }

    // 60. Klaviyo
    private static func checkKlaviyo(key: String) async -> CheckResult {
        guard let url = URL(string: "https://a.klaviyo.com/api/accounts/") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Klaviyo-API-Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-02-22", forHTTPHeaderField: "revision")
        return await httpCheckGenericBearer(req: req, provider: "Klaviyo")
    }

    // 61. Intercom
    private static func checkIntercom(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.intercom.io/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Intercom")
    }

    // 62. Pinecone
    private static func checkPinecone(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.pinecone.io/indexes") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "Api-Key")
        return await httpCheckGenericBearer(req: req, provider: "Pinecone")
    }

    // 63. Database URI Checker Helper (MongoDB, Postgres, MySQL, Redis, AMQP, Elasticsearch)
    private static func checkURIString(_ uri: String, dbType: String, defaultPort: Int) -> CheckResult {
        var details = KeyDetails()
        details.planOrTier = "\(dbType) Database URI"

        if let components = URLComponents(string: uri) {
            let host = components.host ?? "localhost"
            let port = components.port ?? defaultPort
            let user = components.user ?? "default"
            let dbName = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            details.accountName = "\(user)@\(host):\(port)"
            details.balanceOrQuota = dbName.isEmpty ? "Connected Host" : "DB: \(dbName)"
            return CheckResult(status: .valid, snippet: "Valid \(dbType) Connection URI (\(host):\(port))", details: details)
        } else if uri.contains("://") && uri.count >= 10 {
            return CheckResult(status: .valid, snippet: "Valid \(dbType) Connection String", details: details)
        }
        return CheckResult(status: .invalid, snippet: "Invalid \(dbType) Connection URI format")
    }

    // 64. Neon
    private static func checkNeon(key: String) async -> CheckResult {
        guard let url = URL(string: "https://console.neon.tech/api/v2/users/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Neon Postgres")
    }

    // 65. Supabase — decode the JWT to reveal role (anon/service_role) + project ref.
    private static func checkSupabase(key: String) async -> CheckResult {
        var details = KeyDetails()
        if enrichFromJWT(key, into: &details) {
            let role = (decodeJWT(key)?["role"] as? String) ?? "key"
            let warn = role == "service_role" ? " ⚠️ SERVICE ROLE (full DB access)" : ""
            return CheckResult(status: .valid, snippet: "Valid Supabase \(role) key\(warn)", details: details)
        }
        // sb_secret_ / sb_publishable_ (new-style) keys aren't JWTs.
        if key.hasPrefix("sb_secret_") || key.hasPrefix("sb_publishable_") || key.count >= 30 {
            details.planOrTier = key.hasPrefix("sb_secret_") ? "Secret Key" : "Publishable/Anon Key"
            return CheckResult(status: .valid, snippet: "Valid Supabase key (\(details.planOrTier!))", details: details)
        }
        return CheckResult(status: .invalid, snippet: "Invalid Supabase key format")
    }

    // 66. Airtable
    private static func checkAirtable(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.airtable.com/v0/meta/whoami") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    details.email = json["email"] as? String
                }
                return CheckResult(status: .valid, snippet: "Valid Airtable (\(details.email ?? "user"))", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Airtable Token")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 67. Notion
    private static func checkNotion(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.notion.com/v1/users/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        return await httpCheckGenericBearer(req: req, provider: "Notion Integration")
    }

    // 68. Stripe
    private static func checkStripe(key: String) async -> CheckResult {
        if key.hasPrefix("pk_live_") || key.hasPrefix("pk_test_") {
            var details = KeyDetails()
            details.planOrTier = key.hasPrefix("pk_live_") ? "Publishable Live Key" : "Publishable Test Key"
            return CheckResult(status: .valid, snippet: "Valid Stripe Publishable Key", details: details)
        }

        guard let url = URL(string: "https://api.stripe.com/v1/balance") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let credentials = Data("\(key):".utf8).base64EncodedString()
        req.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                details.planOrTier = key.hasPrefix("sk_live_") || key.hasPrefix("rk_live_") ? "Live Secret Key" : "Test Secret Key"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let available = json["available"] as? [[String: Any]], let first = available.first,
                   let amount = first["amount"] as? Int, let cur = first["currency"] as? String {
                    let formatted = Double(amount) / 100.0
                    details.balanceOrQuota = String(format: "Available: $%.2f %@", formatted, cur.uppercased())
                }
                // Fetch the account profile for business name / country / email.
                if let acctURL = URL(string: "https://api.stripe.com/v1/account") {
                    var areq = URLRequest(url: acctURL, timeoutInterval: 8)
                    areq.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
                    if let (adata, _) = try? await APIKeyChecker.send(areq),
                       let aj = try? JSONSerialization.jsonObject(with: adata) as? [String: Any] {
                        let biz = (aj["business_profile"] as? [String: Any])?["name"] as? String
                        details.accountName = biz ?? (aj["settings"] as? [String: Any]).flatMap { ($0["dashboard"] as? [String: Any])?["display_name"] as? String }
                        details.email = aj["email"] as? String
                        var perms: [String] = []
                        if let country = aj["country"] as? String { perms.append(country) }
                        if let cur = aj["default_currency"] as? String { perms.append(cur.uppercased()) }
                        if (aj["charges_enabled"] as? Bool) == true { perms.append("charges enabled") }
                        if (aj["payouts_enabled"] as? Bool) == true { perms.append("payouts enabled") }
                        if !perms.isEmpty { details.permissions = perms }
                    }
                }
                let summary = "Valid Stripe (\(details.accountName ?? details.planOrTier ?? "account"))"
                return CheckResult(status: .valid, snippet: summary, details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid Stripe Secret Key")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 69. Razorpay
    private static func checkRazorpay(key: String) async -> CheckResult {
        // "key_id:key_secret" → live Basic-auth check; otherwise format-only.
        let parts = key.components(separatedBy: ":")
        let mode = key.contains("_live_") ? "Live" : key.contains("_test_") ? "Test" : "Key"
        if parts.count == 2, parts[0].hasPrefix("rzp_"), !parts[1].isEmpty,
           let url = URL(string: "https://api.razorpay.com/v1/payments?count=1") {
            var req = URLRequest(url: url, timeoutInterval: 10)
            let auth = Data("\(parts[0]):\(parts[1])".utf8).base64EncodedString()
            req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
            return await httpCheckGenericBearer(req: req, provider: "Razorpay (\(mode))")
        }
        return formatOnly("Razorpay \(mode) Key ID", key: key, minLen: 16,
                          extra: "Razorpay \(mode) Key (provide id:secret for live check)")
    }

    // 70. Shopify — token type from prefix (shop domain unknown, so no live call).
    private static func checkShopify(key: String) async -> CheckResult {
        let type = key.hasPrefix("shpat_") ? "Admin API Token" : key.hasPrefix("shpca_") ? "Custom App Token"
                 : key.hasPrefix("shppa_") ? "Private App Token" : key.hasPrefix("shpss_") ? "Shared Secret" : "Access Token"
        return formatOnly("Shopify \(type)", key: key, minLen: 20,
                          extra: "Shopify \(type) (needs shop domain for live check)")
    }

    // 71. Square
    private static func checkSquare(key: String) async -> CheckResult {
        guard let url = URL(string: "https://connect.squareup.com/v2/locations") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Square")
    }

    // 72. Checkout.com
    private static func checkCheckout(key: String) async -> CheckResult {
        let live = key.contains("_live_") || key.hasPrefix("sk_") && !key.contains("_test_")
        let type = key.hasPrefix("sk") ? "Secret Key" : key.hasPrefix("pk") ? "Public Key" : "Key"
        return formatOnly("Checkout.com \(live ? "Live" : "Test") \(type)", key: key, minLen: 20)
    }

    // 73. Flutterwave
    private static func checkFlutterwave(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.flutterwave.com/v3/balances") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Flutterwave")
    }

    // 74. ElevenLabs
    private static func checkElevenLabs(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")

        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let tier = json["tier"] as? String ?? "Standard"
                    let used = json["character_count"] as? Int ?? 0
                    let limit = json["character_limit"] as? Int ?? 0
                    details.planOrTier = "\(tier.capitalized) Plan"
                    details.balanceOrQuota = "\(used) / \(limit) chars used"
                }
                return CheckResult(status: .valid, snippet: details.balanceOrQuota ?? "Valid ElevenLabs key", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid ElevenLabs API key")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 75. DeepL
    private static func checkDeepL(key: String) async -> CheckResult {
        let isFree = key.hasSuffix(":fx")
        let urlStr = isFree ? "https://api-free.deepl.com/v2/usage" : "https://api.deepl.com/v2/usage"
        guard let url = URL(string: urlStr) else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "DeepL (\(isFree ? "Free" : "Pro"))")
    }

    // 76. Mapbox
    private static func checkMapbox(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.mapbox.com/tokens/v2?access_token=\(key)") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        let req = URLRequest(url: url, timeoutInterval: 10)
        return await httpCheckGenericBearer(req: req, provider: "Mapbox")
    }

    // 77. Mux — "TokenID:TokenSecret" for basic auth.
    private static func checkMux(key: String) async -> CheckResult {
        let parts = key.components(separatedBy: ":")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return formatOnly("Mux Token", key: key, minLen: 20)
        }
        guard let url = URL(string: "https://api.mux.com/video/v1/assets?limit=1") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let auth = Data("\(parts[0]):\(parts[1])".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Mux")
    }

    // 78. Sentry API
    private static func checkSentry(key: String) async -> CheckResult {
        guard let url = URL(string: "https://sentry.io/api/0/user/") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Sentry API")
    }

    // 79. Sentry DSN — parse host + project id out of the URL.
    private static func checkSentryDSN(_ dsn: String) -> CheckResult {
        guard let comp = URLComponents(string: dsn), let host = comp.host, comp.user != nil else {
            return CheckResult(status: .invalid, snippet: "Invalid Sentry DSN format")
        }
        var details = KeyDetails()
        details.planOrTier = "Sentry DSN"
        details.accountName = host
        let projectId = comp.path.split(separator: "/").last.map(String.init) ?? "?"
        details.balanceOrQuota = "Project \(projectId)"
        details.permissions = ["public-key=\(comp.user!.prefix(8))…", "host=\(host)"]
        return CheckResult(status: .valid, snippet: "Valid Sentry DSN · \(host) · project \(projectId)", details: details)
    }

    // 80. LaunchDarkly
    private static func checkLaunchDarkly(key: String) async -> CheckResult {
        guard let url = URL(string: "https://app.launchdarkly.com/api/v2/users") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "LaunchDarkly")
    }

    // 81. PagerDuty
    private static func checkPagerDuty(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.pagerduty.com/users/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Token token=\(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "PagerDuty")
    }

    // 82. LiveKit — credentials are "APIkey:secret".
    private static func checkLiveKit(key: String) async -> CheckResult {
        let parts = key.components(separatedBy: ":")
        var details = KeyDetails()
        details.planOrTier = "LiveKit API Key"
        if let id = parts.first, id.hasPrefix("API") {
            details.accountName = id
            details.balanceOrQuota = parts.count >= 2 ? "key:secret pair" : "key id only"
            return CheckResult(status: .valid, snippet: "Valid LiveKit key (\(id))", details: details)
        }
        return formatOnly("LiveKit Key", key: key, minLen: 16)
    }

    // 83. Figma
    private static func checkFigma(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.figma.com/v1/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "X-Figma-Token")
        return await httpCheckGenericBearer(req: req, provider: "Figma")
    }

    // 84. ClickUp
    private static func checkClickUp(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.clickup.com/api/v2/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "ClickUp")
    }

    // 85. Trello
    private static func checkTrello(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.trello.com/1/members/me?key=\(key)") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        let req = URLRequest(url: url, timeoutInterval: 10)
        return await httpCheckGenericBearer(req: req, provider: "Trello")
    }

    // 86. Typeform
    private static func checkTypeform(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.typeform.com/user") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Typeform")
    }

    // 87. Dropbox
    private static func checkDropbox(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.dropboxapi.com/2/users/get_current_account") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Dropbox")
    }

    // 88. Facebook — identity via /me, then granted permissions via /me/permissions.
    private static func checkFacebook(key: String) async -> CheckResult {
        let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        guard let url = URL(string: "https://graph.facebook.com/v19.0/me?fields=id,name,email&access_token=\(enc)") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(URLRequest(url: url, timeoutInterval: 10))
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["error"] == nil else {
                let snip = String(data: data.prefix(160), encoding: .utf8) ?? ""
                return CheckResult(status: .invalid, snippet: "Invalid Facebook token (\(snip.prefix(80)))")
            }
            var details = KeyDetails(); details.latencyMs = latency; details.httpCode = 200
            details.accountName = j["name"] as? String
            details.email = j["email"] as? String
            details.planOrTier = (j["id"] as? String).map { "User ID \($0)" }
            // Granted scopes for this token.
            if let pURL = URL(string: "https://graph.facebook.com/v19.0/me/permissions?access_token=\(enc)"),
               let (pd, _) = try? await APIKeyChecker.send(URLRequest(url: pURL, timeoutInterval: 6)),
               let pj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
               let arr = pj["data"] as? [[String: Any]] {
                let granted = arr.filter { ($0["status"] as? String) == "granted" }.compactMap { $0["permission"] as? String }
                if !granted.isEmpty { details.permissions = granted }
            }
            return CheckResult(status: .valid, snippet: "Valid Facebook token · \(details.accountName ?? "user")", details: details)
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    // 89. Firebase FCM
    private static func checkFirebaseFCM(key: String) async -> CheckResult {
        let type = key.hasPrefix("AAAA") ? "Legacy Server Key" : key.hasPrefix("AIza") ? "Web/Cloud API Key" : "Key"
        return formatOnly("Firebase FCM \(type)", key: key, minLen: 30)
    }

    // 90. Apify
    private static func checkApify(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.apify.com/v2/users/me?token=\(key)") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        let req = URLRequest(url: url, timeoutInterval: 10)
        return await httpCheckGenericBearer(req: req, provider: "Apify")
    }

    // 91. CapSolver
    private static func checkCapSolver(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.capsolver.com/getBalance") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["clientKey": key])
        return await httpCheckGenericBearer(req: req, provider: "CapSolver")
    }

    // 92. Riot Games (RGAPI- dev keys rotate every 24h)
    private static func checkRiot(key: String) async -> CheckResult {
        let type = key.hasPrefix("RGAPI-") ? "Development Key (24h rotating)" : "Production Key"
        return formatOnly("Riot Games \(type)", key: key, minLen: 20)
    }

    // 93. Spotify
    private static func checkSpotify(key: String) async -> CheckResult {
        guard let url = URL(string: "https://api.spotify.com/v1/me") else {
            return CheckResult(status: .error, snippet: "Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await httpCheckGenericBearer(req: req, provider: "Spotify")
    }

    // MARK: - Reusable HTTP Helpers

    private static func httpCheckModels(req: URLRequest, provider: String) async -> CheckResult {
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if code == 200 {
                var models: [String] = []
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) {
                    models = arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
                }
                var details = KeyDetails()
                details.models = models
                details.latencyMs = latency
                details.httpCode = 200
                details.rawSnippet = snippet
                details.planOrTier = "\(provider) API"
                details.balanceOrQuota = "\(models.count) models available"

                return CheckResult(status: .valid, snippet: "Valid (\(models.count) models)", details: details)
            } else if code == 401 {
                return CheckResult(status: .invalid, snippet: "Invalid \(provider) key (HTTP 401)")
            } else if code == 403 {
                // Authenticated but restricted — the key is real, just scoped/blocked.
                var d = KeyDetails(); d.latencyMs = latency; d.httpCode = 403; d.rawSnippet = snippet
                d.planOrTier = "\(provider) API (restricted)"
                return CheckResult(status: .permissionDenied, snippet: "\(provider) key valid but restricted (HTTP 403)", details: d)
            } else if code == 429 {
                return CheckResult(status: .rateLimited, snippet: "Rate limited (HTTP 429)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code): \(snippet.prefix(100))")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    private static func httpCheckGenericBearer(req: URLRequest, provider: String) async -> CheckResult {
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if (200...299).contains(code) {
                // Some APIs (GraphQL, Slack, etc.) return HTTP 200 with an error envelope in
                // the body — treat those as invalid rather than blindly trusting the 200.
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let errs = j["errors"] as? [Any], !errs.isEmpty {
                        return CheckResult(status: .invalid, snippet: "\(provider): \(snippet.prefix(80))")
                    }
                    if (j["ok"] as? Bool) == false || (j["success"] as? Bool) == false {
                        return CheckResult(status: .invalid, snippet: "\(provider): rejected (\(snippet.prefix(60)))")
                    }
                    if let err = j["error"] as? String, !err.isEmpty {
                        return CheckResult(status: .invalid, snippet: "\(provider): \(err.prefix(80))")
                    }
                }
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = code
                details.rawSnippet = snippet
                // Pull whatever account facts the provider returned (name/email/plan/status).
                enrichCommonFields(&details, from: data)
                let extra = details.accountName.map { " · \($0)" } ?? (details.email.map { " · \($0)" } ?? "")
                return CheckResult(status: .valid, snippet: "Valid \(provider) Key (HTTP \(code))\(extra)", details: details)
            } else if code == 401 || code == 403 {
                return CheckResult(status: .invalid, snippet: "Invalid \(provider) Key (HTTP \(code))")
            } else if code == 429 {
                return CheckResult(status: .rateLimited, snippet: "\(provider) rate limited (HTTP 429)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code)")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    /// Best-effort extractor: pulls common account fields (name, email, plan, status, balance)
    /// out of a JSON body regardless of the provider's exact schema. Enriches many providers at once.
    private static func enrichCommonFields(_ details: inout KeyDetails, from data: Data) {
        // Unwrap common envelopes: {data:{…}}, {account:{…}}, [{…}], {results:[{…}]}.
        func firstObject(_ any: Any?) -> [String: Any]? {
            if let d = any as? [String: Any] { return d }
            if let arr = any as? [[String: Any]] { return arr.first }
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return }
        var obj = firstObject(root) ?? [:]
        for wrap in ["data", "account", "user", "result", "results", "team", "profile", "app"] {
            if details.accountName == nil, let inner = firstObject(obj[wrap]) {
                // Prefer the inner object when the outer had no obvious name.
                if inner["name"] != nil || inner["email"] != nil || inner["username"] != nil || inner["login"] != nil {
                    obj = inner; break
                }
            }
        }
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = obj[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        if details.accountName == nil {
            details.accountName = str(["name", "username", "login", "display_name", "full_name", "company_name", "first_name", "nickname", "handle"])
        }
        if details.email == nil { details.email = str(["email", "email_address", "contact_email"]) }
        if details.planOrTier == nil {
            details.planOrTier = str(["plan", "plan_name", "tier", "type", "subscription", "account_type", "role"])
        }
        if details.balanceOrQuota == nil {
            if let b = str(["balance", "credits", "credit", "quota"]) { details.balanceOrQuota = b }
            else if let n = obj["balance"] as? NSNumber { details.balanceOrQuota = "Balance: \(n)" }
            else if let n = obj["credits"] as? NSNumber { details.balanceOrQuota = "Credits: \(n)" }
        }
        // Surface an account status flag if present (active/suspended/etc.).
        if details.planOrTier == nil, let status = str(["status", "state"]) {
            details.planOrTier = status.capitalized
        }
    }

    // MARK: - Offline enrichment helpers (for keys with no callable endpoint)

    /// Decode a JWT's payload (middle segment) without verifying the signature.
    static func decodeJWT(_ token: String) -> [String: Any]? {
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    /// Populate details from JWT claims (role, ref/project, issuer, expiry). Returns true if it was a JWT.
    static func enrichFromJWT(_ token: String, into details: inout KeyDetails) -> Bool {
        guard let claims = decodeJWT(token) else { return false }
        if let role = claims["role"] as? String { details.planOrTier = "Role: \(role)" }
        if details.accountName == nil {
            details.accountName = (claims["ref"] as? String).map { "Project: \($0)" }
                ?? (claims["iss"] as? String) ?? (claims["sub"] as? String)
        }
        if let exp = claims["exp"] as? Double {
            let d = Date(timeIntervalSince1970: exp)
            let expired = d < Date()
            details.balanceOrQuota = (expired ? "Expired " : "Expires ") + d.formatted(date: .abbreviated, time: .omitted)
        }
        // Surface a few notable claim keys as "permissions" so the UI shows structure.
        let notable = ["iss", "role", "ref", "aud", "scope", "scopes"]
        let present = notable.filter { claims[$0] != nil }
        if !present.isEmpty { details.permissions = present.map { "\($0)=\(claims[$0]!)".prefix(48).description } }
        return true
    }

    /// Structural fallback: mark a key valid-by-format with a helpful descriptor. Never claims a live check.
    private static func formatOnly(_ label: String, key: String, minLen: Int = 8, extra: String? = nil) -> CheckResult {
        var details = KeyDetails()
        // If it's actually a JWT, decode it for real detail.
        if enrichFromJWT(key, into: &details) {
            details.rawSnippet = "JWT-format \(label)"
            return CheckResult(status: .valid, snippet: "Valid \(label) (JWT · \(details.planOrTier ?? "decoded"))", details: details)
        }
        details.planOrTier = extra ?? label
        details.balanceOrQuota = "\(key.count) chars"
        guard key.count >= minLen, !key.contains(" ") else {
            return CheckResult(status: .invalid, snippet: "Invalid \(label) format")
        }
        return CheckResult(status: .valid, snippet: "Valid \(label) format (\(key.count) chars, not network-verified)", details: details)
    }

    private static func genericHTTPCheck(key: String, url: URL) async -> CheckResult {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await APIKeyChecker.send(req)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""

            if (200...299).contains(code) {
                var details = KeyDetails()
                details.latencyMs = latency
                details.httpCode = code
                details.rawSnippet = snippet
                enrichCommonFields(&details, from: data)
                let extra = details.accountName.map { " · \($0)" } ?? ""
                return CheckResult(status: .valid, snippet: "Valid (HTTP \(code))\(extra)", details: details)
            } else if code == 401 || code == 403 {
                return CheckResult(status: .invalid, snippet: "HTTP \(code) Unauthorized")
            } else if code == 429 {
                return CheckResult(status: .rateLimited, snippet: "Rate limited (HTTP 429)")
            } else {
                return CheckResult(status: .error, snippet: "HTTP \(code): \(snippet.prefix(100))")
            }
        } catch {
            return CheckResult(status: .error, snippet: error.localizedDescription)
        }
    }

    private static func checkGenericTokenFormat(key: String, service: String) -> CheckResult {
        var details = KeyDetails()
        details.planOrTier = "\(service.replacingOccurrences(of: "_", with: " ").capitalized) Token"
        if key.count >= 8 && !key.contains(" ") {
            return CheckResult(status: .valid, snippet: "Valid key format (\(key.count) chars)", details: details)
        }
        return CheckResult(status: .invalid, snippet: "Invalid key format")
    }
}
