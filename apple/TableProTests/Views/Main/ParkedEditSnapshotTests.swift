import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ParkedEditSnapshotTests {
    private func parkedEdits() -> TabChangeSnapshot {
        var snapshot = TabChangeSnapshot()
        snapshot.insertedRowIDs = [.inserted(UUID())]
        snapshot.columns = ["id", "name"]
        snapshot.primaryKeyColumns = ["id"]
        return snapshot
    }

    @Test("A result installed on a background tab drops the edits parked for its old result")
    func backgroundResultDropsParkedEdits() throws {
        let fixture = CoordinatorFixture()
        let background = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM orders", tabType: .query))
        fixture.tabManager.mutate(tabId: background.id) { $0.pendingChanges = self.parkedEdits() }
        fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query))

        fixture.coordinator.queryExecutionCoordinator.presentMultiStatementResults(
            tabId: background.id,
            timing: PluginQueryTiming(total: 0),
            totalRowsAffected: 0,
            newResultSets: [ResultSet(label: "Result 1", tableRows: TableRows())],
            sessionNotice: nil
        )

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == background.id })
        #expect(!tab.pendingChanges.hasChanges)
    }

    @Test("Edits parked on one result are not restored onto the result that replaced it")
    func switchingBackDropsEditsOfAReplacedResult() throws {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        let users = ResultSet(label: "users", tableRows: TableRows())
        fixture.tabManager.mutate(tabId: edited.id) { $0.display.replaceUnpinnedResults(with: [users]) }
        fixture.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        fixture.changeManager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["1", "a"]
        )

        fixture.tabManager.selectedTabId = other.id
        fixture.coordinator.handleTabChange(from: edited.id, to: other.id, tabs: fixture.tabManager.tabs)
        let parked = try #require(fixture.tabManager.tabs.first { $0.id == edited.id }).pendingChanges
        #expect(parked.hasChanges)
        #expect(parked.resultSetId == users.id)

        // Written straight to the tab, as a result landing in the turn before the switch handler ran would be.
        let orders = ResultSet(label: "orders", tableRows: TableRows())
        fixture.tabManager.mutate(tabId: edited.id) { $0.display.replaceUnpinnedResults(with: [orders]) }
        fixture.tabManager.selectedTabId = edited.id
        fixture.coordinator.handleTabChange(from: other.id, to: edited.id, tabs: fixture.tabManager.tabs)

        #expect(!fixture.changeManager.hasChanges)
        #expect(!(try #require(fixture.tabManager.tabs.first { $0.id == edited.id })).pendingChanges.hasChanges)
    }

    @Test("A result that lands before the switch handler runs voids the edits still in the change manager")
    func resultLandingBeforeTheSwitchHandlerVoidsTheEdits() throws {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        let users = ResultSet(label: "users", tableRows: TableRows())
        fixture.tabManager.mutate(tabId: edited.id) { $0.display.replaceUnpinnedResults(with: [users]) }
        fixture.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        fixture.changeManager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["1", "a"]
        )

        // The selection moved, the handler has not run yet, and the run finishes in between.
        fixture.tabManager.selectedTabId = other.id
        fixture.coordinator.queryExecutionCoordinator.presentMultiStatementResults(
            tabId: edited.id,
            timing: PluginQueryTiming(total: 0),
            totalRowsAffected: 0,
            newResultSets: [ResultSet(label: "orders", tableRows: TableRows())],
            sessionNotice: nil
        )
        fixture.coordinator.handleTabChange(from: edited.id, to: other.id, tabs: fixture.tabManager.tabs)
        #expect(!(try #require(fixture.tabManager.tabs.first { $0.id == edited.id })).pendingChanges.hasChanges)

        fixture.tabManager.selectedTabId = edited.id
        fixture.coordinator.handleTabChange(from: other.id, to: edited.id, tabs: fixture.tabManager.tabs)
        #expect(!fixture.changeManager.hasChanges)
    }

    @Test("A tab reselected without the switch handler keeps the edits it stages afterwards")
    func reselectWithoutTheHandlerKeepsLaterEdits() throws {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        let third = fixture.addTab(QueryTab(title: "C", query: "SELECT 2", tabType: .query), select: false)

        // A to B and back inside one update: a result lands on A in between, and no handler runs.
        fixture.tabManager.selectedTabId = other.id
        fixture.coordinator.dropParkedEdits(ofBackgroundTab: edited.id)
        fixture.tabManager.selectedTabId = edited.id
        fixture.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        fixture.changeManager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["1", "a"]
        )

        fixture.tabManager.selectedTabId = third.id
        fixture.coordinator.handleTabChange(from: edited.id, to: third.id, tabs: fixture.tabManager.tabs)

        #expect((try #require(fixture.tabManager.tabs.first { $0.id == edited.id })).pendingChanges.hasChanges)
    }

    @Test("A result installed on the selected tab clears its off-screen mark")
    func resultOnTheSelectedTabClearsTheMark() throws {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        fixture.tabManager.selectedTabId = other.id
        fixture.coordinator.dropParkedEdits(ofBackgroundTab: edited.id)
        fixture.tabManager.selectedTabId = edited.id

        fixture.coordinator.queryExecutionCoordinator.presentMultiStatementResults(
            tabId: edited.id,
            timing: PluginQueryTiming(total: 0),
            totalRowsAffected: 0,
            newResultSets: [ResultSet(label: "users", tableRows: TableRows())],
            sessionNotice: nil
        )

        #expect(fixture.coordinator.tabsGivenResultOffScreen.keys.contains(edited.id) == false)
    }

    @Test("Edits come back when the tab still shows the result they were made on")
    func switchingBackRestoresEditsOfTheSameResult() throws {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        let users = ResultSet(label: "users", tableRows: TableRows())
        fixture.tabManager.mutate(tabId: edited.id) { $0.display.replaceUnpinnedResults(with: [users]) }
        fixture.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        fixture.changeManager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["1", "a"]
        )

        fixture.tabManager.selectedTabId = other.id
        fixture.coordinator.handleTabChange(from: edited.id, to: other.id, tabs: fixture.tabManager.tabs)
        #expect(!fixture.changeManager.hasChanges)
        fixture.tabManager.selectedTabId = edited.id
        fixture.coordinator.handleTabChange(from: other.id, to: edited.id, tabs: fixture.tabManager.tabs)

        #expect(fixture.changeManager.hasChanges)
    }

    @Test("Only a background tab's parked edits are dropped")
    func selectedTabKeepsItsSnapshot() throws {
        let fixture = CoordinatorFixture()
        let selected = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM orders", tabType: .query))
        fixture.tabManager.mutate(tabId: selected.id) { $0.pendingChanges = self.parkedEdits() }

        fixture.coordinator.dropParkedEdits(ofBackgroundTab: selected.id)

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == selected.id })
        #expect(tab.pendingChanges.hasChanges)
    }
}
