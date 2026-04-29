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
import Testing
@testable import TablePro

@MainActor
private final class StubClipboard: ClipboardProvider {
    var text: String?
    var hasGridRowsValue = false

    func readText() -> String? { text }
    func writeText(_ text: String) { self.text = text; hasGridRowsValue = false }
    func writeRows(tsv: String, html: String?) { self.text = tsv; hasGridRowsValue = true }
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
            delegate: nil
        )
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let rows = (0..<rowCount).map { i in (0..<columns.count).map { c in "r\(i)c\(c)" } }
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)
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

    @Test("Returns false when not editable")
    func refusesWhenReadOnly() {
        let stub = StubClipboard()
        stub.text = "x\ty"
        ClipboardService.shared = stub

        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            selectedRowIndices: .constant([]),
            delegate: nil
        )

        let result = coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: 0)

        #expect(result == false)
    }
}
