import CryptoKit
import Foundation
import os

final class MCPAuditWriteQueue: @unchecked Sendable {
    static let shared = MCPAuditWriteQueue()

    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ entry: AuditEntry, into storage: MCPAuditLogStorage) {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        tail = Task {
            await previous?.value
            await storage.addEntry(entry)
        }
    }

    func flush() async {
        let pending = lock.withLock { tail }
        await pending?.value
    }
}

enum MCPAuditLogger {
    private static let serverAuth = Logger(subsystem: "com.TablePro", category: "MCPAuth")
    private static let serverAdmin = Logger(subsystem: "com.TablePro", category: "MCPAdmin")
    private static let serverQuery = Logger(subsystem: "com.TablePro", category: "MCPQuery")
    private static let serverTool = Logger(subsystem: "com.TablePro", category: "MCPTool")
    private static let serverResource = Logger(subsystem: "com.TablePro", category: "MCPResource")

    private static let messageExcerptLimit = 256

    static func flush() async {
        await MCPAuditWriteQueue.shared.flush()
    }

    static func logAuthSuccess(tokenId: UUID, tokenName: String?, ip: String) {
        serverAuth.info("Auth success: token=\(tokenId.uuidString, privacy: .public) ip=\(ip, privacy: .public)")
        record(
            category: .auth,
            tokenId: tokenId,
            tokenName: tokenName,
            action: "auth.success",
            outcome: .success,
            details: "ip=\(ip)"
        )
    }

    static func logAuthAllowedAnonymous(ip: String) {
        serverAuth.info("Auth allowed anonymously (loopback, requireAuthentication=false): ip=\(ip, privacy: .public)")
        record(
            category: .auth,
            action: "auth.anonymousLoopback",
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
        tokenId: UUID? = nil,
        tokenName: String? = nil,
        ip: String,
        details: String? = nil
    ) {
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
            tokenId: tokenId,
            tokenName: tokenName,
            action: "pairing.exchange",
            outcome: outcome,
            details: composeDetails(ip: ip, extra: details)
        )
    }

    static func logPairingRedirectRejected(clientName: String, ip: String, reason: String) {
        serverAuth.warning(
            "Pairing redirect rejected: client=\(clientName, privacy: .public) reason=\(reason, privacy: .public)"
        )
        record(
            category: .auth,
            tokenName: clientName,
            action: "pairing.redirectRejected",
            outcome: .denied,
            details: composeDetails(ip: ip, extra: "reason=\(reason)")
        )
    }

    static func logTokenCreated(tokenId: UUID, tokenName: String) {
        serverAdmin.info("Token created: \(tokenName, privacy: .public)")
        record(
            category: .admin,
            tokenId: tokenId,
            tokenName: tokenName,
            action: "token.created",
            outcome: .success
        )
    }

    static func logTokenRevoked(tokenId: UUID, tokenName: String) {
        serverAdmin.info("Token revoked: \(tokenName, privacy: .public)")
        record(
            category: .admin,
            tokenId: tokenId,
            tokenName: tokenName,
            action: "token.revoked",
            outcome: .success
        )
    }

