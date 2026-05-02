import Foundation
import os

enum MCPAuditLogger {
    private static let serverAuth = Logger(subsystem: "com.TablePro", category: "MCPAuth")
    private static let serverAccess = Logger(subsystem: "com.TablePro", category: "MCPAccess")
    private static let serverAdmin = Logger(subsystem: "com.TablePro", category: "MCPAdmin")
    private static let serverQuery = Logger(subsystem: "com.TablePro", category: "MCPQuery")
    private static let serverTool = Logger(subsystem: "com.TablePro", category: "MCPTool")
    private static let serverResource = Logger(subsystem: "com.TablePro", category: "MCPResource")

    private static let sqlExcerptLimit = 256

    static func logAuthSuccess(tokenName: String, ip: String) {
        serverAuth.info("Auth success: token=\(tokenName, privacy: .public) ip=\(ip, privacy: .public)")
        record(
            category: .auth,
            tokenName: tokenName,
            action: "auth.success",
            outcome: .success,
            details: "ip=\(ip)"
        )
    }

    static func logAuthFailure(reason: String, ip: String) {
        serverAuth.warning("Auth failure: reason=\(reason, privacy: .public) ip=\(ip, privacy: .public)")
        record(
            category: .auth,
            action: "auth.failure",
            outcome: .denied,
            details: "ip=\(ip) reason=\(reason)"
        )
    }

    static func logRateLimited(ip: String, retryAfterSeconds: Int) {
        serverAuth.warning(
            "Rate limited: ip=\(ip, privacy: .public) retryAfter=\(retryAfterSeconds, privacy: .public)s"
        )
        record(
            category: .auth,
            action: "auth.rateLimited",
            outcome: .rateLimited,
            details: "ip=\(ip) retryAfter=\(retryAfterSeconds)s"
        )
    }

    static func logPairingExchange(
        outcome: AuditOutcome,
        tokenName: String? = nil,
        ip: String,
        details: String? = nil
    ) {
        let resolvedDetails = Self.composePairingDetails(ip: ip, extra: details)
        switch outcome {
        case .success:
            serverAuth.info(
                "Pairing exchange success: token=\(tokenName ?? "-", privacy: .public) ip=\(ip, privacy: .public)"
            )
        case .denied:
            serverAuth.warning(
                "Pairing exchange denied: ip=\(ip, privacy: .public) details=\(details ?? "-", privacy: .public)"
            )
        case .rateLimited:
            serverAuth.warning("Pairing exchange rate limited: ip=\(ip, privacy: .public)")
        case .error:
            serverAuth.error(
                "Pairing exchange error: ip=\(ip, privacy: .public) details=\(details ?? "-", privacy: .public)"
            )
        }
        record(
            category: .auth,
            tokenName: tokenName,
            action: "pairing.exchange",
            outcome: outcome,
            details: resolvedDetails
        )
    }

    private static func composePairingDetails(ip: String, extra: String?) -> String {
        guard let extra, !extra.isEmpty else {
            return "ip=\(ip)"
        }
        return "ip=\(ip) \(extra)"
    }

    static func logTokenCreated(tokenName: String) {
        serverAdmin.info("Token created: \(tokenName, privacy: .public)")
        record(
            category: .admin,
            tokenName: tokenName,
            action: "token.created",
            outcome: .success
        )
    }

    static func logTokenRevoked(tokenName: String) {
        serverAdmin.info("Token revoked: \(tokenName, privacy: .public)")
        record(
            category: .admin,
            tokenName: tokenName,
            action: "token.revoked",
            outcome: .success
        )
    }

    static func logServerStarted(port: UInt16, remoteAccess: Bool, tlsEnabled: Bool) {
        serverAdmin.info(
            "MCP server started: port=\(port, privacy: .public) remote=\(remoteAccess, privacy: .public) tls=\(tlsEnabled, privacy: .public)"
        )
        record(
            category: .admin,
            action: "server.started",
            outcome: .success,
            details: "port=\(port) remote=\(remoteAccess) tls=\(tlsEnabled)"
        )
    }

    static func logServerStopped() {
        serverAdmin.info("MCP server stopped")
        record(
            category: .admin,
            action: "server.stopped",
            outcome: .success
        )
    }

    static func logQueryExecuted(
        tokenId: UUID?,
        tokenName: String?,
        connectionId: UUID,
        sql: String,
        durationMs: Int,
        rowCount: Int,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        serverQuery.info(
            """
            Query: token=\(tokenName ?? "-", privacy: .public) \
            connection=\(connectionId, privacy: .public) \
            duration=\(durationMs, privacy: .public)ms \
            rows=\(rowCount, privacy: .public) \
            outcome=\(outcome.rawValue, privacy: .public) \
            sql=\(sql, privacy: .private)
            """
        )

        var detailParts: [String] = [
            "duration=\(durationMs)ms",
            "rows=\(rowCount)",
            "sql=\(truncate(sql, to: sqlExcerptLimit))"
        ]
        if let errorMessage {
            detailParts.append("error=\(truncate(errorMessage, to: 256))")
        }

        record(
            category: .query,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: "query.executed",
            outcome: outcome,
            details: detailParts.joined(separator: " ")
        )
    }

    static func logToolCalled(
        tokenId: UUID?,
        tokenName: String?,
        toolName: String,
        connectionId: UUID? = nil,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        serverTool.info(
            """
            Tool: token=\(tokenName ?? "-", privacy: .public) \
            tool=\(toolName, privacy: .public) \
            connection=\(connectionId?.uuidString ?? "-", privacy: .public) \
            outcome=\(outcome.rawValue, privacy: .public)
            """
        )

        var detailParts: [String] = ["tool=\(toolName)"]
        if let errorMessage {
            detailParts.append("error=\(truncate(errorMessage, to: 256))")
        }

        record(
            category: .tool,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: "tool.\(toolName)",
            outcome: outcome,
            details: detailParts.joined(separator: " ")
        )
    }

    static func logResourceRead(
        tokenId: UUID?,
        tokenName: String?,
        uri: String,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        serverResource.info(
            """
            Resource: token=\(tokenName ?? "-", privacy: .public) \
            uri=\(uri, privacy: .public) \
            outcome=\(outcome.rawValue, privacy: .public)
            """
        )

        var detailParts: [String] = ["uri=\(uri)"]
        if let errorMessage {
            detailParts.append("error=\(truncate(errorMessage, to: 256))")
        }

        record(
            category: .resource,
            tokenId: tokenId,
            tokenName: tokenName,
            action: "resource.read",
            outcome: outcome,
            details: detailParts.joined(separator: " ")
        )
    }

    private static func record(
        category: AuditCategory,
        tokenId: UUID? = nil,
        tokenName: String? = nil,
        connectionId: UUID? = nil,
        action: String,
        outcome: AuditOutcome,
        details: String? = nil
    ) {
        let entry = AuditEntry(
            category: category,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: action,
            outcome: outcome,
            details: details
        )
        Task {
            await MCPAuditLogStorage.shared.addEntry(entry)
        }
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        let nsText = text as NSString
        guard nsText.length > limit else { return text }
        let prefix = nsText.substring(to: limit)
        return prefix + "..."
    }
}
