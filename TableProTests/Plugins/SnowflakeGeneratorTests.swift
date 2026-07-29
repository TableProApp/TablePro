//
//  SnowflakeGeneratorTests.swift
//  TableProTests
//
//  Tests for the Snowflake DML statement generator, DDL generator, and
//  SHOW-based schema query builders (compiled via symlinks from
//  SnowflakeDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Snowflake Statement Generator")
struct SnowflakeStatementGeneratorTests {
    private func generator(
        columns: [String] = ["id", "name", "payload"],
        types: [String] = ["NUMBER", "VARCHAR(100)", "VARIANT"],
        primaryKeys: [String] = ["id"]
    ) -> SnowflakeStatementGenerator {
        SnowflakeStatementGenerator(
            qualifiedTable: "\"DB\".\"PUBLIC\".\"T\"",
            columns: columns,
            columnTypeNames: types,
            primaryKeyColumns: primaryKeys
        )
    }

    private func update(_ column: String, to value: PluginCellValue, original: [PluginCellValue]) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: column, oldValue: .null, newValue: value)],
            originalRow: original
        )
    }

    @Test("Plain inserts use VALUES with placeholders")
    func testPlainInsert() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = generator(columns: ["id", "name"], types: ["NUMBER", "VARCHAR"], primaryKeys: ["id"])
            .generateStatements(
                from: [change],
                insertedRowData: [0: [.text("1"), .text("Alice")]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        #expect(result.count == 1)
        #expect(result[0].statement == "INSERT INTO \"DB\".\"PUBLIC\".\"T\" (\"id\", \"name\") VALUES (?, ?)")
        #expect(result[0].parameters == [.text("1"), .text("Alice")])
    }

    @Test("Inserts touching VARIANT columns use INSERT SELECT with PARSE_JSON")
    func testVariantInsertUsesSelect() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let result = generator().generateStatements(
            from: [change],
            insertedRowData: [0: [.text("1"), .text("Alice"), .text("{\"a\":1}")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        #expect(result[0].statement ==
            "INSERT INTO \"DB\".\"PUBLIC\".\"T\" (\"id\", \"name\", \"payload\") SELECT ?, ?, PARSE_JSON(?)")
    }

    @Test("Updates set PARSE_JSON for VARIANT and filter by primary key")
    func testVariantUpdate() {
        let change = update("payload", to: .text("{\"b\":2}"), original: [.text("7"), .text("Bob"), .null])
        let result = generator().generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(result[0].statement ==
            "UPDATE \"DB\".\"PUBLIC\".\"T\" SET \"payload\" = PARSE_JSON(?) WHERE \"id\" = ?")
        #expect(result[0].parameters == [.text("{\"b\":2}"), .text("7")])
    }

    @Test("Without primary keys the WHERE clause uses all non-variant columns")
    func testAllColumnFallbackSkipsVariant() {
        let change = update("name", to: .text("New"), original: [.text("7"), .null, .text("{}")])
        let result = generator(primaryKeys: []).generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(result[0].statement ==
            "UPDATE \"DB\".\"PUBLIC\".\"T\" SET \"name\" = ? WHERE \"id\" = ? AND \"name\" IS NULL")
        #expect(result[0].parameters == [.text("New"), .text("7")])
    }

    @Test("Deletes filter by primary key")
    func testDelete() {
        let change = PluginRowChange(
            rowIndex: 3,
            type: .delete,
            cellChanges: [],
            originalRow: [.text("9"), .text("Eve"), .null]
        )
        let result = generator().generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [3], insertedRowIndices: []
        )
        #expect(result[0].statement == "DELETE FROM \"DB\".\"PUBLIC\".\"T\" WHERE \"id\" = ?")
        #expect(result[0].parameters == [.text("9")])
    }

    @Test("Semi-structured detection covers VARIANT, OBJECT, and ARRAY")
    func testSemiStructuredDetection() {
        #expect(SnowflakeStatementGenerator.isSemiStructured("VARIANT"))
        #expect(SnowflakeStatementGenerator.isSemiStructured("object"))
        #expect(SnowflakeStatementGenerator.isSemiStructured("ARRAY"))
        #expect(!SnowflakeStatementGenerator.isSemiStructured("VARCHAR(10)"))
        #expect(!SnowflakeStatementGenerator.isSemiStructured("NUMBER(10,2)"))
    }
}

@Suite("Snowflake DDL Generator")
struct SnowflakeDDLGeneratorTests {
    private let generator = SnowflakeDDLGenerator(qualifiedTable: { "\"DB\".\"PUBLIC\".\"\($0)\"" })

