//
//  ClearedCellCommitTests.swift
//  TableProTests
//
//  An emptied cell in a column whose type has no empty value is staged as NULL, so a cleared
//  MySQL `deleted_at` is written as NULL rather than the server's zero date. A NOT NULL column of
//  such a type refuses the edit, since it holds neither value.
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopClearedCellLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class ClearedCellRowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@MainActor
private struct ClearedCellFixture {
    static let columns = ["id", "deleted_at", "name", "visits", "created_at", "doc"]
    static let deletedAt = 1
    static let name = 2
    static let visits = 3
    static let createdAt = 4
    static let doc = 5

    let manager: DataChangeManager
    let coordinator: TableViewCoordinator
    let store: ClearedCellRowStore

    init() {
        manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopClearedCellLayoutPersister()
        )
        let created: PluginCellValue = .text("2023-12-01 09:00:00")
        let doc: PluginCellValue = .text("{\"a\":1}")
        store = ClearedCellRowStore(TableRows.from(
            queryRows: [
                [.text("1"), .text("2024-01-01 10:00:00"), .text("Alice"), .text("3"), created, doc],
                [.text("2"), .text("2024-02-02 10:00:00"), .text("Bob"), .text("4"), created, doc],
                [.text("3"), .text("2024-03-03 10:00:00"), .text("Carol"), .text("5"), created, doc]
            ],
            columns: Self.columns,
            columnTypes: [
                .integer(rawType: "INT"),
                .datetime(rawType: "DATETIME"),
                .text(rawType: "VARCHAR(255)"),
                .integer(rawType: "INT"),
                .timestamp(rawType: "TIMESTAMP"),
                .json(rawType: "JSON")
            ],
            columnNullable: ["deleted_at": true, "name": true, "created_at": false]
        ))
        let store = store
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.updateCache()
    }

    func value(row: Int, column: Int) -> PluginCellValue {
        store.tableRows.rows[row].values[column]
    }

    func stagedValue(row: Int, column: Int) -> PluginCellValue? {
        manager.pending.change(forRow: .existing(row), type: .update)?
            .cellChanges.first { $0.columnIndex == column }?.newValue
    }
}

@MainActor
struct ClearedCellCommitTests {
    @Test("Clearing a date cell stages NULL and the UPDATE binds NULL, not an empty string")
    func clearedDateIsNull() throws {
        let fixture = ClearedCellFixture()

        fixture.coordinator.commitCellEdit(row: 0, columnIndex: ClearedCellFixture.deletedAt, newValue: "")

        #expect(fixture.stagedValue(row: 0, column: ClearedCellFixture.deletedAt) == .null)
        #expect(fixture.value(row: 0, column: ClearedCellFixture.deletedAt) == .null)
        let statement = try #require(try fixture.manager.generateSQL().first)
        #expect(statement.sql.contains("`deleted_at` = ?"))
        let boundValue = try #require(statement.parameters.first)
        #expect(boundValue == nil)
    }

    @Test("Clearing a text cell keeps the empty string, which is a value there")
    func clearedTextStaysEmpty() {
        let fixture = ClearedCellFixture()

        fixture.coordinator.commitCellEdit(row: 0, columnIndex: ClearedCellFixture.name, newValue: "")

        #expect(fixture.stagedValue(row: 0, column: ClearedCellFixture.name) == .text(""))
        #expect(fixture.value(row: 0, column: ClearedCellFixture.name) == .text(""))
    }

    @Test("Clearing a NOT NULL timestamp stages nothing and keeps the stored value")
    func clearedNotNullTimestampIsRefused() {
        let fixture = ClearedCellFixture()

        fixture.coordinator.commitCellEdit(row: 0, columnIndex: ClearedCellFixture.createdAt, newValue: "")

        #expect(fixture.manager.hasChanges == false)
        #expect(fixture.value(row: 0, column: ClearedCellFixture.createdAt) == .text("2023-12-01 09:00:00"))
    }

    @Test("A detached editor's cleared number commits NULL into the row it was opened for")
    func clearedNumberByRowIDIsNull() {
        let fixture = ClearedCellFixture()

        fixture.coordinator.commitCellEdit(rowID: .existing(2), columnIndex: ClearedCellFixture.visits, newValue: "")

        #expect(fixture.stagedValue(row: 2, column: ClearedCellFixture.visits) == .null)
    }

    @Test("The JSON editor's cleared document commits NULL, which a JSON column can hold where '' is refused")
    func clearedJSONIsNull() {
        let fixture = ClearedCellFixture()

        fixture.coordinator.commitCellEdit(
            rowID: .existing(1), fallbackDisplayRow: 1, columnIndex: ClearedCellFixture.doc, newValue: ""
        )

        #expect(fixture.stagedValue(row: 1, column: ClearedCellFixture.doc) == .null)
    }

    @Test("An empty Fill Column on a date writes NULL into every row")
    func emptyFillOnDateIsNull() throws {
        let fixture = ClearedCellFixture()
        let value = try #require(
            fixture.coordinator.fillColumnValue(text: "", setNull: false, columnIndex: ClearedCellFixture.deletedAt)
        )

