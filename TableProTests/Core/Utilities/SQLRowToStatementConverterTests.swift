//
//  SQLRowToStatementConverterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Row To Statement Converter")
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
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            dialect: dialect
        )
    }

    // MARK: - INSERT Generation

    @Test("Single row produces one INSERT statement")
    func insertSingleRow() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("Multiple rows are joined by newlines")
    func insertMultipleRows() throws {
        let converter = try makeConverter()
        let rows: [[PluginCellValue]] = [
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
    func insertNullValues() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: [["1", nil, nil]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', NULL, NULL);")
    }

    @Test("Empty strings render as empty quoted string")
    func insertEmptyStrings() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: [["1", "", ""]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', '', '');")
    }

    @Test("Single quotes in data are escaped as double single-quotes")
    func insertSpecialCharactersSingleQuotes() throws {
        let converter = try makeConverter()
        let result = converter.generateInserts(rows: [["1", "O'Brien", "o'brien@example.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'O''Brien', 'o''brien@example.com');")
    }

    // MARK: - UPDATE Generation

    @Test("UPDATE with primary key excludes PK from SET and uses PK in WHERE")
    func updateWithPrimaryKey() throws {
        let converter = try makeConverter()
        let result = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1';")
    }

    @Test("UPDATE without primary key uses all columns in SET and WHERE")
    func updateWithoutPrimaryKey() throws {
        let converter = try makeConverter(primaryKeyColumn: nil)
        let result = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `id` = '1', `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1' AND `name` = 'Alice' AND `email` = 'alice@example.com';")
    }

    @Test("UPDATE without PK uses IS NULL in WHERE clause for NULL values")
    func updateNullValuesInWhereClauseNoPK() throws {
        let converter = try makeConverter(primaryKeyColumn: nil)
        let result = converter.generateUpdates(rows: [["1", nil, "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `id` = '1', `name` = NULL, `email` = 'alice@example.com' WHERE `id` = '1' AND `name` IS NULL AND `email` = 'alice@example.com';")
    }

    @Test("UPDATE with PK uses IS NULL in WHERE when PK value is NULL")
    func updateNullPrimaryKeyValue() throws {
        let converter = try makeConverter()
        let result = converter.generateUpdates(rows: [[nil, "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` IS NULL;")
    }

    // MARK: - Database-Specific Quoting

    @Test("ClickHouse fallback uses standard UPDATE syntax (plugin handles ALTER TABLE at runtime)")
    func clickhouseFallbackUsesStandardUpdate() throws {
        let converter = try makeConverter(databaseType: .clickhouse, dialect: Self.clickhouseDialect)
        let result = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `id` = '1';")
    }

    @Test("MSSQL uses bracket quoting")
    func mssqlUsesBracketQuoting() throws {
        let converter = try makeConverter(databaseType: .mssql, dialect: Self.mssqlDialect)
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO [users] ([id], [name], [email]) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("PostgreSQL uses double-quote quoting")
    func postgresqlUsesDoubleQuoteQuoting() throws {
        let converter = try makeConverter(databaseType: .postgresql, dialect: Self.postgresDialect)
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("MySQL uses backtick quoting")
    func mysqlUsesBacktickQuoting() throws {
        let converter = try makeConverter(databaseType: .mysql)
        let result = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'Alice', 'alice@example.com');")
    }

    @Test("DuckDB uses double-quote quoting and standard UPDATE syntax")
    func duckdbUsesDoubleQuoteAndStandardUpdate() throws {
        let converter = try makeConverter(databaseType: .duckdb, dialect: Self.duckdbDialect)
        let insert = converter.generateInserts(rows: [["1", "Alice", "alice@example.com"]])
        #expect(insert == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'Alice', 'alice@example.com');")
        let update = converter.generateUpdates(rows: [["1", "Alice", "alice@example.com"]])
        #expect(update == "UPDATE \"users\" SET \"name\" = 'Alice', \"email\" = 'alice@example.com' WHERE \"id\" = '1';")
    }

    @Test("MySQL escapes backslashes in values")
    func mysqlBackslashEscaping() throws {
        let converter = try makeConverter(databaseType: .mysql)
        let result = converter.generateInserts(rows: [["1", "C:\\Users\\test", "a@b.com"]])
        #expect(result == "INSERT INTO `users` (`id`, `name`, `email`) VALUES ('1', 'C:\\\\Users\\\\test', 'a@b.com');")
    }

    @Test("PostgreSQL does not escape backslashes")
    func postgresqlNoBackslashEscaping() throws {
        let converter = try makeConverter(databaseType: .postgresql, dialect: Self.postgresDialect)
        let result = converter.generateInserts(rows: [["1", "C:\\Users\\test", "a@b.com"]])
        #expect(result == "INSERT INTO \"users\" (\"id\", \"name\", \"email\") VALUES ('1', 'C:\\Users\\test', 'a@b.com');")
    }

    @Test("UPDATE falls back to all-column WHERE when PK not in columns")
    func updatePkNotInColumnsFallsBack() throws {
        let converter = try makeConverter(
            columns: ["name", "email"],
            primaryKeyColumn: "id",
            databaseType: .mysql
        )
        let result = converter.generateUpdates(rows: [["Alice", "alice@example.com"]])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@example.com' WHERE `name` = 'Alice' AND `email` = 'alice@example.com';")
    }

    // MARK: - Edge Cases

    @Test("Empty rows input returns empty string")
    func emptyRowsReturnsEmptyString() throws {
        let converter = try makeConverter()
        #expect(converter.generateInserts(rows: []) == "")
        #expect(converter.generateUpdates(rows: []) == "")
    }

    @Test("Row cap at 50,000 — 50,001 rows produces exactly 50,000 lines")
    func rowCapAt50k() throws {
        let converter = try makeConverter(
            columns: ["id", "name"],
            primaryKeyColumn: "id"
        )
        let rows: [[PluginCellValue]] = (1...50_001).map { i in [.text("\(i)"), .text("name\(i)")] }
        let result = converter.generateInserts(rows: rows)
        let lines = result.components(separatedBy: "\n")
        #expect(lines.count == 50_000)
    }

    @Test("PostgreSQL: binary cell renders as bytea hex literal in INSERT")
    func postgresBinaryInsertEmitsByteaLiteral() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumn: "id",
            databaseType: .postgresql,
            quoteIdentifier: { "\"\($0)\"" },
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
        let bytes = Data([0xD3, 0x8C, 0xE5, 0x66])
        let result = converter.generateInserts(rows: [[.text("1"), .bytes(bytes)]])
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
        let result = converter.generateInserts(rows: [[.text("1"), .bytes(bytes)]])
        #expect(result.contains("X'DEADBEEF'"))
        #expect(!result.contains("NULL"))
    }

    @Test("MSSQL: binary cell renders as 0x... literal in INSERT")
    func mssqlBinaryInsertEmitsZeroXLiteral() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumn: "id",
            databaseType: .mssql,
            quoteIdentifier: { "[\($0)]" },
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
        let bytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let result = converter.generateInserts(rows: [[.text("1"), .bytes(bytes)]])
        #expect(result.contains("0xCAFEBABE"))
        #expect(!result.contains("'CAFEBABE'"))
    }

    @Test("UPDATE with binary value emits hex literal in SET clause")
    func updateBinaryValueEmitsHexLiteral() throws {
        let converter = try SQLRowToStatementConverter(
            tableName: "documents",
            columns: ["id", "payload"],
            primaryKeyColumn: "id",
            databaseType: .postgresql,
            quoteIdentifier: { "\"\($0)\"" },
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
        let bytes = Data([0xAB, 0xCD])
        let result = converter.generateUpdates(rows: [[.text("42"), .bytes(bytes)]])
        #expect(result.contains("\"payload\" = '\\xABCD'::bytea"))
        #expect(result.contains("WHERE \"id\" = '42'"))
    }
}
