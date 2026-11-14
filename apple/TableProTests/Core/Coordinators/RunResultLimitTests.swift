//
//  RunResultLimitTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @MainActor
    struct RunResultLimitTests {
        // SQL Server: the grammar that reads GO lines as batch separators.
        private let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop", type: .mssql))

        // Every batch answers `setsPerBatch` one-row result sets, numbered across the run.
        private func run(_ text: String, setsPerBatch: Int) async throws -> [ResultSet] {
            let connection = fixture.connection
            let counter = BatchCounter()
            let driver = ScriptAnsweringDriver(connection: connection, answer: { _ in
                let first = counter.take(setsPerBatch)
                return ScriptAnsweringDriver.batch((first..<first + setsPerBatch).map {
                    ScriptAnsweringDriver.resultSet(columns: ["id"], rows: [["\($0)"]])
                })
            })
            var session = ConnectionSession(connection: connection, driver: driver)
            session.status = .connected
            session.browseDatabase = connection.database
            DatabaseManager.shared.injectSession(session, for: connection.id)
            defer { DatabaseManager.shared.removeSession(for: connection.id) }

            let tab = fixture.addTab(QueryTab(title: "Query", query: text, tabType: .query))
            let runner: QueryExecutionCoordinator = fixture.coordinator.queryExecutionCoordinator
            runner.executeBatches(runner.executionBatches(in: text), parameters: [], onTab: tab.id)
            let handle = try #require(fixture.coordinator.queryTasks.task(for: tab.id))
            await handle.value
            return try #require(fixture.tabManager.tabs.first { $0.id == tab.id }).display.resultSets
        }

        @Test("With no limit a run keeps every result and says nothing", .appSettings { $0.dataGrid.resultSetsKeptPerRun = 0 })
        func noLimitKeepsEveryResult() async throws {
            let results = try await run("SELECT * FROM users\nGO\nSELECT * FROM orders\nGO", setsPerBatch: 60)

            #expect(results.count == 120)
            #expect(results.first?.tableRows.value(at: 0, column: 0) == .text("1"))
            #expect(results.last?.tableRows.value(at: 0, column: 0) == .text("120"))
            #expect(results.allSatisfy { $0.statusMessage?.contains("dropped") != true })
        }

        @Test("Over the limit a run keeps the newest results and each says how many were dropped",
              .appSettings { $0.dataGrid.resultSetsKeptPerRun = 3 })
        func limitKeepsTheNewestResults() async throws {
            let results = try await run("SELECT * FROM users", setsPerBatch: 5)

            #expect(results.map { $0.tableRows.value(at: 0, column: 0) } == [.text("3"), .text("4"), .text("5")])
            #expect(results.allSatisfy { $0.statusMessage?.hasSuffix("2 earlier results were dropped.") == true })
        }

        @Test("Result sets a batch read past count as dropped, with no limit too", .appSettings { $0.dataGrid.resultSetsKeptPerRun = 0 })
        func setsABatchReadPastCountAsDropped() async throws {
            let results = try await run("SELECT * FROM users", setsPerBatch: QueryBatchResult.keptResultSetLimit + 2)

            #expect(results.count == QueryBatchResult.keptResultSetLimit)
            #expect(results.first?.tableRows.value(at: 0, column: 0) == .text("3"))
            #expect(results.allSatisfy { $0.statusMessage?.hasSuffix("2 earlier results were dropped.") == true })
        }
    }
}

private final class BatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0

    func take(_ count: Int) -> Int {
        lock.withLock {
            defer { next += count }
            return next + 1
        }
    }
}
