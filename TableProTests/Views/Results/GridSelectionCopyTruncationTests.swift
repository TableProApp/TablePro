//
//  GridSelectionCopyTruncationTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class TruncationClipboard: ClipboardProvider {
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
private final class TruncationLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
struct GridSelectionCopyTruncationTests {
    private func makeCoordinator(rowCount: Int) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: TruncationLayoutPersister()
        )
        let tableRows = TableRows.from(
            queryRows: (0..<rowCount).map { [.text("\($0)"), .text("v\($0)")] },
            columns: ["id", "value"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.updateCache()
        return coordinator
    }

    private static func block(rowCount: Int) -> GridSelection {
        .single(
            GridRect(rows: 0...(rowCount - 1), columns: 0...1),
            anchor: GridCoord(row: 0, displayColumn: 0),
            active: GridCoord(row: rowCount - 1, displayColumn: 1)
        )
    }

    @Test("a cell copy cut at the row cap says how many rows it left out")
    func copyPastTheCapSaysSo() {
        let clipboard = TruncationClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }
        let cap = RowOperationsManager.maxClipboardRows
        let rowCount = cap + 2
        let coordinator = makeCoordinator(rowCount: rowCount)

        coordinator.copyGridSelection(Self.block(rowCount: rowCount))

        let lines = clipboard.text?.components(separatedBy: "\n") ?? []
        #expect(lines.count == cap + 1)
        #expect(lines.first == "0\tv0")
        #expect(lines.dropLast().last == "\(cap - 1)\tv\(cap - 1)")
        #expect(lines.last == "(truncated, showing first \(cap) of \(rowCount) rows)")
    }

    @Test("a cell copy under the cap carries no notice")
    func copyUnderTheCapHasNoNotice() {
        let clipboard = TruncationClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }
        let coordinator = makeCoordinator(rowCount: 3)

        coordinator.copyGridSelection(Self.block(rowCount: 3))

        #expect(clipboard.text == "0\tv0\n1\tv1\n2\tv2")
    }
}
