import Foundation

public enum GoogleEndpointPolicy {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]

    private static let legacyTokenHost = "accounts.google.com"

    public static func isTrustedGoogleAPI(_ url: URL) -> Bool {
        guard let host = httpsHost(of: url) else { return false }
        return isGoogleAPIHost(host)
    }

    public static func isTrustedTokenEndpoint(_ url: URL) -> Bool {
        guard let host = httpsHost(of: url) else { return false }
        return isGoogleAPIHost(host) || host == legacyTokenHost
    }

    private static func httpsHost(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased()
        else {
            return nil
        }
        return host
    }

    private static func isGoogleAPIHost(_ host: String) -> Bool {
        host == "googleapis.com" || host.hasSuffix(".googleapis.com")
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }
}
