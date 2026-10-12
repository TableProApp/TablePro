//
//  MCPExportWriterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MCPCsvExportTests {
    @Test("CSV quotes a bare carriage return so a cell never splits a row")
    func csvQuotesCarriageReturn() {
        let line = MCPCsvWriter.write(
            columns: ["note"],
            rows: [[.text("first\rsecond")]]
        )
        #expect(line.contains("\"first\rsecond\""))
    }

    @Test("CSV quotes commas, quotes, newlines and tabs")
    func csvQuotesSeparators() {
        #expect(MCPCsvWriter.field("a,b") == "\"a,b\"")
        #expect(MCPCsvWriter.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(MCPCsvWriter.field("line\nbreak") == "\"line\nbreak\"")
        #expect(MCPCsvWriter.field("col\tsep") == "\"col\tsep\"")
        #expect(MCPCsvWriter.field("plain") == "plain")
    }

    @Test("CSV neutralises a leading equals, plus, minus or at sign")
    func csvNeutralisesFormulas() {
        for prefix in ["=", "+", "-", "@"] {
            let value = prefix + "cmd|' /C calc'!A0"
            let output = MCPCsvWriter.field(value)
            #expect(output.hasPrefix("\"'"), "\(prefix) must be neutralised and quoted")
            #expect(!output.hasPrefix("\"\(prefix)"), "\(prefix) must not stay the first character")
        }
    }

    @Test("CSV neutralises a leading tab or carriage return, which spreadsheets also treat as a formula lead")
    func csvNeutralisesWhitespaceLeadIns() {
        #expect(MCPCsvWriter.field("\t=1+1").hasPrefix("\"'"))
        #expect(MCPCsvWriter.field("\r=1+1").hasPrefix("\"'"))
    }

    @Test("A formula prefix inside a value is left alone")
    func csvLeavesInnerSignsAlone() {
        #expect(MCPCsvWriter.field("total = 5") == "total = 5")
        #expect(MCPCsvWriter.field("a+b") == "a+b")
    }

    @Test("Null cells are empty and scalars are written unquoted")
    func csvScalarCells() {
        #expect(MCPCsvWriter.cell(.null).isEmpty)
        #expect(MCPCsvWriter.cell(.number("7")) == "7")
        #expect(MCPCsvWriter.cell(.boolean("true")) == "true")
        #expect(MCPCsvWriter.cell(.boolean("0")) == "0")
        #expect(MCPCsvWriter.cell(.binary(Data([0x00, 0x01]))) == "AAE=")
    }

    @Test("Rows are separated by CRLF, as RFC 4180 asks")
    func csvUsesCrlf() {
        let output = MCPCsvWriter.write(
            columns: ["id"],
            rows: [[.number("1")], [.number("2")]]
        )
        #expect(output == "id\r\n1\r\n2")
    }
}

struct MCPSqlExportDialectTests {
    private let postgres = MCPSqlExportDialect(
        identifierQuote: "\"",
        booleanStyle: .truefalse,
        usesBackslashEscaping: false,
        binaryStyle: .postgresBytea
    )
    private let mysql = MCPSqlExportDialect(
        identifierQuote: "`",
        booleanStyle: .numeric,
        usesBackslashEscaping: true,
        binaryStyle: .bitString
    )
    private let mssql = MCPSqlExportDialect(
        identifierQuote: "[",
        booleanStyle: .numeric,
        usesBackslashEscaping: false,
        binaryStyle: .zeroX
    )

    @Test("The dialect is resolved from the connection type, not assumed to be MySQL")
    func dialectComesFromTheConnectionType() throws {
        let resolvedPostgres = try #require(MCPSqlExportDialect.resolve(for: .postgresql))
        #expect(resolvedPostgres.identifierQuote == "\"")
        #expect(resolvedPostgres.booleanStyle == .truefalse)
        #expect(!resolvedPostgres.usesBackslashEscaping)

        let resolvedMySQL = try #require(MCPSqlExportDialect.resolve(for: .mysql))
        #expect(resolvedMySQL.identifierQuote == "`")
        #expect(resolvedMySQL.booleanStyle == .numeric)
        #expect(resolvedMySQL.usesBackslashEscaping)
    }

