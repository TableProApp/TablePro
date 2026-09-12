//
//  SQLExportStatementSizeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// The size limit through a whole export, rather than through the accumulator alone: the dump on
/// disk, the summary the dialog shows, and the engine-specific literals inside the statements.
@Suite("SQL export statement size")
struct SQLExportStatementSizeTests {
    private final class StubExportDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId: String
        private let rows: [[PluginCellValue]]
        private let columns: [String]
        private let columnTypeNames: [String]
        private let afterLastRow: (@Sendable () -> Void)?

        init(
            databaseTypeId: String = "MySQL",
            columns: [String] = ["id", "payload"],
            columnTypeNames: [String] = ["INT", "LONGTEXT"],
            rows: [[PluginCellValue]],
            afterLastRow: (@Sendable () -> Void)? = nil
        ) {
            self.databaseTypeId = databaseTypeId
            self.columns = columns
            self.columnTypeNames = columnTypeNames
            self.rows = rows
            self.afterLastRow = afterLastRow
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            let header = PluginStreamHeader(columns: columns, columnTypeNames: columnTypeNames)
            let payload = rows
            let afterLastRow = afterLastRow
            return AsyncThrowingStream { continuation in
                continuation.yield(.header(header))
                continuation.yield(.rows(payload))
                afterLastRow?()
                continuation.finish()
            }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String {
            "CREATE TABLE \(table) (id INT, payload LONGTEXT)"
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

    private func table(_ name: String = "wide") -> PluginExportTable {
        PluginExportTable(
            name: name, databaseName: "", tableType: "table", optionValues: [false, false, true], schema: nil)
    }

    private func wideRows(count: Int, payloadBytes: Int) -> [[PluginCellValue]] {
        (0 ..< count).map { [.text("\($0)"), .text(String(repeating: "x", count: payloadBytes))] }
    }

    private func statements(in dump: String) -> [String] {
        let pieces = dump.components(separatedBy: "INSERT INTO")
        guard pieces.count > 1 else { return [] }
        return Array(pieces[1...])
    }

    private func options(
        maxStatementBytes: Int,
        batchSize: Int = 500,
        insertMode: SQLExportInsertMode = .insert
    ) -> SQLExportOptions {
        var options = SQLExportOptions()
        options.maxStatementBytes = maxStatementBytes
        options.batchSize = batchSize
        options.insertMode = insertMode
        return options
    }

    /// The reported bug: 500 rows of a mebibyte each went out as one statement of about 524 MB,
    /// which MariaDB answers with "Server has gone away". Scaled down to keep the suite quick; the
    /// shape is the same.
    @Test("A table of wide rows is split into statements that each stay under the limit")
    func wideRowsSplitOnTheByteLimit() async throws {
        let source = StubExportDataSource(rows: wideRows(count: 40, payloadBytes: 100_000))
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source, options: options(maxStatementBytes: 1 << 20))

        let written = statements(in: output.text)
        #expect(written.count > 1, "40 rows of 100 KB must not go out as one statement")
        for statement in written {
            #expect(statement.utf8.count <= 1 << 20)
        }
    }

    @Test("Turning the limit off puts the same rows in one statement")
    func noLimitReproducesTheOldOutput() async throws {
        let source = StubExportDataSource(rows: wideRows(count: 40, payloadBytes: 100_000))
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source, options: options(maxStatementBytes: 0))
        #expect(statements(in: output.text).count == 1)
    }