        fixture.coordinator.applyFillColumn(columnIndex: ClearedCellFixture.deletedAt, value: value)

        for row in 0..<3 {
            #expect(fixture.stagedValue(row: row, column: ClearedCellFixture.deletedAt) == .null)
        }
    }

    @Test("An empty Fill Column on a NOT NULL timestamp has no value to write")
    func emptyFillOnNotNullTimestampIsRefused() {
        let fixture = ClearedCellFixture()

        #expect(fixture.coordinator.fillColumnValue(text: "", setNull: false, columnIndex: ClearedCellFixture.createdAt) == nil)
        #expect(
            fixture.coordinator.fillColumnValue(text: "2024-05-05 00:00:00", setNull: false, columnIndex: ClearedCellFixture.createdAt)
                == .text("2024-05-05 00:00:00")
        )
    }

    @Test("Set Value offers Empty on a text column and not on a date or a number")
    func setValueEmptyFollowsColumnType() {
        let fixture = ClearedCellFixture()
        let rowView = DataGridRowView()

        let dateTitles = rowView.buildSetValueMenu(
            dataColumnIndex: ClearedCellFixture.deletedAt, tableRows: fixture.store.tableRows
        ).items.map { $0.title }
        let numberTitles = rowView.buildSetValueMenu(
            dataColumnIndex: ClearedCellFixture.visits, tableRows: fixture.store.tableRows
        ).items.map { $0.title }
        let textTitles = rowView.buildSetValueMenu(
            dataColumnIndex: ClearedCellFixture.name, tableRows: fixture.store.tableRows
        ).items.map { $0.title }

        #expect(!dateTitles.contains("Empty"))
        #expect(dateTitles.contains("NULL"))
        #expect(!numberTitles.contains("Empty"))
        #expect(textTitles.contains("Empty"))
    }

    @Test("Set Value offers Empty on an enum only when one of its labels is empty")
    func setValueEmptyOnEnumFollowsLabels() {
        let tableRows = TableRows.from(
            queryRows: [[.text("a"), .text("x")]],
            columns: ["plain", "withEmpty"],
            columnTypes: [.enumType(rawType: "ENUM", values: nil), .enumType(rawType: "ENUM", values: nil)],
            columnEnumValues: ["plain": ["a", "b"], "withEmpty": ["", "x"]]
        )
        let rowView = DataGridRowView()

        #expect(!rowView.buildSetValueMenu(dataColumnIndex: 0, tableRows: tableRows).items.map { $0.title }.contains("Empty"))
        #expect(rowView.buildSetValueMenu(dataColumnIndex: 1, tableRows: tableRows).items.map { $0.title }.contains("Empty"))
    }

    @Test("A NOT NULL number with no default offers no Set Value items at all")
    func setValueMenuEmptyForNotNullNumber() {
        let tableRows = TableRows.from(
            queryRows: [[.text("1")]],
            columns: ["visits"],
            columnTypes: [.integer(rawType: "INT")],
            columnNullable: ["visits": false]
        )

        #expect(DataGridRowView().buildSetValueMenu(dataColumnIndex: 0, tableRows: tableRows).items.isEmpty)
    }

    @Test("Pasted lines keep an empty line as a value and drop the closing line breaks")
    func pastedLines() {
        #expect(TableViewCoordinator.pastedLines("a\n\nc") == ["a", "", "c"])
        #expect(TableViewCoordinator.pastedLines("a\nb\n") == ["a", "b"])
        #expect(TableViewCoordinator.pastedLines("hello\n\n") == ["hello"])
        #expect(TableViewCoordinator.pastedLines("a") == ["a"])
    }

    @Test("A CRLF copy splits into the same lines as a LF copy")
    func pastedLinesFoldCRLF() {
        #expect(TableViewCoordinator.pastedLines("a\r\n\r\nc\r\n") == ["a", "", "c"])
        #expect(TableViewCoordinator.pastedLines("x\ty\r\nq\tw\r\n") == ["x\ty", "q\tw"])
    }

    @Test("A pasted NULL is NULL where the type cannot hold the text, and text everywhere else")
    func pastedText() {
        let datetime = ColumnType.datetime(rawType: "DATETIME")
        let varchar = ColumnType.text(rawType: "VARCHAR(20)")
        func pasted(_ field: String, _ columnType: ColumnType?) -> String? {
            TableViewCoordinator.pastedText(field, columnType: columnType)
        }
        #expect(pasted("NULL", datetime) == nil)
        #expect(pasted("NULL", .integer(rawType: "INT")) == nil)
        #expect(pasted("NULL", varchar) == "NULL")
        #expect(pasted("NULL", .enumType(rawType: "ENUM", values: ["NULL", "a"])) == "NULL")
        #expect(pasted("NULL", nil) == "NULL")
        #expect(pasted("", datetime) == "")
        #expect(pasted("null", datetime) == "null")
    }

}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct ClearedCellPasteTests {
        @Test("An empty pasted field lands as NULL in a date column and as the empty string in text")
        func emptyPastedFieldFollowsColumnType() throws {
            let stub = try #require(RecordingClipboard.current)
            stub.text = "\t"
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: ClearedCellFixture.deletedAt))

            #expect(fixture.value(row: 0, column: ClearedCellFixture.deletedAt) == .null)
            #expect(fixture.value(row: 0, column: ClearedCellFixture.name) == .text(""))
        }

        @Test("A copied NULL pasted into a date cell is NULL, not the text NULL")
        func pastedNullIsNull() throws {
            let stub = try #require(RecordingClipboard.current)
            stub.text = "NULL"
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: ClearedCellFixture.deletedAt))

            #expect(fixture.value(row: 1, column: ClearedCellFixture.deletedAt) == .null)
        }

        @Test("The text NULL pasted into a text cell stays text, since a stored 'NULL' copies the same way")
        func pastedNullTextIntoTextStaysText() throws {
            let stub = try #require(RecordingClipboard.current)
            stub.text = "NULL"
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: ClearedCellFixture.name))

            #expect(fixture.value(row: 1, column: ClearedCellFixture.name) == .text("NULL"))
        }

        @Test("A NULL copied from the grid pastes as NULL into a text cell")
        func copiedNullRoundTripsIntoText() throws {
            let fixture = ClearedCellFixture()
            fixture.coordinator.commitCellEdit(row: 0, columnIndex: ClearedCellFixture.name, newValue: nil)

            fixture.coordinator.copyCellValue(at: 0, columnIndex: ClearedCellFixture.name)
            let clipboard = try #require(RecordingClipboard.current)
            #expect(clipboard.text == "NULL")
            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: ClearedCellFixture.name))

            #expect(fixture.value(row: 1, column: ClearedCellFixture.name) == .null)
        }

        @Test("The grid's copy pastes field by field, so a line break inside a value moves nothing")
        func gridCopyKeepsFieldBoundaries() throws {
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.writeCells(GridCellsClipboardPayload(text: "first\nsecond\nNULL", fields: [["first\nsecond"], [nil]]))
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: ClearedCellFixture.name))

            #expect(fixture.value(row: 0, column: ClearedCellFixture.name) == .text("first\nsecond"))
            #expect(fixture.value(row: 1, column: ClearedCellFixture.name) == .null)
            #expect(fixture.value(row: 2, column: ClearedCellFixture.name) == .text("Carol"))
        }

        @Test("Fields left behind by text another app wrote over the copy are not used")
        func staleGridCopyIsIgnored() throws {
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.text = "NULL"
            clipboard.gridCells = GridCellsClipboardPayload(text: "other", fields: [[nil]])
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: ClearedCellFixture.name))

            #expect(fixture.value(row: 0, column: ClearedCellFixture.name) == .text("NULL"))
        }

        @Test("A stored 'NULL' copied from the grid pastes as the same text")
        func copiedNullTextRoundTripsAsText() throws {
            let fixture = ClearedCellFixture()
            fixture.coordinator.commitCellEdit(row: 0, columnIndex: ClearedCellFixture.name, newValue: "NULL")

            fixture.coordinator.copyCellValue(at: 0, columnIndex: ClearedCellFixture.name)
            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 2, anchorColumn: ClearedCellFixture.name))

            #expect(fixture.value(row: 2, column: ClearedCellFixture.name) == .text("NULL"))
        }

        @Test("A copied NULL pasted into a NOT NULL column leaves the cell as it was")
        func pastedNullIntoNotNullIsRefused() throws {
            let stub = try #require(RecordingClipboard.current)
            stub.text = "NULL"
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: ClearedCellFixture.createdAt))

            #expect(fixture.value(row: 1, column: ClearedCellFixture.createdAt) == .text("2023-12-01 09:00:00"))
            #expect(fixture.manager.hasChanges == false)
        }

        @Test("A block that opens on an empty line still fills every column of the lines below it")
        func leadingEmptyLineKeepsBlockWidth() throws {
            let stub = try #require(RecordingClipboard.current)
            stub.text = "\nZed\t9"
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: ClearedCellFixture.name))

            #expect(fixture.value(row: 0, column: ClearedCellFixture.name) == .text(""))
            #expect(fixture.value(row: 1, column: ClearedCellFixture.name) == .text("Zed"))
            #expect(fixture.value(row: 1, column: ClearedCellFixture.visits) == .text("9"))
        }

        @Test("An empty line in a pasted column keeps the values below it on their own rows")
        func emptyLineKeepsRowsAligned() throws {
            let stub = try #require(RecordingClipboard.current)
            stub.text = "Xavier\n\nZoe"
            let fixture = ClearedCellFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: ClearedCellFixture.name))

            #expect(fixture.value(row: 0, column: ClearedCellFixture.name) == .text("Xavier"))
            #expect(fixture.value(row: 1, column: ClearedCellFixture.name) == .text(""))
            #expect(fixture.value(row: 2, column: ClearedCellFixture.name) == .text("Zoe"))
        }
    }
}
