//
//  QueryExecutorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("QueryExecutor")
@MainActor
struct QueryExecutorTests {
    // MARK: - SQL parsing (delegates to QuerySqlParser)

    @Test("extractTableName parses bareword FROM clause")
    func extractTableNameBareword() {
        let name = QuerySqlParser.extractTableName(from: "SELECT * FROM users WHERE id = 1")
        #expect(name == "users")
    }

    @Test("extractTableName parses backtick-quoted table")
    func extractTableNameBackticks() {
        let name = QuerySqlParser.extractTableName(from: "SELECT * FROM `User Logs`")
        #expect(name == "User Logs")
    }

    @Test("extractTableName parses double-quoted table")
    func extractTableNameDoubleQuotes() {
        let name = QuerySqlParser.extractTableName(from: "SELECT * FROM \"public.user\"")
        #expect(name == "public.user")
    }

    @Test("extractTableName parses MSSQL-style bracket-quoted table")
    func extractTableNameBracketQuotes() {
        let name = QuerySqlParser.extractTableName(from: "SELECT id FROM [Users] WHERE id = 1")
        #expect(name == "Users")
    }

    @Test("extractTableName parses MQL dot notation")
    func extractTableNameMQLDot() {
        let name = QuerySqlParser.extractTableName(from: "db.users.find({})")
        #expect(name == "users")
    }

