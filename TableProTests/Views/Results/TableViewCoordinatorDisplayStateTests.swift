//
//  TableViewCoordinatorDisplayStateTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TableViewCoordinator retained display state")
@MainActor
struct TableViewCoordinatorDisplayStateTests {
    private static let rows = TableRows(
        rows: [Row(id: .existing(0), values: [.text("A")])],
        columns: ["name"],
        columnTypes: [.text(rawType: nil)]
    )

    /// The order `DataGridView.makeNSView` runs in. The two calls after the adopt are what used to
    /// discard the text it had just been handed, because a fresh coordinator reports the first
    /// schema and the first format list it sees as a change.
    private func mount(
        displayState: DataGridDisplayState? = nil,
        displayFormats: [ValueDisplayFormat?] = []
    ) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeDisplayStatePersister()
        )
        var rows = Self.rows
        coordinator.tableRowsProvider = { rows }
        coordinator.tableRowsMutator = { mutation in mutation(&rows) }
        if let displayState {
            coordinator.adoptDisplayState(displayState)
        }
        coordinator.syncDisplayFormats(displayFormats)
        coordinator.rebuildColumnMetadataCache(from: rows)
        coordinator.updateCache()
        return coordinator
    }

    private func text(_ coordinator: TableViewCoordinator, raw: String) -> String? {
        coordinator.displayValue(
            forID: .existing(0),
            column: 0,
            rawValue: .text(raw),
            columnType: .text(rawType: nil)
        )
    }

    @Test("A remount reuses the formatted text the previous grid produced")
    func remountReusesFormattedText() {
        let state = DataGridDisplayState()
        let first = mount(displayState: state)
        #expect(text(first, raw: "A") == "A")

        let remounted = mount(displayState: state)
        #expect(text(remounted, raw: "B") == "A")
    }

    @Test("A remount with a display format applied still reuses the formatted text")
    func remountWithDisplayFormatsReusesFormattedText() {
        let formats: [ValueDisplayFormat?] = [.raw]
        let state = DataGridDisplayState()
        let first = mount(displayState: state, displayFormats: formats)
        #expect(text(first, raw: "A") == "A")

        let remounted = mount(displayState: state, displayFormats: formats)
        #expect(text(remounted, raw: "B") == "A")
    }

    @Test("A grid with no owner formats from scratch on every mount")
    func unownedGridDoesNotShareText() {
        let first = mount()
        #expect(text(first, raw: "A") == "A")

        let second = mount()
        #expect(text(second, raw: "B") == "B")
    }

    @Test("Adopting a state takes over its viewport anchor")
    func adoptingTakesOverTheViewportAnchor() {
        let state = DataGridDisplayState()
        state.firstVisibleRow = 3_200
        #expect(mount(displayState: state).scrollAnchorRow == 3_200)
    }

    @Test("Restoring an anchor puts the row back at the top of a real scroll view")
    func restoringAnAnchorScrollsTheGrid() {
        let rowCount = 1_000
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeDisplayStatePersister()
        )
        let rows = TableRows.from(
            queryRows: (0..<rowCount).map { [PluginCellValue.text("row \($0)")] },
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )
        coordinator.tableRowsProvider = { rows }

        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tableView.rowHeight = 24
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        tableView.dataSource = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scrollView.documentView = tableView
        scrollView.layoutSubtreeIfNeeded()
        coordinator.tableView = tableView
        coordinator.updateCache()
        tableView.reloadData()

        let state = DataGridDisplayState()
        state.firstVisibleRow = 500
        coordinator.adoptDisplayState(state)
        coordinator.restoreScrollAnchor()

        #expect(scrollView.contentView.bounds.origin.y == tableView.rect(ofRow: 500).origin.y)
        /// Consumed by the restore, so a later update over the same rows does not drag the user
        /// back to where they were two switches ago.
        #expect(coordinator.scrollAnchorRow == 0)
    }
}

private final class FakeDisplayStatePersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}

    func clear(for key: ColumnLayoutTableKey) {}
}