    @Test("The row count still closes a statement when the rows are narrow")
    func narrowRowsCloseOnTheRowCount() async throws {
        let source = StubExportDataSource(rows: wideRows(count: 250, payloadBytes: 4))
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source,
            options: options(maxStatementBytes: 1 << 20, batchSize: 100))
        #expect(statements(in: output.text).count == 3)
    }

    /// The summary is the only place the setting can be judged from, so it reports the size whether
    /// or not the limit bound anything.
    @Test("The summary names the largest INSERT the export wrote")
    func theSummaryReportsTheLargestStatement() async throws {
        let source = StubExportDataSource(rows: wideRows(count: 40, payloadBytes: 100_000))
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source, options: options(maxStatementBytes: 1 << 20))

        let note = try #require(output.result.notes.first)
        #expect(note.hasPrefix("Largest INSERT written: "))
        #expect(note.contains("rows)"))
        #expect(output.result.warnings.isEmpty, "a size the limit held is a note, never a warning")
    }

    /// A row wider than the whole limit cannot be split, so the limit does not hold for it. That is
    /// a warning, because the dump can still be rejected on restore.
    @Test("A row too wide for the limit is reported as a warning")
    func anOversizedRowRaisesAWarning() async throws {
        let source = StubExportDataSource(rows: wideRows(count: 2, payloadBytes: 400_000))
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source, options: options(maxStatementBytes: 262_144))

        let warning = try #require(output.result.warnings.first)
        #expect(warning.contains("does not fit") || warning.contains("do not fit"))
        #expect(statements(in: output.text).count == 2)
    }

    @Test("An empty table reports no size at all")
    func anEmptyTableReportsNothing() async throws {
        let source = StubExportDataSource(rows: [])
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source, options: options(maxStatementBytes: 1 << 20))
        #expect(output.result.notes.isEmpty)
        #expect(!output.text.contains("INSERT INTO"))
    }

    /// Oracle has no multi-row `VALUES`, so the row ceiling holds whatever the user picked.
    @Test("Oracle gets one row per INSERT however high the row count is set")
    func oracleNeverWritesAMultiRowInsert() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "Oracle", rows: wideRows(count: 5, payloadBytes: 4))
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source,
            options: options(maxStatementBytes: 1 << 20, batchSize: 500))
        #expect(statements(in: output.text).count == 5)
    }

    @Test("SQL Server never passes its thousand-row VALUES ceiling")
    func sqlServerStaysUnderItsRowCeiling() {
        #expect(SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: "SQL Server") == 1_000)
        #expect(SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: "Oracle") == 1)
        #expect(SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: "MySQL") == .max)
        #expect(SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: "SomeFuturePlugin") == .max)
    }

    /// Stop can land after the last row and before the stream ends, where the loop's own checks no
    /// longer run. The buffered statement must not be written and the file must not be committed:
    /// a cancelled export that reports success is worse than one that reports nothing.
    @Test("Stopping after the last row throws rather than writing the buffered INSERT")
    func cancellingBeforeTheFinalFlushAbandonsTheDump() async throws {
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 1))
        let source = StubExportDataSource(
            rows: wideRows(count: 5, payloadBytes: 8),
            afterLastRow: { progress.cancel() })

        await #expect(throws: (any Error).self) {
            _ = try await SQLExportHarness.shared.dump(
                tables: [table()], dataSource: source,
                options: options(maxStatementBytes: 1 << 20), progress: progress)
        }
    }

    /// A table whose scope selected nothing still produces a header, and the insert mode's warning
    /// used to be raised from the header alone. That branded a clean export a failure: a non-empty
    /// `warnings` retitles the summary alert and takes away its suppression checkbox.
    @Test("An empty table raises no insert-mode warning it never wrote a row under")
    func anEmptyTableRaisesNoModeWarning() async throws {
        let empty = StubExportDataSource(databaseTypeId: "PostgreSQL", rows: [])
        let emptyOutput = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: empty,
            options: options(maxStatementBytes: 1 << 20, insertMode: .updateExisting))
        #expect(emptyOutput.result.warnings.isEmpty)
        #expect(emptyOutput.result.notes.isEmpty)

        /// The same table with rows still reports it, so the warning was deferred rather than lost.
        let filled = StubExportDataSource(
            databaseTypeId: "PostgreSQL", rows: wideRows(count: 2, payloadBytes: 8))
        let filledOutput = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: filled,
            options: options(maxStatementBytes: 1 << 20, insertMode: .updateExisting))
        #expect(filledOutput.result.warnings.count == 1)
    }

    /// PostgreSQL rejects `X'..'` for a `bytea` column, so the dump has to carry `decode` instead.
    @Test("A PostgreSQL dump writes decode for a binary value")
    func postgresBinaryValuesUseDecode() async throws {
        let source = StubExportDataSource(
            databaseTypeId: "PostgreSQL",
            columnTypeNames: ["INT", "BYTEA"],
            rows: [[.text("1"), .bytes(Data([0x41, 0x42, 0x43]))]])
        let output = try await SQLExportHarness.shared.dump(
            tables: [table()], dataSource: source, options: options(maxStatementBytes: 1 << 20))
        #expect(output.text.contains("decode('414243', 'hex')"))
        #expect(!output.text.contains("X'414243'"))
    }
}