    static func logServerStarted(port: UInt16) {
        serverAdmin.info(
            """
            MCP server started: port=\(port, privacy: .public)
            """
        )
        record(
            category: .admin,
            action: "server.started",
            outcome: .success,
            details: "port=\(port)"
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
        principal: MCPPrincipal,
        connectionId: UUID,
        sql: String,
        durationMs: Int,
        rowCount: Int,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        let digest = statementDigest(sql)
        serverQuery.info(
            """
            Query: token=\(principal.auditLabel ?? "-", privacy: .public) \
            connection=\(connectionId, privacy: .public) \
            duration=\(durationMs, privacy: .public)ms \
            rows=\(rowCount, privacy: .public) \
            outcome=\(outcome.rawValue, privacy: .public) \
            sqlDigest=\(digest, privacy: .public)
            """
        )

        var detailParts: [String] = [
            "duration=\(durationMs)ms",
            "rows=\(rowCount)",
            "sqlDigest=\(digest)"
        ]
        if let errorMessage {
            detailParts.append("error=\(truncate(errorMessage, to: messageExcerptLimit))")
        }

        record(
            category: .query,
            tokenId: principal.tokenId,
            tokenName: principal.auditLabel,
            connectionId: connectionId,
            action: "query.executed",
            outcome: outcome,
            details: detailParts.joined(separator: " ")
        )
    }

    static func logToolCalled(
        principal: MCPPrincipal,
        toolName: String,
        connectionId: UUID? = nil,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        serverTool.info(
            """
            Tool: token=\(principal.auditLabel ?? "-", privacy: .public) \
            tool=\(toolName, privacy: .public) \
            connection=\(connectionId?.uuidString ?? "-", privacy: .public) \
            outcome=\(outcome.rawValue, privacy: .public)
            """
        )

        var detailParts: [String] = ["tool=\(toolName)"]
        if let errorMessage {
            detailParts.append("error=\(truncate(errorMessage, to: messageExcerptLimit))")
        }

        record(
            category: .tool,
            tokenId: principal.tokenId,
            tokenName: principal.auditLabel,
            connectionId: connectionId,
            action: "tool.\(toolName)",
            outcome: outcome,
            details: detailParts.joined(separator: " ")
        )
    }

    static func logResourceRead(
        principal: MCPPrincipal,
        uri: String,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        serverResource.info(
            """
            Resource: token=\(principal.auditLabel ?? "-", privacy: .public) \
            uri=\(uri, privacy: .public) \
            outcome=\(outcome.rawValue, privacy: .public)
            """
        )

        var detailParts: [String] = ["uri=\(uri)"]
        if let errorMessage {
            detailParts.append("error=\(truncate(errorMessage, to: messageExcerptLimit))")
        }

        record(
            category: .resource,
            tokenId: principal.tokenId,
            tokenName: principal.auditLabel,
            action: "resource.read",
            outcome: outcome,
            details: detailParts.joined(separator: " ")
        )
    }

    static func statementDigest(_ sql: String) -> String {
        SHA256.hash(data: Data(sql.utf8)).hexEncoded
    }

    private static func composeDetails(ip: String, extra: String?) -> String {
        guard let extra, !extra.isEmpty else { return "ip=\(ip)" }
        return "ip=\(ip) \(extra)"
    }

    /// Records a call to an outside MCP server, before the request leaves.
    ///
    /// Written ahead of the call on purpose: a server that never answers has still been sent
    /// something, and an entry written on completion would miss exactly the calls worth auditing.
    /// The payload itself is not stored, only its SHA-256 and its byte count, following the same
    /// reasoning as `messageExcerptLimit`: production rows pass through these calls and the log is
    /// plain SQLite with 90-day retention.
    static func logOutboundToolCall(
        serverId: UUID,
        serverName: String,
        sessionId: UUID,
        connectionId: UUID?,
        toolName: String,
        payload: Data
    ) {
        serverTool.info(
            """
            Outbound MCP tool call: server=\(serverId.uuidString, privacy: .public) \
            tool=\(toolName, privacy: .public) bytes=\(payload.count, privacy: .public)
            """
        )
        record(
            category: .tool,
            connectionId: connectionId,
            action: "mcp.outbound.toolCall",
            outcome: .success,
            details: nil,
            outbound: AuditOutboundDetail(
                serverId: serverId,
                serverName: serverName,
                sessionId: sessionId,
                target: toolName,
                payloadSHA256: SHA256.hash(data: payload).hexEncoded,
                payloadBytes: payload.count
            )
        )
    }

    private static func record(
        category: AuditCategory,
        tokenId: UUID? = nil,
        tokenName: String? = nil,
        connectionId: UUID? = nil,
        action: String,
        outcome: AuditOutcome,
        details: String? = nil,
        outbound: AuditOutboundDetail? = nil
    ) {
        let entry = AuditEntry(
            category: category,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: action,
            outcome: outcome,
            details: details,
            outbound: outbound
        )
        MCPAuditWriteQueue.shared.enqueue(entry, into: MCPAuditLogStorage.shared)
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        let nsText = text as NSString
        guard nsText.length > limit else { return text }
        return nsText.substring(to: limit) + "…"
    }
}