    @Test("An engine with no SQL dialect cannot produce SQL output")
    func enginesWithoutADialectResolveToNil() {
        #expect(MCPSqlExportDialect.resolve(for: .redis) == nil)
        #expect(MCPSqlExportDialect.resolve(for: .mongodb) == nil)
        #expect(MCPSqlExportDialect.resolve(for: .etcd) == nil)
    }

    @Test("A single quote round trips safely on PostgreSQL instead of producing injectable output")
    func postgresSingleQuoteRoundTrips() {
        let sql = MCPSqlExportWriter.write(
            table: "public.users",
            columns: ["id", "name", "active"],
            rows: [[.number("1"), .text("O'Brien"), .boolean("true")]],
            dialect: postgres
        )
        #expect(sql.contains("INSERT INTO \"public\".\"users\" (\"id\", \"name\", \"active\")"))
        #expect(sql.contains("'O''Brien'"))
        #expect(!sql.contains("\\'"))
        #expect(sql.contains("TRUE"))
    }

    @Test("A backslash is not doubled on PostgreSQL, where it is an ordinary character")
    func postgresLeavesBackslashesAlone() {
        #expect(postgres.literal("a\\b") == "'a\\b'")
        #expect(postgres.literal("it's") == "'it''s'")
    }

    @Test("MySQL keeps backticks and doubles the backslash it treats as an escape")
    func mysqlEscaping() {
        let sql = MCPSqlExportWriter.write(
            table: "users",
            columns: ["name", "active"],
            rows: [[.text("a\\b'c"), .boolean("false")]],
            dialect: mysql
        )
        #expect(sql.contains("INSERT INTO `users` (`name`, `active`)"))
        #expect(sql.contains("'a\\\\b''c'"))
        #expect(sql.contains(", 0)"))
    }

    @Test("An identifier containing the quote character is escaped, not truncated")
    func identifierQuotingIsEscaped() {
        #expect(postgres.quote("we\"ird") == "\"we\"\"ird\"")
        #expect(mysql.quote("we`ird") == "`we``ird`")
        #expect(mssql.quote("we]ird") == "[we]]ird]")
    }

    @Test("Booleans follow the engine's own literal style")
    func booleanLiteralsFollowTheDialect() {
        #expect(postgres.boolean(true) == "TRUE")
        #expect(postgres.boolean(false) == "FALSE")
        #expect(mysql.boolean(true) == "1")
        #expect(mysql.boolean(false) == "0")
    }

    @Test("Every cell kind becomes a valid literal")
    func literalsCoverEveryCellKind() {
        #expect(MCPSqlExportWriter.literal(.null, dialect: postgres) == "NULL")
        #expect(MCPSqlExportWriter.literal(.number("4"), dialect: postgres) == "4")
        #expect(MCPSqlExportWriter.literal(.text("it's"), dialect: postgres) == "'it''s'")
        #expect(MCPSqlExportWriter.literal(.boolean("t"), dialect: mysql) == "'t'")
        #expect(MCPSqlExportWriter.literal(.boolean("yes"), dialect: mysql) == "1")
        #expect(MCPSqlExportWriter.literal(.number("+5"), dialect: postgres) == "5")
    }

    @Test("Binary cells are written as the engine's hex literal, never as base64 text")
    func binaryLiteralsFollowTheEngine() {
        let bytes = Data([0xDE, 0xAD])
        #expect(MCPSqlExportWriter.literal(.binary(bytes), dialect: postgres) == "decode('dead', 'hex')")
        #expect(MCPSqlExportWriter.literal(.binary(bytes), dialect: mysql) == "X'dead'")
        #expect(MCPSqlExportWriter.literal(.binary(bytes), dialect: mssql) == "0xdead")
    }

