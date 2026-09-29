import Foundation
import AppKit

// MARK: - Chromium Launcher (Remote-Debugging + DevTools Protocol cookie injection)
//
// Modern Chrome/Chromium (~v130+) no longer honors a plaintext `value` written
// directly into the Cookies SQLite file — it discards the row (and often rebuilds
// the whole database) because cookies must be encrypted with a Keychain-bound key.
//
// The robust, version-independent approach is to launch the browser with
// `--remote-debugging-port`, then set cookies over the DevTools Protocol
// (`Network.setCookies`) before navigating. This works on every current build.
//
// If no Chromium-family browser is installed, we can download an open-source
// Chromium snapshot on demand (with the user's consent).

enum ChromiumLauncherError: LocalizedError {
    case noBrowser
    case debuggerUnavailable
    case badResponse(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBrowser:            return "No Chromium-based browser found."
        case .debuggerUnavailable:  return "The browser did not expose a debugging endpoint in time."
        case .badResponse(let s):   return "DevTools error: \(s)"
        case .downloadFailed(let s):return "Chromium download failed: \(s)"
        }
    }
}

public final class ChromiumLauncher {
    public static let shared = ChromiumLauncher()
    private init() {}

    // Preference-ordered install locations for Chromium-family browsers.
    private static let knownBinaries: [String] = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
        "/Applications/Opera.app/Contents/MacOS/Opera",
        "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
        "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
        "/Applications/Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev",
    ]

    // MARK: Locating a browser

    /// First installed Chromium-family browser, if any.
    public func installedBinary() -> String? {
        Self.knownBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Path to a previously downloaded open-source Chromium, if present.
    public func downloadedBinary() -> String? {
        let bin = chromiumDir.appendingPathComponent("chrome-mac/Chromium.app/Contents/MacOS/Chromium").path
        return FileManager.default.isExecutableFile(atPath: bin) ? bin : nil
    }

    /// Any usable browser binary (installed first, then downloaded copy).
    public func anyBinary() -> String? {
        installedBinary() ?? downloadedBinary()
    }

    // MARK: Support directories

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CookieVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var chromiumDir: URL { supportDir.appendingPathComponent("chromium", isDirectory: true) }
    /// Ephemeral per-launch browser profiles (deleted when the browser closes).
    private var sessionsDir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("CookieVaultSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Deletes leftover session profiles (e.g. if a previous cleanup didn't run).
    static func sweepOldSessions() {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("CookieVaultSessions", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    // Browsers this app launched for cookie sessions, so we can terminate them on demand.
    private let launchLock = NSLock()
    private var launchedSessions: [Process] = []

    private func trackSession(_ p: Process) {
        launchLock.lock(); launchedSessions.append(p); launchLock.unlock()
    }

    /// Number of cookie-session browsers this app currently has running.
    public var runningSessionCount: Int {
        launchLock.lock(); defer { launchLock.unlock() }
        return launchedSessions.filter { $0.isRunning }.count
    }

    /// Kill every isolated cookie-session browser this app launched — WITHOUT touching the
    /// user's own Chrome. Terminates tracked processes, then `pkill`s any session browser by
    /// its unique profile marker (covers instances launched before an app restart), and sweeps
    /// the leftover profiles. Returns how many tracked processes were signalled.
    @discardableResult
    public func killAllSessions() -> Int {
        launchLock.lock()
        let procs = launchedSessions
        launchedSessions.removeAll()
        launchLock.unlock()

        var killed = 0
        for p in procs where p.isRunning { p.terminate(); killed += 1 }

        // Belt-and-braces: pkill anything whose command line carries our profile marker.
        // Only this app's session browsers use "CookieVaultSessions" in --user-data-dir, so
        // the user's regular Chrome windows are never affected.
        let pk = Process()
        pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pk.arguments = ["-f", "CookieVaultSessions"]
        try? pk.run(); pk.waitUntilExit()

        // Give processes a moment to exit, then remove their profiles.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { Self.sweepOldSessions() }
        return killed
    }

    // MARK: - Public launch entry point

    /// Launches a browser with a dedicated profile, injects `cookies` via DevTools,
    /// then navigates the visible tab to `targetURL`.
    /// - Parameter binary: explicit browser binary; falls back to `anyBinary()`.
    public func launch(cookies: [Cookie],
                       targetURL: URL,
                       profileKey: String,
                       binary: String? = nil,
                       progress: @escaping (String) -> Void) async throws {
        guard let bin = binary ?? anyBinary() else { throw ChromiumLauncherError.noBrowser }

        let port = Self.freePort()
        let safeKey = profileKey.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        // Ephemeral, unique profile fully isolated from the user's main browser — its
        // cookies live only for this session and are deleted when the browser closes.
        let profile = sessionsDir.appendingPathComponent("cv_\(safeKey.isEmpty ? "s" : safeKey)_\(UUID().uuidString)", isDirectory: true)

        progress("Starting browser…")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = [
            "--user-data-dir=\(profile.path)",
            "--remote-debugging-port=\(port)",
            "--remote-allow-origins=*",
            "--no-first-run",
            "--no-default-browser-check",
            "--no-service-autorun",
            "--password-store=basic",
            "--disable-sync",
            // Anti-bot-detection: hide the automation fingerprint that makes sites like
            // Patreon/Cloudflare invalidate the session the moment you interact with the page.
            "--disable-blink-features=AutomationControlled",
            "--exclude-switches=enable-automation",
            "--disable-features=IsolateOrigins,site-per-process,AutomationControlled",
            "about:blank",
        ]
        try task.run()
        trackSession(task)

        // When this isolated browser is closed, wipe its profile (and the injected cookies).
        Task.detached(priority: .background) {
            task.waitUntilExit()
            try? FileManager.default.removeItem(at: profile)
        }

        // Wait for the DevTools endpoint to come up.
        progress("Connecting to DevTools…")
        let wsURL = try await waitForDebugger(port: port, timeout: 20)

        // Drive CDP: create a tab, set cookies, navigate.
        let cdp = try await CDPClient.connect(wsURL: wsURL)
        defer { cdp.close() }

        progress("Opening session…")
        // Reuse the browser's initial tab if one exists, so we don't leave a stray
        // blank tab behind; only create one if none is available yet.
        var targetId: String? = nil
        for _ in 0..<20 {
            let res = try await cdp.send("Target.getTargets")
            if let infos = res["targetInfos"] as? [[String: Any]],
               let page = infos.first(where: { ($0["type"] as? String) == "page" }) {
                targetId = page["targetId"] as? String
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if targetId == nil {
            targetId = try await cdp.send("Target.createTarget", ["url": "about:blank"])["targetId"] as? String
        }
        guard let targetId else { throw ChromiumLauncherError.badResponse("no targetId") }
        let attached = try await cdp.send("Target.attachToTarget", ["targetId": targetId, "flatten": true])
        guard let sessionId = attached["sessionId"] as? String else {
            throw ChromiumLauncherError.badResponse("no sessionId")
        }

        _ = try await cdp.send("Network.enable", [:], sessionId: sessionId)
        _ = try? await cdp.send("Page.enable", [:], sessionId: sessionId)

        // Belt-and-braces stealth: also strip navigator.webdriver on every new document,
        // so the automation flag never appears to page scripts even if a flag is ignored.
        _ = try? await cdp.send("Page.addScriptToEvaluateOnNewDocument",
                                ["source": "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});"],
                                sessionId: sessionId)

        progress("Injecting \(cookies.count) cookies…")
        let params = Self.cookieParams(cookies)
        // Primary injection on the page session (this is the call that works on modern Chrome).
        _ = try await cdp.send("Network.setCookies", ["cookies": params], sessionId: sessionId)
        // Best-effort browser-wide copy so requests outside the page session carry them too.
        // Storage.setCookies is the correct browser-level method (Network.setCookies needs a session).
        _ = try? await cdp.send("Storage.setCookies", ["cookies": params])

        progress("Loading page…")
        _ = try await cdp.send("Page.navigate", ["url": targetURL.absoluteString], sessionId: sessionId)
    }

    /// Maps our `Cookie` model to CDP `Network.CookieParam` dictionaries.
    ///
    /// Key correctness details for keeping a session alive once you interact with the page:
    /// - `sameSite`: preserved from the export; when unknown we use `None` so the cookie is
    ///   sent on the SPA's cross-context fetch/XHR calls (a `Lax` default would drop it and
    ///   log you out on the first action). `SameSite=None` requires `Secure`, so we force it.
    /// - `url`: supplied so host-only cookies scope correctly instead of being rejected.
    private static func cookieParams(_ cookies: [Cookie]) -> [[String: Any]] {
        cookies.compactMap { c in
            let domain = c.domain.trimmingCharacters(in: .whitespaces)
            let bareHost = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            // Skip cookies with no usable host — a single bad entry would otherwise make CDP
            // reject the whole setCookies batch (which broke launching entirely).
            guard bareHost.contains(".") else { return nil }
            let hostOnly = !domain.hasPrefix(".")
            let path = c.path.isEmpty ? "/" : c.path

            // Resolve sameSite; default to None so auth cookies survive XHR/fetch after interaction.
            let ss: String
            switch (c.sameSite ?? "").lowercased() {
            case "lax": ss = "Lax"
            case "strict": ss = "Strict"
            default: ss = "None"
            }
            // SameSite=None mandates Secure; also force Secure on https hosts.
            let secure = c.secure || ss == "None"

            var p: [String: Any] = [
                "name": c.name,
                "value": c.value,
                "path": path,
                "secure": secure,
                "httpOnly": c.flag,
                "sameSite": ss,
            ]
            // Domain (dot-prefixed) cookies: explicit domain for subdomain coverage.
            // Host-only cookies: a url so CDP scopes them to just that host.
            if hostOnly {
                p["url"] = "https://\(bareHost)\(path)"
            } else {
                p["domain"] = domain
            }
            if let exp = c.expiry { p["expires"] = exp.timeIntervalSince1970 }
            return p
        }
    }

    // MARK: - DevTools discovery

    private func waitForDebugger(port: Int, timeout: TimeInterval) async throws -> URL {
        let versionURL = URL(string: "http://127.0.0.1:\(port)/json/version")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (data, resp) = try? await URLSession.shared.data(from: versionURL),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ws = json["webSocketDebuggerUrl"] as? String,
               let url = URL(string: ws) {
                return url
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ChromiumLauncherError.debuggerUnavailable
    }

    // MARK: - Open-source Chromium download

    /// Latest snapshot revision for this Mac's architecture.
    private var snapshotPlatform: String {
        #if arch(arm64)
        return "Mac_Arm"
        #else
        return "Mac"
        #endif
    }

    /// Downloads and unpacks an open-source Chromium snapshot. Returns the binary path.
    public func downloadChromium(progress: @escaping (Double, String) -> Void) async throws -> String {
        let base = "https://commondatastorage.googleapis.com/chromium-browser-snapshots/\(snapshotPlatform)"
        progress(0, "Finding latest Chromium…")
        guard let lastChangeURL = URL(string: "\(base)/LAST_CHANGE"),
              let (revData, _) = try? await URLSession.shared.data(from: lastChangeURL),
              let rev = String(data: revData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rev.isEmpty,
              let zipURL = URL(string: "\(base)/\(rev)/chrome-mac.zip") else {
            throw ChromiumLauncherError.downloadFailed("could not resolve snapshot URL")
        }

        progress(0, "Downloading Chromium (r\(rev))…")
        let tmpZip = try await Self.downloadFile(from: zipURL) { frac in
            progress(frac, "Downloading Chromium… \(Int(frac * 100))%")
        }

        progress(1, "Unpacking…")
        let fm = FileManager.default
        try? fm.removeItem(at: chromiumDir)
        try fm.createDirectory(at: chromiumDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", tmpZip.path, "-d", chromiumDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? fm.removeItem(at: tmpZip)

        guard let bin = downloadedBinary() else {
            throw ChromiumLauncherError.downloadFailed("binary not found after unzip")
        }

        // Remove the quarantine flag so the snapshot launches without a Gatekeeper prompt.
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", chromiumDir.appendingPathComponent("chrome-mac/Chromium.app").path]
        try? strip.run()
        strip.waitUntilExit()

        progress(1, "Chromium ready")
        return bin
    }

    /// Streams a download to a temp file, reporting fractional progress.
    private static func downloadFile(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    // MARK: - Free TCP port

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var res = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &res) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: res.sin_port))
        return port > 0 ? port : Int.random(in: 9200...9700)
    }
}

// MARK: - Download delegate (fractional progress → async result)

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var continuation: CheckedContinuation<URL, Error>?
    private let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move out of the delegate-owned temp location before the callback returns.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv_chromium_\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Minimal DevTools Protocol client over a WebSocket

private final class CDPClient {
    private let task: URLSessionWebSocketTask
    private var nextId = 0

    private init(task: URLSessionWebSocketTask) { self.task = task }

    static func connect(wsURL: URL) async throws -> CDPClient {
        var req = URLRequest(url: wsURL)
        // Recent Chrome rejects DevTools WebSocket upgrades from unexpected origins
        // unless --remote-allow-origins matches; send a localhost origin to be safe.
        req.setValue("http://127.0.0.1", forHTTPHeaderField: "Origin")
        let ws = URLSession(configuration: .default).webSocketTask(with: req)
        ws.resume()
        return CDPClient(task: ws)
    }

    /// Sends a CDP command and waits for its matching response, ignoring events.
    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:], sessionId: String? = nil) async throws -> [String: Any] {
        nextId += 1
        let id = nextId
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { message["sessionId"] = sessionId }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await task.send(.string(String(data: data, encoding: .utf8)!))

        // Read frames until the response with our id arrives.
        while true {
            let frame = try await task.receive()
            let text: String
            switch frame {
            case .string(let s): text = s
            case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
            @unknown default:    continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            if let responseId = obj["id"] as? Int, responseId == id {
                if let err = obj["error"] as? [String: Any] {
                    throw ChromiumLauncherError.badResponse((err["message"] as? String) ?? "\(err)")
                }
                return (obj["result"] as? [String: Any]) ?? [:]
            }
            // otherwise it's an event or another response — keep reading
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
