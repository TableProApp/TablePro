import Foundation

public enum MCPCorsHeaders {
    private static let allowedHosts: Set<String> = [
        "claude.ai",
        "app.cursor.com"
    ]

    private static let baseHeaders: [(String, String)] = [
        ("Access-Control-Allow-Methods", "POST, OPTIONS"),
        (
            "Access-Control-Allow-Headers",
            "Authorization, Content-Type, Accept, MCP-Protocol-Version, Mcp-Method, Mcp-Name, Mcp-Session-Id, *"
        ),
        ("Access-Control-Expose-Headers", "Mcp-Session-Id"),
        ("Access-Control-Max-Age", "86400")
    ]

    public static func headers(forOrigin origin: String?) -> [(String, String)] {
        guard let origin, !origin.isEmpty, isAllowed(origin: origin) else { return [] }
        var headers: [(String, String)] = [("Access-Control-Allow-Origin", origin)]
        headers.append(("Vary", "Origin"))
        headers.append(contentsOf: baseHeaders)
        return headers
    }

    public static func isAllowed(origin: String) -> Bool {
        guard let url = URL(string: origin),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.path.isEmpty else {
            return false
        }
        guard url.port == nil || url.port == 443 else { return false }
        return allowedHosts.contains(host)
    }
}
