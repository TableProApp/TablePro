//
//  SQLRowToStatementConverterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Row To Statement Converter")
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
    ) -> SQLRowToStatementConverter {
        SQLRowToStatementConverter(
            tableName: tableName,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            dialect: dialect
        )
    }

    // MARK: - INSERT Generation

    @Test("Single row produces one INSERT statement")
    func insertSingleRow() {
        let converter = makeConverter()
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("Multiple rows are joined by newlines")
    func insertMultipleRows() {
        let converter = makeConverter()
        let rows: [[String?]] = [
            ["1", "Alice", "alice@example.com"],
            ["2", "Bob", "bob@example.com"]
        ]
        let result = converter.generateInserts(rows: rows)
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
        #expect(lines[1] == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('2', 'Bob', 'bob@example.com');")
    }

    @Test("NULL values render as unquoted NULL")
    func insertNullValues() {
        let converter = makeConverter()
        let result = converter.generateInserts(rows: [["1", nil, nil]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', NULL, NULL);")
    }

    @Test("Empty strings render as empty quoted string")
    func insertEmptyStrings() {
        let converter = makeConverter()
        let result = converter.generateInserts(rows: [["1", "", ""]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', '', '');")
    }

    @Test("Single quotes in data are escaped as double single-quotes")
    func insertSpecialCharactersSingleQuotes() {
        let converter = makeConverter()
        let result = converter.generateInserts(rows: [["1", "O'Brien", "o'brien@example.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'O''Brien', 'o''brien@example.com');")
    }

    // MARK: - UPDATE Generation

    @Test("UPDATE with primary key excludes PK from SET and uses PK in WHERE")
    func updateWithPrimaryKey() {
        let converter = makeConverter()
        let result = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1';")
    }

    @Test("UPDATE without primary key uses all columns in SET and WHERE")
    func updateWithoutPrimaryKey() {
        let converter = makeConverter(primaryKeyColumn: nil)
        let result = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `id` = '1', `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1' AND `name` = 'Alice' AND `email` = 'alice@example.com';")
    }

    @Test("UPDATE without PK uses IS NULL in WHERE clause for NULL values")
    func updateNullValuesInWhereClauseNoPK() {
        let converter = makeConverter(primaryKeyColumn: nil)
        let result = converter.generateUpdates(rows: [["1", nil, "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `id` = '1', `name` = NULL, `email` = 'alice@example.com' WHERE `id` = '1' AND `name` IS NULL AND `email` = 'alice@example.com';")
    }

    @Test("UPDATE with PK uses IS NULL in WHERE when PK value is NULL")
    func updateNullPrimaryKeyValue() {
        let converter = makeConverter()
        let result = converter.generateUpdates(rows: [[nil, "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` IS NULL;")
    }

    // MARK: - Database-Specific Quoting

    @Test("ClickHouse fallback uses standard UPDATE syntax (plugin handles ALTER TABLE at runtime)")
    func clickhouseFallbackUsesStandardUpdate() {
        let converter = makeConverter(databaseType: .clickhouse, dialect: Self.clickhouseDialect)
        let result = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1';")
    }

    @Test("MSSQL uses bracket quoting")
    func mssqlUsesBracketQuoting() {
        let converter = makeConverter(databaseType: .mssql, dialect: Self.mssqlDialect)
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO [users] ([id], [name], [email]) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("PostgreSQL uses double-quote quoting")
    func postgresqlUsesDoubleQuoteQuoting() {
        let converter = makeConverter(databaseType: .postgresql, dialect: Self.postgresDialect)
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("MySQL uses backtick quoting")
    func mysqlUsesBacktickQuoting() {
        let converter = makeConverter(databaseType: .mysql)
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("DuckDB uses double-quote quoting and standard UPDATE syntax")
    func duckdbUsesDoubleQuoteAndStandardUpdate() {
        let converter = makeConverter(databaseType: .duckdb, dialect: Self.duckdbDialect)
        let insert = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(insert == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'Alice', 'alice@example.com');")
        let update = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(update == "UPDATE \"users\" SET \"name\" = 'Alice', \"email\" = 'alice@example.com' WHERE \"id\" = '1';")
    }

    @Test("MySQL escapes backslashes in values")
    func mysqlBackslashEscaping() {
        let converter = makeConverter(databaseType: .mysql)
        let result = converter.generateInserts(rows: [["1", "C:\\Users\\test", "a@b.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'C:\\\\Users\\\\test', 'a@b.com');")
    }

    @Test("PostgreSQL does not escape backslashes")
    func postgresqlNoBackslashEscaping() {
        let converter = makeConverter(databaseType: .postgresql, dialect: Self.postgresDialect)
        let result = converter.generateInserts(rows: [["1", "C:\\Users\\test", "a@b.com"]])
        #expect(result == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'C:\\Users\\test', 'a@b.com');")
    }

    @Test("UPDATE falls back to all-column WHERE when PK not in columns")
    func updatePkNotInColumnsFallsBack() {
        let converter = makeConverter(
            columns: ["name", "email"],
            primaryKeyColumn: "id",
            databaseType: .mysql
        )
        let result = converter.generateUpdates(rows: [["Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `name` = 'Alice' AND `email` = 'alice@example.com';")
    }

    // MARK: - Edge Cases

    @Test("Empty rows input returns empty string")
    func emptyRowsReturnsEmptyString() {
        let converter = makeConverter()
        #expect(converter.generateInserts(rows: []) == "")
        #expect(converter.generateUpdates(rows: []) == "")
    }

    @Test("Row cap at 50,000 — 50,001 rows produces exactly 50,000 lines")
    func rowCapAt50k() {
        let converter = makeConverter(
            columns: ["id", "name"],
            primaryKeyColumn: "id"
        )
        let rows: [[String?]] = (1...50_001).map { i in ["\(i)", "name\(i)"] }
        let result = converter.generateInserts(rows: rows)
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 50_000)
    }
}
