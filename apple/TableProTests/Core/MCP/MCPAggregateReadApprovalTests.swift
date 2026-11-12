//
//  MCPAggregateReadApprovalTests.swift
//  TableProTests
//
//  A read that spans connections cannot ask about each one, so it covers only the connections the
//  approval gate already lets through. A call that names one connection is asked about it once.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import TableProPluginKit
import Testing

struct MCPAggregateReadApprovalTests {
    private let granted = UUID()
    private let withheld = UUID()

    private func ledger() -> MCPApprovalLedger {
        MCPApprovalLedger(clock: MCPTestClock(), store: MCPInMemoryApprovalStore())
    }

    private func makePolicy(
        approval: MCPConnectionApproval,
        presenter: RecordingApprovalPresenter,
        connections: [UUID: MCPConnectionAuthSnapshot]? = nil
    ) -> MCPAuthPolicy {
        MCPToolTestHarness.authPolicy(
            connections: connections ?? [
                granted: MCPToolTestHarness.snapshot(policy: .askEachTime, name: "Granted"),
                withheld: MCPToolTestHarness.snapshot(policy: .askEachTime, name: "Withheld")
            ],
            approval: approval,
            presenter: presenter,
            ledger: ledger()
        )
    }

    private func entry(connectionId: UUID, query: String) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "shop",
            databaseType: .postgresql,
            source: .editor,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    private func historyStore() -> ToolTestQueryHistoryStore {
        ToolTestQueryHistoryStore(entries: [
            entry(connectionId: granted, query: "SELECT 1"),
            entry(connectionId: withheld, query: "UPDATE employees SET salary = 250000")
        ])
    }

    private func tab(on connectionId: UUID, title: String) -> MCPTabSnapshot {
        MCPTabSnapshot(
            tabId: UUID(),
            connectionId: connectionId,
            connectionName: title,
            tabType: "table",
            tableName: title,
            databaseName: "shop",
            schemaName: "public",
            displayTitle: title,
            windowId: UUID(),
            isActive: true,
            window: nil
        )
    }

    private func context() -> MCPRequestContext {
        MCPToolTestHarness.context(principal: MCPToolTestHarness.principal(access: .all))
    }

    private func approve(_ connectionId: UUID, in policy: MCPAuthPolicy) async throws {
        try await policy.resolveAndAuthorize(
            principal: MCPToolTestHarness.principal(access: .all),
            tool: "list_tables",
            connectionId: connectionId
        )
    }

