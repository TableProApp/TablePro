//
//  RunResultPlanTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProTestSupport
@testable import TablePro
import Testing

struct RunResultPlanTests {
    @Test("Statements that return no rows share one summary placed where the last of them ran")
    func columnlessStatementsCollapse() {
        let plan = RunResultPlan(producesRows: [false, false, true, false, true])
        #expect(plan.entries == [.statement(2), .summary([0, 1, 3]), .statement(4)])
        #expect(plan.droppedNotice == nil)
    }

    @Test("A single statement without rows keeps its own result")
    func singleColumnlessStatementStays() {
        let plan = RunResultPlan(producesRows: [false, true])
        #expect(plan.entries == [.statement(0), .statement(1)])
    }

    @Test("A run that ends on a statement without rows ends on the summary")
    func summaryIsLastWhenTheRunEndsWithoutRows() {
        let plan = RunResultPlan(producesRows: [true, false, false])
        #expect(plan.entries.last == .summary([1, 2]))
    }

    @Test("Only the last results that return rows are kept, and only their rows are built")
    func rowResultsAreCapped() {
        let plan = RunResultPlan(producesRows: Array(repeating: true, count: 5), maxRowResults: 2)
        #expect(plan.entries == [.statement(3), .statement(4)])
        #expect(plan.droppedRowResultCount == 3)
        #expect(plan.showsRows(ofStatement: 4))
        #expect(!plan.showsRows(ofStatement: 0))
        #expect(plan.droppedNotice != nil)
    }

    @Test("A long script of writes becomes one result")
    func longWriteScriptIsOneResult() {
        let plan = RunResultPlan(producesRows: Array(repeating: false, count: 10_000))
        #expect(plan.entries.count == 1)
        #expect(!plan.showsRows(ofStatement: 0))
    }
}

@MainActor
struct RunAllSummaryResultTests {
    @Test("Run All of statements that return no rows shows one summary result")
    func runAllCollapsesWrites() async throws {
        let connection = TestFixtures.makeConnection()
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer {
            coordinator.cancelAllQueryTasks()
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        let script = "CREATE TABLE a (x int);\nINSERT INTO a VALUES (1);\nUPDATE a SET x = 2;"
        let tab = QueryTab(title: "Query", query: script, tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.runAllStatements()
        try await waitUntil {
            !coordinator.tabExecution.isExecuting(tab.id) && tabManager.tabs.first?.display.resultSets.isEmpty == false
        }

        let results = try #require(tabManager.tabs.first?.display.resultSets)
        #expect(results.count == 1)
        let summary = try #require(results.first)
        #expect(summary.resultColumns.isEmpty)
        #expect(summary.statusMessage?.contains("3") == true)
        #expect(summary.statementAnchor == nil)
    }

    @Test("The summary adds up rows affected and time, keeps each driver message once and the output in order")
    func summaryCarriesWhatTheStatementsReported() {
        let fixture = CoordinatorFixture()
        let parts = [
            RunSummaryPart(rowsAffected: 2, executionTime: 0.5, serverOutput: PluginServerOutput(lines: ["a"], isTruncated: false), statusMessage: "INSERT: 2 rows"),
            RunSummaryPart(rowsAffected: 3, executionTime: 0.25, serverOutput: PluginServerOutput(lines: ["b"], isTruncated: true), statusMessage: "Still creating"),
            RunSummaryPart(rowsAffected: 0, executionTime: 0.25, serverOutput: .none, statusMessage: "Still creating"),
        ]

        let summary = fixture.coordinator.queryExecutionCoordinator.makeRunSummaryResultSet(parts)

        #expect(summary.rowsAffected == 5)
        #expect(summary.executionTime == 1)
        #expect(summary.serverOutput == PluginServerOutput(lines: ["a", "b"], isTruncated: true))
        let status = summary.statusMessage ?? ""
        #expect(status.contains("INSERT: 2 rows"))
        #expect(status.components(separatedBy: "Still creating").count == 2)
        #expect(summary.resultColumns.isEmpty)
        #expect(summary.origin == nil)
    }
}
