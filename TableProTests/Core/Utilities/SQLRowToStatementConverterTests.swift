//
//  SQLRowToStatementConverterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct SQLRowToStatementConverterTests {
    // MARK: - Test Dialect Helpers

    private static let mysqlDialect = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [],
        functions: [],
        dataTypes: [],
        requiresBackslashEscaping: true
    )

    private static let postgresDialect = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [],
        functions: [],
        dataTypes: []
    )

    private static let mssqlDialect = SQLDialectDescriptor(
        identifierQuote: "[",
        keywords: [],
        functions: [],
        dataTypes: [],
        paginationStyle: .offsetFetch
    )

    private static let clickhouseDialect = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [],
        functions: [],
        dataTypes: [],
        requiresBackslashEscaping: true
    )

    private static let duckdbDialect = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [],
        functions: [],
        dataTypes: []
    )

    // MARK: - Factory

    private func makeConverter(
        tableName: String = "users",
        columns: [String] = ["id", "name", "email"],
        primaryKeyColumn: String? = "id",
        databaseType: DatabaseType = .mysql,
        dialect: SQLDialectDescriptor? = Self.mysqlDialect
    ) throws -> SQLRowToStatementConverter {
        try SQLRowToStatementConverter(
            tableName: tableName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumn.map { [$0] } ?? [],
            databaseType: databaseType,
            dialect: dialect
        )
    }

    private func plain(_ rows: [[PluginCellValue]]) -> [SQLRowToStatementConverter.SourceRow] {
        rows.map { SQLRowToStatementConverter.SourceRow(values: $0) }
    }

    // MARK: - INSERT Generation

    @Test("Single row produces one INSERT statement")
    func insertSingleRow() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("Multiple rows are joined by newlines")
    func insertMultipleRows() throws {
        let converter = try makeConverter()
        let rows: [[PluginCellValue]] = [
            ["1", "Alice", "alice@example.com"],
            ["2", "Bob", "bob@example.com"]
        ]
        let result = converter.generateInserts(rows: plain(rows))
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
        #expect(lines[1] == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('2', 'Bob', 'bob@example.com');")
    }

    @Test("NULL values render as unquoted NULL")
    func insertNullValues() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: plain([["1", nil, nil]]))
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', NULL, NULL);")
    }

    @Test("Empty strings render as empty quoted string")
    func insertEmptyStrings() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: plain([["1", "", ""]]))
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', '', '');")
    }

    @Test("Single quotes in data are escaped as double single-quotes")
    func insertSpecialCharactersSingleQuotes() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: plain([["1", "O'Brien", "o'brien@example.com"]]))
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'O''Brien', 'o''brien@example.com');")
    }

    // MARK: - UPDATE Generation

    @Test("UPDATE with primary key excludes PK from SET and uses PK in WHERE")
    func updateWithPrimaryKey() throws {
        let converter = try makeConverter()
        let result = converter.generateUpdates(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1';")
    }

    @Test("UPDATE without primary key uses all columns in SET and WHERE")
    func updateWithoutPrimaryKey() throws {
        let converter = try makeConverter(primaryKeyColumn: nil)
        let result = converter.generateUpdates(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "UPDATE `users` SET `id` = '1', `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1' AND `name` = 'Alice' AND `email` = 'alice@example.com';")
    }

    @Test("UPDATE without PK uses IS NULL in WHERE clause for NULL values")
    func updateNullValuesInWhereClauseNoPK() throws {
        let converter = try makeConverter(primaryKeyColumn: nil)
        let result = converter.generateUpdates(rows: plain([["1", nil, "alice@example.com"]]))
        #expect(result == "UPDATE `users` SET `id` = '1', `name` = NULL, `email` = 'alice@example.com' WHERE `id` = '1' AND `name` IS NULL AND `email` = 'alice@example.com';")
    }

    @Test("UPDATE writes nothing for a row whose key is NULL, which identifies no row")
    func updateNullPrimaryKeyValue() throws {
        let converter = try makeConverter()
        let result = converter.generateUpdates(rows: plain([[nil, "Alice", "alice@example.com"]]))
        #expect(result == "")
    }

    // MARK: - Database-Specific Quoting

    @Test("ClickHouse fallback uses standard UPDATE syntax (plugin handles ALTER TABLE at runtime)")
    func clickhouseFallbackUsesStandardUpdate() throws {
        let converter = try makeConverter(databaseType: .clickhouse, dialect: Self.clickhouseDialect)
        let result = converter.generateUpdates(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1';")
    }

    /// The `N` is not decoration: a plain `'…'` is a `varchar` literal, so pasting these
    /// statements into a database with a non-Unicode collation stores `?` for every character
    /// outside its code page, whatever the column type is.
    @Test("MSSQL uses bracket quoting and N-prefixed literals")
    func mssqlUsesBracketQuoting() throws {
        let converter = try makeConverter(databaseType: .mssql, dialect: Self.mssqlDialect)
        let result = converter.generateInserts(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "INSERT INTO [users] ([id], [name], [email]) VALUES (N'1', N'Alice', N'alice@example.com');")
    }

    @Test("MSSQL: non-Latin text survives a copied INSERT and UPDATE")
    func mssqlKeepsNonLatinText() throws {
        let converter = try makeConverter(databaseType: .mssql, dialect: Self.mssqlDialect)
        let inserts = converter.generateInserts(rows: plain([["1", "日本語", "a@b.c"]]))
        #expect(inserts.contains("N'日本語'"))
        let updates = converter.generateUpdates(rows: plain([["1", "日本語", "a@b.c"]]))
        #expect(updates.contains("[name] = N'日本語'"))
        #expect(updates.contains("WHERE [id] = N'1'"))
    }

    @Test("PostgreSQL uses double-quote quoting")
    func postgresqlUsesDoubleQuoteQuoting() throws {
        let converter = try makeConverter(databaseType: .postgresql, dialect: Self.postgresDialect)
        let result = converter.generateInserts(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("MySQL uses backtick quoting")
    func mysqlUsesBacktickQuoting() throws {
        let converter = try makeConverter(databaseType: .mysql)
        let result = converter.generateInserts(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("DuckDB uses double-quote quoting and standard UPDATE syntax")
    func duckdbUsesDoubleQuoteAndStandardUpdate() throws {
        let converter = try makeConverter(databaseType: .duckdb, dialect: Self.duckdbDialect)
        let insert = converter.generateInserts(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(insert == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'Alice', 'alice@example.com');")
        let update = converter.generateUpdates(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(update == "UPDATE \"users\" SET \"name\" = 'Alice', \"email\" = 'alice@example.com' WHERE \"id\" = '1';")
    }

    @Test("MySQL escapes backslashes in values")
    func mysqlBackslashEscaping() throws {
        let converter = try makeConverter(databaseType: .mysql)
        let result = converter.generateInserts(rows: plain([["1", "C:\\Users\\test", "a@b.com"]]))
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'C:\\\\Users\\\\test', 'a@b.com');")
    }

    @Test("PostgreSQL does not escape backslashes")
    func postgresqlNoBackslashEscaping() throws {
        let converter = try makeConverter(databaseType: .postgresql, dialect: Self.postgresDialect)
        let result = converter.generateInserts(rows: plain([["1", "C:\\Users\\test", "a@b.com"]]))
        #expect(result == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'C:\\Users\\test', 'a@b.com');")
    }

    @Test("UPDATE writes nothing when a declared key column is missing, as the save does")
    func updatePkNotInColumnsWritesNothing() throws {
        let converter = try makeConverter(
            columns: ["name", "email"],
            primaryKeyColumn: "id",
            databaseType: .mysql
        )
        let result = converter.generateUpdates(rows: plain([["Alice", "alice@example.com"]]))
        #expect(result == "")
    }

    @Test("UPDATE restricts SET to settable columns and keys WHERE on the primary key")
    func updateSettableColumnsRestrictsSetClause() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            settableColumns: ["email"],
            dialect: Self.mysqlDialect
        )
        let result = converter.generateUpdates(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "UPDATE `users` SET `email` = 'alice@example.com' WHERE `id` = '1';")
    }

    @Test("UPDATE without a primary key keeps the full row in WHERE while restricting SET")
    func updateSettableColumnsNoPrimaryKeyKeepsFullRowWhere() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: [],
            databaseType: .mysql,
            settableColumns: ["email"],
            dialect: Self.mysqlDialect
        )
        let result = converter.generateUpdates(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "UPDATE `users` SET `email` = 'alice@example.com' WHERE `id` = '1' AND `name` = 'Alice' AND `email` = 'alice@example.com';")
    }

    @Test("UPDATE emits no statement when only the primary key is settable")
    func updateSettableColumnsPrimaryKeyOnlyEmitsNothing() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            settableColumns: ["id"],
            dialect: Self.mysqlDialect
        )
        let result = converter.generateUpdates(rows: plain([["1", "Alice", "alice@example.com"]]))
        #expect(result == "")
    }

    // MARK: - Edge Cases

    @Test("Empty rows input returns empty string")
    func emptyRowsReturnsEmptyString() throws {
        let converter = try makeConverter()
        #expect(converter.generateInserts(rows: plain([])) == "")
        #expect(converter.generateUpdates(rows: plain([])) == "")
    }

    @Test("Row cap at 50,000 — 50,001 rows produces exactly 50,000 lines")
    func rowCapAt50k() throws {
        let converter = try makeConverter(
            columns: ["id", "name"],
            primaryKeyColumn: "id"
        )
        let rows: [[PluginCellValue]] = (1...50_001).map { i in [.text("\(i)"), .text("name\(i)")] }
        let result = converter.generateInserts(rows: plain(rows))
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 50_000)
    }

    @Test("PostgreSQL: binary cell renders as bytea hex literal in INSERT")
    func postgresBinaryInsertEmitsByteaLiteral() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            quoteIdentifier: { "\"\($0)\"" },
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
        let bytes = Data([0xD3, 0x8C, 0xE5, 0x66])
        let result = converter.generateInserts(rows: plain([[.text("1"), .bytes(bytes)]]))
        #expect(result.contains("'\\xD38CE566'::bytea"))
        #expect(!result.contains("NULL"))
    }

    @Test("MySQL: binary cell renders as X'...' literal in INSERT")
    func mysqlBinaryInsertEmitsXLiteral() throws {
        let converter = try makeConverter(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumn: "id"
        )
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let result = converter.generateInserts(rows: plain([[.text("1"), .bytes(bytes)]]))
        #expect(result.contains("X'DEADBEEF'"))
        #expect(!result.contains("NULL"))
    }

    @Test("MSSQL: binary cell renders as 0x... literal in INSERT")
    func mssqlBinaryInsertEmitsZeroXLiteral() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumns: ["id"],
            databaseType: .mssql,
            quoteIdentifier: { "[\($0)]" },
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
        let bytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let result = converter.generateInserts(rows: plain([[.text("1"), .bytes(bytes)]]))
        #expect(result.contains("0xCAFEBABE"))
        #expect(!result.contains("'CAFEBABE'"))
    }

    @Test("UPDATE with binary value emits hex literal in SET clause")
    func updateBinaryValueEmitsHexLiteral() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            quoteIdentifier: { "\"\($0)\"" },
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
        let bytes = Data([0xAB, 0xCD])
        let result = converter.generateUpdates(rows: plain([[.text("42"), .bytes(bytes)]]))
        #expect(result.contains("\"payload\" = '\\xABCD'::bytea"))
        #expect(result.contains("WHERE \"id\" = '42'"))
    }

    // MARK: - Columns the server owns, keys and the stored row

    private func mssqlConverter(
        columns: [String] = ["Comment", "ID", "Name"],
        primaryKeyColumns: [String] = [],
        schemaName: String? = nil,
        unwritableColumns: Set<String> = ["ID"],
        rowMatchPolicy: RowMatchPolicy = .none,
        settableColumns: [String]? = nil
    ) throws -> SQLRowToStatementConverter {
        try SQLRowToStatementConverter(
            tableName: "Enterprise_App_Approved",
            schemaName: schemaName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: .mssql,
            unwritableColumns: unwritableColumns,
            rowMatchPolicy: rowMatchPolicy,
            settableColumns: settableColumns,
            quoteIdentifier: { "[\($0)]" },
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
    }

    @Test
    func keylessUpdateLeavesAnIdentityColumnOutOfSetButMatchesOnIt() throws {
        let result = try mssqlConverter().generateUpdates(rows: plain([["Test", "1761", "APP_TEST"]]))
        #expect(result == "UPDATE [Enterprise_App_Approved] SET [Comment] = N'Test', [Name] = N'APP_TEST' WHERE [Comment] = N'Test' AND [ID] = N'1761' AND [Name] = N'APP_TEST';")
    }

    @Test
    func keyedUpdateLeavesAServerOwnedColumnOutOfSet() throws {
        let converter = try mssqlConverter(
            columns: ["code", "ID", "Name"], primaryKeyColumns: ["code"], unwritableColumns: ["ID"]
        )
        let result = converter.generateUpdates(rows: plain([["a", "7", "Alice"]]))
        #expect(result == "UPDATE [Enterprise_App_Approved] SET [Name] = N'Alice' WHERE [code] = N'a';")
    }

    @Test
    func insertLeavesServerOwnedAndDefaultMarkedColumnsOut() throws {
        let converter = try mssqlConverter(columns: ["ID", "Name", "Status"], unwritableColumns: ["ID"])
        let staged = SQLRowToStatementConverter.SourceRow(
            values: ["1761", "Alice", "__DEFAULT__"], isPendingInsert: true, defaultedColumns: [2]
        )
        #expect(converter.generateInserts(rows: [staged]) == "INSERT INTO [Enterprise_App_Approved] ([Name]) VALUES (N'Alice');")
    }

    @Test
    func insertOfOnlyServerFilledColumnsUsesDefaultValues() throws {
        let converter = try mssqlConverter(columns: ["ID", "Status"], unwritableColumns: ["ID"])
        let staged = SQLRowToStatementConverter.SourceRow(values: ["1761", "__DEFAULT__"], defaultedColumns: [1])
        #expect(converter.generateInserts(rows: [staged]) == "INSERT INTO [Enterprise_App_Approved] DEFAULT VALUES;")
    }

    @Test
    func updateAssignsDefaultForADefaultMarkedCell() throws {
        let converter = try mssqlConverter(columns: ["code", "Status"], primaryKeyColumns: ["code"], unwritableColumns: [])
        let staged = SQLRowToStatementConverter.SourceRow(values: ["a", "__DEFAULT__"], defaultedColumns: [1])
        #expect(converter.generateUpdates(rows: [staged]) == "UPDATE [Enterprise_App_Approved] SET [Status] = DEFAULT WHERE [code] = N'a';")
    }

    @Test
    func aStoredValueThatReadsLikeTheDefaultMarkerIsCopiedAsData() throws {
        let converter = try mssqlConverter(columns: ["code", "Status"], primaryKeyColumns: ["code"], unwritableColumns: [])
        let stored = plain([["a", "__DEFAULT__"]])
        #expect(converter.generateUpdates(rows: stored) == "UPDATE [Enterprise_App_Approved] SET [Status] = N'__DEFAULT__' WHERE [code] = N'a';")
        #expect(converter.generateInserts(rows: stored) == "INSERT INTO [Enterprise_App_Approved] ([code], [Status]) VALUES (N'a', N'__DEFAULT__');")
    }

    @Test
    func compositeKeyMatchesOnEveryKeyColumnAndAssignsNone() throws {
        let converter = try mssqlConverter(
            columns: ["order_id", "line_no", "qty"], primaryKeyColumns: ["order_id", "line_no"], unwritableColumns: []
        )
        let result = converter.generateUpdates(rows: plain([["5", "2", "3"]]))
        #expect(result == "UPDATE [Enterprise_App_Approved] SET [qty] = N'3' WHERE [order_id] = N'5' AND [line_no] = N'2';")
    }

    @Test
    func tableIsQualifiedWithItsSchema() throws {
        let converter = try mssqlConverter(schemaName: "sales")
        let result = converter.generateInserts(rows: plain([["Test", "1", "A"]]))
        #expect(result.hasPrefix("INSERT INTO [sales].[Enterprise_App_Approved] "))
    }

    @Test
    func whereComesFromTheStoredRowAndAnEditedKeyIsAssigned() throws {
        let converter = try mssqlConverter(columns: ["code", "Name"], primaryKeyColumns: ["code"], unwritableColumns: [])
        let edited = SQLRowToStatementConverter.SourceRow(
            values: [.text("B"), .text("Alice")], storedValues: [.text("A"), .text("Alice")]
        )
        let result = converter.generateUpdates(rows: [edited])
        #expect(result == "UPDATE [Enterprise_App_Approved] SET [code] = N'B', [Name] = N'Alice' WHERE [code] = N'A';")
    }

    @Test
    func keylessWhereUsesTheStoredValueOfAnEditedCell() throws {
        let edited = SQLRowToStatementConverter.SourceRow(
            values: [.text("Test2"), .text("1761"), .text("A")], storedValues: [.text("Test"), .text("1761"), .text("A")]
        )
        let result = try mssqlConverter().generateUpdates(rows: [edited])
        #expect(result.hasSuffix("WHERE [Comment] = N'Test' AND [ID] = N'1761' AND [Name] = N'A';"))
        #expect(result.contains("SET [Comment] = N'Test2'"))
    }

    @Test
    func aRowNotYetInTheTableWritesNoUpdate() throws {
        let pending = SQLRowToStatementConverter.SourceRow(values: [.text("x"), .null, .text("A")], isPendingInsert: true)
        #expect(try mssqlConverter().generateUpdates(rows: [pending]) == "")
    }

    @Test
    func keylessWhereCoversColumnsOutsideTheSettableOnes() throws {
        let converter = try mssqlConverter(settableColumns: ["Comment"])
        let result = converter.generateUpdates(rows: plain([["Test", "1761", "APP_TEST"]]))
        #expect(result == "UPDATE [Enterprise_App_Approved] SET [Comment] = N'Test' WHERE [Comment] = N'Test' AND [ID] = N'1761' AND [Name] = N'APP_TEST';")
    }

    @Test
    func keylessWhereCastsTheTypesSQLServerCannotCompare() throws {
        let converter = try mssqlConverter(
            columns: ["Notes", "Name"], unwritableColumns: [], rowMatchPolicy: RowMatchPolicy(textColumns: ["Notes"])
        )
        let result = converter.generateUpdates(rows: plain([["long text", "A"]]))
        #expect(result.contains("WHERE CAST([Notes] AS NVARCHAR(MAX)) = N'long text' AND [Name] = N'A';"))
    }

    @Test
    func keylessUpdateIsNotWrittenWhenAColumnCannotBeCompared() throws {
        let converter = try mssqlConverter(
            columns: ["Shape", "Name"], unwritableColumns: [], rowMatchPolicy: RowMatchPolicy(excludedColumns: ["Shape"])
        )
        #expect(converter.generateUpdates(rows: plain([["x", "A"]])) == "")
    }

    @Test
    func keyedUpdateIsWrittenWhateverThePolicyExcludes() throws {
        let converter = try mssqlConverter(
            columns: ["code", "Shape"], primaryKeyColumns: ["code"], unwritableColumns: [],
            rowMatchPolicy: RowMatchPolicy(excludedColumns: ["Shape"])
        )
        #expect(converter.generateUpdates(rows: plain([["a", "x"]])) == "UPDATE [Enterprise_App_Approved] SET [Shape] = N'x' WHERE [code] = N'a';")
    }
}
