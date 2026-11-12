//
//  QueryRunLogRecordingTests.swift
//  TableProTests
//
//  Each run path records what its statements came to beside the results it installs, without
//  changing which results it installs.
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct QueryRunLogRecordingTests {
    @MainActor
    private final class Harness {
        let connection: DatabaseConnection
        let tabManager = QueryTabManager()
        let coordinator: MainContentCoordinator
        let tabId: UUID

        init(driver: (DatabaseConnection) -> any DatabaseDriver, query: String = "") {
            connection = TestFixtures.makeConnection()
            var session = ConnectionSession(connection: connection, driver: driver(connection))
            session.status = .connected
            session.browseDatabase = connection.database
            DatabaseManager.shared.injectSession(session, for: connection.id)
            coordinator = MainContentCoordinator(
                connection: connection,
                tabManager: tabManager,
                changeManager: DataChangeManager(),
                toolbarState: ConnectionToolbarState()
            )
            let tab = QueryTab(title: "Query", query: query, tabType: .query)
            tabManager.tabs.append(tab)
            tabManager.selectedTabId = tab.id
            tabId = tab.id
        }

        var tab: QueryTab? {
            tabManager.tabs.first { $0.id == tabId }
        }

        func runStatements(_ script: String) {
            coordinator.queryExecutionCoordinator.executeMultipleStatementsWithParameters(
                SQLStatementScanner.executableStatements(in: script),
                parameters: []
            )
        }

        func settled() async throws {
            try await waitUntil { [self] in
                !coordinator.tabExecution.isExecuting(tabId) && tab?.display.runLog != nil
            }
        }

        func tearDown() {
            coordinator.cancelAllQueryTasks()
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
    }

    private static func answering(_ connection: DatabaseConnection) -> ScriptAnsweringDriver {
        ScriptAnsweringDriver(connection: connection, sendsBatchesWhole: false, statementAnswer: { sql in
            guard sql.uppercased().hasPrefix("UPDATE") else {
                return ScriptAnsweringDriver.resultSet(columns: ["id"], rows: [["1"], ["2"]])
            }
            return QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 3, executionTime: 0, error: nil)
        })
    }

    private static func failing(_ connection: DatabaseConnection) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver(connection: connection)
        driver.failsStatementContaining = (
            "nope",
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "relation \"nope\" does not exist"])
        )
        return driver
    }

    @Test("A run of a SELECT and an UPDATE logs both, each pointing at its result, and keeps today's result in front")
    func mixedRunLogsEachStatement() async throws {
        let harness = Harness(driver: Self.answering)
        defer { harness.tearDown() }

        harness.runStatements("SELECT id FROM users;\nUPDATE orders SET paid = 1;")
        try await harness.settled()

        let tab = try #require(harness.tab)
        let log = try #require(tab.display.runLog)
        #expect(log.entries.map(\.outcome) == [.returnedRows(2), .affectedRows(3)])
        #expect(log.entries.map(\.resultSetId) == tab.display.resultSets.map(\.id))
        #expect(log.entries.first?.statement.hasPrefix("SELECT id FROM users") == true)
        #expect(tab.display.resultsPage == .result)
        #expect(tab.display.activeResultSetId == tab.display.resultSets.last?.id)
    }

    @Test("A script that fails logs the statement before it and the failure, and brings Message forward")
    func failedScriptOpensOnMessage() async throws {
        let harness = Harness(driver: Self.failing)
        defer { harness.tearDown() }

        harness.runStatements("SELECT 1;\nSELECT * FROM nope;")
        try await harness.settled()

        let tab = try #require(harness.tab)
        let log = try #require(tab.display.runLog)
        #expect(tab.display.resultSets.count == 2)
        #expect(log.entries.count == 2)
        #expect(log.entries.first?.resultSetId == tab.display.resultSets.first?.id)
        #expect(log.entries.last?.outcome.isFailure == true)
        #expect(log.entries.last?.statement.contains("nope") == true)
        #expect(log.entries.last?.resultSetId == tab.display.resultSets.last?.id)
        #expect(tab.display.resultsPage == .message)
    }

    @Test("A single statement that fails logs the banner's message and brings Message forward")
    func singleFailureIsLogged() async throws {
        let harness = Harness(driver: Self.failing)
        defer { harness.tearDown() }

        harness.coordinator.executeQueryInternal("SELECT * FROM nope")
        try await harness.settled()

        let tab = try #require(harness.tab)
        let message = try #require(tab.execution.errorMessage)
        #expect(tab.display.runLog?.entries.map(\.outcome) == [.failed(message: message)])
        #expect(tab.display.resultsPage == .message)
    }

    @Test("A single statement that returns rows logs one entry for its result, and a re-read of it starts no new log")
    func singleRunAndReread() async throws {
        let harness = Harness(driver: Self.answering)
        defer { harness.tearDown() }

        harness.coordinator.executeQueryInternal("SELECT id FROM users")
        try await harness.settled()

        let ran = try #require(harness.tab)
        let log = try #require(ran.display.runLog)
        let firstId = try #require(ran.display.activeResultSetId)
        #expect(log.entries.map(\.outcome) == [.returnedRows(2)])
        #expect(log.entries.first?.resultSetId == firstId)
        #expect(ran.display.resultsPage == .result)

        harness.coordinator.executeQueryInternal(
            "SELECT id FROM users ORDER BY id",
            source: .reread(RereadTarget(
                tabId: harness.tabId,
                resultId: firstId,
                databaseName: ran.tableContext.databaseName,
                schemaName: ran.tableContext.schemaName
            ))
        )
        try await waitUntil {
            !harness.coordinator.tabExecution.isExecuting(harness.tabId)
                && harness.tab?.display.activeResultSetId != firstId
        }

        let reread = try #require(harness.tab)
        #expect(reread.display.runLog?.startedAt == log.startedAt)
        #expect(reread.display.runLog?.entries.first?.statement == "SELECT id FROM users")
        #expect(reread.display.runLog?.entries.first?.resultSetId == reread.display.activeResultSetId)
    }

    @Test("Stopping a run logs the statement it interrupted as cancelled and keeps the earlier results")
    func stoppedRunIsLogged() async throws {
        let harness = Harness(driver: { connection in
            let driver = MockDatabaseDriver(connection: connection)
            driver.executeDelaySeconds = 2
            return driver
        })
        defer { harness.tearDown() }
        let driver = try #require(
            DatabaseManager.shared.driver(for: harness.connection.id) as? MockDatabaseDriver
        )

        harness.runStatements("UPDATE a SET x = 1;\nUPDATE b SET y = 2;")
        try await waitUntil { driver.executedQueries.contains { $0.contains("UPDATE a") } }
        harness.coordinator.stopExecution(for: harness.tabId)
        try await harness.settled()

        let tab = try #require(harness.tab)
        let log = try #require(tab.display.runLog)
        #expect(log.entries.last?.outcome == .cancelled)
        #expect(log.entries.allSatisfy { $0.resultSetId == nil })
        #expect(tab.display.resultSets.isEmpty)
        #expect(tab.display.resultsPage == .message)
    }
}