    @Test("extractTableName parses MQL bracket notation")
    func extractTableNameMQLBracket() {
        let name = QuerySqlParser.extractTableName(from: #"db["user logs"].find({})"#)
        #expect(name == "user logs")
    }

    @Test("extractTableName returns nil when no FROM clause")
    func extractTableNameNoMatch() {
        #expect(QuerySqlParser.extractTableName(from: "SHOW TABLES") == nil)
        #expect(QuerySqlParser.extractTableName(from: "CREATE TABLE foo (id INT)") == nil)
    }

    @Test("stripTrailingOrderBy removes a trailing ORDER BY clause")
    func stripTrailingOrderByRemovesClause() {
        let stripped = QuerySqlParser.stripTrailingOrderBy(from: "SELECT * FROM users ORDER BY id DESC")
        #expect(stripped == "SELECT * FROM users")
    }

    @Test("stripTrailingOrderBy preserves SQL without ORDER BY")
    func stripTrailingOrderByPreservesUnchanged() {
        let stripped = QuerySqlParser.stripTrailingOrderBy(from: "SELECT * FROM users WHERE id > 1")
        #expect(stripped == "SELECT * FROM users WHERE id > 1")
    }

    @Test("stripTrailingOrderBy does not strip ORDER BY inside subquery")
    func stripTrailingOrderByIgnoresInsideParens() {
        let original = "SELECT id FROM (SELECT id FROM users ORDER BY id) AS sub"
        let stripped = QuerySqlParser.stripTrailingOrderBy(from: original)
        #expect(stripped == original)
    }

    @Test("parseSQLiteCheckConstraintValues extracts IN-list values")
    func parseSQLiteCheckExtracts() {
        let ddl = "CREATE TABLE t (status TEXT CHECK(\"status\" IN ('a','b','c')))"
        let values = QuerySqlParser.parseSQLiteCheckConstraintValues(createSQL: ddl, columnName: "status")
        #expect(values == ["a", "b", "c"])
    }

    @Test("parseSQLiteCheckConstraintValues returns nil when constraint missing")
    func parseSQLiteCheckMissing() {
        let ddl = "CREATE TABLE t (status TEXT)"
        let values = QuerySqlParser.parseSQLiteCheckConstraintValues(createSQL: ddl, columnName: "status")
        #expect(values == nil)
    }

    // MARK: - DDL detection

    @Test("isDDLStatement recognizes CREATE/DROP/ALTER/TRUNCATE/RENAME")
    func isDDLStatementPositive() {
        #expect(QueryExecutor.isDDLStatement("CREATE TABLE foo (id INT)"))
        #expect(QueryExecutor.isDDLStatement("DROP TABLE foo"))
        #expect(QueryExecutor.isDDLStatement("alter table foo add column bar int"))
        #expect(QueryExecutor.isDDLStatement("  TRUNCATE foo"))
        #expect(QueryExecutor.isDDLStatement("RENAME TABLE foo TO bar"))
    }

    @Test("isDDLStatement returns false for SELECT, INSERT, UPDATE, DELETE")
    func isDDLStatementNegative() {
        #expect(!QueryExecutor.isDDLStatement("SELECT 1"))
        #expect(!QueryExecutor.isDDLStatement("INSERT INTO foo VALUES (1)"))
        #expect(!QueryExecutor.isDDLStatement("UPDATE foo SET x = 1"))
        #expect(!QueryExecutor.isDDLStatement("DELETE FROM foo"))
    }

    // MARK: - Parameter detection

    @Test("detectAndReconcileParameters returns empty when SQL has no placeholders")
    func detectParamsNoPlaceholders() {
        let result = QueryExecutor.detectAndReconcileParameters(
            sql: "SELECT * FROM users",
            existing: []
        )
        #expect(result.isEmpty)
    }

    @Test("detectAndReconcileParameters preserves existing values for matching names")
    func detectParamsPreservesExistingValues() {
        let existing = [
            QueryParameter(name: "user_id", value: "42", type: .integer)
        ]
        let result = QueryExecutor.detectAndReconcileParameters(
            sql: "SELECT * FROM users WHERE id = :user_id",
            existing: existing
        )
        #expect(result.count == 1)
        #expect(result[0].name == "user_id")
        #expect(result[0].value == "42")
        #expect(result[0].type == .integer)
    }

    @Test("detectAndReconcileParameters drops parameters no longer in SQL")
    func detectParamsDropsRemoved() {
        let existing = [
            QueryParameter(name: "old", value: "x"),
            QueryParameter(name: "kept", value: "y")
        ]
        let result = QueryExecutor.detectAndReconcileParameters(
            sql: "SELECT * FROM t WHERE c = :kept",
            existing: existing
        )
        #expect(result.map(\.name) == ["kept"])
        #expect(result[0].value == "y")
    }

    @Test("detectAndReconcileParameters adds new parameters with empty values")
    func detectParamsAddsNew() {
        let result = QueryExecutor.detectAndReconcileParameters(
            sql: "SELECT * FROM t WHERE a = :a AND b = :b",
            existing: []
        )
        #expect(result.map(\.name) == ["a", "b"])
        #expect(result.allSatisfy { $0.value.isEmpty })
    }

    // MARK: - Schema metadata parsing

    @Test("parseSchemaMetadata maps columns, foreign keys, primary keys")
    func parseSchemaMetadataMapsFields() {
        let columns = [
            ColumnInfo(
                name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
            ),
            ColumnInfo(
                name: "name", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                defaultValue: "guest", extra: nil, charset: nil, collation: nil, comment: nil
            )
        ]
        let fks = [
            ForeignKeyInfo(
                name: "fk_role", column: "role_id",
                referencedTable: "roles", referencedColumn: "id"
            )
        ]
        let schema: SchemaResult = (columnInfo: columns, fkInfo: fks, approximateRowCount: 1_234)

        let parsed = QueryExecutor.parseSchemaMetadata(schema)

        #expect(parsed.primaryKeyColumns == ["id"])
        #expect(parsed.columnDefaults["id"] == .some(nil))
        #expect(parsed.columnDefaults["name"] == .some("guest"))
        #expect(parsed.columnNullable["id"] == false)
        #expect(parsed.columnNullable["name"] == true)
        #expect(parsed.columnForeignKeys["role_id"]?.referencedTable == "roles")
        #expect(parsed.approximateRowCount == 1_234)
    }

    @Test("parseSchemaMetadata extracts MySQL-style ENUM values")
    func parseSchemaMetadataExtractsEnumValues() {
        let columns = [
            ColumnInfo(
                name: "status",
                dataType: "ENUM('open','closed','archived')",
                isNullable: false, isPrimaryKey: false,
                defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
            )
        ]
        let schema: SchemaResult = (columnInfo: columns, fkInfo: [], approximateRowCount: nil)

        let parsed = QueryExecutor.parseSchemaMetadata(schema)

        #expect(parsed.columnEnumValues["status"] == ["open", "closed", "archived"])
    }

    @Test("parseSchemaMetadata returns empty containers when input is empty")
    func parseSchemaMetadataEmpty() {
        let schema: SchemaResult = (columnInfo: [], fkInfo: [], approximateRowCount: nil)
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.primaryKeyColumns.isEmpty)
        #expect(parsed.columnDefaults.isEmpty)
        #expect(parsed.columnNullable.isEmpty)
        #expect(parsed.columnForeignKeys.isEmpty)
        #expect(parsed.columnEnumValues.isEmpty)
        #expect(parsed.approximateRowCount == nil)
    }

    // TODO: integration test for `QueryExecutor.executeQuery` orchestration
    // (parallel schema fetch, cancel-on-fetch-error, parameterised path).
    // Requires either a `DatabaseDriver` mock registered with
    // `DatabaseManager.shared` or a DI refactor of `QueryExecutor` to accept
    // an injected driver. Static helpers above already cover SQL parsing,
    // metadata parsing, parameter reconciliation, DDL detection, and row-cap
    // policy.
}
