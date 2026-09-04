//
//  SQLExportDialectTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// What a SQL export writes has to be what the source engine reads back.
///
/// The expected strings here are not a preference. Each was run against a live MariaDB 12.3 and
/// sqlite3 while fixing #2630, and what each engine accepted is recorded beside it. CI reaches
/// neither engine, so these tests are the record of that measurement.
@Suite("SQL export dialect")
struct SQLExportDialectTests {

    private func dialect(for type: DatabaseType) -> SQLDialectDescriptor? {
        try? resolveSQLDialect(for: type)
    }

    // MARK: - Identifier quoting

    /// Measured: MariaDB rejects `INSERT INTO "fields" ("id") VALUES (1)` with ERROR 1064, because
    /// outside ANSI_QUOTES a double-quoted token is a string literal and not an identifier. That is
    /// the reported bug: the query-results export had no driver and fell back to ANSI quoting.
    @Test("A MySQL dialect quotes with backticks, not double quotes")
    func mysqlQuotesWithBackticks() throws {
        let quote = quoteIdentifierFromDialect(try #require(dialect(for: .mysql)))
        #expect(quote("fields") == "`fields`")
        #expect(quote("fields") != "\"fields\"")
    }

    @Test("A PostgreSQL dialect quotes with double quotes")
    func postgresQuotesWithDoubleQuotes() throws {
        let quote = quoteIdentifierFromDialect(try #require(dialect(for: .postgresql)))
        #expect(quote("fields") == "\"fields\"")
    }

    /// SQL Server opens with `[` and closes with `]`, so a naive quote + name + quote produces
    /// `[fields[`. Reading `identifierQuote` raw gets this wrong; the helper carries the case.
    @Test("SQL Server brackets close with the other character")
    func sqlServerUsesBrackets() throws {
        let quote = quoteIdentifierFromDialect(try #require(dialect(for: .mssql)))
        #expect(quote("fields") == "[fields]")
        #expect(quote("we]ird") == "[we]]ird]")
    }

    @Test("Every engine escapes its own quote character inside an identifier")
    func embeddedQuotesAreEscaped() throws {
        let mysql = quoteIdentifierFromDialect(try #require(dialect(for: .mysql)))
        #expect(mysql("we`ird") == "`we``ird`")

        let postgres = quoteIdentifierFromDialect(try #require(dialect(for: .postgresql)))
        #expect(postgres("we\"ird") == "\"we\"\"ird\"")
    }

    // MARK: - Literal escaping

    /// Measured: `C:\temp\next` written with ANSI rules re-imports into MariaDB as hex
    /// 433A09656D700A657874, ten bytes rather than twelve, because `\t` became a tab and `\n` a
    /// newline. Silent corruption, which is why the export must never guess this.
    @Test("A MySQL dialect doubles a backslash so the value survives the round trip")
    func mysqlEscapesBackslashes() throws {
        let escape = escapeStringLiteralFromDialect(try #require(dialect(for: .mysql)))
        #expect(escape("C:\\temp\\next") == "C:\\\\temp\\\\next")
        #expect(escape("O'Brien") == "O''Brien")
    }

    /// A dump taken without a driver has to be the same file as one taken with it. The MySQL
    /// driver escapes nine characters; escaping only the backslash and the quote left a raw
    /// `\u{1A}` in the output, which truncates a dump fed to the Windows `mysql` client.
    @Test("The dialect escaper writes what the MySQL driver writes")
    func mysqlEscaperMatchesTheDriver() throws {
        let escape = escapeStringLiteralFromDialect(try #require(dialect(for: .mysql)))
        #expect(escape("a\nb") == "a\\nb")
        #expect(escape("a\tb") == "a\\tb")
        #expect(escape("a\rb") == "a\\rb")
        #expect(escape("a\u{1A}b") == "a\\Zb")
        #expect(escape("a\u{08}b") == "a\\bb")
        #expect(escape("a\u{0C}b") == "a\\fb")
    }

    /// PostgreSQL reads a backslash literally in a standard-conforming string, so doubling it
    /// there would insert a second backslash into the data.
    @Test("A PostgreSQL dialect leaves a backslash alone")
    func postgresLeavesBackslashesAlone() throws {
        let escape = escapeStringLiteralFromDialect(try #require(dialect(for: .postgresql)))
        #expect(escape("C:\\temp\\next") == "C:\\temp\\next")
        #expect(escape("O'Brien") == "O''Brien")
    }

    /// Snowflake's driver declares `requiresBackslashEscapingInLiterals` and neither of its
    /// descriptors did, so the driver-backed and driver-free paths escaped the same value
    /// differently.
    ///
    /// This reads the curated snapshot, because plugins never load under XCTest. The declaration
    /// that matters in the shipping app is the plugin's own, in `SnowflakePlugin.swift`:
    /// `buildMetadataSnapshot` takes `editor.sqlDialect` from `driverType.sqlDialect` and replaces
    /// the curated one outright once the plugin loads. Both now declare it.
    @Test("Snowflake's descriptor agrees with its driver about backslashes")
    func snowflakeDescriptorDeclaresBackslashEscaping() throws {
        let descriptor = try #require(dialect(for: DatabaseType(rawValue: "Snowflake")))
        #expect(descriptor.requiresBackslashEscaping)
    }
}

/// A result set has no schema, so a query export must write neither `CREATE` nor `DROP`.
@Suite("Query export options")
struct QueryExportOptionsTests {

    private func column(_ id: String, _ label: String) -> PluginExportOptionColumn {
        PluginExportOptionColumn(id: id, label: label, width: 44)
    }

    /// `fetchTableDDL` returns "" for both query data sources, so structure produces no CREATE.
    /// Leaving drop on beside it wrote `DROP TABLE <the source table>` into a dump that never
    /// recreated it, and the name is the real table's whenever the export came from a table tab.
    @Test("A SQL query export writes data only, never structure or drop")
    func sqlQueryExportIsDataOnly() {
        let columns = [column("structure", "Structure"), column("drop", "Drop"), column("data", "Data")]
        #expect(
            QueryExportOptions.dataOnly(columns: columns, defaults: [true, true, true])
                == [false, false, true])
    }

    /// The ids are per format and the positions do not line up: MQL declares
    /// `[drop, indexes, data]`, so clearing index 0 and 1 would turn off its indexes and leave its
    /// drop on, which is the opposite of what is wanted.
    @Test("Clearing is keyed by column id, because the positions differ per format")
    func mqlQueryExportKeepsIndexesAndClearsDrop() {
        let columns = [column("drop", "Drop"), column("indexes", "Indexes"), column("data", "Data")]
        #expect(
            QueryExportOptions.dataOnly(columns: columns, defaults: [true, true, true])
                == [false, true, true])
    }

    @Test("A format with no per-object options is left alone")
    func formatWithoutOptions() {
        #expect(QueryExportOptions.dataOnly(columns: [], defaults: []).isEmpty)
    }

    /// A plugin whose defaults are shorter than its columns falls back to each column's own
    /// default rather than reading off the end.
    @Test("A short defaults array falls back to the column's own default")
    func shortDefaultsFallBack() {
        let columns = [column("structure", "Structure"), column("data", "Data")]
        #expect(QueryExportOptions.dataOnly(columns: columns, defaults: []) == [false, true])
    }
}

/// `DROP ... CASCADE` follows the engine, because it is not portable.
///
/// Measured: MariaDB accepts it and the manual says it does nothing ("permitted to make porting
/// easier"); sqlite3 rejects `DROP TABLE IF EXISTS "fields" CASCADE;` outright with
/// `near "CASCADE": syntax error`. The clause was previously emitted for every engine.
@Suite("SQL export drop clause")
struct SQLExportDropClauseTests {

    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        let supportsCascadeDrop: Bool

        init(databaseTypeId: String, supportsCascadeDrop: Bool) {
            self.databaseTypeId = databaseTypeId
            self.supportsCascadeDrop = supportsCascadeDrop
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["INTEGER"])))
                continuation.yield(.rows([[.text("1")]]))
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String {
            "CREATE TABLE \(table) (id INTEGER)"
        }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    /// Declares no capability at all, so what it answers is the protocol extension's default.
    private final class SilentExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "SQLite"

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String { identifier }
        func escapeStringLiteral(_ value: String) -> String { value }
        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private func dump(databaseTypeId: String, supportsCascadeDrop: Bool) async throws -> String {
        try await SQLExportHarness.shared.dump(
            tables: [
                PluginExportTable(
                    name: "fields",
                    databaseName: "",
                    tableType: "table",
                    optionValues: [true, true, true],
                    schema: nil
                )
            ],
            dataSource: StubExportDataSource(
                databaseTypeId: databaseTypeId, supportsCascadeDrop: supportsCascadeDrop)
        ).text
    }

    @Test("An engine that does not take CASCADE gets a plain DROP")
    func engineWithoutCascade() async throws {
        let sql = try await dump(databaseTypeId: "MySQL", supportsCascadeDrop: false)
        #expect(sql.contains("DROP TABLE IF EXISTS `fields`;"))
        #expect(!sql.contains("CASCADE"))
    }

    /// PostgreSQL is the engine the clause was written for: it drops dependent views with it.
    @Test("An engine that takes CASCADE keeps it")
    func engineWithCascade() async throws {
        let sql = try await dump(databaseTypeId: "PostgreSQL", supportsCascadeDrop: true)
        #expect(sql.contains("DROP TABLE IF EXISTS `fields` CASCADE;"))
    }

    /// The default is the answer that is never a syntax error. This asserts the protocol
    /// extension's own value, so flipping that default fails here rather than shipping a dump
    /// SQLite refuses.
    @Test("A data source that declares nothing gets no CASCADE")
    func defaultIsNoCascade() {
        let source: any PluginExportDataSource = SilentExportDataSource()
        #expect(!source.supportsCascadeDrop)
    }
}
