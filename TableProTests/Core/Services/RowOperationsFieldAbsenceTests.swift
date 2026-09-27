//
//  RowOperationsFieldAbsenceTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class AbsenceClipboard: ClipboardProvider {
    var written: GridRowsClipboardPayload?
    var gridRowsToRead: GridRowsClipboardPayload?
    var textToRead: String?

    func readText() -> String? { textToRead }
    func readGridRows() -> GridRowsClipboardPayload? { gridRowsToRead }
    func writeText(_ text: String) {}
    func writeCsv(_ csv: String) {}
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { written = gridRows }
    var hasText: Bool { textToRead != nil }
    var hasGridRows: Bool { gridRowsToRead != nil }
}

@MainActor
struct RowOperationsFieldAbsenceTests {
    private static let columns = ["_id", "name", "deletedAt"]

    private func makeManager(_ databaseType: DatabaseType = .mongodb) -> (RowOperationsManager, DataChangeManager) {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "items",
            columns: Self.columns,
            primaryKeyColumns: ["_id"],
            databaseType: databaseType,
            generatedColumns: []
        )
        return (RowOperationsManager(changeManager: changeManager), changeManager)
    }

    private func rows(_ queryRows: [[PluginCellValue]] = [], absentCells: [Int: Set<Int>] = [:]) -> TableRows {
        TableRows.from(
            queryRows: queryRows,
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count),
            hasAuthoritativeSchema: true,
            absentCells: absentCells
        )
    }

    private func paste(
        _ clipboard: AbsenceClipboard,
        into manager: RowOperationsManager,
        parser: RowDataParser? = nil
    ) -> (TableRows, RowOperationsManager.PasteRowsResult) {
        var tableRows = rows()
        let result = manager.pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["_id"],
            tableRows: &tableRows,
            clipboard: clipboard,
            parser: parser
        )
        return (tableRows, result)
    }

    @Test("A new MongoDB row starts with its fields missing, and a SQL row with NULLs")
    func newRowStartsMissingOnlyWhereFieldsCanBe() throws {
        let (mongo, mongoChanges) = makeManager()
        var mongoRows = rows()
        let added = try #require(mongo.addNewRow(tableRows: &mongoRows))

        #expect(mongoRows.rows[0].absentColumns == [0, 1, 2])
        #expect(mongoChanges.changes.first?.absentColumns == [0, 1, 2])
        #expect(added.values == [.null, .null, .null])

        let (sql, sqlChanges) = makeManager(.mysql)
        var sqlRows = rows()
        _ = sql.addNewRow(tableRows: &sqlRows)

        #expect(sqlRows.rows[0].absentColumns.isEmpty)
        #expect(sqlChanges.changes.first?.absentColumns.isEmpty == true)
    }

    @Test("A duplicated document keeps its NULL fields and leaves its missing fields missing")
    func duplicateCopiesAbsence() throws {
        let (manager, changes) = makeManager()
        var tableRows = rows([["1", "Ada", .null], ["2", "Bo", .null]], absentCells: [1: [2]])

        let nullKept = try #require(manager.duplicateRow(sourceRowIndex: 0, tableRows: &tableRows))
        let missingKept = try #require(manager.duplicateRow(sourceRowIndex: 1, tableRows: &tableRows))

        #expect(tableRows.row(withID: nullKept.rowID)?.absentColumns.isEmpty == true)
        #expect(tableRows.row(withID: missingKept.rowID)?.absentColumns == [2])
        #expect(changes.pending.insertedAbsentColumns(forRow: missingKept.rowID) == [2])
        #expect(missingKept.values[0] == .text("__DEFAULT__"))
    }

    @Test("Copying rows records which fields each lacked, in the copied column order")
    func copyWritesAbsence() throws {
        let (manager, _) = makeManager()
        let clipboard = AbsenceClipboard()
        ClipboardService.shared = clipboard
        let tableRows = rows([["1", "Ada", .null], ["2", "Bo", .null]], absentCells: [1: [2]])

        manager.copySelectedRowsToClipboard(selectedIndices: [0, 1], tableRows: tableRows, visibleColumnIndices: [2, 1])

        let payload = try #require(clipboard.written)
        #expect(payload.columns == ["deletedAt", "name"])
        #expect(payload.absentCells == [1: [0]])
    }

    @Test("Pasting copied rows leaves missing what the copy lacked, and what it did not carry")
    func structuredPasteCopiesAbsence() throws {
        let (manager, _) = makeManager()
        let clipboard = AbsenceClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: ["_id", "name"],
            rows: [["1", "Ada"], ["2", .null]],
            absentCells: [1: [1]]
        )

        let (tableRows, result) = paste(clipboard, into: manager)

        #expect(result.pastedRows.count == 2)
        #expect(tableRows.rows[0].absentColumns == [2])
        #expect(tableRows.rows[1].absentColumns == [1, 2])
    }

    @Test("A SQL paste leaves a column the copy did not carry NULL, as before")
    func sqlPasteHasNoAbsence() {
        let (manager, _) = makeManager(.mysql)
        let clipboard = AbsenceClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(columns: ["_id", "name"], rows: [["1", "Ada"]])

        let (tableRows, result) = paste(clipboard, into: manager)

        #expect(result.pastedRows.first?.values == [.text("__DEFAULT__"), "Ada", .null])
        #expect(tableRows.rows[0].absentColumns.isEmpty)
    }

    @Test("Pasted text says nothing about fields, so a NULL in it leaves the field out of a document")
    func textPasteReadsNullAsMissing() {
        let (manager, _) = makeManager()
        let clipboard = AbsenceClipboard()
        clipboard.textToRead = "1\tAda\tNULL"

        let (tableRows, _) = paste(clipboard, into: manager, parser: TSVRowParser())

        #expect(tableRows.rows[0].absentColumns == [2])
    }
}
