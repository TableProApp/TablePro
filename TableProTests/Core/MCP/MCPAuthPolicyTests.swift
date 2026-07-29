import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MCP Auth Policy")
struct MCPAuthPolicyTests {
    private let connectionA = UUID()
    private let connectionB = UUID()

    private func makePolicy(_ snapshot: MCPConnectionAuthSnapshot?) -> MCPAuthPolicy {
        MCPAuthPolicy(connectionResolver: { _ in snapshot })
    }

    private func makeSnapshot(
        externalAccess: ExternalAccessLevel = .readWrite,
        policy: AIConnectionPolicy = .alwaysAllow
    ) -> MCPConnectionAuthSnapshot {
        MCPConnectionAuthSnapshot(
            policy: policy,
            externalAccess: externalAccess,
            name: "Test Connection",
            databaseType: DatabaseType.postgresql.rawValue
        )
    }

    private func makePrincipal(connectionAccess: ConnectionAccess = .all) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: "fp",
            tokenId: UUID(),
            scopes: [.toolsRead, .toolsWrite, .resourcesRead, .admin],
            connectionAccess: connectionAccess,
            metadata: MCPPrincipalMetadata(label: "token", issuedAt: .distantPast, expiresAt: nil)
        )
    }

    @Test("Blocked external access denies any connection tool")
    func blockedConnectionDenied() async throws {
        let policy = makePolicy(makeSnapshot(externalAccess: .blocked))
        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .denied = decision else {
            Issue.record("Expected denied for blocked connection, got \(decision)")
            return
        }
    }

    @Test("Read-only external access denies a write query")
    func readOnlyDeniesWrite() async throws {
        let policy = makePolicy(makeSnapshot(externalAccess: .readOnly))
        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "execute_query",
            connectionId: connectionA,
            sql: "UPDATE users SET name = 'x' WHERE id = 1",
            sessionId: "session"
        )
        guard case .denied = decision else {
            Issue.record("Expected denied for write on read-only connection, got \(decision)")
            return
        }
    }

    @Test("Read-only external access allows a read query")
    func readOnlyAllowsRead() async throws {
        let policy = makePolicy(makeSnapshot(externalAccess: .readOnly))
        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "execute_query",
            connectionId: connectionA,
            sql: "SELECT * FROM users",
            sessionId: "session"
        )
        guard case .allowed = decision else {
            Issue.record("Expected allowed for read on read-only connection, got \(decision)")
            return
        }
    }

    @Test("Token scoped to one connection is denied on another")
    func connectionScopingDeniesOtherConnection() async throws {
        let policy = makePolicy(makeSnapshot())
        let decision = try await policy.authorize(
            principal: makePrincipal(connectionAccess: .limited([connectionA])),
            tool: "list_tables",
            connectionId: connectionB,
            sql: nil,
            sessionId: "session"
        )
        guard case .denied = decision else {
            Issue.record("Expected denied for connection outside token scope, got \(decision)")
            return
        }
    }

    @Test("Token scoped to a connection is allowed on that connection")
    func connectionScopingAllowsScopedConnection() async throws {
        let policy = makePolicy(makeSnapshot())
        let decision = try await policy.authorize(
            principal: makePrincipal(connectionAccess: .limited([connectionA])),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .allowed = decision else {
            Issue.record("Expected allowed for connection within token scope, got \(decision)")
            return
        }
    }

    @Test("AI policy never denies access")
    func aiPolicyNeverDenied() async throws {
        let policy = makePolicy(makeSnapshot(policy: .never))
        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .denied = decision else {
            Issue.record("Expected denied for AI policy never, got \(decision)")
            return
        }
    }

    @Test("AI policy ask-each-time requires user approval")
    func aiPolicyAskEachTimeRequiresApproval() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .requiresUserApproval = decision else {
            Issue.record("Expected approval requirement for ask-each-time, got \(decision)")
            return
        }
    }

    @Test("Recorded approval allows the connection for the rest of the session")
    func recordedApprovalAllowsConnection() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        await policy.recordApproval(sessionId: "session", connectionId: connectionA)

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .allowed = decision else {
            Issue.record("Expected an approved connection to be allowed, got \(decision)")
            return
        }
    }

    @Test("Clearing a terminated session drops its approvals")
    func clearSessionDropsApprovals() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        await policy.recordApproval(sessionId: "session", connectionId: connectionA)
        await policy.clearSession("session")

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .requiresUserApproval = decision else {
            Issue.record("Expected approval to be required again after the session was cleared, got \(decision)")
            return
        }
    }

    @Test("Clearing an unknown session is a no-op")
    func clearUnknownSessionIsNoOp() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        await policy.recordApproval(sessionId: "session", connectionId: connectionA)
        await policy.clearSession("other-session")

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .allowed = decision else {
            Issue.record("Clearing another session must not drop this session's approvals, got \(decision)")
            return
        }
    }

    @Test("Unknown connection denies")
    func unknownConnectionDenied() async throws {
        let policy = makePolicy(nil)
        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA,
            sql: nil,
            sessionId: "session"
        )
        guard case .denied = decision else {
            Issue.record("Expected denied for unknown connection, got \(decision)")
            return
        }
    }

    @Test("No connection target only requires token scopes")
    func noConnectionAllows() async throws {
        let policy = makePolicy(nil)
        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_connections",
            connectionId: nil,
            sql: nil,
            sessionId: "session"
        )
        guard case .allowed = decision else {
            Issue.record("Expected allowed for tool without a connection target, got \(decision)")
            return
        }
    }
}
