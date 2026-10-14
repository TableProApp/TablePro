//
//  StructureListGridModelTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class ListClipboard: ClipboardProvider {
    var text: String?

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { self.text = text }
    func writeCsv(_ csv: String) { text = csv }
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { text = tsv }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { false }
}

@MainActor
private final class NoLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
struct StructureListGridModelTests {
    private let columns = ["Name", "Timing"]
    private let rows = [
        StructureListRow(id: "a", values: ["alpha", "BEFORE"]),
        StructureListRow(id: "b", values: ["beta", "AFTER"]),
        StructureListRow(id: "c", values: ["gamma", "AFTER"]),
    ]

    private func loadedModel(accessibilityLabel: String? = nil) -> StructureListGridModel<String> {
        let model = StructureListGridModel<String>(accessibilityLabel: accessibilityLabel)
        _ = model.ensureLoaded(key: 1, columns: columns) { rows }
        return model
    }

    private func makeCoordinator(tableView: NSTableView? = nil) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoLayoutPersister()
        )
        coordinator.tableView = tableView
        return coordinator
    }

    @Test("Rows are built once per content key, in the order given, as text cells")
    func buildsRowsOncePerKey() {
        let model = StructureListGridModel<String>()
        var builds = 0
        let loaded = model.ensureLoaded(key: 1, columns: columns) {
            builds += 1
            return rows
        }
        _ = model.ensureLoaded(key: 1, columns: columns) {
            builds += 1
            return rows
        }
        #expect(builds == 1)
        #expect(loaded.columns == columns)
        #expect(loaded.rows.map { $0.values.map(\.asText) } == rows.map { $0.values.map(Optional.some) })
        #expect(model.rowIDs == ["a", "b", "c"])

        let reordered = model.ensureLoaded(key: 2, columns: columns) {
            builds += 1
            return rows.reversed()
        }
        #expect(builds == 2)
        #expect(reordered.rows.first?.values.first?.asText == "gamma")
        #expect(model.rowIDs == ["c", "b", "a"])
    }

    @Test("A display row and a row id map both ways, and an unknown one maps to nothing")
    func mapsDisplayRowsAndIDs() {
        let model = loadedModel()
        #expect(model.id(atDisplayRow: 1) == "b")
        #expect(model.id(atDisplayRow: 3) == nil)
        #expect(model.id(atDisplayRow: -1) == nil)
        #expect(model.ids(atDisplayRows: [0, 2, 7]) == ["a", "c"])
        #expect(model.displayRows(of: ["c", "z"]) == [2])
        #expect(model.displayRows(of: []).isEmpty)
    }

    @Test("Copying rows writes them as tab-separated lines in display order")
    func copiesRowsAsTabSeparatedText() {
        let clipboard = ListClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        loadedModel().dataGridCopyRows([2, 0, 9])

        #expect(clipboard.text == "alpha\tBEFORE\ngamma\tAFTER")
    }

    @Test("Copying no row leaves the clipboard alone")
    func copyingNothingWritesNothing() {
        let clipboard = ListClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        loadedModel().dataGridCopyRows([])

        #expect(clipboard.text == nil)
    }

    @Test("A header click reaches the owner of the rows")
    func forwardsSortToOwner() {
        let model = loadedModel()
        var received: SortState?
        model.onSortStateChanged = { received = $0 }
        let state = SortState(columns: [SortColumn(columnIndex: 1, direction: .descending)], source: .user)

        model.dataGridSortStateChanged(state)

        #expect(received == state)
    }

    @Test("Every reload has the selection put back by identity")
    func rearmsSelectionRestoreOnAttach() {
        let coordinator = makeCoordinator()
        coordinator.hasRestoredSelection = true
        loadedModel().dataGridAttach(tableViewCoordinator: coordinator)
        #expect(!coordinator.hasRestoredSelection)
    }

    @Test("The selection binding maps rows to ids and back")
    func selectionBindingMapsBothWays() {
        let model = loadedModel()
        var ids: Set<String> = ["b"]
        let selection = model.selection(get: { ids }, set: { ids = $0 })

        #expect(selection.wrappedValue == [1])
        selection.wrappedValue = [0, 2]
        #expect(ids == ["a", "c"])
    }

    @Test("Rows published before the grid puts the selection back after a reload leave the ids alone")
    func dropsPublicationsDuringReload() {
        let model = loadedModel()
        let coordinator = makeCoordinator()
        model.dataGridAttach(tableViewCoordinator: coordinator)
        var ids: Set<String> = ["a", "b"]
        let selection = model.selection(get: { ids }, set: { ids = $0 })

        selection.wrappedValue = [2]
        #expect(ids == ["a", "b"])

        coordinator.hasRestoredSelection = true
        selection.wrappedValue = [2]
        #expect(ids == ["c"])
    }

    @Test("Republishing the rows the selection already shows keeps the ids a filter hides")
    func echoKeepsHiddenIDs() {
        let model = loadedModel()
        var ids: Set<String> = ["a", "hidden"]
        let selection = model.selection(get: { ids }, set: { ids = $0 })

        selection.wrappedValue = [0]
        #expect(ids == ["a", "hidden"])
    }

    @Test("Default widths fill only the columns the layout has no width for")
    func defaultWidthsFillMissingColumns() {
        var stored = ColumnLayoutState()
        stored.columnWidths["Timing"] = 300

        let layout = StructureListGrid<String>.layout(stored, columns: columns, defaultWidths: [220, 90])

        #expect(layout.columnWidths == ["Name": 220, "Timing": 300])
        #expect(StructureListGrid<String>.layout(stored, columns: columns, defaultWidths: []) == stored)
    }

    @Test("Minimum widths follow the columns by index and name nothing past them")
    func minimumWidthsFollowColumns() {
        #expect(StructureListGrid<String>.minimumWidths([140, 70], columns: columns) == ["Name": 140, "Timing": 70])
        #expect(StructureListGrid<String>.minimumWidths([140], columns: columns) == ["Name": 140])
        #expect(StructureListGrid<String>.minimumWidths([], columns: columns).isEmpty)
    }

    @Test("A spoken value is answered for its display row and column, and nothing else is")
    func answersSpokenValues() {
        let model = StructureListGridModel<String>()
        _ = model.ensureLoaded(key: 1, columns: columns) {
            [
                StructureListRow(id: "a", values: ["alpha", "YES"], spokenValues: [1: "Enabled"]),
                StructureListRow(id: "b", values: ["beta", "NO"]),
            ]
        }

        #expect(model.dataGridAccessibilityText(row: 0, column: 1) == "Enabled")
        #expect(model.dataGridAccessibilityText(row: 0, column: 0) == nil)
        #expect(model.dataGridAccessibilityText(row: 1, column: 1) == nil)
        #expect(model.dataGridAccessibilityText(row: 5, column: 1) == nil)
    }

    @Test("The grid is named for the list it shows")
    func namesTheGrid() {
        let tableView = NSTableView()
        tableView.setAccessibilityLabel(String(localized: "Data grid"))
        let coordinator = makeCoordinator(tableView: tableView)

        loadedModel(accessibilityLabel: StructureTab.triggers.displayName).dataGridAttach(tableViewCoordinator: coordinator)

        #expect(tableView.accessibilityLabel() == StructureTab.triggers.displayName)
    }
}
