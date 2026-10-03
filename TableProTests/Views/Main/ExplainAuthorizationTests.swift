//
//  ExplainAuthorizationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ExplainAuthorizationTests {
    private static let plan = ExplainVariant(
        id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN (FORMAT JSON)", format: .postgresJson
    )
    private static let analyze = ExplainVariant(
        id: "analyze", label: "EXPLAIN ANALYZE", sqlPrefix: "EXPLAIN (ANALYZE, FORMAT JSON)", format: .postgresJson
    )

    @Test("Explain Analyze of a DELETE on a Read-Only connection is refused and never reaches the driver")
    func analyzeOfAWriteOnReadOnlyIsRefused() async {
        let harness = Harness(level: .readOnly, query: "DELETE FROM t", confirming: StubConfirming(answer: true))
        defer { harness.tearDown() }

        await harness.explain(Self.analyze)

        let requests = await harness.gate.requests
        let decisions = await harness.gate.decisions
        #expect(requests.count == 1)
        #expect(requests.first?.sql?.hasPrefix("EXPLAIN (ANALYZE, FORMAT JSON) DELETE") == true)
        #expect(requests.first?.kind.declaresWrite == true)
        #expect(decisions.first?.isAuthorized == false)
        #expect(harness.driver.sentStatements.isEmpty)
        #expect(harness.errorMessage != nil)
        #expect(harness.errorMessage == decisions.first?.deniedReason)
    }

    @Test("Explain Analyze of a DELETE under Alert asks first, and a Cancel sends nothing and reports nothing")
    func analyzeOfAWriteUnderAlertAsksFirst() async {
        let confirming = StubConfirming(answer: false)
        let harness = Harness(level: .alert, query: "DELETE FROM t", confirming: confirming)
        defer { harness.tearDown() }

        await harness.explain(Self.analyze)

        #expect(confirming.callCount == 1)
        #expect(confirming.lastRequest?.sql?.hasPrefix("EXPLAIN (ANALYZE, FORMAT JSON) DELETE") == true)
        #expect(harness.driver.sentStatements.isEmpty)
        #expect(harness.errorMessage == nil)
    }

    @Test(
        "A plain EXPLAIN of a read is authorized without a prompt and runs",
        arguments: [SafeModeLevel.silent, .alert, .safeMode, .readOnly]
    )
    func planOfAReadRunsWithoutAPrompt(level: SafeModeLevel) async {
        await expectPlanRunsWithoutAPrompt(level: level, query: "SELECT 1")
    }

    @Test(
        "A plain EXPLAIN of a DELETE only plans it, so it is authorized without a prompt and runs",
        arguments: [SafeModeLevel.silent, .alert, .safeMode, .readOnly]
    )
    func planOfAWriteRunsWithoutAPrompt(level: SafeModeLevel) async {
        await expectPlanRunsWithoutAPrompt(level: level, query: "DELETE FROM t")
    }

    @Test("A second Explain while the first is still being authorized is ignored")
    func secondExplainDuringAuthorizationIsIgnored() async {
        let harness = Harness(level: .alert, query: "SELECT 1", confirming: StubConfirming(answer: true))
        defer { harness.tearDown() }

        let first = harness.coordinator.runExplain(variant: Self.plan)
        let second = harness.coordinator.runExplain(variant: Self.plan)
        await first?.value
        await harness.coordinator.queryTasks.task(for: harness.tabId)?.value

        let requests = await harness.gate.requests
        #expect(second == nil)
        #expect(requests.count == 1)
        #expect(harness.driver.sentStatements == ["EXPLAIN (FORMAT JSON) SELECT 1"])
    }

    private func expectPlanRunsWithoutAPrompt(level: SafeModeLevel, query: String) async {
        let confirming = StubConfirming(answer: false)
        let harness = Harness(level: level, query: query, confirming: confirming)
        defer { harness.tearDown() }

        await harness.explain(Self.plan)

        let requests = await harness.gate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.kind == .readQuery)
        #expect(confirming.callCount == 0)
        #expect(harness.authenticating.callCount == 0)
        #expect(harness.driver.sentStatements == ["EXPLAIN (FORMAT JSON) \(query)"])
        #expect(harness.errorMessage == nil)
    }

    // MARK: - Harness

    private actor RecordingGate: ExecutionGate {
        private let inner: any ExecutionGate
        private(set) var requests: [OperationRequest] = []
        private(set) var decisions: [OperationDecision] = []

        init(_ inner: any ExecutionGate) {
            self.inner = inner
        }

        func authorize(_ request: OperationRequest) async -> OperationDecision {
            requests.append(request)
            let decision = await inner.authorize(request)
            decisions.append(decision)
            return decision
        }
    }

    @MainActor
    private struct Harness {
        let coordinator: MainContentCoordinator
        let connection: DatabaseConnection
        let driver: ScriptAnsweringDriver
        let gate: RecordingGate
        let authenticating: StubAuthenticating
        let tabId: UUID

        init(level: SafeModeLevel, query: String, confirming: StubConfirming) {
            let connection = DatabaseConnection(
                name: "Explain", database: "app", type: .postgresql, safeModeLevel: level
            )
            let driver = ScriptAnsweringDriver(connection: connection, sendsBatchesWhole: false)
            var session = ConnectionSession(connection: connection, driver: driver)
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: connection.id)

            let toolbarState = ConnectionToolbarState()
            toolbarState.safeModeLevel = level
            let tabManager = QueryTabManager()
            let coordinator = MainContentCoordinator(
                connection: connection,
                tabManager: tabManager,
                changeManager: DataChangeManager(),
                toolbarState: toolbarState
            )
            let authenticating = StubAuthenticating(answer: true)
            let gate = RecordingGate(DefaultExecutionGate(
                confirming: confirming,
                authenticating: authenticating,
                safeModeLevelResolver: { _ in level },
                forcesWriteResolver: { _ in false },
                auditLog: ExecutionAuditLog(
                    fileURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("explain-authorization-audit-\(UUID().uuidString).json")
                )
            ))
            coordinator.executionGate = gate

            let tab = QueryTab(title: "Query", query: query, tabType: .query)
            tabManager.tabs.append(tab)
            tabManager.selectedTabId = tab.id

            self.coordinator = coordinator
            self.connection = connection
            self.driver = driver
            self.gate = gate
            self.authenticating = authenticating
            self.tabId = tab.id
        }

        var errorMessage: String? {
            coordinator.tabManager.tabs.first { $0.id == tabId }?.execution.errorMessage
        }

        func explain(_ variant: ExplainVariant) async {
            await coordinator.runExplain(variant: variant)?.value
            await coordinator.queryTasks.task(for: tabId)?.value
        }

        func tearDown() {
            coordinator.cancelAllQueryTasks()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
    }
}
