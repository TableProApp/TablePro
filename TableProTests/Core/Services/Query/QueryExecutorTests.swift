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

    @Test("extractTableName parses MQL getCollection notation")
    func extractTableNameMQLGetCollection() {
        let plain = QuerySqlParser.extractTableName(from: #"db.getCollection("user logs").find({})"#)
        let escaped = QuerySqlParser.extractTableName(from: #"db.getCollection("say\"hi").find({})"#)
        let shadowed = QuerySqlParser.extractTableName(from: #"db.getCollection("stats").countDocuments({})"#)
        #expect(plain == "user logs")
        #expect(escaped == "say\"hi")
        #expect(shadowed == "stats")
    }

    @Test("extractTableName returns nil when no FROM clause")
    func extractTableNameNoMatch() {
        #expect(QuerySqlParser.extractTableName(from: "SHOW TABLES") == nil)
        #expect(QuerySqlParser.extractTableName(from: "CREATE TABLE foo (id INT)") == nil)
    }

    // MARK: - Schema-qualified sources

    /// A generated write names the table without a qualifier and lets the session resolve it, so a
    /// schema the session is not pointed at must stay read-only.

    @Test("A qualified source resolves when it names the session's own schema")
    func qualifiedSourceMatchingSessionSchema() {
        #expect(QuerySqlParser.extractTableName(
            from: "SELECT * FROM public.users u WHERE u.id = 1",
            dialect: .postgres,
            browseSchema: "public"
        ) == "users")
        #expect(QuerySqlParser.extractTableName(
            from: "SELECT * FROM \"public\".\"users\"",
            dialect: .postgres,
            browseSchema: "public"
        ) == "users")
    }

    @Test("A qualified source naming another schema stays read-only")
    func qualifiedSourceOtherSchema() {
        #expect(QuerySqlParser.extractTableName(
            from: "SELECT * FROM analytics.users u WHERE u.id = 1",
            dialect: .postgres,
            browseSchema: "public"
        ) == nil)
    }

    @Test("A qualified source stays read-only when the session schema is unknown")
    func qualifiedSourceWithoutSessionSchema() {
        #expect(QuerySqlParser.extractTableName(
            from: "SELECT * FROM public.users u WHERE u.id = 1",
            dialect: .postgres
        ) == nil)
    }

    @Test("Schema matching ignores case")
    func qualifiedSourceCaseInsensitive() {
        #expect(QuerySqlParser.extractTableName(
            from: "SELECT * FROM PUBLIC.users u",
            dialect: .postgres,
            browseSchema: "public"
        ) == "users")
    }

    @Test("An unqualified source is unaffected by the session schema")
    func unqualifiedSourceIgnoresSessionSchema() {
        #expect(QuerySqlParser.extractTableName(
            from: "SELECT * FROM users u WHERE u.id = 1",
            dialect: .postgres,
            browseSchema: "analytics"
        ) == "users")
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

    // MARK: - Sorting a query result

    @Test("applyingOrderBy puts the clause before a LIMIT the user wrote")
    func applyingOrderByPrecedesLimit() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "\"total\" ASC",
            to: "SELECT * FROM orders LIMIT 100",
            lexicalDialect: .postgres
        )
        #expect(sorted == "SELECT * FROM orders ORDER BY \"total\" ASC LIMIT 100")
    }

    @Test("applyingOrderBy keeps the user's LIMIT when replacing an existing ORDER BY")
    func applyingOrderByKeepsLimitWhenReplacing() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "\"total\" DESC",
            to: "SELECT * FROM orders ORDER BY id LIMIT 100",
            lexicalDialect: .postgres
        )
        #expect(sorted == "SELECT * FROM orders ORDER BY \"total\" DESC LIMIT 100")
    }

    @Test("applyingOrderBy preserves a LIMIT with an OFFSET")
    func applyingOrderByPreservesOffset() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "\"id\" ASC",
            to: "SELECT * FROM orders LIMIT 10 OFFSET 20",
            lexicalDialect: .postgres
        )
        #expect(sorted == "SELECT * FROM orders ORDER BY \"id\" ASC LIMIT 10 OFFSET 20")
    }

    @Test("applyingOrderBy appends to a query with no row-limiting clause")
    func applyingOrderByAppendsWhenNoLimit() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "\"id\" ASC",
            to: "SELECT * FROM orders",
            lexicalDialect: .postgres
        )
        #expect(sorted == "SELECT * FROM orders ORDER BY \"id\" ASC")
    }

    @Test("applyingOrderBy ignores a LIMIT inside a subquery")
    func applyingOrderByIgnoresSubqueryLimit() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "\"id\" ASC",
            to: "SELECT * FROM (SELECT * FROM t LIMIT 5) s",
            lexicalDialect: .postgres
        )
        #expect(sorted == "SELECT * FROM (SELECT * FROM t LIMIT 5) s ORDER BY \"id\" ASC")
    }

    @Test("applyingOrderBy with no columns strips the old ORDER BY and keeps the LIMIT")
    func applyingOrderByEmptyClauseKeepsLimit() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "",
            to: "SELECT * FROM orders ORDER BY id LIMIT 100",
            lexicalDialect: .postgres
        )
        #expect(sorted == "SELECT * FROM orders LIMIT 100")
    }

    @Test("applyingOrderBy with no columns drops an OFFSET FETCH tail, which needs an ORDER BY")
    func applyingOrderByEmptyClauseDropsAnsiTail() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "",
            to: "SELECT * FROM t ORDER BY id OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY",
            lexicalDialect: .generic
        )
        #expect(sorted == "SELECT * FROM t")
    }

    @Test("applyingOrderBy leaves a column named offset alone")
    func applyingOrderByIgnoresOffsetColumn() {
        let sorted = QuerySqlParser.applyingOrderBy(
            "`name` ASC",
            to: "SELECT offset, name FROM events",
            lexicalDialect: .mysql
        )
        #expect(sorted == "SELECT offset, name FROM events ORDER BY `name` ASC")
    }

    // MARK: - Row cap qualification

    @Test("qualifiesForRowCap accepts SELECT and WITH queries on query tabs")
    func qualifiesForRowCapSelects() {
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "SELECT * FROM users", tabType: .query, databaseType: .mysql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "WITH cte AS (SELECT 1) SELECT * FROM cte", tabType: .query, databaseType: .postgresql
        ))
    }

    @Test("qualifiesForRowCap accepts SELECT followed by newline, tab, or punctuation")
    func qualifiesForRowCapKeywordBoundaries() {
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "SELECT\n  *\nFROM big_table", tabType: .query, databaseType: .mysql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "SELECT\t* FROM t", tabType: .query, databaseType: .mysql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "SELECT*FROM t", tabType: .query, databaseType: .mysql
        ))
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "SELECTX FROM t", tabType: .query, databaseType: .mysql
        ))
    }

    @Test("qualifiesForRowCap accepts the other row-producing statement forms")
    func qualifiesForRowCapRowProducingForms() {
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "(SELECT * FROM events) UNION ALL (SELECT * FROM events_archive)",
            tabType: .query,
            databaseType: .postgresql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "TABLE big_table", tabType: .query, databaseType: .postgresql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "VALUES (1), (2), (3)", tabType: .query, databaseType: .postgresql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "((SELECT * FROM t))", tabType: .query, databaseType: .postgresql
        ))
    }

    @Test("qualifiesForRowCap still rejects a write hidden behind a leading parenthesis")
    func qualifiesForRowCapParenthesisedWrite() {
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "(DELETE FROM users)", tabType: .query, databaseType: .postgresql
        ))
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "( SELECT * FROM t INTO OUTFILE '/tmp/x' )", tabType: .query, databaseType: .mysql
        ))
    }

    @Test("qualifiesForRowCap accepts SELECT queries preceded by comments")
    func qualifiesForRowCapCommentPrefixed() {
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "-- top users\nSELECT * FROM users", tabType: .query, databaseType: .mysql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "/* audit */ SELECT * FROM users", tabType: .query, databaseType: .mysql
        ))
    }

    @Test("qualifiesForRowCap rejects writes, DDL, EXPLAIN, and table tabs")
    func qualifiesForRowCapRejections() {
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "DELETE FROM users", tabType: .query, databaseType: .mysql
        ))
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "CREATE TABLE foo (id INT)", tabType: .query, databaseType: .mysql
        ))
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "EXPLAIN SELECT * FROM users", tabType: .query, databaseType: .mysql
        ))
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "SELECT * FROM users", tabType: .table, databaseType: .mysql
        ))
        #expect(!QueryExecutor.qualifiesForRowCap(
            sql: "WITH cte AS (SELECT 1) DELETE FROM users", tabType: .query, databaseType: .postgresql
        ))
    }

    @Test("qualifiesForRowCap accepts a SELECT ending in ORDER BY")
    func qualifiesForRowCapOrderBy() {
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "SELECT * FROM alert_events ORDER BY alert_time", tabType: .query, databaseType: .mysql
        ))
        #expect(QueryExecutor.qualifiesForRowCap(
            sql: "SELECT * FROM t WHERE created_at >= '2026-01-01' ORDER BY id DESC",
            tabType: .query, databaseType: .mysql
        ))
    }

    // MARK: - Row cap resolution

    private func withRowCapSettings(truncate: Bool, cap: Int, _ body: () -> Void) {
        let previousTruncate = AppSettingsManager.shared.dataGrid.truncateQueryResults
        let previousCap = AppSettingsManager.shared.dataGrid.queryResultRowCap
        AppSettingsManager.shared.dataGrid.truncateQueryResults = truncate
        AppSettingsManager.shared.dataGrid.queryResultRowCap = cap
        defer {
            AppSettingsManager.shared.dataGrid.truncateQueryResults = previousTruncate
            AppSettingsManager.shared.dataGrid.queryResultRowCap = previousCap
        }
        body()
    }

    @Test("resolveRowCap returns nil when the row cap is unlimited")
    func resolveRowCapUnlimitedReturnsNil() {
        withRowCapSettings(truncate: true, cap: 0) {
            #expect(QueryExecutor.resolveRowCap(
                sql: "SELECT * FROM alert_events ORDER BY alert_time",
                tabType: .query,
                databaseType: .mysql
            ) == nil)
        }
    }

    @Test("resolveRowCap returns the configured cap for a capped SELECT")
    func resolveRowCapReturnsConfiguredCap() {
        withRowCapSettings(truncate: true, cap: 10_000) {
            #expect(QueryExecutor.resolveRowCap(
                sql: "SELECT * FROM alert_events ORDER BY alert_time",
                tabType: .query,
                databaseType: .mysql
            ) == 10_000)
        }
    }

    @Test("resolveRowCap returns nil when truncation is disabled")
    func resolveRowCapTruncationDisabled() {
        withRowCapSettings(truncate: false, cap: 10_000) {
            #expect(QueryExecutor.resolveRowCap(
                sql: "SELECT * FROM users",
                tabType: .query,
                databaseType: .mysql
            ) == nil)
        }
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
        let schema = FetchedTableSchema(columns: columns, foreignKeys: fks, approximateRowCount: 1_234)

        let parsed = QueryExecutor.parseSchemaMetadata(schema)

        #expect(parsed.primaryKeyColumns == ["id"])
        #expect(parsed.columnDefaults["id"] == .some(nil))
        #expect(parsed.columnDefaults["name"] == .some("guest"))
        #expect(parsed.columnNullable["id"] == false)
        #expect(parsed.columnNullable["name"] == true)
        #expect(parsed.columnForeignKeys?["role_id"]?.referencedTable == "roles")
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
        let schema = FetchedTableSchema(columns: columns, foreignKeys: [], approximateRowCount: nil)

        let parsed = QueryExecutor.parseSchemaMetadata(schema)

        #expect(parsed.columnEnumValues["status"] == ["open", "closed", "archived"])
    }


    @Test("parseSchemaMetadata keeps a failed foreign key fetch distinguishable from zero foreign keys")
    func parseSchemaMetadataNilForeignKeys() {
        let schema = FetchedTableSchema(columns: [], foreignKeys: nil, approximateRowCount: nil)
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.columnForeignKeys == nil)
    }

    @Test("parseSchemaMetadata returns empty containers when input is empty")
    func parseSchemaMetadataEmpty() {
        let schema = FetchedTableSchema(columns: [], foreignKeys: [], approximateRowCount: nil)
        let parsed = QueryExecutor.parseSchemaMetadata(schema)
        #expect(parsed.primaryKeyColumns.isEmpty)
        #expect(parsed.columnDefaults.isEmpty)
        #expect(parsed.columnNullable.isEmpty)
        #expect(parsed.columnForeignKeys?.isEmpty == true)
        #expect(parsed.columnEnumValues.isEmpty)
        #expect(parsed.approximateRowCount == nil)
    }

    // MARK: - Inline result-set metadata

    @Test("inlineMetadata extracts primary keys and nullability from result flags")
    func inlineMetadataExtractsFlags() throws {
        let meta = [
            ResultColumnMeta(isPrimaryKey: true, isNullable: false, isAutoIncrement: true),
            ResultColumnMeta(isPrimaryKey: false, isNullable: true, isAutoIncrement: false)
        ]
        let parsed = try #require(QueryExecutor.inlineMetadata(from: meta, columns: ["id", "name"]))
        #expect(parsed.primaryKeyColumns == ["id"])
        #expect(parsed.columnNullable["id"] == false)
        #expect(parsed.columnNullable["name"] == true)
        #expect(parsed.columnDefaults.isEmpty)
        #expect(parsed.columnForeignKeys == nil)
        #expect(parsed.approximateRowCount == nil)
    }

    @Test("inlineMetadata reports a composite primary key in column order")
    func inlineMetadataCompositePrimaryKey() throws {
        let meta = [
            ResultColumnMeta(isPrimaryKey: true, isNullable: false, isAutoIncrement: false),
            ResultColumnMeta(isPrimaryKey: true, isNullable: false, isAutoIncrement: false),
            ResultColumnMeta(isPrimaryKey: false, isNullable: true, isAutoIncrement: false)
        ]
        let parsed = try #require(QueryExecutor.inlineMetadata(from: meta, columns: ["order_id", "product_id", "qty"]))
        #expect(parsed.primaryKeyColumns == ["order_id", "product_id"])
    }

    @Test("inlineMetadata returns nil when result metadata is absent or empty")
    func inlineMetadataNilWhenAbsent() {
        #expect(QueryExecutor.inlineMetadata(from: nil, columns: ["id"]) == nil)
        #expect(QueryExecutor.inlineMetadata(from: [], columns: ["id"]) == nil)
    }

    @Test("inlineMetadata returns nil when metadata count does not match columns")
    func inlineMetadataNilOnCountMismatch() {
        let meta = [ResultColumnMeta(isPrimaryKey: true, isNullable: false, isAutoIncrement: false)]
        #expect(QueryExecutor.inlineMetadata(from: meta, columns: ["id", "name"]) == nil)
    }

    // TODO: integration test for the execute -> Phase 1 render -> Phase 2 metadata
    // flow in QueryExecutionCoordinator (rows render without awaiting schema; the
    // schema task applies metadata and bumps metadataVersion afterwards). Requires
    // a `DatabaseDriver` mock registered with `DatabaseManager.shared` or a DI
    // refactor. Static helpers above cover SQL parsing, metadata parsing, inline
    // result-set metadata, parameter reconciliation, DDL detection, and row-cap policy.
}
