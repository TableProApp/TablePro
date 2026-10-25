//
//  RowOperationsManagerUUIDKeyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct RowOperationsManagerUUIDKeyTests {
    private static let columns = ["id", "name", "created_at"]
    private static let columnTypes: [ColumnType] = [
        .text(rawType: "uuid"), .text(rawType: "text"), .timestamp(rawType: "timestamptz")
    ]
    private static let uuidKey: [Int: UUIDCellForm] = [0: .hyphenated]

    private func makeManager() -> (RowOperationsManager, DataChangeManager) {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "events",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        return (RowOperationsManager(changeManager: changeManager), changeManager)
    }

    private func makeRows(_ queryRows: [[PluginCellValue]] = [], columnDefaults: [String: String?] = [:]) -> TableRows {
        TableRows.from(
            queryRows: queryRows,
            columns: Self.columns,
            columnTypes: Self.columnTypes,
            columnDefaults: columnDefaults,
            hasAuthoritativeSchema: true
        )
    }

    private func uuidText(_ value: PluginCellValue?) -> String? {
        guard let text = value?.asText, UUID(uuidString: text) != nil, text == text.lowercased() else { return nil }
        return text
    }

    // MARK: - Add Row

    @Test("Add Row gives a UUID key the server does not fill a fresh UUID and reports it as prefilled")
    func addRowPrefillsTheKey() throws {
        let (manager, changeManager) = makeManager()
        var rows = makeRows()

        let first = try #require(manager.addNewRow(tableRows: &rows, uuidKeyForms: Self.uuidKey))
        let second = try #require(manager.addNewRow(tableRows: &rows, uuidKeyForms: Self.uuidKey))

        let firstKey = try #require(uuidText(first.values[0]))
        #expect(uuidText(second.values[0]) != firstKey)
        #expect(first.values[1] == .null)
        #expect(first.prefilledColumns == [0])
        #expect(rows.rows[0].values[0] == .text(firstKey))
        #expect(changeManager.isRowInserted(first.rowID))
    }

    @Test("Add Row without UUID keys leaves the key NULL and prefills nothing")
    func addRowWithoutUUIDKeys() throws {
        let (manager, _) = makeManager()
        var rows = makeRows()

        let result = try #require(manager.addNewRow(tableRows: &rows))

        #expect(result.values[0] == .null)
        #expect(result.prefilledColumns.isEmpty)
    }

    @Test("A key the server fills keeps DEFAULT even when it holds UUIDs")
    func addRowKeepsServerDefault() throws {
        let (manager, _) = makeManager()
        var rows = makeRows(columnDefaults: ["id": "gen_random_uuid()"])

        let result = try #require(manager.addNewRow(tableRows: &rows, uuidKeyForms: Self.uuidKey))

        #expect(result.values[0] == .text("__DEFAULT__"))
        #expect(result.prefilledColumns.isEmpty)
    }

    // MARK: - Duplicate Row

    @Test("Duplicate gives the copy a fresh UUID key instead of DEFAULT")
    func duplicatePutsAFreshUUID() throws {
        let (manager, _) = makeManager()
        let sourceKey = "0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001"
        var rows = makeRows([[.text(sourceKey), .text("a"), .text("2024-01-01 00:00:00+00")]])

        let copy = try #require(manager.duplicateRow(sourceRowIndex: 0, tableRows: &rows, uuidKeyForms: Self.uuidKey))
        let plain = try #require(manager.duplicateRow(sourceRowIndex: 0, tableRows: &rows))

        let copyKey = try #require(uuidText(copy.values[0]))
        #expect(copyKey != sourceKey)
        #expect(copy.values[1] == .text("a"))
        #expect(copy.prefilledColumns == [0])
        #expect(plain.values[0] == .text("__DEFAULT__"))
    }

    @Test("Duplicating a pending row keeps the SQL staged in it, except in the columns the copy resets")
    func duplicateKeepsExpressionMarks() throws {
        let (manager, changeManager) = makeManager()
        var rows = makeRows()
        let sourceID = RowID.inserted(UUID())
        let values: [PluginCellValue] = [.text("now()"), .text("a"), .text("now()")]
        _ = rows.appendInsertedRow(id: sourceID, values: values)
        changeManager.recordRowInsertion(rowID: sourceID, values: values, expressionColumns: [0, 2])

        let copy = try #require(manager.duplicateRow(sourceRowIndex: 0, tableRows: &rows, uuidKeyForms: Self.uuidKey))

        #expect(changeManager.expressionColumns(forRow: copy.rowID) == [2])
        #expect(copy.values[2] == .text("now()"))
        #expect(uuidText(copy.values[0]) != nil)
    }

    @Test("Duplicating a saved row stages no SQL")
    func duplicateOfASavedRowHasNoMarks() throws {
        let (manager, changeManager) = makeManager()
        var rows = makeRows([[.text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001"), .text("now()"), .null]])

        let copy = try #require(manager.duplicateRow(sourceRowIndex: 0, tableRows: &rows))

        #expect(changeManager.expressionColumns(forRow: copy.rowID).isEmpty)
    }

    // MARK: - Paste rows

    @Test("Pasted rows each get their own fresh UUID key")
    func pasteGivesEachRowAUUID() throws {
        let (manager, _) = makeManager()
        var rows = makeRows()
        let clipboard = RecordingClipboard()
        clipboard.text = "k1\tAnn\tNULL\nk2\tBob\tNULL"

        let result = manager.pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            tableRows: &rows,
            uuidKeyForms: Self.uuidKey,
            clipboard: clipboard
        )

        let keys = result.pastedRows.compactMap { uuidText($0.values[0]) }
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
        #expect(result.pastedRows.map { $0.values[1] } == [.text("Ann"), .text("Bob")])
    }

    @Test("Rows copied from the grid paste with fresh UUID keys too")
    func pasteStructuredRowsGivesUUIDs() {
        let (manager, _) = makeManager()
        var rows = makeRows()
        let clipboard = RecordingClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001"), .text("Ann"), .null]]
        )

        let result = manager.pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            tableRows: &rows,
            uuidKeyForms: Self.uuidKey,
            clipboard: clipboard
        )

        let key = uuidText(result.pastedRows.first?.values[0])
        #expect(key != nil)
        #expect(key != "0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001")
    }

    @Test("Pasted rows on a key that is not a UUID key still hand it to the server")
    func pasteWithoutUUIDKeysKeepsDefault() {
        let (manager, _) = makeManager()
        var rows = makeRows()
        let clipboard = RecordingClipboard()
        clipboard.text = "k1\tAnn\tNULL"

        let result = manager.pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            tableRows: &rows,
            clipboard: clipboard
        )

        #expect(result.pastedRows.first?.values[0] == .text("__DEFAULT__"))
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct RowOperationsExpressionClipboardTests {
        private static let columns = ["id", "name", "created_at"]

        private func makeManager() -> (RowOperationsManager, DataChangeManager) {
            let changeManager = DataChangeManager()
            changeManager.configureForTable(
                tableName: "events",
                columns: Self.columns,
                primaryKeyColumns: ["id"],
                databaseType: .postgresql,
                generatedColumns: []
            )
            return (RowOperationsManager(changeManager: changeManager), changeManager)
        }

        private func makeRows(_ queryRows: [[PluginCellValue]] = []) -> TableRows {
            TableRows.from(
                queryRows: queryRows,
                columns: Self.columns,
                columnTypes: [.text(rawType: "text"), .text(rawType: "text"), .timestamp(rawType: "timestamptz")],
                hasAuthoritativeSchema: true
            )
        }

        private func paste(
            _ manager: RowOperationsManager,
            into rows: inout TableRows
        ) throws -> RowOperationsManager.PasteRowsResult {
            let clipboard = try #require(RecordingClipboard.current)
            return manager.pasteRowsFromClipboard(
                columns: Self.columns,
                primaryKeyColumns: ["id"],
                tableRows: &rows,
                clipboard: clipboard
            )
        }

        @Test("Rows copied from the grid keep their staged SQL as SQL, and stored text that spells a function as text")
        func copiedRowsKeepTheirMarks() throws {
            let (manager, changeManager) = makeManager()
            var rows = makeRows([[.text("1"), .text("saved"), .text("CURRENT_TIMESTAMP")]])
            let pendingID = RowID.inserted(UUID())
            let pendingValues: [PluginCellValue] = [.text("2"), .text("pending"), .text("now()")]
            _ = rows.appendInsertedRow(id: pendingID, values: pendingValues)
            changeManager.recordRowInsertion(rowID: pendingID, values: pendingValues, expressionColumns: [2])

            manager.copyRowsToClipboard([.existing(0), pendingID], tableRows: rows)
            let payload = try #require(RecordingClipboard.current?.gridRows)
            #expect(payload.expressionCells == [1: [2]])

            let result = try paste(manager, into: &rows)

            let pasted = result.pastedRows.map(\.rowID)
            #expect(pasted.count == 2)
            #expect(changeManager.expressionColumns(forRow: pasted[0]).isEmpty)
            #expect(changeManager.expressionColumns(forRow: pasted[1]) == [2])
            #expect(result.pastedRows[0].values[2] == .text("CURRENT_TIMESTAMP"))
            #expect(result.pastedRows[1].values[2] == .text("now()"))
        }

        @Test("A copied mark on the key goes with the key's value, which the server assigns")
        func keyMarkIsDropped() throws {
            let (manager, changeManager) = makeManager()
            var rows = makeRows()
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.gridRows = GridRowsClipboardPayload(
                columns: Self.columns,
                rows: [[.text("now()"), .text("a"), .text("now()")]],
                expressionCells: [0: [0, 2]]
            )

            let result = try paste(manager, into: &rows)

            let rowID = try #require(result.pastedRows.first?.rowID)
            #expect(changeManager.expressionColumns(forRow: rowID) == [2])
        }

        @Test("Cells the grid copied as wide as the table paste as rows with their marks")
        func copiedCellsKeepTheirMarksAsRows() throws {
            let (manager, changeManager) = makeManager()
            var rows = makeRows()
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.writeCells(GridCellsClipboardPayload(
                text: "7\tAnn\tnow()\n8\tBob\tnow()",
                fields: [["7", "Ann", "now()"], ["8", "Bob", "now()"]],
                expressionFields: [0: [2]]
            ))

            let result = try paste(manager, into: &rows)

            let pasted = result.pastedRows.map(\.rowID)
            #expect(pasted.count == 2)
            #expect(changeManager.expressionColumns(forRow: pasted[0]) == [2])
            #expect(changeManager.expressionColumns(forRow: pasted[1]).isEmpty)
        }
    }
}