    @Test("Under Ask Once the silent set holds only the connections already granted")
    func askOnceKeepsOnlyGrantedConnections() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)
        try await approve(granted, in: policy)

        let allowed = await policy.connectionIdsReadableWithoutPrompt(principal: MCPToolTestHarness.principal())

        #expect(allowed == [granted])
        #expect(await presenter.askedCount == 1)
    }

    @Test("A connection the user just denied stays out of the silent set")
    func deniedConnectionStaysOut() async throws {
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, connections: [
            granted: MCPToolTestHarness.snapshot(policy: .alwaysAllow, name: "Granted"),
            withheld: MCPToolTestHarness.snapshot(policy: .askEachTime, name: "Withheld")
        ])
        await #expect(throws: DatabaseAccessError.self) {
            try await approve(withheld, in: policy)
        }

        let allowed = await policy.connectionIdsReadableWithoutPrompt(principal: MCPToolTestHarness.principal())

        #expect(allowed == [granted])
        #expect(await presenter.askedCount == 1)
    }

    @Test("Under Ask Every Time the silent set holds only connections set to Always Allow")
    func askEveryTimeKeepsOnlyAlwaysAllow() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .everyTime, presenter: presenter, connections: [
            granted: MCPToolTestHarness.snapshot(policy: .alwaysAllow, name: "Granted"),
            withheld: MCPToolTestHarness.snapshot(policy: .askEachTime, name: "Withheld")
        ])
        try await approve(withheld, in: policy)

        let allowed = await policy.connectionIdsReadableWithoutPrompt(principal: MCPToolTestHarness.principal())

        #expect(allowed == [granted])
    }

    @Test("Under Never Ask the silent set is every connection the token may see")
    func neverAskKeepsEveryReadableConnection() async {
        let hidden = UUID()
        let blocked = UUID()
        let outsideToken = UUID()
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(approval: .alwaysApprove, presenter: presenter, connections: [
            granted: MCPToolTestHarness.snapshot(policy: .askEachTime, name: "Granted"),
            hidden: MCPToolTestHarness.snapshot(policy: .never, name: "Hidden"),
            blocked: MCPToolTestHarness.snapshot(policy: .askEachTime, externalAccess: .blocked, name: "Blocked"),
            outsideToken: MCPToolTestHarness.snapshot(policy: .askEachTime, name: "Outside")
        ])

        let allowed = await policy.connectionIdsReadableWithoutPrompt(
            principal: MCPToolTestHarness.principal(access: .limited([granted, hidden, blocked]))
        )

        #expect(allowed == [granted])
        #expect(await presenter.askedCount == 0)
    }

    @Test("History without a connection id leaves out a connection nobody approved, and asks nothing")
    func historyWithoutConnectionCoversOnlyApprovedConnections() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)
        try await approve(granted, in: policy)
        let store = historyStore()

        let result = try await SearchQueryHistoryTool().call(
            arguments: .object(["query": .string("")]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy, history: store)
        )

        let filters = await store.receivedFilters
        #expect(filters.first?.allowedConnectionIds == [granted])
        let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
        #expect(entries.allSatisfy { $0["connection_id"]?.stringValue == granted.uuidString })
        #expect(await presenter.askedCount == 1)
    }

    @Test("History without a connection id still leaves out a connection the user denied")
    func historyAfterADenialLeavesTheConnectionOut() async throws {
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter, connections: [
            granted: MCPToolTestHarness.snapshot(policy: .alwaysAllow, name: "Granted"),
            withheld: MCPToolTestHarness.snapshot(policy: .askEachTime, name: "Withheld")
        ])
        await #expect(throws: DatabaseAccessError.self) {
            try await approve(withheld, in: policy)
        }
        let store = historyStore()

        let result = try await SearchQueryHistoryTool().call(
            arguments: .object(["query": .string("")]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy, history: store)
        )

        let filters = await store.receivedFilters
        #expect(filters.first?.allowedConnectionIds == [granted])
        let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
        for entry in entries {
            #expect(entry["query"]?.stringValue?.contains("salary") != true)
        }
    }

    @Test("Under Ask Every Time history without a connection id reads nothing and asks nothing")
    func askEveryTimeAggregateHistoryIsEmpty() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .everyTime, presenter: presenter)
        let store = historyStore()

        let result = try await SearchQueryHistoryTool().call(
            arguments: .object(["query": .string("")]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy, history: store)
        )

        #expect(result.structuredContent?["entries"]?.arrayValue?.isEmpty == true)
        #expect(await store.receivedFilters.isEmpty)
        #expect(await presenter.askedCount == 0)
    }

    @Test("Under Ask Every Time a history search that names a connection returns it, without asking again")
    func askEveryTimeNamedHistoryIsReturned() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .everyTime, presenter: presenter)
        let store = historyStore()

        let result = try await SearchQueryHistoryTool().call(
            arguments: .object(["query": .string(""), "connection_id": .string(withheld.uuidString)]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy, history: store)
        )

        let entries = try #require(result.structuredContent?["entries"]?.arrayValue)
        #expect(entries.count == 1)
        #expect(entries.first?["connection_id"]?.stringValue == withheld.uuidString)
        #expect(await presenter.askedCount == 0)
    }

    @Test("Tabs without a connection id leave out a connection nobody approved")
    func tabsWithoutConnectionCoverOnlyApprovedConnections() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)
        try await approve(granted, in: policy)
        let tabs = [tab(on: granted, title: "orders"), tab(on: withheld, title: "payroll")]

        let result = try await ListRecentTabsTool(collectSnapshots: { tabs }).call(
            arguments: .object([:]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy)
        )

        let listed = try #require(result.structuredContent?["tabs"]?.arrayValue)
        #expect(listed.count == 1)
        #expect(listed.first?["connection_id"]?.stringValue == granted.uuidString)
        #expect(await presenter.askedCount == 1)
    }

    @Test("Under Ask Every Time tabs of a named connection are listed without asking again")
    func askEveryTimeNamedTabsAreListed() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .everyTime, presenter: presenter)
        let tabs = [tab(on: granted, title: "orders"), tab(on: withheld, title: "payroll")]

        let result = try await ListRecentTabsTool(collectSnapshots: { tabs }).call(
            arguments: .object(["connection_id": .string(withheld.uuidString)]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy)
        )

        let listed = try #require(result.structuredContent?["tabs"]?.arrayValue)
        #expect(listed.count == 1)
        #expect(listed.first?["connection_id"]?.stringValue == withheld.uuidString)
        #expect(await presenter.askedCount == 0)
    }

    @Test("The snapshot filter keeps only the given connections")
    func snapshotFilterKeepsTheGivenConnections() {
        let tabs = [tab(on: granted, title: "orders"), tab(on: withheld, title: "payroll")]

        let kept = MCPTabSnapshotProvider.snapshots(tabs, in: [granted])

        #expect(kept.count == 1)
        #expect(kept.first?.connectionId == granted)
        #expect(MCPTabSnapshotProvider.snapshots(tabs, in: []).isEmpty)
    }

    @Test("Focusing a tab asks about its connection, and a denial raises nothing")
    func focusHonoursADenial() async throws {
        let presenter = RecordingApprovalPresenter(answer: false)
        let policy = makePolicy(approval: .oncePerConnection, presenter: presenter)
        let payroll = tab(on: withheld, title: "payroll")

        let result = try await FocusQueryTabTool(collectSnapshots: { [payroll] }).call(
            arguments: .object(["tab_id": .string(payroll.tabId.uuidString)]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy)
        )

        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.hasPrefix("denied:"))
        #expect(!text.contains(withheld.uuidString))
        #expect(await presenter.askedCount == 1)
    }

    @Test("Focusing a tab the user allows goes on to look for its window")
    func focusAfterAnAllowLooksForTheWindow() async throws {
        let presenter = RecordingApprovalPresenter(answer: true)
        let policy = makePolicy(approval: .everyTime, presenter: presenter)
        let payroll = tab(on: withheld, title: "payroll")

        let result = try await FocusQueryTabTool(collectSnapshots: { [payroll] }).call(
            arguments: .object(["tab_id": .string(payroll.tabId.uuidString)]),
            context: context(),
            services: MCPToolTestHarness.services(authPolicy: policy)
        )

        #expect(await presenter.askedCount == 1)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
    }
}
