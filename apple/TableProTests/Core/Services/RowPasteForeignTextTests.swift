//
//  RowPasteForeignTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RowPasteForeignTextTests {
    private static let columns = ["id", "name", "email"]

    private func parse(_ text: String, primaryKey: [String] = ["id"]) throws -> [[PluginCellValue]] {
        let schema = TableSchema(columns: Self.columns, primaryKeyColumns: primaryKey)
        return try TSVRowParser().parse(text, schema: schema).get().map(\.values)
    }

    @Test("A row whose first cell is empty keeps every value in its own column")
    func leadingEmptyFieldStaysInPlace() throws {
        let rows = try parse("\tAnn\tann@x.com\n\tBob\tbob@x.com")

        #expect(rows == [
            [.text("__DEFAULT__"), .text("Ann"), .text("ann@x.com")],
            [.text("__DEFAULT__"), .text("Bob"), .text("bob@x.com")]
        ])
    }

    @Test("An empty first cell reads as NULL when the table has no key to reset")
    func leadingEmptyFieldIsNullWithoutAKey() throws {
        let rows = try parse("\tAnn\tann@x.com", primaryKey: [])

        #expect(rows == [[.null, .text("Ann"), .text("ann@x.com")]])
    }

    @Test("Trailing empty cells stay NULL and blank lines are not rows")
    func trailingEmptyFieldsAndBlankLines() throws {
        let rows = try parse("7\tAnn\t\r\n\r\n8\t\tbob@x.com\n \n", primaryKey: [])

        #expect(rows == [
            [.text("7"), .text("Ann"), .null],
            [.text("8"), .null, .text("bob@x.com")]
        ])
    }

    @Test("A cell keeps its own leading and trailing spaces")
    func cellSpacesAreKept() throws {
        let rows = try parse("7\t  indented\ttrailing  ", primaryKey: [])

        #expect(rows == [[.text("7"), .text("  indented"), .text("trailing  ")]])
    }

    @Test("Pasting spreadsheet rows with a blank first column lands each value under its header")
    func pasteThroughTheManager() {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        let manager = RowOperationsManager(changeManager: changeManager)
        let clipboard = RecordingClipboard()
        clipboard.text = "\tAnn\tann@x.com"
        var rows = TableRows.from(
            queryRows: [],
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count)
        )

        let result = manager.pasteRowsFromClipboard(
            columns: Self.columns, primaryKeyColumns: ["id"], tableRows: &rows, clipboard: clipboard
        )

        #expect(result.pastedRows.first?.values == [.text("__DEFAULT__"), .text("Ann"), .text("ann@x.com")])
    }
}

@MainActor
struct RowPasteBatchRecordingTests {
    private static let columns = ["id", "name"]

    private func makeManagers() -> (RowOperationsManager, DataChangeManager, UndoManager) {
        let changeManager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        changeManager.undoManagerProvider = { undoManager }
        changeManager.configureForTable(
            tableName: "users",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        return (RowOperationsManager(changeManager: changeManager), changeManager, undoManager)
    }

    private func paste(_ text: String, with manager: RowOperationsManager, into rows: inout TableRows)
        -> RowOperationsManager.PasteRowsResult
    {
        let clipboard = RecordingClipboard()
        clipboard.text = text
        return manager.pasteRowsFromClipboard(
            columns: Self.columns, primaryKeyColumns: ["id"], tableRows: &rows, clipboard: clipboard
        )
    }

    private func emptyRows() -> TableRows {
        TableRows.from(
            queryRows: [["1", "Zed"]],
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count)
        )
    }

    @Test("A paste of several rows is one undo step, and its redo puts every row back")
    func pasteIsOneUndoStep() {
        let (manager, changeManager, undoManager) = makeManagers()
        var rows = emptyRows()
        var applied: [UndoResult] = []
        changeManager.onUndoApplied = { applied.append($0) }

        let result = paste("7\tAnn\n8\tBob\n9\tCy", with: manager, into: &rows)

        let pastedIDs = Set(result.pastedRows.map { $0.rowID })
        let pastedValues = result.pastedRows.map { $0.values }
        #expect(result.delta == .rowsInserted(IndexSet(integersIn: 1..<4)))
        #expect(changeManager.insertedRowIDs == pastedIDs)
        #expect(rows.count == 4)

        undoManager.undo()
        #expect(changeManager.insertedRowIDs.isEmpty)
        #expect(!changeManager.hasChanges)
        #expect(!undoManager.canUndo)
        for step in applied {
            _ = manager.applyUndoResult(step, tableRows: &rows)
        }
        applied.removeAll()
        #expect(rows.count == 1)

        undoManager.redo()
        #expect(changeManager.insertedRowIDs.count == 3)
        for step in applied {
            _ = manager.applyUndoResult(step, tableRows: &rows)
        }
        #expect(rows.count == 4)
        let restoredValues = rows.rows.suffix(3).map { Array($0.values) }
        #expect(restoredValues == pastedValues)
    }

    @Test("The batch entry point records every row with its values, missing fields and expressions")
    func batchInsertionRecordsEachRow() {
        let (_, changeManager, _) = makeManagers()
        let first = RowID.inserted(UUID())
        let second = RowID.inserted(UUID())

        changeManager.recordBatchRowInsertion(rows: [
            DataChangeManager.InsertedRow(
                location: InsertedRowLocation(rowID: first, storageIndex: 0), values: ["1", "now()"],
                expressionColumns: [1]
            ),
            DataChangeManager.InsertedRow(
                location: InsertedRowLocation(rowID: second, storageIndex: 1), values: ["2", nil],
                absentColumns: [1]
            )
        ])

        let state = changeManager.saveState()
        #expect(state.insertedRowData[first] == ["1", "now()"])
        #expect(state.insertedRowData[second] == ["2", nil])
        #expect(changeManager.expressionColumns(forRow: first) == [1])
        let secondChange = changeManager.changes.first { $0.rowID == second }
        #expect(secondChange?.absentColumns == [1])
        #expect(changeManager.hasChanges)
    }
}
