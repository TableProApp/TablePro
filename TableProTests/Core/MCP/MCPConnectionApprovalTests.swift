//
//  MCPConnectionApprovalTests.swift
//  TableProTests
//
//  Whether an MCP client is asked before it reaches a connection is MCP's own setting, not the AI
//  tab's. What a client may do once it is there is unchanged: a connection blocked for external
//  clients, one whose AI policy is Never, and Safe Mode all still refuse, whatever the approval
//  setting says.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MCP connection approval")
struct MCPConnectionApprovalTests {
    private let connectionA = UUID()

    private func makeSnapshot(
        externalAccess: ExternalAccessLevel = .readWrite,
        policy: AIConnectionPolicy = .askEachTime
    ) -> MCPConnectionAuthSnapshot {
        MCPConnectionAuthSnapshot(
            policy: policy,
            externalAccess: externalAccess,
            name: "Test Connection",
            databaseType: DatabaseType.postgresql.rawValue
        )
    }

    private func makePrincipal(
        tokenId: UUID? = UUID(),
        label: String = "token",
        fingerprint: String = "fp",
        isBridge: Bool = false
    ) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
            scopes: MCPScope.fullAccessSet,
            connectionAccess: .all,
            metadata: MCPPrincipalMetadata(
                label: label,
                issuedAt: .distantPast,
                expiresAt: nil,
                isBridgeCredential: isBridge
            )
        )
    }

    private func makePolicy(
        approval: MCPConnectionApproval,
        snapshot: MCPConnectionAuthSnapshot? = nil,
        presenter: any MCPApprovalPresenting = RecordingApprovalPresenter(answer: true),
        store: any MCPApprovalStoring = MCPInMemoryApprovalStore()
    ) -> MCPAuthPolicy {
        MCPAuthPolicy(
            connectionResolver: { _ in snapshot ?? self.makeSnapshot() },
            connectionIdsProvider: { [] },
            approvalLedger: MCPApprovalLedger(clock: MCPTestClock(), store: store),
            approvalSetting: MCPFixedApprovalReader(approval),
            presenter: presenter
        )
    }

    @Test("Never Ask reaches the connection without a prompt")
    func neverAskSkipsThePrompt() async throws {
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(approval: .alwaysApprove, presenter: presenter)

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .allowed = decision else {
            Issue.record("Expected Never Ask to allow without asking, got \(decision)")
            return
        }
        #expect(await presenter.askedCount == 0)
    }

    @Test("Asking is still required at the two asking levels")
    func askingLevelsStillAsk() async throws {
        for approval in [MCPConnectionApproval.everyTime, .oncePerConnection] {
            let policy = makePolicy(approval: approval)

            let decision = try await policy.authorize(
                principal: makePrincipal(),
                tool: "list_tables",
                connectionId: connectionA
            )

            guard case .requiresUserApproval = decision else {
                Issue.record("Expected \(approval) to ask, got \(decision)")
                return
            }
        }
    }

    @Test("Never Ask does not open a connection the user blocked for external clients")
    func neverAskDoesNotOverrideBlocked() async throws {
        let policy = makePolicy(
            approval: .alwaysApprove,
            snapshot: makeSnapshot(externalAccess: .blocked)
        )

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .denied = decision else {
            Issue.record("Expected a blocked connection to stay blocked, got \(decision)")
            return
        }
    }

    @Test("Never Ask does not open a connection whose AI policy is Never")
    func neverAskDoesNotOverrideNeverPolicy() async throws {
        let policy = makePolicy(approval: .alwaysApprove, snapshot: makeSnapshot(policy: .never))

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .denied = decision else {
            Issue.record("Expected an AI policy of Never to keep denying, got \(decision)")
            return
        }
    }

    @Test("A connection set to Always Allow is reached without asking whatever the level")
    func perConnectionAlwaysAllowWins() async throws {
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(
            approval: .everyTime,
            snapshot: makeSnapshot(policy: .alwaysAllow),
            presenter: presenter
        )

        let decision = try await policy.authorize(
            principal: makePrincipal(),
            tool: "list_tables",
            connectionId: connectionA
        )

        guard case .allowed = decision else {
            Issue.record("Expected a per-connection Always Allow to win, got \(decision)")
            return
        }
        #expect(await presenter.askedCount == 0)
    }

    @Test("Ask Once remembers the answer, and the next call does not ask")
    func askOnceRemembers() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)
        let principal = makePrincipal()

        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )
        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.askedCount == 1)
    }

    @Test("Ask Every Time asks again on the next call")
    func everyTimeAsksAgain() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let policy = makePolicy(approval: .everyTime, presenter: presenter, store: store)
        let principal = makePrincipal()

        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )
        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.askedCount == 2)
    }

    @Test("The prompt says whether the answer will be remembered")
    func promptExplainsWhatAllowMeans() async throws {
        let remembering = RecordingApprovalPresenter(answer: true)
        try await makePolicy(approval: .oncePerConnection, presenter: remembering)
            .resolveAndAuthorize(principal: makePrincipal(), tool: "list_tables", connectionId: connectionA)
        #expect(await remembering.lastRequest?.memory == .untilRevoked)

        let onceOnly = RecordingApprovalPresenter(answer: true)
        try await makePolicy(approval: .everyTime, presenter: onceOnly)
            .resolveAndAuthorize(principal: makePrincipal(), tool: "list_tables", connectionId: connectionA)
        #expect(await onceOnly.lastRequest?.memory == .thisRequestOnly)
    }

    @Test("A refusal stands for a cool-off instead of raising a fresh prompt on the retry")
    func denialIsRememberedBriefly() async throws {
        let presenter = RecordingApprovalPresenter(answer: false)
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)
        let principal = makePrincipal()

        for _ in 0..<3 {
            await #expect(throws: DatabaseAccessError.self) {
                try await policy.resolveAndAuthorize(
                    principal: principal, tool: "list_tables", connectionId: connectionA
                )
            }
        }

        #expect(await presenter.askedCount == 1)
    }

    @Test("The bundled bridge keeps its grant when its credential rotates")
    func bridgeGrantSurvivesCredentialRotation() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)

        let firstCredential = makePrincipal(
            tokenId: UUID(),
            label: MCPTokenStore.stdioBridgeTokenName,
            fingerprint: "bridge-1",
            isBridge: true
        )
        try await policy.resolveAndAuthorize(
            principal: firstCredential, tool: "list_tables", connectionId: connectionA
        )

        await policy.clearApprovals(tokenId: firstCredential.tokenId, wasBridgeCredential: true)

        let rotated = makePrincipal(
            tokenId: UUID(),
            label: MCPTokenStore.stdioBridgeTokenName,
            fingerprint: "bridge-2",
            isBridge: true
        )
        try await policy.resolveAndAuthorize(
            principal: rotated, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.askedCount == 1)
    }

    @Test("Revoking a token the user issued drops the grant it was carrying")
    func revokingAnIssuedTokenDropsItsGrant() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)
        let principal = makePrincipal(label: "Laptop token")

        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )
        await policy.clearApprovals(tokenId: principal.tokenId)
        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.askedCount == 2)
    }

    @Test("A remembered grant survives the teardown a settings change triggers")
    func grantSurvivesServerTeardown() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)
        let principal = makePrincipal()

        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )
        await policy.clearAllApprovals()
        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.askedCount == 1)
    }

    @Test("An anonymous caller's approval is never written to disk")
    func anonymousApprovalIsNotPersisted() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)

        try await policy.resolveAndAuthorize(
            principal: .anonymousLoopback, tool: "list_tables", connectionId: connectionA
        )

        #expect(await store.grants().isEmpty)
    }

    @Test("Forgetting a grant makes the next call ask again")
    func forgettingAGrantAsksAgain() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)
        let principal = makePrincipal()

        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )
        let grants = await policy.grants()
        let subject = try #require(grants.first?.subject)
        await policy.revokeGrant(subject: subject, connectionId: connectionA)

        try await policy.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.askedCount == 2)
    }

    @Test("A token that merely calls itself the bridge inherits none of the bridge's grants")
    func aTokenNamedLikeTheBridgeInheritsNothing() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, store: store)

        let bridge = makePrincipal(label: MCPTokenStore.stdioBridgeTokenName, fingerprint: "real", isBridge: true)
        try await policy.resolveAndAuthorize(
            principal: bridge, tool: "list_tables", connectionId: connectionA
        )

        let impostor = makePrincipal(
            label: MCPTokenStore.stdioBridgeTokenName,
            fingerprint: "impostor",
            isBridge: false
        )
        try await policy.resolveAndAuthorize(
            principal: impostor, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.askedCount == 2)
    }

    @Test("Ask Every Time asks again even for a connection that already carries a grant")
    func everyTimeIgnoresAnExistingGrant() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let principal = makePrincipal()

        let remembering = RecordingApprovalPresenter(answer: true)
        let granting = makePolicy(approval: .oncePerConnection, presenter: remembering, store: store)
        try await granting.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )
        #expect(await granting.grants().count == 1)

        let strict = RecordingApprovalPresenter(answer: true)
        let tightened = makePolicy(approval: .everyTime, presenter: strict, store: store)
        try await tightened.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )

        #expect(await strict.askedCount == 1)
    }

    @Test("A denial withdraws a grant the user had already given")
    func denialWithdrawsAnExistingGrant() async throws {
        let store = MCPApprovalStore(defaults: Self.scratchDefaults())
        let principal = makePrincipal()

        let allowing = makePolicy(
            approval: .oncePerConnection,
            presenter: RecordingApprovalPresenter(answer: true),
            store: store
        )
        try await allowing.resolveAndAuthorize(
            principal: principal, tool: "list_tables", connectionId: connectionA
        )
        #expect(await allowing.grants().count == 1)

        let denying = makePolicy(
            approval: .everyTime,
            presenter: RecordingApprovalPresenter(answer: false),
            store: store
        )
        await #expect(throws: DatabaseAccessError.self) {
            try await denying.resolveAndAuthorize(
                principal: principal, tool: "list_tables", connectionId: connectionA
            )
        }

        #expect(await denying.grants().isEmpty)
    }

    @Test("An anonymous caller is told its approval lasts only for the session")
    func anonymousPromptSaysSessionOnly() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)

        try await policy.resolveAndAuthorize(
            principal: .anonymousLoopback, tool: "list_tables", connectionId: connectionA
        )

        #expect(await presenter.lastRequest?.memory == .thisSession)
    }

    @Test("An anonymous caller's refusal also stands for a cool-off")
    func anonymousDenialIsRememberedBriefly() async throws {
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)

        for _ in 0..<3 {
            await #expect(throws: DatabaseAccessError.self) {
                try await policy.resolveAndAuthorize(
                    principal: .anonymousLoopback, tool: "list_tables", connectionId: connectionA
                )
            }
        }

        #expect(await presenter.askedCount == 1)
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "com.TablePro.tests.mcpApprovals." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
