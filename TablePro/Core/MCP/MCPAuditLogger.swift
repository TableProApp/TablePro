import Foundation
import os

enum MCPAuditLogger {
    private static let serverAuth = Logger(subsystem: "com.TablePro", category: "MCPAuth")
    private static let serverAccess = Logger(subsystem: "com.TablePro", category: "MCPAccess")
    private static let serverAdmin = Logger(subsystem: "com.TablePro", category: "MCPAdmin")

    static func logAuthSuccess(tokenName: String, ip: String) {
        serverAuth.info("Auth success: token=\(tokenName, privacy: .public) ip=\(ip, privacy: .public)")
    }

    static func logAuthFailure(reason: String, ip: String) {
        serverAuth.warning("Auth failure: reason=\(reason, privacy: .public) ip=\(ip, privacy: .public)")
    }

    static func logRateLimited(ip: String, retryAfterSeconds: Int) {
        serverAuth.warning(
            "Rate limited: ip=\(ip, privacy: .public) retryAfter=\(retryAfterSeconds, privacy: .public)s"
        )
    }

    static func logTokenCreated(tokenName: String) {
        serverAdmin.info("Token created: \(tokenName, privacy: .public)")
    }

    static func logTokenRevoked(tokenName: String) {
        serverAdmin.info("Token revoked: \(tokenName, privacy: .public)")
    }

    static func logServerStarted(port: UInt16, remoteAccess: Bool, tlsEnabled: Bool) {
        serverAdmin.info(
            "MCP server started: port=\(port, privacy: .public) remote=\(remoteAccess, privacy: .public) tls=\(tlsEnabled, privacy: .public)"
        )
    }

    static func logServerStopped() {
        serverAdmin.info("MCP server stopped")
    }
}
