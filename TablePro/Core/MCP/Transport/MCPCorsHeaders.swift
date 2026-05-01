import Foundation

public enum MCPCorsHeaders {
    public static let standard: [(String, String)] = [
        ("Access-Control-Allow-Origin", "http://localhost"),
        ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
        (
            "Access-Control-Allow-Headers",
            "Content-Type, Mcp-Session-Id, mcp-protocol-version, Authorization, Last-Event-ID"
        ),
        ("Access-Control-Expose-Headers", "Mcp-Session-Id"),
        ("Access-Control-Max-Age", "86400")
    ]

    public static func corsHeaders(allowingOrigin origin: String) -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", origin),
            ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
            (
                "Access-Control-Allow-Headers",
                "Content-Type, Mcp-Session-Id, mcp-protocol-version, Authorization, Last-Event-ID"
            ),
            ("Access-Control-Expose-Headers", "Mcp-Session-Id"),
            ("Access-Control-Max-Age", "86400")
        ]
    }
}
