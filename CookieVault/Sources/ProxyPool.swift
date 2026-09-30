import Foundation

// MARK: - Proxy support for API-key checking
//
// Users hitting provider rate limits can add a pool of HTTP/HTTPS/SOCKS proxies. Each proxy
// becomes its own URLSession; the checker rotates requests across them (plus an optional
// direct session), so no single IP hammers a provider. Proxy auth (user:pass) is answered
// via a session delegate.

public struct ProxyConfig: Equatable {
    public var scheme: String   // "http" | "https" | "socks5"
    public var host: String
    public var port: Int
    public var user: String?
    public var pass: String?

    /// Parse the common proxy formats:
    ///   host:port
    ///   host:port:user:pass
    ///   user:pass@host:port
    ///   scheme://user:pass@host:port   (scheme = http/https/socks5)
    public static func parse(_ raw: String) -> ProxyConfig? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }

        var scheme = "http"
        if let r = s.range(of: "://") {
            scheme = String(s[..<r.lowerBound]).lowercased()
            s = String(s[r.upperBound...])
        }
        if scheme == "socks" { scheme = "socks5" }

        var user: String?, pass: String?
        // Credentials before an '@' (URL style).
        if let at = s.lastIndex(of: "@") {
            let creds = String(s[..<at])
            s = String(s[s.index(after: at)...])
            let cp = creds.split(separator: ":", maxSplits: 1).map(String.init)
            if cp.count == 2 { user = cp[0]; pass = cp[1] }
        }

        // Now s is host:port  OR (colon style) host:port:user:pass
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count >= 2, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        let host = parts[0]
        guard !host.isEmpty else { return nil }
        if user == nil, parts.count >= 4 { user = parts[2]; pass = parts[3] }

        return ProxyConfig(scheme: scheme, host: host, port: port, user: user, pass: pass)
    }

    /// A concise label for the UI (never shows the password).
    var label: String {
        let auth = user != nil ? "\(user!)@" : ""
        return "\(scheme)://\(auth)\(host):\(port)"
    }

    /// URLSession connectionProxyDictionary for this proxy.
    var proxyDictionary: [AnyHashable: Any] {
        switch scheme {
        case "socks5", "socks":
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        default:
            // HTTP + HTTPS via the same proxy. HTTPS keys are macOS string keys.
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port,
            ]
        }
    }
}

/// Answers proxy authentication challenges with the proxy's stored credentials.
final class ProxyAuthDelegate: NSObject, URLSessionTaskDelegate {
    private let user: String?
    private let pass: String?
    init(user: String?, pass: String?) { self.user = user; self.pass = pass }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let isProxy = space.isProxy() || space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
        if isProxy, challenge.previousFailureCount == 0, let user = user, let pass = pass {
            completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// A URLSession paired with its auth delegate. A URLSession created with a delegate keeps a
// STRONG reference to that delegate until the session is invalidated — so without the deinit
// below, every proxy-pool rebuild would leak a session + delegate. `finishTasksAndInvalidate()`
// lets any in-flight check complete before the session (and its delegate) are released.
final class ProxySession {
    let session: URLSession
    private let delegate: ProxyAuthDelegate?
    let label: String

    init(direct: Bool, config: ProxyConfig?) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 24
        cfg.timeoutIntervalForRequest = 14
        cfg.timeoutIntervalForResource = 22
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let config { cfg.connectionProxyDictionary = config.proxyDictionary }
        let del = config.map { ProxyAuthDelegate(user: $0.user, pass: $0.pass) }
        self.delegate = del
        self.session = URLSession(configuration: cfg, delegate: del, delegateQueue: nil)
        self.label = direct ? "direct" : (config?.label ?? "proxy")
    }

    deinit { session.finishTasksAndInvalidate() }
}
