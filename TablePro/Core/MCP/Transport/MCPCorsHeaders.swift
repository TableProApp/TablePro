import Foundation

public enum MCPCorsHeaders {
    private static let allowedHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "claude.ai",
        "app.cursor.com"
    ]

    private static let baseHeaders: [(String, String)] = [
        ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
        (
            "Access-Control-Allow-Headers",
            "Content-Type, Mcp-Session-Id, mcp-protocol-version, Authorization, Last-Event-ID"
        ),
        ("Access-Control-Expose-Headers", "Mcp-Session-Id"),
        ("Access-Control-Max-Age", "86400")
    ]

    public static func headers(forOrigin origin: String?) -> [(String, String)] {
        guard let origin, !origin.isEmpty else { return [] }
        guard isAllowed(origin: origin) else { return [] }
        var headers: [(String, String)] = [("Access-Control-Allow-Origin", origin)]
        headers.append(("Vary", "Origin"))
        headers.append(contentsOf: baseHeaders)
        return headers
    }

    public static func isAllowed(origin: String) -> Bool {
        guard let url = URL(string: origin),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }
        guard scheme == "http" || scheme == "https" else { return false }
        return allowedHosts.contains(host)
    }
}
