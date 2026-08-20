//
//  CellPasteRoutingTests.swift
//  TableProTests
//
//  Locks the contract that pasteCellsFromClipboard defers to row paste
//  when the clipboard carries the in-app gridRows tag or has a row-shaped
//  TSV. Without these checks, Cmd+V on a focused cell after Cmd+C on a row
//  silently overwrites the row's tail columns.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class NoopColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class StubClipboard: ClipboardProvider {
    var text: String?
    var hasGridRowsValue = false

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { self.text = text; hasGridRowsValue = false }
    func writeCsv(_ csv: String) { self.text = csv; hasGridRowsValue = false }
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) {
        self.text = tsv
        hasGridRowsValue = true
    }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { hasGridRowsValue }
}

@Suite("pasteCellsFromClipboard routing")
@MainActor
struct CellPasteRoutingTests {
    private func makeCoordinator(columns: [String], rowCount: Int) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopColumnLayoutPersister()
        )
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let rows = (0..<rowCount).map { i in (0..<columns.count).map { c in "r\(i)c\(c)" } }
        let tableRows = TableRows.from(queryRows: rows.map { row in row.map { PluginCellValue.text($0) } }, columns: columns, columnTypes: columnTypes)
        coordinator.tableRowsProvider = { tableRows }
        coordinator.updateCache()
        return coordinator
    }

    @Test("Defers to row paste when clipboard has gridRows tag")
    func defersOnGridRowsTag() {
        let stub = StubClipboard()
        stub.text = "anything\twith\ttabs"
        stub.hasGridRowsValue = true
        ClipboardService.shared = stub

        let coordinator = makeCoordinator(columns: ["a", "b", "c"], rowCount: 5)
        let result = coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: 0)

        #expect(result == false)
    }

    @Test("Defers to row paste when every TSV line matches column count")
    func defersOnRowShapedTSV() {
        let stub = StubClipboard()
        stub.text = "x\ty\tz\nq\tw\te"
        stub.hasGridRowsValue = false
        ClipboardService.shared = stub

        let coordinator = makeCoordinator(columns: ["a", "b", "c"], rowCount: 5)
        let result = coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: 0)

        #expect(result == false)
    }

    @Test("Cell pastes shape-mismatched TSV into focused range")
    func cellPastesShapeMismatchedTSV() {
        let stub = StubClipboard()
        stub.text = "x\ty"
        stub.hasGridRowsValue = false
        ClipboardService.shared = stub

        let coordinator = makeCoordinator(columns: ["a", "b", "c", "d", "e"], rowCount: 5)
        let result = coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: 0)

        #expect(result == true)
    }

    /// #2172: a one-value clipboard used to be refused here and fall through to row paste, which
    /// appended a row and left the focused cell untouched. Copying a cell and pasting it into
    /// another cell has to fill that cell.
    @Test("Cell pastes a single copied value into the focused cell")
    func cellPastesSingleValue() {
        let stub = StubClipboard()
        stub.text = "hello"
        stub.hasGridRowsValue = false
        ClipboardService.shared = stub

        let coordinator = makeCoordinator(columns: ["a", "b", "c"], rowCount: 5)

        #expect(coordinator.canPasteCellsFromClipboard(anchorRow: 2, anchorColumn: 1))
        #expect(coordinator.pasteCellsFromClipboard(anchorRow: 2, anchorColumn: 1))
    }

    @Test("A single value still defers to row paste when the clipboard carries the gridRows tag")
    func singleValueDefersOnGridRowsTag() {
        let stub = StubClipboard()
        stub.text = "hello"
        stub.hasGridRowsValue = true
        ClipboardService.shared = stub

        let coordinator = makeCoordinator(columns: ["a", "b", "c"], rowCount: 5)

        #expect(coordinator.canPasteCellsFromClipboard(anchorRow: 2, anchorColumn: 1) == false)
        #expect(coordinator.pasteCellsFromClipboard(anchorRow: 2, anchorColumn: 1) == false)
    }

    @Test("A single value fills the cell even in a one-column table, where it looks row-shaped")
    func singleValueInSingleColumnTable() {
        let stub = StubClipboard()
        stub.text = "hello"
        stub.hasGridRowsValue = false
        ClipboardService.shared = stub

        let coordinator = makeCoordinator(columns: ["a"], rowCount: 3)

        #expect(coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: 0))
    }

    @Test("canPasteCellsFromClipboard agrees with pasteCellsFromClipboard and mutates nothing")
    func canPasteAgreesAndDoesNotMutate() {
        let stub = StubClipboard()
        stub.text = "x\ty"
        stub.hasGridRowsValue = false
        ClipboardService.shared = stub

        let coordinator = makeCoordinator(columns: ["a", "b", "c", "d", "e"], rowCount: 5)
        let before = Array(coordinator.tableRowsProvider().rows)

        #expect(coordinator.canPasteCellsFromClipboard(anchorRow: 0, anchorColumn: 0))
        #expect(Array(coordinator.tableRowsProvider().rows) == before)
        #expect(coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: 0))
    }

    @Test("Returns false when not editable")
    func refusesWhenReadOnly() {
        let stub = StubClipboard()
        stub.text = "x\ty"
        ClipboardService.shared = stub

        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopColumnLayoutPersister()
        )

        let result = coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: 0)

        #expect(result == false)
    }
}
