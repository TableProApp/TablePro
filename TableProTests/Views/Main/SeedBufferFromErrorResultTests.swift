//
//  SeedBufferFromErrorResultTests.swift
//  TableProTests
//
//  A failed Run All makes an empty error result active and seeds the row buffer from it. The grid
//  skips its whole update while a cell editor or viewer is open, and only a full replace closes
//  them, so a seed that did not take that path left the previous result's headings, row and
//  selection under the error for as long as the viewer stayed up.
//
//  The grid is a real `DataGridView` in an `NSHostingView`, fed from the coordinator's buffer the
//  way the editor feeds it, because the early return lived in `updateNSView`.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class NoopSeedLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class SeedFixture {
    let coordinator: MainContentCoordinator
    let tabManager: QueryTabManager
    let tabId: UUID
    private let delegate = DataTabGridDelegate()
    private var window: NSWindow?
    private var host: NSHostingView<DataGridView>?

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
        coordinator.dataTabDelegate = delegate

        let result = ResultSet(label: "Result 1", tableRows: previous)
        tabManager.mutate(tabId: tabId) { tab in
            tab.display.resultSets = [result]
            tab.display.activeResultSetId = result.id
        }
        coordinator.setActiveTableRows(previous, for: tabId)
    }

    var grid: TableViewCoordinator? {
        delegate.tableViewCoordinator
    }

    var tableView: NSTableView? {
        grid?.tableView
    }

    var presentedHeadings: [String] {
        guard let tableView else { return [] }
        return tableView.tableColumns
            .filter { !$0.isHidden && $0.identifier != ColumnIdentitySchema.rowNumberIdentifier }
            .map(\.headerCell.stringValue)
    }

    var tab: QueryTab? {
        tabManager.tabs.first { $0.id == tabId }
    }

    func mountGrid() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: makeGrid())
        window.contentView = host
        self.window = window
        self.host = host
        settle()
    }

    /// A new root value, the way the editor hands the grid one on every render of the tab.
    func render() {
        host?.rootView = makeGrid()
        settle()
    }

    func openViewer(row: Int) -> Bool {
        guard let grid, let tableView,
              let column = tableView.tableColumns.firstIndex(where: {
                  !$0.isHidden && $0.identifier != ColumnIdentitySchema.rowNumberIdentifier
              })
        else { return false }
        grid.showOverlayViewer(tableView: tableView, row: row, column: column, columnIndex: 0, value: "3")
        return grid.overlayViewer?.isActive == true
    }

    /// What a failed Run All does to the tab once its statements have run: the results it produced plus
    /// an error result, the error result active, and the buffer seeded from it.
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
        grid?.overlayViewer?.dismiss()
        window?.orderOut(nil)
        coordinator.teardown()
    }

    private func makeGrid() -> DataGridView {
        let tabId = tabId
        return DataGridView(
            tableRowsProvider: { [coordinator] in
                coordinator.tabSessionRegistry.existingTableRows(for: tabId) ?? TableRows()
            },
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            configuration: DataGridConfiguration(tabType: .query),
            delegate: delegate,
            layoutPersister: NoopSeedLayoutPersister(),
            selectedRowIndices: .constant([]),
            sortState: .constant(SortState()),
            columnLayout: .constant(ColumnLayoutState())
        )
    }

    private func settle() {
        for _ in 0 ..< 10 {
            host?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }
}

@MainActor
struct SeedBufferFromErrorResultTests {
    private static let previous = TableRows.from(
        queryRows: [[.text("3")]],
        columns: ["third_col"],
        columnTypes: [.text(rawType: nil)]
    )

    @Test("a failed run over an open cell viewer closes it and takes down the previous headings")
    func failureOverAnOpenViewerReconcilesTheGrid() throws {
        let fixture = SeedFixture(previous: Self.previous)
        defer { fixture.close() }
        fixture.mountGrid()
        try #require(fixture.presentedHeadings == ["third_col"])
        try #require(fixture.openViewer(row: 0))

        fixture.failRun()
        fixture.render()

        #expect(fixture.grid?.overlayViewer?.isActive != true)
        #expect(fixture.presentedHeadings.isEmpty, "got \(fixture.presentedHeadings)")
        #expect(fixture.tableView?.numberOfRows == 0)
    }

    @Test("a failed run drops the row selection the previous result's rows made")
    func failureClearsThePreviousSelection() throws {
        let fixture = SeedFixture(previous: Self.previous)
        defer { fixture.close() }
        fixture.tabManager.mutate(tabId: fixture.tabId) { tab in
            tab.selectedRowIndices = [0]
        }
        try #require(fixture.tab?.selectedRowIndices == [0])

        fixture.failRun()

        #expect(fixture.tab?.selectedRowIndices.isEmpty == true)
        #expect(fixture.coordinator.tabSessionRegistry.tableRows(for: fixture.tabId).columns.isEmpty)
    }
}
