//
//  DatabendCatalogTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Databend catalog")
struct DatabendCatalogTests {
    @Test("Names are backtick-quoted, and a name holding a backtick switches to double quotes")
    func identifierQuoting() {
        #expect(DatabendCatalog.quoteIdentifier("orders") == "`orders`")
        #expect(DatabendCatalog.quoteIdentifier("b\\s") == "`b\\s`")
        #expect(DatabendCatalog.quoteIdentifier("t`u") == "\"t`u\"")
        #expect(DatabendCatalog.quoteIdentifier("t`u\"v") == "\"t`u\"\"v\"")
        #expect(DatabendCatalog.quoteIdentifier("t`u\\") == "\"t`u\\\\\"")
    }

    @Test("A system.columns row becomes the column, default and comment included")
    func parsesSystemColumnsRow() throws {
        let row: [PluginCellValue] = [.text("label"), .text("VARCHAR"), .text("DEFAULT"), .text("'x'"), .text("YES"), .text("cmt")]
        let column = try #require(DatabendCatalog.column(from: row))
        #expect(column.name == "label")
        #expect(column.dataType == "VARCHAR")
        #expect(column.isNullable)
        #expect(!column.isPrimaryKey)
        #expect(column.defaultValue == "'x'")
        #expect(column.comment == "cmt")
    }

    @Test("A column without a default kind has no default, and an empty comment is none")
    func parsesColumnWithoutDefault() throws {
        let row: [PluginCellValue] = [.text("id"), .text("int"), .text(""), .text(""), .text("NO"), .text("")]
        let column = try #require(DatabendCatalog.column(from: row))
        #expect(column.dataType == "INT")
        #expect(!column.isNullable)
        #expect(column.defaultValue == nil)
        #expect(column.comment == nil)
    }

    @Test("The whole-database read carries the table name first")
    func parsesBulkRow() throws {
        let row: [PluginCellValue] = [.text("t"), .text("a"), .text("ARRAY(INT32)"), .text(""), .text(""), .text("YES"), .text("")]
        let column = try #require(DatabendCatalog.column(from: row, offset: 1))
        #expect(column.name == "a")
        #expect(column.dataType == "ARRAY(INT32)")
    }

    @Test("Catalog queries escape the names they are given")
    func queriesEscapeNames() {
        let query = DatabendCatalog.columnsQuery(database: "d'b", table: "t\\x")
        #expect(query.contains("`database` = 'd''b'"))
        #expect(query.contains("`table` = 't\\\\x'"))
        #expect(DatabendCatalog.checkConstraintsQuery(database: "db", table: "t").contains("type = 'check'"))
    }

    @Test("A column is written with Databend's nullability, default and comment and nothing MySQL-only")
    func columnDefinition() {
        let column = PluginColumnDefinition(
            name: "label", dataType: "VARCHAR", isNullable: true, defaultValue: "'x'",
            autoIncrement: true, comment: "it's", unsigned: true, onUpdate: "CURRENT_TIMESTAMP",
            charset: "utf8mb4", collation: "utf8mb4_bin"
        )
        #expect(DatabendCatalog.columnDefinitionSQL(column) == "`label` VARCHAR NULL DEFAULT 'x' COMMENT 'it''s'")
    }

    @Test("CREATE TABLE lists the columns and adds no key, index or engine")
    func createTable() {
        let definition = PluginCreateTableDefinition(
            tableName: "events",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "BIGINT", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "at", dataType: "TIMESTAMP", isNullable: true, defaultValue: "now()")
            ],
            primaryKeyColumns: ["id"],
            engine: "InnoDB",
            ifNotExists: true
        )
        #expect(DatabendCatalog.createTableSQL(definition: definition) == """
            CREATE TABLE IF NOT EXISTS `events` (
                `id` BIGINT NOT NULL,
                `at` TIMESTAMP NULL DEFAULT now()
            );
            """)
    }

    @Test("A rename uses RENAME COLUMN and a changed definition restates the whole column")
    func modifyColumn() {
        let old = PluginColumnDefinition(name: "a", dataType: "INT", isNullable: true, comment: "c")
        let renamed = PluginColumnDefinition(name: "b", dataType: "INT", isNullable: true, comment: "c")
        let retyped = PluginColumnDefinition(name: "b", dataType: "BIGINT", isNullable: false, comment: "c")

        #expect(DatabendCatalog.modifyColumnSQL(table: "t", oldColumn: old, newColumn: renamed)
            == "ALTER TABLE `t` RENAME COLUMN `a` TO `b`")
        #expect(DatabendCatalog.modifyColumnSQL(table: "t", oldColumn: old, newColumn: retyped)
            == "ALTER TABLE `t` RENAME COLUMN `a` TO `b`;\nALTER TABLE `t` MODIFY COLUMN `b` BIGINT NOT NULL COMMENT 'c'")
        #expect(DatabendCatalog.modifyColumnSQL(table: "t", oldColumn: old, newColumn: old) == nil)
    }

    @Test("Table metadata reads information_schema.tables by name")
    func tableMetadata() throws {
        let row: [PluginCellValue] = [.text("w"), .text("2"), .text("556"), .text("868"), .text(""), .text("FUSE")]
        let metadata = try #require(DatabendCatalog.tableMetadata(from: row))
        #expect(metadata.tableName == "w")
        #expect(metadata.rowCount == 2)
        #expect(metadata.totalSize == 1_424)
        #expect(metadata.comment == nil)
        #expect(metadata.engine == "FUSE")
    }
}
