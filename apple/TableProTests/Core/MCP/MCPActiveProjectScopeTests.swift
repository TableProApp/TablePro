import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import TableProPluginKit
import Testing

struct MCPActiveProjectScopeTests {
    private let inProject = UUID()
    private let outside = UUID()

    private func policy(
        scope: Set<UUID>?,
        externalAccess: ExternalAccessLevel = .readWrite,
        policy: AIConnectionPolicy = .alwaysAllow
    ) -> MCPAuthPolicy {
        let snapshot = MCPConnectionAuthSnapshot(
            policy: policy,
            externalAccess: externalAccess,
            name: "Test Connection",
            databaseType: DatabaseType.postgresql.rawValue
        )
        return MCPAuthPolicy(
            connectionResolver: { _ in snapshot },
            connectionIdsProvider: { [inProject, outside] in [inProject, outside] },
            activeProjectScope: { scope },
            approvalLedger: MCPApprovalLedger(clock: MCPTestClock(), store: MCPInMemoryApprovalStore()),
            approvalSetting: MCPFixedApprovalReader(.oncePerConnection),
            presenter: RecordingApprovalPresenter(answer: false)
        )
    }

    private func token(
        connectionAccess: ConnectionAccess = .all,
        isBridge: Bool = false,
        isClaudeAgent: Bool = false
    ) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: "fp",
            tokenId: UUID(),
            scopes: MCPScope.fullAccessSet,
            connectionAccess: connectionAccess,
            metadata: MCPPrincipalMetadata(
                label: "token",
                issuedAt: .distantPast,
                expiresAt: nil,
                isBridgeCredential: isBridge,
                isClaudeAgentCredential: isClaudeAgent
            )
        )
    }

    private func reason(_ decision: AuthDecision) -> String? {
        if case .denied(let reason) = decision { return reason }
        return nil
    }

    @Test("A token is refused a connection outside the active project, with a reason that names the project")
    func outsideTheProjectIsRefused() async throws {
        let policy = policy(scope: [inProject])

        let refused = try await policy.authorize(principal: token(), tool: "list_tables", connectionId: outside)
        let allowed = try await policy.authorize(principal: token(), tool: "list_tables", connectionId: inProject)

        #expect(reason(refused) == MCPAuthPolicy.outsideActiveProjectRefusal)
        #expect(reason(refused) != String(localized: "Connection not found"))
        guard case .allowed = allowed else {
            Issue.record("Expected a connection of the active project to be allowed, got \(allowed)")
            return
        }
    }

    @Test("The refusal reaches the client as a forbidden error, never as a prompt")
    func refusalThrowsForbidden() async {
        let policy = policy(scope: [inProject], policy: .askEachTime)

        do {
            try await policy.resolveAndAuthorize(principal: token(), tool: "list_tables", connectionId: outside)
            Issue.record("Expected a refusal for a connection outside the active project")
        } catch DatabaseAccessError.forbidden(let reason, _) {
            #expect(reason == MCPAuthPolicy.outsideActiveProjectRefusal)
        } catch {
            Issue.record("Expected a forbidden error, got \(error)")
        }
    }

    @Test("In All Connections a token reaches every connection its other checks allow")
    func allConnectionsRefusesNothing() async throws {
        let decision = try await policy(scope: nil).authorize(
            principal: token(), tool: "list_tables", connectionId: outside
        )

        guard case .allowed = decision else {
            Issue.record("Expected allowed in All Connections, got \(decision)")
            return
        }
    }

    @Test("The stdio bridge follows the active project like any other outside client")
    func bridgeCredentialFollowsTheProject() async throws {
        let decision = try await policy(scope: [inProject]).authorize(
            principal: token(isBridge: true), tool: "list_tables", connectionId: outside
        )

        #expect(reason(decision) == MCPAuthPolicy.outsideActiveProjectRefusal)
    }

    @Test("The in-app chat keeps its own window's connection whatever project is active")
    func inAppChatIsNotScoped() async throws {
        let policy = policy(scope: [inProject])

        for principal in [MCPPrincipal.inAppAssistant, token(isClaudeAgent: true)] {
            let decision = try await policy.authorize(principal: principal, tool: "list_tables", connectionId: outside)
            guard case .allowed = decision else {
                Issue.record("Expected the in-app chat to stay allowed, got \(decision)")
                return
            }
            #expect(!principal.followsActiveProject)
        }
        #expect(token().followsActiveProject)
        #expect(token(isBridge: true).followsActiveProject)
    }

    @Test("The project only narrows: a blocked, AI-disabled or unlisted connection keeps its own refusal")
    func existingRefusalsStand() async throws {
        let blocked = try await policy(scope: [inProject], externalAccess: .blocked)
            .authorize(principal: token(), tool: "list_tables", connectionId: inProject)
        let never = try await policy(scope: [inProject], policy: .never)
            .authorize(principal: token(), tool: "list_tables", connectionId: inProject)
        let notGranted = try await policy(scope: [inProject])
            .authorize(principal: token(connectionAccess: .limited([outside])), tool: "list_tables", connectionId: inProject)
        let outsideAndBlocked = try await policy(scope: [inProject], externalAccess: .blocked)
            .authorize(principal: token(), tool: "list_tables", connectionId: outside)

        #expect(reason(blocked) == String(localized: "External access is disabled for this connection"))
        #expect(reason(never) == String(localized: "AI access is disabled for this connection"))
        #expect(reason(notGranted) == String(localized: "Token does not have access to this connection"))
        #expect(reason(outsideAndBlocked) == String(localized: "External access is disabled for this connection"))
    }

    @Test("A read across connections keeps only the active project's for a token, and all of them for the chat")
    func readableIdsFollowTheProject() async {
        let policy = policy(scope: [inProject])

        #expect(await policy.readableConnectionIds(principal: token()) == [inProject])
        #expect(await policy.connectionIdsReadableWithoutPrompt(principal: token()) == [inProject])
        #expect(await policy.readableConnectionIds(principal: .inAppAssistant) == [inProject, outside])
        #expect(await self.policy(scope: nil).readableConnectionIds(principal: token()) == [inProject, outside])
    }
}
