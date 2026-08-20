//
//  MCPAuthPolicyTests.swift
//  TableProTests
//
//  The protocol is stateless, so an approval can no longer hang off a session id: it is keyed on
//  the token that earned it and expires on its own. A second token inherits nothing, and revoking
//  a token drops the approvals it was carrying. Scope is enforced here too, not only in the
//  settings UI: an anonymous caller may not write and may not administer, whatever scopes it
//  claims to hold, and a refusal names the missing scope back to the client (RFC 6750
//  `insufficient_scope`).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MCP Auth Policy")
struct MCPAuthPolicyTests {
    private let connectionA = UUID()
    private let connectionB = UUID()

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

    private func makePolicy(
        _ snapshot: MCPConnectionAuthSnapshot?,
        ledger: MCPApprovalLedger = MCPApprovalLedger(clock: MCPTestClock()),
        connectionIds: Set<UUID> = []
    ) -> MCPAuthPolicy {
        MCPAuthPolicy(
            connectionResolver: { _ in snapshot },
            connectionIdsProvider: { connectionIds },
            approvalLedger: ledger
        )
    }

    private func makePolicy(
        resolver: @escaping MCPConnectionSnapshotResolver,
        connectionIds: Set<UUID>
    ) -> MCPAuthPolicy {
        MCPAuthPolicy(
            connectionResolver: resolver,
            connectionIdsProvider: { connectionIds },
            approvalLedger: MCPApprovalLedger(clock: MCPTestClock())
        )
    }

