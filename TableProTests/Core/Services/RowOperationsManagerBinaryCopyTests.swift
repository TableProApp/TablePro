//
//  RowOperationsManagerBinaryCopyTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class BinaryCopyClipboard: ClipboardProvider {
    var writtenRows: String?

    func readText() -> String? { nil }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) {}
    func writeCsv(_ csv: String) {}
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { writtenRows = tsv }
    var hasText: Bool { false }
    var hasGridRows: Bool { false }
}

@MainActor
struct RowOperationsManagerBinaryCopyTests {
    private func makeManagerAndRows(binaryRow: [PluginCellValue]) -> (RowOperationsManager, TableRows) {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        let rowOps = RowOperationsManager(changeManager: changeManager)
        let tableRows = TableRows.from(
            queryRows: [binaryRow],
            columns: ["id", "payload"],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "BYTEA")]
        )
        return (rowOps, tableRows)
    }

    /// The copy goes through `ClipboardService.shared`, and the system pasteboard reads back empty
    /// on a headless runner, so the text is taken from a clipboard installed for the one copy.
    private func copiedText(_ rowOps: RowOperationsManager, _ tableRows: TableRows) -> String {
        let clipboard = BinaryCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }
        rowOps.copySelectedRowsToClipboard(selectedIndices: [0], tableRows: tableRows)
        return clipboard.writtenRows ?? ""
    }

    @Test("Issue #1188 row copies binary cell as 0xHEX, not NULL")
    func issue1188CopyAsHex() {
        let bytes = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let (rowOps, tableRows) = makeManagerAndRows(binaryRow: [.text("1"), .bytes(bytes)])

        let copied = copiedText(rowOps, tableRows)
        #expect(copied.contains("0xD38CE566"))
        #expect(!copied.contains("NULL"))
        #expect(copied.contains("\t"))
    }

    @Test("Empty bytes copies as 0x")
    func emptyBytesCopiesAsZeroX() {
        let (rowOps, tableRows) = makeManagerAndRows(binaryRow: [.text("1"), .bytes(Data())])

        let copied = copiedText(rowOps, tableRows)

        #expect(copied.contains("0x") || copied.hasSuffix("\t"))
        #expect(!copied.contains("NULL"))
    }

    @Test("Mixed null and binary preserves both")
    func mixedNullAndBytes() {
        let (rowOps, tableRows) = makeManagerAndRows(binaryRow: [.null, .bytes(Data([0xAA, 0xBB]))])

        let copied = copiedText(rowOps, tableRows)

        #expect(copied.contains("NULL"))
        #expect(copied.contains("0xAABB"))
    }
}