    @Test("An Oracle binary cell uses HEXTORAW, and an empty one EMPTY_BLOB")
    func oracleBinaryLiterals() {
        let oracle = MCPSqlExportDialect(
            identifierQuote: "\"",
            booleanStyle: .numeric,
            usesBackslashEscaping: false,
            binaryStyle: .hexToRaw
        )
        #expect(oracle.binary(Data([0x01])) == "HEXTORAW('01')")
        #expect(oracle.binary(Data()) == "EMPTY_BLOB()")
    }

    @Test("A table with no columns produces nothing rather than broken SQL")
    func emptyColumnsProduceNothing() {
        let sql = MCPSqlExportWriter.write(
            table: "users",
            columns: [],
            rows: [[.number("1")]],
            dialect: postgres
        )
        #expect(sql.isEmpty)
    }
}

struct MCPJsonExportTests {
    @Test("Each row becomes an object keyed by column name")
    func rowsBecomeObjects() throws {
        let output = MCPJsonExportWriter.write(
            columns: ["id", "name"],
            rows: [[.number("1"), .text("Ada")]]
        )
        let decoded = try JSONDecoder().decode(JsonValue.self, from: Data(output.utf8))
        #expect(decoded.arrayValue?.count == 1)
        #expect(decoded.arrayValue?.first?["id"]?.intValue == 1)
        #expect(decoded.arrayValue?.first?["name"]?.stringValue == "Ada")
    }

    @Test("A short row does not invent values for the missing columns")
    func shortRowsAreNotPadded() throws {
        let output = MCPJsonExportWriter.write(
            columns: ["id", "name", "email"],
            rows: [[.number("1"), .text("Ada")]]
        )
        let decoded = try JSONDecoder().decode(JsonValue.self, from: Data(output.utf8))
        #expect(decoded.arrayValue?.first?["email"] == nil)
    }
}

struct MCPJsonExportTypedValueTests {
    @Test("Strings are escaped and every value keeps its JSON type")
    func valuesKeepTheirJsonType() throws {
        let output = MCPJsonExportWriter.write(
            columns: ["say \"hi\"", "amount", "ok", "blob", "none"],
            rows: [[.text("line\nbreak"), .number("-3.25"), .boolean("0"), .binary(Data([0x00, 0x01])), .null]]
        )
        let decoded = try JSONDecoder().decode(JsonValue.self, from: Data(output.utf8))
        let row = try #require(decoded.arrayValue?.first)
        #expect(row["say \"hi\""] == .string("line\nbreak"))
        #expect(row["amount"]?.doubleValue == -3.25)
        #expect(row["ok"] == .bool(false))
        #expect(row["blob"] == .string("AAE="))
        #expect(row["none"] == .null)
    }
}

struct MCPExportValueTests {
    private func value(_ cell: PluginCellValue, _ columnType: ColumnType?, on family: SQLTypeFamily) -> MCPExportValue {
        MCPExportValue(cell: cell, columnType: columnType, family: family)
    }

    @Test("A number column's text becomes a number only when it is one")
    func numbersAreCheckedNotAssumed() {
        #expect(value(.text("42"), .integer(rawType: "int"), on: .mysql) == .number("42"))
        #expect(value(.text("-3.25"), .decimal(rawType: "numeric"), on: .postgres) == .number("-3.25"))
        #expect(value(.text("NaN"), .decimal(rawType: "float8"), on: .postgres) == .text("NaN"))
        #expect(value(.text("$1.00"), .decimal(rawType: "money"), on: .postgres) == .text("$1.00"))
    }

    @Test("A boolean column's text becomes a boolean only for a spelling it recognizes")
    func booleansAreCheckedNotAssumed() {
        #expect(value(.text("true"), .boolean(rawType: "bool"), on: .postgres) == .boolean("true"))
        #expect(value(.text("0"), .boolean(rawType: "tinyint(1)"), on: .mysql) == .boolean("0"))
        #expect(value(.text("maybe"), .boolean(rawType: "bool"), on: .postgres) == .text("maybe"))
    }

    @Test("A boolean column holding a number other than 0 or 1 keeps it as a number")
    func booleanColumnKeepsOtherNumbers() {
        #expect(value(.text("5"), .boolean(rawType: "tinyint(1)"), on: .mysql) == .number("5"))
        #expect(value(.text("-128"), .boolean(rawType: "tinyint(1)"), on: .mysql) == .number("-128"))
    }

