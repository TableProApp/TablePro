import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ResultPinning")
struct ResultPinningTests {
    @Test("A new execution replaces unpinned results and keeps pinned ones")
    @MainActor
    func replaceKeepsPinnedResults() {
        var display = TabDisplayState()
        let pinned = Self.makeResultSet(label: "kept", isPinned: true)
        let scratch = Self.makeResultSet(label: "scratch")
        display.resultSets = [pinned, scratch]
        display.activeResultSetId = scratch.id

        let fresh = Self.makeResultSet(label: "fresh")
        display.replaceUnpinnedResults(with: [fresh])

        #expect(display.resultSets.map(\.id) == [pinned.id, fresh.id])
        #expect(display.activeResultSetId == fresh.id)
    }

    @Test("A new execution never targets a pinned result when every result is pinned")
    @MainActor
    func replaceWhenAllResultsArePinned() {
        var display = TabDisplayState()
        let first = Self.makeResultSet(label: "first", isPinned: true)
        let second = Self.makeResultSet(label: "second", isPinned: true)
        display.resultSets = [first, second]
        display.activeResultSetId = second.id

        let fresh = Self.makeResultSet(label: "fresh")
        display.replaceUnpinnedResults(with: [fresh])

        #expect(display.resultSets.map(\.id) == [first.id, second.id, fresh.id])
        #expect(display.activeResultSetId == fresh.id)
        #expect(first.isPinned)
        #expect(second.isPinned)
    }

    @Test("A multi-statement execution appends every statement result after the pinned ones")
    @MainActor
    func replaceWithMultipleStatementResults() {
        var display = TabDisplayState()
        let pinned = Self.makeResultSet(label: "kept", isPinned: true)
        display.resultSets = [pinned, Self.makeResultSet(label: "scratch")]

        let first = Self.makeResultSet(label: "Result 1")
        let second = Self.makeResultSet(label: "Result 2")
        display.replaceUnpinnedResults(with: [first, second])

        #expect(display.resultSets.map(\.id) == [pinned.id, first.id, second.id])
        #expect(display.activeResultSetId == second.id)
    }

    @Test("Removing unpinned results keeps the pinned ones and reactivates the last")
    @MainActor
    func removeUnpinnedKeepsPinned() {
        var display = TabDisplayState()
        let pinned = Self.makeResultSet(label: "kept", isPinned: true)
        let scratch = Self.makeResultSet(label: "scratch")
        display.resultSets = [pinned, scratch]
        display.activeResultSetId = scratch.id

        display.removeUnpinnedResults()

        #expect(display.resultSets.map(\.id) == [pinned.id])
        #expect(display.activeResultSetId == pinned.id)
    }

    @Test("Clearing results keeps a pinned result and its rows")
    @MainActor
    func clearKeepsPinnedResultAndRows() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")
        let tabId = try #require(coordinator.tabManager.selectedTab?.id)
        let index = try #require(coordinator.tabManager.selectedTabIndex)

        let pinnedRows = TestFixtures.makeTableRows(rowCount: 3)
        let pinned = ResultSet(label: "kept", tableRows: pinnedRows)
        pinned.isPinned = true
        let scratch = ResultSet(label: "scratch", tableRows: TestFixtures.makeTableRows(rowCount: 7))

        coordinator.tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [pinned, scratch]
            tab.display.activeResultSetId = scratch.id
            tab.execution.lastExecutedAt = Date()
        }
        coordinator.setActiveTableRows(scratch.tableRows, for: tabId)

        coordinator.clearActiveQueryResults()

        let tab = try #require(coordinator.tabManager.selectedTab)
        #expect(tab.display.resultSets.map(\.id) == [pinned.id])
        #expect(tab.display.activeResultSetId == pinned.id)
        #expect(pinned.tableRows.rows.count == 3)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 3)
        #expect(tab.display.isResultsCollapsed == false)
    }

    @Test("Closing a pinned result is refused")
    @MainActor
    func closeRefusesPinnedResult() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")
        let index = try #require(coordinator.tabManager.selectedTabIndex)
        let pinned = Self.makeResultSet(label: "kept", isPinned: true)
        coordinator.tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [pinned]
            tab.display.activeResultSetId = pinned.id
        }

        coordinator.closeResultSet(id: pinned.id)

        #expect(coordinator.tabManager.selectedTab?.display.resultSets.map(\.id) == [pinned.id])
    }

    @Test("Toggling pin flips the flag on the addressed result")
    @MainActor
    func togglePinFlipsFlag() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")
        let index = try #require(coordinator.tabManager.selectedTabIndex)
        let result = Self.makeResultSet(label: "Result")
        coordinator.tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [result]
            tab.display.activeResultSetId = result.id
        }

        #expect(coordinator.isActiveResultSetPinned == false)
        coordinator.togglePinResultSet(id: result.id)
        #expect(result.isPinned)
        #expect(coordinator.isActiveResultSetPinned)

        coordinator.togglePinResultSet(id: result.id)
        #expect(result.isPinned == false)
    }

    @Test("A single result can be pinned; a table tab result cannot")
    @MainActor
    func pinGating() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")
        #expect(coordinator.canPinActiveResultSet == false)

        let index = try #require(coordinator.tabManager.selectedTabIndex)
        let result = Self.makeResultSet(label: "Result")
        coordinator.tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [result]
            tab.display.activeResultSetId = result.id
        }
        #expect(coordinator.canPinActiveResultSet)

        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        let tableIndex = try #require(coordinator.tabManager.selectedTabIndex)
        let browsed = Self.makeResultSet(label: "users")
        coordinator.tabManager.mutate(at: tableIndex) { tab in
            tab.display.resultSets = [browsed]
            tab.display.activeResultSetId = browsed.id
        }
        #expect(coordinator.canPinActiveResultSet == false)
    }

    @Test("A tab holding a pinned result is not reusable")
    @MainActor
    func pinnedResultBlocksTabReuse() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")
        #expect(coordinator.isActiveTabReusable)

        let index = try #require(coordinator.tabManager.selectedTabIndex)
        let pinned = Self.makeResultSet(label: "kept", isPinned: true)
        coordinator.tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [pinned]
            tab.display.activeResultSetId = pinned.id
        }

        #expect(coordinator.isActiveTabReusable == false)
    }

    @Test("Reusing a tab for another table drops its result sets")
    @MainActor
    func replacingTabContentDropsResultSets() throws {
        let tabManager = QueryTabManager()
        tabManager.addTab(databaseName: "db")
        let index = try #require(tabManager.selectedTabIndex)
        let pinned = Self.makeResultSet(label: "orders", isPinned: true)
        tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [pinned]
            tab.display.activeResultSetId = pinned.id
        }

        let replaced = try tabManager.replaceTabContent(
            tableName: "users", databaseType: .mysql, databaseName: "db"
        )

        #expect(replaced)
        let tab = try #require(tabManager.selectedTab)
        #expect(tab.display.resultSets.isEmpty)
        #expect(tab.display.activeResultSetId == nil)
    }

    @MainActor
    private static func makeResultSet(label: String, isPinned: Bool = false) -> ResultSet {
        let resultSet = ResultSet(label: label)
        resultSet.isPinned = isPinned
        return resultSet
    }

    @MainActor
    private static func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }
}