    @Test("Add column renders type, default, nullability, and comment")
    func testAddColumn() {
        let column = PluginColumnDefinition(
            name: "score", dataType: "NUMBER(10,2)", isNullable: false, defaultValue: "0", comment: "points"
        )
        #expect(generator.addColumnSQL(table: "T", column: column) ==
            "ALTER TABLE \"DB\".\"PUBLIC\".\"T\" ADD COLUMN \"score\" NUMBER(10,2) DEFAULT 0 NOT NULL COMMENT 'points'")
    }

    @Test("VARCHAR can widen but never shrink")
    func testVarcharWidening() {
        #expect(SnowflakeDDLGenerator.isSupportedTypeChange(from: "VARCHAR(100)", to: "VARCHAR(500)"))
        #expect(!SnowflakeDDLGenerator.isSupportedTypeChange(from: "VARCHAR(500)", to: "VARCHAR(100)"))
    }

    @Test("NUMBER precision can change but scale cannot")
    func testNumberConstraints() {
        #expect(SnowflakeDDLGenerator.isSupportedTypeChange(from: "NUMBER(10,2)", to: "NUMBER(20,2)"))
        #expect(!SnowflakeDDLGenerator.isSupportedTypeChange(from: "NUMBER(10,2)", to: "NUMBER(10,4)"))
    }

    @Test("Cross-type changes are rejected")
    func testCrossTypeRejected() {
        #expect(!SnowflakeDDLGenerator.isSupportedTypeChange(from: "VARCHAR(10)", to: "NUMBER(10,0)"))
        let old = PluginColumnDefinition(name: "c", dataType: "VARCHAR(10)")
        let new = PluginColumnDefinition(name: "c", dataType: "NUMBER(10,0)")
        #expect(generator.modifyColumnSQL(table: "T", old: old, new: new) == nil)
    }

    @Test("Combined alters render as one statement with comma actions")
    func testCombinedAlter() {
        let old = PluginColumnDefinition(name: "c", dataType: "VARCHAR(10)", isNullable: true)
        let new = PluginColumnDefinition(name: "c", dataType: "VARCHAR(50)", isNullable: false, comment: "x")
        let sql = generator.modifyColumnSQL(table: "T", old: old, new: new)
        #expect(sql ==
            "ALTER TABLE \"DB\".\"PUBLIC\".\"T\" ALTER COLUMN \"c\" SET DATA TYPE VARCHAR(50), COLUMN \"c\" SET NOT NULL, COLUMN \"c\" COMMENT 'x'")
    }

    @Test("Rename plus alter renders two statements")
    func testRenameWithAlter() {
        let old = PluginColumnDefinition(name: "a", dataType: "VARCHAR(10)")
        let new = PluginColumnDefinition(name: "b", dataType: "VARCHAR(50)")
        let sql = generator.modifyColumnSQL(table: "T", old: old, new: new)
        #expect(sql ==
            "ALTER TABLE \"DB\".\"PUBLIC\".\"T\" RENAME COLUMN \"a\" TO \"b\";\n" +
            "ALTER TABLE \"DB\".\"PUBLIC\".\"T\" ALTER COLUMN \"b\" SET DATA TYPE VARCHAR(50)")
    }

    @Test("Primary key changes drop then add")
    func testModifyPrimaryKey() {
        let statements = generator.modifyPrimaryKeySQL(table: "T", oldColumns: ["a"], newColumns: ["a", "b"])
        #expect(statements == [
            "ALTER TABLE \"DB\".\"PUBLIC\".\"T\" DROP PRIMARY KEY",
            "ALTER TABLE \"DB\".\"PUBLIC\".\"T\" ADD PRIMARY KEY (\"a\", \"b\")"
        ])
    }

    @Test("Create table includes a primary key constraint")
    func testCreateTable() {
        let definition = PluginCreateTableDefinition(
            tableName: "T",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "NUMBER", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "name", dataType: "VARCHAR(50)")
            ]
        )
        let sql = generator.createTableSQL(definition: definition)
        #expect(sql?.contains("CREATE TABLE \"DB\".\"PUBLIC\".\"T\"") == true)
        #expect(sql?.contains("PRIMARY KEY (\"id\")") == true)
    }
}

@Suite("Snowflake Schema Queries")
struct SnowflakeSchemaQueriesTests {
    @Test("SHOW statements quote identifiers")
    func testShowQuoting() {
        #expect(SnowflakeSchemaQueries.showObjects(database: "my\"db", schema: "S") ==
            "SHOW TERSE OBJECTS IN SCHEMA \"my\"\"db\".\"S\"")
    }

    @Test("SHOW TABLES LIKE escapes pattern wildcards")
    func testLikeEscaping() {
        let sql = SnowflakeSchemaQueries.showTablesLike(database: "D", schema: "S", table: "my_table")
        #expect(sql.contains("'my\\\\_table'"))
    }

    @Test("Object kinds map to app table types")
    func testKindMapping() {
        #expect(SnowflakeSchemaQueries.objectType(forKind: "TABLE") == "TABLE")
        #expect(SnowflakeSchemaQueries.objectType(forKind: "VIEW") == "VIEW")
        #expect(SnowflakeSchemaQueries.objectType(forKind: "MATERIALIZED_VIEW") == "MATERIALIZED_VIEW")
    }

    @Test("Clustering key expressions parse to column names")
    func testClusterByParsing() {
        #expect(SnowflakeSchemaQueries.parseClusterBy("LINEAR(col1, col2)") == ["col1", "col2"])
        #expect(SnowflakeSchemaQueries.parseClusterBy("LINEAR(\"a\")") == ["a"])
    }

    @Test("Multi-statement detection requires content after a semicolon")
    func testMultiStatementDetection() {
        #expect(SnowflakeSchemaQueries.isLikelyMultiStatement("SELECT 1; SELECT 2"))
        #expect(!SnowflakeSchemaQueries.isLikelyMultiStatement("SELECT 1;"))
        #expect(!SnowflakeSchemaQueries.isLikelyMultiStatement("SELECT 1"))
    }
}
