//
//  MCPCompletionApprovalGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import TableProPluginKit
import Testing

struct MCPCompletionApprovalGateTests {
    private let connectionId = UUID()

    private func makePrincipal() -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: "fp",
            tokenId: UUID(),
            scopes: MCPScope.fullAccessSet,
            connectionAccess: .all,
            metadata: MCPPrincipalMetadata(
                label: "token",
                issuedAt: .distantPast,
                expiresAt: nil,
                isBridgeCredential: false
            )
        )
    }

    private func makePolicy(
        approval: MCPConnectionApproval,
        policy: AIConnectionPolicy = .askEachTime,
        presenter: RecordingApprovalPresenter
    ) -> MCPAuthPolicy {
        let snapshot = MCPConnectionAuthSnapshot(
            policy: policy,
            externalAccess: .readWrite,
            name: "Test Connection",
            databaseType: DatabaseType.postgresql.rawValue
        )
        return MCPAuthPolicy(
            connectionResolver: { _ in snapshot },
            connectionIdsProvider: { [] },
            approvalLedger: MCPApprovalLedger(clock: MCPTestClock(), store: MCPInMemoryApprovalStore()),
            approvalSetting: MCPFixedApprovalReader(approval),
            presenter: presenter
        )
    }

    @Test("A connection nobody approved yet is refused without raising the prompt")
    func unapprovedIsRefusedSilently() async {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)

        let allowed = await policy.isAllowedWithoutPrompt(principal: makePrincipal(), connectionId: connectionId)

        #expect(!allowed)
        #expect(await presenter.askedCount == 0)
    }

    @Test("A remembered grant lets the silent check through")
    func rememberedGrantIsAllowed() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)
        let principal = makePrincipal()
        try await policy.resolveAndAuthorize(principal: principal, tool: "list_tables", connectionId: connectionId)

        #expect(await policy.isAllowedWithoutPrompt(principal: principal, connectionId: connectionId))
    }

    @Test("A client the user just denied stays refused")
    func deniedClientIsRefused() async {
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)
        let principal = makePrincipal()
        await #expect(throws: DatabaseAccessError.self) {
            try await policy.resolveAndAuthorize(principal: principal, tool: "list_tables", connectionId: connectionId)
        }

        #expect(await !policy.isAllowedWithoutPrompt(principal: principal, connectionId: connectionId))
        #expect(await presenter.askedCount == 1)
    }

    @Test("Ask Every Time never passes the silent check")
    func everyTimeIsRefused() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .everyTime, presenter: presenter)
        let principal = makePrincipal()
        try await policy.resolveAndAuthorize(principal: principal, tool: "list_tables", connectionId: connectionId)

        #expect(await !policy.isAllowedWithoutPrompt(principal: principal, connectionId: connectionId))
    }

    @Test("Always Allow and Never Ask pass the silent check")
    func openSettingsAreAllowed() async {
        let presenter = RecordingApprovalPresenter(answer: false)
        let alwaysAllow = makePolicy(approval: .everyTime, policy: .alwaysAllow, presenter: presenter)
        let neverAsk = makePolicy(approval: .alwaysApprove, presenter: presenter)

        #expect(await alwaysAllow.isAllowedWithoutPrompt(principal: makePrincipal(), connectionId: connectionId))
        #expect(await neverAsk.isAllowedWithoutPrompt(principal: makePrincipal(), connectionId: connectionId))
    }

    @Test("A connection set to Never is refused whatever the approval setting")
    func neverPolicyIsRefused() async {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .alwaysApprove, policy: .never, presenter: presenter)

        #expect(await !policy.isAllowedWithoutPrompt(principal: makePrincipal(), connectionId: connectionId))
    }

    @Test("Completing a database, schema or table of an unapproved connection reads nothing")
    func unapprovedConnectionCompletesNothing() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setDatabases(["warehouse"])
        await source.setSchemas(["public"])
        await source.setTables(["orders"])
        await source.setUnapproved([CompletionFixtures.analyticsId])
        let provider = MCPCompletionProvider(source: source)
        let context = ["connection_id": CompletionFixtures.analyticsId.uuidString]

        for argument in ["database", "schema", MCPPromptArgument.tableArgumentName] {
            let result = await provider.complete(
                reference: .prompt(name: "explain_table"),
                argumentName: argument,
                argumentValue: "",
                context: context,
                principal: CompletionFixtures.principal()
            )
            #expect(result.values.isEmpty)
        }

        #expect(await source.databaseCalls.isEmpty)
        #expect(await source.schemaCalls.isEmpty)
        #expect(await source.tableCalls.isEmpty)
    }

    @Test("Names cached while approved are not served once the approval is gone")
    func cachedNamesNeedApproval() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders"])
        let provider = MCPCompletionProvider(source: source, clock: MCPProtocolStubClock(), cacheDuration: 15)
        let principal = CompletionFixtures.principal()
        let context = ["connection": "Analytics"]

        let first = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "",
            context: context,
            principal: principal
        )
        #expect(first.values == ["orders"])

        await source.setUnapproved([CompletionFixtures.analyticsId])
        let second = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "",
            context: context,
            principal: principal
        )
        #expect(second.values.isEmpty)
    }
}