    private func makePrincipal(
        tokenId: UUID? = UUID(),
        scopes: Set<MCPScope> = MCPScope.fullAccessSet,
        connectionAccess: ConnectionAccess = .all,
        fingerprint: String = "fp"
    ) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
            scopes: scopes,
            connectionAccess: connectionAccess,
            metadata: MCPPrincipalMetadata(label: "token", issuedAt: .distantPast, expiresAt: nil)
        )
    }

    @Test("Blocked external access denies every tool that names the connection")
    func blockedConnectionDenied() async throws {
        let policy = makePolicy(makeSnapshot(externalAccess: .blocked))

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .denied = decision else {
            Issue.record("Expected denied for a blocked connection, got \(decision)")
            return
        }
    }

    @Test("A read-only connection refuses a write query and allows a read")
    func readOnlyConnectionRefusesWrites() async throws {
        let policy = makePolicy(makeSnapshot(externalAccess: .readOnly))
        let principal = makePrincipal()

        let write = try await policy.authorize(
            principal: principal,
            tool: "execute_query",
            connectionId: connectionA,
            sql: "UPDATE users SET name = 'x' WHERE id = 1"
        )
        let read = try await policy.authorize(
            principal: principal,
            tool: "execute_query",
            connectionId: connectionA,
            sql: "SELECT * FROM users"
        )

        guard case .denied = write else {
            Issue.record("Expected denied for a write on a read-only connection, got \(write)")
            return
        }
        guard case .allowed = read else {
            Issue.record("Expected allowed for a read on a read-only connection, got \(read)")
            return
        }
    }

    @Test("A token scoped to one connection is denied on another")
    func connectionScopingIsEnforced() async throws {
        let policy = makePolicy(makeSnapshot())
        let principal = makePrincipal(connectionAccess: .limited([connectionA]))

        let allowed = try await policy.authorize(principal: principal, tool: "list_tables", connectionId: connectionA)
        let denied = try await policy.authorize(principal: principal, tool: "list_tables", connectionId: connectionB)

        guard case .allowed = allowed else {
            Issue.record("Expected allowed inside the token's scope, got \(allowed)")
            return
        }
        guard case .denied = denied else {
            Issue.record("Expected denied outside the token's scope, got \(denied)")
            return
        }
    }

    @Test("An AI policy of never denies the connection outright")
    func aiPolicyNeverDenies() async throws {
        let policy = makePolicy(makeSnapshot(policy: .never))

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .denied = decision else {
            Issue.record("Expected denied for an AI policy of never, got \(decision)")
            return
        }
    }

    @Test("An unknown connection is denied")
    func unknownConnectionDenied() async throws {
        let policy = makePolicy(nil)

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .denied = decision else {
            Issue.record("Expected denied for an unknown connection, got \(decision)")
            return
        }
    }

    @Test("A tool that names no connection only has to clear the scope check")
    func toolWithoutConnectionIsAllowed() async throws {
        let policy = makePolicy(nil)

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_connections",
            connectionId: nil
        )

        guard case .allowed = decision else {
            Issue.record("Expected allowed for a tool with no connection target, got \(decision)")
            return
        }
    }

    @Test("An anonymous caller may not run the destructive-confirmation tool, admin scope or not")
    func anonymousIsRefusedTheAdminTool() async throws {
        let policy = makePolicy(makeSnapshot())

        let decision = try await policy.authorize(
            principal: makePrincipal(tokenId: nil, scopes: MCPScope.fullAccessSet),
            tool: "confirm_destructive_operation",
            connectionId: connectionA
        )

        guard case .deniedInsufficientScope(let required, _) = decision else {
            Issue.record("Expected an insufficient scope refusal for an anonymous caller, got \(decision)")
            return
        }
        #expect(required == [.admin])
    }

    @Test("An issued token without the admin scope may not run the destructive-confirmation tool")
    func readWriteTokenIsRefusedTheAdminTool() async throws {
        let policy = makePolicy(makeSnapshot())

        let decision = try await policy.authorize(
            principal: makePrincipal(scopes: MCPScope.readWriteSet),
            tool: "confirm_destructive_operation",
            connectionId: connectionA
        )

        guard case .deniedInsufficientScope(let required, _) = decision else {
            Issue.record("Expected an insufficient scope refusal, got \(decision)")
            return
        }
        #expect(required == [.admin])
    }

    @Test("An anonymous caller may not write, even carrying the write scope")
    func anonymousIsRefusedAWrite() async throws {
        let policy = makePolicy(makeSnapshot())

        let decision = try await policy.authorize(
            principal: makePrincipal(tokenId: nil, scopes: MCPScope.readWriteSet),
            tool: "execute_query",
            connectionId: connectionA,
            sql: "DELETE FROM users WHERE id = 1"
        )

        guard case .deniedInsufficientScope(let required, _) = decision else {
            Issue.record("Expected an insufficient scope refusal for an anonymous write, got \(decision)")
            return
        }
        #expect(required == [.toolsWrite])
    }

    @Test("A read-only token may not write")
    func readOnlyTokenIsRefusedAWrite() async throws {
        let policy = makePolicy(makeSnapshot())

        let decision = try await policy.authorize(
            principal: makePrincipal(scopes: MCPScope.readOnlySet),
            tool: "execute_query",
            connectionId: connectionA,
            sql: "INSERT INTO users (name) VALUES ('x')"
        )

        guard case .deniedInsufficientScope(let required, _) = decision else {
            Issue.record("Expected an insufficient scope refusal, got \(decision)")
            return
        }
        #expect(required == [.toolsWrite])
    }

    @Test("A read-only token still reads")
    func readOnlyTokenStillReads() async throws {
        let policy = makePolicy(makeSnapshot())

        let decision = try await policy.authorize(
            principal: makePrincipal(scopes: MCPScope.readOnlySet),
            tool: "execute_query",
            connectionId: connectionA,
            sql: "SELECT 1"
        )

        guard case .allowed = decision else {
            Issue.record("Expected a read to be allowed for a read-only token, got \(decision)")
            return
        }
    }

    @Test("A scope refusal reaches the client as a 403 naming the scope it needed")
    func scopeRefusalCarriesTheChallenge() async throws {
        let policy = makePolicy(makeSnapshot())

        do {
            try await policy.resolveAndAuthorize(
                principal: makePrincipal(scopes: MCPScope.readOnlySet),
                tool: "execute_query",
                connectionId: connectionA,
                sql: "UPDATE users SET name = 'x' WHERE id = 1"
            )
            Issue.record("Expected the write to be refused")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.forbidden)
            #expect(error.httpStatus.code == 403)
            let header = try #require(error.extraHeaders.first(where: { $0.0 == "WWW-Authenticate" })?.1)
            #expect(header.contains("realm=\"TablePro\""))
            #expect(header.contains("error=\"insufficient_scope\""))
            #expect(header.contains("scope=\"tools:write\""))
            #expect(error.data?["requiredScopes"] == JsonValue.array([.string("tools:write")]))
        }
    }

    @Test("A connection set to ask each time asks the first time")
    func askEachTimeRequiresApproval() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .requiresUserApproval = decision else {
            Issue.record("Expected an approval requirement, got \(decision)")
            return
        }
    }

    @Test("A recorded approval covers the token that earned it")
    func recordedApprovalAllowsTheConnection() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        let principal = makePrincipal()
        await policy.recordApproval(principal: principal, connectionId: connectionA)

        let decision = try await policy.authorize(
            principal: principal,
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .allowed = decision else {
            Issue.record("Expected an approved connection to be allowed, got \(decision)")
            return
        }
    }

    @Test("A second token inherits nothing from the first token's approval")
    func approvalDoesNotTransferToAnotherToken() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        let approved = makePrincipal(fingerprint: "approved")
        await policy.recordApproval(principal: approved, connectionId: connectionA)

        let decision = try await policy.authorize(
            principal: makePrincipal(fingerprint: "other"),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .requiresUserApproval = decision else {
            Issue.record("Expected a second token to be asked on its own, got \(decision)")
            return
        }
    }

    @Test("An approval covers only the connection it was given for")
    func approvalIsPerConnection() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        let principal = makePrincipal()
        await policy.recordApproval(principal: principal, connectionId: connectionA)

        let decision = try await policy.authorize(
            principal: principal,
            tool: "list_tables",
            connectionId: connectionB
        )

        guard case .requiresUserApproval = decision else {
            Issue.record("Expected another connection to be asked separately, got \(decision)")
            return
        }
    }

    @Test("Revoking a token clears the approvals it was carrying and leaves the others alone")
    func clearingApprovalsFollowsTheToken() async throws {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let policy = makePolicy(makeSnapshot(policy: .askEachTime), ledger: ledger)
        let revoked = makePrincipal(fingerprint: "revoked")
        let survivor = makePrincipal(fingerprint: "survivor")
        await policy.recordApproval(principal: revoked, connectionId: connectionA)
        await policy.recordApproval(principal: survivor, connectionId: connectionA)

        await policy.clearApprovals(tokenId: revoked.tokenId)

        let afterRevocation = try await policy.authorize(
            principal: revoked,
            tool: "list_tables",
            connectionId: connectionA
        )
        let untouched = try await policy.authorize(
            principal: survivor,
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .requiresUserApproval = afterRevocation else {
            Issue.record("Expected the revoked token to be asked again, got \(afterRevocation)")
            return
        }
        guard case .allowed = untouched else {
            Issue.record("Expected an unrelated token to keep its approval, got \(untouched)")
            return
        }
    }

    @Test("An approval expires on its own")
    func approvalExpires() async throws {
        let clock = MCPTestClock()
        let policy = makePolicy(
            makeSnapshot(policy: .askEachTime),
            ledger: MCPApprovalLedger(ttl: .seconds(1_800), clock: clock)
        )
        let principal = makePrincipal()
        await policy.recordApproval(principal: principal, connectionId: connectionA)

        await clock.advance(by: .seconds(1_801))

        let decision = try await policy.authorize(
            principal: principal,
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .requiresUserApproval = decision else {
            Issue.record("Expected an expired approval to be asked again, got \(decision)")
            return
        }
    }

    @Test("Clearing every approval asks each token again")
    func clearingAllApprovals() async throws {
        let policy = makePolicy(makeSnapshot(policy: .askEachTime))
        let principal = makePrincipal()
        await policy.recordApproval(principal: principal, connectionId: connectionA)

        await policy.clearAllApprovals()

        let decision = try await policy.authorize(
            principal: principal,
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .requiresUserApproval = decision else {
            Issue.record("Expected every approval to be dropped, got \(decision)")
            return
        }
    }

    @Test("An aggregate read sees only the connections the token could have named directly")
    func readableConnectionsFollowTheSameRules() async {
        let blocked = UUID()
        let refused = UUID()
        let outOfScope = UUID()
        let visible = UUID()
        let snapshots: [UUID: MCPConnectionAuthSnapshot] = [
            blocked: makeSnapshot(externalAccess: .blocked),
            refused: makeSnapshot(policy: .never),
            outOfScope: makeSnapshot(),
            visible: makeSnapshot()
        ]
        let policy = makePolicy(
            resolver: { snapshots[$0] },
            connectionIds: [blocked, refused, outOfScope, visible, UUID()]
        )

        let readable = await policy.readableConnectionIds(
            principal: makePrincipal(connectionAccess: .limited([blocked, refused, visible]))
        )

        #expect(readable == [visible])
    }
}
