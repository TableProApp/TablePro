// A failed Run All makes an empty error result active and seeds the row buffer from it. The old grid
// skipped its whole update while a cell editor or viewer was open, so the previous result's headings,
// row and selection stayed under the error. The model forwards every change whatever the view is doing.

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class SeedFixture {
    let coordinator: MainContentCoordinator
    let tabManager: QueryTabManager
    let tabId: UUID

    init(previous: TableRows) {
        tabManager = QueryTabManager()
        coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let tab = QueryTab(title: "Query 1", query: "SELECT 3 AS third_col;", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        tabId = tab.id

        let result = ResultSet(label: "Result 1", tableRows: previous)
        tabManager.mutate(tabId: tabId) { tab in
            tab.display.resultSets = [result]
            tab.display.activeResultSetId = result.id
        }
        coordinator.setActiveTableRows(previous, for: tabId)
    }

    var model: DataGridModel {
        coordinator.gridModel(forTab: tabId)
    }

    var tab: QueryTab? {
        tabManager.tabs.first { $0.id == tabId }
    }

    // What a failed Run All does once its statements ran: the results plus an error result, the error active.
    func failRun() {
        let errorResult = ResultSet(label: "Result 2")
        errorResult.errorMessage = "Statement 2/2 failed: no such table: missing_table"
        coordinator.flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
        tabManager.mutate(tabId: tabId) { tab in
            tab.execution.errorMessage = errorResult.errorMessage
            tab.display.replaceUnpinnedResults(with: [ResultSet(label: "Result 1"), errorResult])
        }
        coordinator.seedBufferFromActiveResult(tabId: tabId)
    }

    func close() {
        coordinator.teardown()
    }
}

@MainActor
struct SeedBufferFromErrorResultTests {
    private static let previous = TableRows.from(
        queryRows: [[.text("3")]],
        columns: ["third_col"],
        columnTypes: [.text(rawType: nil)]
    )

    @Test("a failed run under an open cell editor still takes down the previous columns and rows")
    func failureUnderAnOpenEditorReconcilesTheGrid() throws {
        let fixture = SeedFixture(previous: Self.previous)
        defer { fixture.close() }
        let model = fixture.model
        let mount = DataTabGridMountStub()
        model.attach(mount)
        mount.isEditing = true
        try #require(model.columns.orderedNames == ["third_col"])

        fixture.failRun()

        #expect(model.columns.isEmpty)
        #expect(model.rowCount == 0)
        #expect(mount.changes.contains(.columnsChanged))
        #expect(mount.changes.last == .reload)
        withExtendedLifetime(mount) {}
    }

    @Test("a failed run drops the row selection the previous result's rows made")
    func failureClearsThePreviousSelection() throws {
        let fixture = SeedFixture(previous: Self.previous)
        defer { fixture.close() }
        let model = fixture.model
        model.selectRows([.existing(0)])
        try #require(model.selectedRowIDs == [.existing(0)])

        fixture.failRun()

        #expect(model.selection.isEmpty)
        #expect(fixture.tab?.selectionSnapshot.isEmpty == true)
        #expect(fixture.coordinator.tabSessionRegistry.tableRows(for: fixture.tabId).columns.isEmpty)
    }
}
