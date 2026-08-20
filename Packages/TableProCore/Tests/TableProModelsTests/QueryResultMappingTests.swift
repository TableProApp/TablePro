import Testing
import Foundation
@testable import TableProModels
@testable import TableProPluginKit

@Suite("QueryResult Mapping Tests")
struct QueryResultMappingTests {
    @Test("Maps PluginQueryResult to QueryResult")
    func mapPluginQueryResult() {
        let plugin = PluginQueryResult(
            columns: ["id", "name", "email"],
            columnTypeNames: ["INTEGER", "VARCHAR", "VARCHAR"],
            rows: [["1", "Alice", "alice@test.com"], ["2", "Bob", nil]],
            rowsAffected: 0,
            executionTime: 0.042,
            isTruncated: false,
            statusMessage: "OK"
        )

        let result = QueryResult(from: plugin)

        #expect(result.columns.count == 3)
        #expect(result.columns[0].name == "id")
        #expect(result.columns[0].typeName == "INTEGER")
        #expect(result.columns[0].ordinalPosition == 0)
        #expect(result.columns[2].name == "email")
        #expect(result.columns[2].ordinalPosition == 2)
        #expect(result.rows.count == 2)
        #expect(result.rows[1][2] == nil)
        #expect(result.executionTime == 0.042)
        #expect(result.statusMessage == "OK")
    }

    @Test("PluginCellValue rows convert to legacy strings (null, text, bytes as hex)")
    func mapsCellValuesToLegacyStrings() {
        let plugin = PluginQueryResult(
            columns: ["t", "n", "b"],
            columnTypeNames: ["TEXT", "TEXT", "BLOB"],
            rows: [[.text("hi"), .null, .bytes(Data([0xAB, 0xCD]))]],
            rowsAffected: 0,
            executionTime: 0
        )

        let result = QueryResult(from: plugin)

        #expect(result.rows[0][0] == "hi")
        #expect(result.rows[0][1] == nil)
        #expect(result.rows[0][2] == "ABCD")
    }

    @Test("Maps PluginTableInfo to TableInfo")
    func mapPluginTableInfo() {
        let tablePlugin = PluginTableInfo(name: "users", type: "TABLE", rowCount: 1000)
        let table = TableInfo(from: tablePlugin)
        #expect(table.name == "users")
        #expect(table.type == .table)
        #expect(table.rowCount == 1000)

        let viewPlugin = PluginTableInfo(name: "active_users", type: "VIEW")
        let view = TableInfo(from: viewPlugin)
        #expect(view.type == .view)

        let matViewPlugin = PluginTableInfo(name: "summary", type: "MATERIALIZED VIEW")
        let matView = TableInfo(from: matViewPlugin)
        #expect(matView.type == .materializedView)
    }

    @Test("Maps PluginColumnInfo to ColumnInfo")
    func mapPluginColumnInfo() {
        let plugin = PluginColumnInfo(
            name: "email",
            dataType: "VARCHAR(255)",
            isNullable: false,
            isPrimaryKey: false,
            defaultValue: nil,
            comment: "User email"
        )
        let col = ColumnInfo(from: plugin, ordinalPosition: 2)
        #expect(col.name == "email")
        #expect(col.typeName == "VARCHAR(255)")
        #expect(col.isNullable == false)
        #expect(col.comment == "User email")
        #expect(col.ordinalPosition == 2)
    }

    @Test("Maps PluginIndexInfo to IndexInfo")
    func mapPluginIndexInfo() {
        let plugin = PluginIndexInfo(
            name: "idx_email",
            columns: ["email"],
            isUnique: true,
            isPrimary: false,
            type: "BTREE"
        )
        let index = IndexInfo(from: plugin)
        #expect(index.name == "idx_email")
        #expect(index.columns == ["email"])
        #expect(index.isUnique)
        #expect(!index.isPrimary)
    }

    @Test("Maps PluginForeignKeyInfo to ForeignKeyInfo")
    func mapPluginForeignKeyInfo() {
        let plugin = PluginForeignKeyInfo(
            name: "fk_user",
            column: "user_id",
            referencedTable: "users",
            referencedColumn: "id",
            referencedSchema: "other_schema",
            onDelete: "CASCADE",
            onUpdate: "NO ACTION"
        )
        let fk = ForeignKeyInfo(from: plugin)
        #expect(fk.name == "fk_user")
        #expect(fk.column == "user_id")
        #expect(fk.referencedTable == "users")
        #expect(fk.referencedSchema == "other_schema")
        #expect(fk.onDelete == "CASCADE")
    }
}
