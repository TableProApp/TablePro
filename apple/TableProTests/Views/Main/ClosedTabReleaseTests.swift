//
//  ClosedTabReleaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// A closed tab's rows are the largest thing the app holds, so after a close nothing may keep them alive.
@MainActor
struct ClosedTabReleaseTests {
    private static let rowCount = 2_000

    private func runResult(in fixture: CoordinatorFixture, query: String) async throws -> QueryTab {
        let tab = fixture.addTab(QueryTab(title: "Query", query: query, tabType: .query))
        fixture.coordinator.runQuery(onTab: tab.id, viewport: .firstRow)
        try await waitUntil {
            fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id).rows.count == Self.rowCount
        }
        await fixture.coordinator.queryTasks.task(for: tab.id)?.value
        _ = fixture.coordinator.gridModel(forTab: tab.id)
        return tab
    }

    private func makeFixture() -> CoordinatorFixture {
        let connection = TestFixtures.makeConnection(database: "app")
        let driver = PluginDriverAdapter(connection: connection, pluginDriver: RowsDriver(rowCount: Self.rowCount))
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        fixture.coordinator.executionGate = AlwaysAllowGate()
        return fixture
    }

    // A copy of the buffer shares its storage, so a write to the copy moves it only while another holder remains.
    private func isOnlyHolder(_ probe: inout ContiguousArray<Row>) -> Bool {
        let shared = probe.withUnsafeBufferPointer { $0.baseAddress }
        probe[0] = probe[0]
        return probe.withUnsafeBufferPointer { $0.baseAddress } == shared
    }

    @Test("Closing the last tab lets go of its rows and its result")
    func closingTheLastTabReleasesTheResult() async throws {
        let fixture = makeFixture()
        let tab = try await runResult(in: fixture, query: "SELECT * FROM trips")
        weak var result = fixture.tabManager.tabs.first { $0.id == tab.id }?.display.activeResultSet
        var probe = fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id).rows
        #expect(result != nil)

        fixture.coordinator.closeTabsByUser(ids: [tab.id])

        #expect(result == nil)
        #expect(isOnlyHolder(&probe))
    }

    @Test("Closing one of two tabs lets go of the closed tab's rows and its result")
    func closingOneTabReleasesItsResult() async throws {
        let fixture = makeFixture()
        _ = try await runResult(in: fixture, query: "SELECT * FROM kept")
        let tab = try await runResult(in: fixture, query: "SELECT * FROM trips")
        weak var result = fixture.tabManager.tabs.first { $0.id == tab.id }?.display.activeResultSet
        var probe = fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id).rows
        #expect(result != nil)

        fixture.coordinator.closeTabsByUser(ids: [tab.id])

        #expect(result == nil)
        #expect(isOnlyHolder(&probe))
    }
}

private final class RowsDriver: PluginDriverStub, @unchecked Sendable {
    private let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    // The run path pins a MySQL tab to its database before it runs, and the PluginKit default refuses the switch.
    func switchDatabase(to database: String) async throws {}

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        PluginQueryResult(
            columns: ["id", "name"],
            columnTypeNames: ["INTEGER", "TEXT"],
            rows: (0..<rowCount).map { [.text(String($0)), .text("a name long enough to live on the heap \($0)")] },
            rowsAffected: 0,
            executionTime: 0
        )
    }
}
