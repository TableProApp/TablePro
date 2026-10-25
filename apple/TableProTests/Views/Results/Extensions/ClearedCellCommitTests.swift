//
//  ClearedCellCommitTests.swift
//  TableProTests
//
//  An emptied cell in a column whose type has no empty value is staged as NULL, so a cleared MySQL `deleted_at` is
//  written as NULL rather than the server's zero date. A NOT NULL column of such a type refuses the edit.
//

import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class ClearedCellOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let manager: DataChangeManager
    let changeState: AnyChangeManager

    init(_ tableRows: TableRows) {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: tableRows.columns,
            primaryKeyColumns: [tableRows.columns[0]],
            databaseType: .mysql,
            generatedColumns: []
        )
        self.tableRows = tableRows
        self.manager = manager
        changeState = AnyChangeManager(manager)
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        for edit in edits {
            changeState.recordCellChange(
                rowID: edit.rowID,
                columnIndex: edit.dataIndex,
                columnName: edit.columnName,
                oldValue: edit.oldValue,
                newValue: edit.newValue,
                originalRow: edit.originalRow,
                absence: edit.absence,
                isExpression: edit.isExpression
            )
            if let index = tableRows.index(of: edit.rowID) {
                _ = tableRows.edit(row: index, column: edit.dataIndex, value: edit.newValue)
            }
        }
        return true
    }
}

@MainActor
private struct ClearedCellFixture {
    static let columns = ["id", "deleted_at", "name", "visits", "created_at", "doc"]

    let owner: ClearedCellOwner
    let model: DataGridModel

    init() {
        let created: PluginCellValue = .text("2023-12-01 09:00:00")
        let doc: PluginCellValue = .text("{\"a\":1}")
        let rows = TableRows.from(
            queryRows: [
                [.text("1"), .text("2024-01-01 10:00:00"), .text("Alice"), .text("3"), created, doc],
                [.text("2"), .text("2024-02-02 10:00:00"), .text("Bob"), .text("4"), created, doc],
                [.text("3"), .text("2024-03-03 10:00:00"), .text("Carol"), .text("5"), created, doc],
            ],
            columns: Self.columns,
            columnTypes: [
                .integer(rawType: "INT"),
                .datetime(rawType: "DATETIME"),
                .text(rawType: "VARCHAR(255)"),
                .integer(rawType: "INT"),
                .timestamp(rawType: "TIMESTAMP"),
                .json(rawType: "JSON"),
            ],
            columnNullable: ["deleted_at": true, "name": true, "created_at": false]
        )
        owner = ClearedCellOwner(rows)
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        configuration.traits = DataGridEngineTraits(databaseType: .mysql, cellWriterSupport: owner.manager.cellWriterSupport)
        model = DataGridModel(configuration: configuration)
        model.dataSource = owner
        model.actions = owner
        model.reloadRows()
    }

    @discardableResult
    func enter(_ text: String?, row: Int, column: String) -> Bool {
        let target = DataGridEditTarget(rowID: .existing(row), columnID: DataGridColumnID(name: column, occurrence: 0))
        return DataGridViewController.commitEnteredText(text, to: target, in: model)
    }

    func value(row: Int, column: String) -> PluginCellValue {
        let index = Self.columns.firstIndex(of: column) ?? 0
        return owner.tableRows.rows[row].values[index]
    }

    func stagedValue(row: Int, column: String) -> PluginCellValue? {
        let index = Self.columns.firstIndex(of: column) ?? 0
        return owner.manager.pending.change(forRow: .existing(row), type: .update)?
            .cellChanges.first { $0.columnIndex == index }?.newValue
    }
}

@MainActor
struct ClearedCellCommitTests {
    @Test("Clearing a date cell stages NULL and the UPDATE binds NULL, not an empty string")
    func clearedDateIsNull() throws {
        let fixture = ClearedCellFixture()

        #expect(fixture.enter("", row: 0, column: "deleted_at"))

        #expect(fixture.stagedValue(row: 0, column: "deleted_at") == .null)
        #expect(fixture.value(row: 0, column: "deleted_at") == .null)
        let statement = try #require(try fixture.owner.manager.generateSQL().first)
        #expect(statement.sql.contains("`deleted_at` = ?"))
        let boundValue = try #require(statement.parameters.first)
        #expect(boundValue == nil)
    }

    @Test("Clearing a text cell keeps the empty string, which is a value there")
    func clearedTextStaysEmpty() {
        let fixture = ClearedCellFixture()

        fixture.enter("", row: 0, column: "name")

        #expect(fixture.stagedValue(row: 0, column: "name") == .text(""))
        #expect(fixture.value(row: 0, column: "name") == .text(""))
    }

    @Test("Clearing a NOT NULL timestamp is refused, stages nothing and keeps the stored value")
    func clearedNotNullTimestampIsRefused() {
        let fixture = ClearedCellFixture()

        #expect(!fixture.enter("", row: 0, column: "created_at"))

        #expect(fixture.owner.manager.hasChanges == false)
        #expect(fixture.value(row: 0, column: "created_at") == .text("2023-12-01 09:00:00"))
    }

    @Test("A cleared number commits NULL into the record the editor opened on")
    func clearedNumberByRowIDIsNull() {
        let fixture = ClearedCellFixture()

        fixture.enter("", row: 2, column: "visits")

        #expect(fixture.stagedValue(row: 2, column: "visits") == .null)
    }

    @Test("The JSON editor's cleared document commits NULL, which a JSON column can hold where '' is refused")
    func clearedJSONIsNull() {
        let fixture = ClearedCellFixture()

        fixture.enter("", row: 1, column: "doc")

        #expect(fixture.stagedValue(row: 1, column: "doc") == .null)
    }

    @Test("A NULL from a menu's Set NULL item stages NULL over text")
    func menuNullIsNull() {
        let fixture = ClearedCellFixture()

        fixture.enter(nil, row: 0, column: "name")

        #expect(fixture.stagedValue(row: 0, column: "name") == .null)
    }
}
