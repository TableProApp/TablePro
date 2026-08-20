//
//  MCPExportWriterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MCP CSV export")
struct MCPCsvExportTests {
    @Test("CSV quotes a bare carriage return so a cell never splits a row")
    func csvQuotesCarriageReturn() {
        let line = MCPCsvWriter.write(
            columns: ["note"],
            rows: [.array([.string("first\rsecond")])]
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
        #expect(MCPCsvWriter.cell(.int(7)) == "7")
        #expect(MCPCsvWriter.cell(.bool(true)) == "true")
        #expect(MCPCsvWriter.cell(.bool(false)) == "false")
    }

    @Test("Rows are separated by CRLF, as RFC 4180 asks")
    func csvUsesCrlf() {
        let output = MCPCsvWriter.write(
            columns: ["id"],
            rows: [.array([.int(1)]), .array([.int(2)])]
        )
        #expect(output == "id\r\n1\r\n2")
    }
}

@Suite("MCP SQL export follows the connection dialect")
struct MCPSqlExportDialectTests {
    private let postgres = MCPSqlExportDialect(
        identifierQuote: "\"",
        booleanStyle: .truefalse,
        usesBackslashEscaping: false
    )
    private let mysql = MCPSqlExportDialect(
        identifierQuote: "`",
        booleanStyle: .numeric,
        usesBackslashEscaping: true
    )
    private let mssql = MCPSqlExportDialect(
        identifierQuote: "[",
        booleanStyle: .numeric,
        usesBackslashEscaping: false
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
            rows: [.array([.int(1), .string("O'Brien"), .bool(true)])],
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
            rows: [.array([.string("a\\b'c"), .bool(false)])],
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

    @Test("Null and structured cells become valid literals")
    func literalsCoverEveryCellKind() {
        #expect(MCPSqlExportWriter.literal(.null, dialect: postgres) == "NULL")
        #expect(MCPSqlExportWriter.literal(.int(4), dialect: postgres) == "4")
        let structured = MCPSqlExportWriter.literal(
            .object(["a": .string("it's")]),
            dialect: postgres
        )
        #expect(structured.hasPrefix("'"))
        #expect(structured.contains("''"))
    }

    @Test("A table with no columns produces nothing rather than broken SQL")
    func emptyColumnsProduceNothing() {
        let sql = MCPSqlExportWriter.write(
            table: "users",
            columns: [],
            rows: [.array([.int(1)])],
            dialect: postgres
        )
        #expect(sql.isEmpty)
    }
}

@Suite("MCP JSON export")
struct MCPJsonExportTests {
    @Test("Each row becomes an object keyed by column name")
    func rowsBecomeObjects() throws {
        let output = MCPJsonExportWriter.write(
            columns: ["id", "name"],
            rows: [.array([.int(1), .string("Ada")])]
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
            rows: [.array([.int(1), .string("Ada")])]
        )
        let decoded = try JSONDecoder().decode(JsonValue.self, from: Data(output.utf8))
        #expect(decoded.arrayValue?.first?["email"] == nil)
    }
}

@Suite("MCP export destination")
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