    @Test("A BIT column is a bit string on PostgreSQL and DuckDB, a number on MySQL and a boolean on SQL Server")
    func bitColumnsFollowTheEngine() {
        #expect(value(.text("1"), .boolean(rawType: "bit"), on: .postgres) == .text("1"))
        #expect(value(.text("00000101"), .boolean(rawType: "bit"), on: .postgres) == .text("00000101"))
        #expect(value(.text("0101"), .boolean(rawType: "BIT"), on: .duckdb) == .text("0101"))
        #expect(value(.text("5"), .boolean(rawType: "BIT"), on: .mysql) == .number("5"))
        #expect(value(.text("1"), .boolean(rawType: "bit"), on: .mssql) == .boolean("1"))
    }

    @Test("Text, unknown columns, nulls and bytes keep what they are")
    func otherCellsKeepTheirKind() {
        #expect(value(.text("007"), .text(rawType: "varchar"), on: .postgres) == .text("007"))
        #expect(value(.text("1"), nil, on: .generic) == .text("1"))
        #expect(value(.null, .integer(rawType: "int"), on: .mysql) == .null)
        #expect(value(.bytes(Data([0x01])), .blob(rawType: "blob"), on: .sqlite) == .binary(Data([0x01])))
    }
}

struct MCPExportDestinationTests {
    private func downloadsRoot() throws -> URL {
        let root = try #require(
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    @Test("A bare file name resolves inside Downloads")
    func bareNameResolvesInsideDownloads() throws {
        let name = "tablepro-mcp-\(UUID().uuidString).csv"
        let url = try MCPExportDestination.resolveDownloadsURL(for: name, format: .csv)
        #expect(url.lastPathComponent == name)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == (try downloadsRoot()).path)
    }

    @Test("A path outside Downloads is refused")
    func pathsOutsideDownloadsAreRefused() {
        for path in ["/etc/passwd.csv", "/tmp/leak.csv", "../leak.csv", "../../leak.csv"] {
            #expect(throws: MCPToolExecutionError.self, "\(path) must be refused") {
                _ = try MCPExportDestination.resolveDownloadsURL(for: path, format: .csv)
            }
        }
    }

    @Test("The extension must match the format")
    func extensionMustMatchTheFormat() {
        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPExportDestination.resolveDownloadsURL(for: "export.txt", format: .csv)
        }
        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPExportDestination.resolveDownloadsURL(for: "export.csv", format: .json)
        }
        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPExportDestination.resolveDownloadsURL(for: "export", format: .csv)
        }
    }

    @Test("A hidden file name is refused")
    func hiddenFilesAreRefused() {
        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPExportDestination.resolveDownloadsURL(for: ".secret.csv", format: .csv)
        }
    }

    @Test("An existing file is never overwritten, a unique name is used instead")
    func existingFilesAreNeverOverwritten() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("export.csv")
        try "existing".write(to: target, atomically: true, encoding: .utf8)

        let first = MCPExportDestination.uniqueURL(for: target)
        #expect(first.lastPathComponent == "export-1.csv")
        #expect(try String(contentsOf: target, encoding: .utf8) == "existing")

        try "also existing".write(to: first, atomically: true, encoding: .utf8)
        let second = MCPExportDestination.uniqueURL(for: target)
        #expect(second.lastPathComponent == "export-2.csv")
    }

    @Test("A free name is left untouched")
    func freeNamesAreLeftAlone() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("export.csv")
        #expect(MCPExportDestination.uniqueURL(for: target) == target)
    }

    @Test("Each format declares the MIME type the resource link carries")
    func formatsDeclareMimeTypes() {
        #expect(MCPExportFormat.csv.mimeType == "text/csv")
        #expect(MCPExportFormat.json.mimeType == "application/json")
        #expect(MCPExportFormat.sql.mimeType == "application/sql")
        #expect(MCPExportFormat.allCases.map(\.rawValue) == ["csv", "json", "sql"])
    }
}
