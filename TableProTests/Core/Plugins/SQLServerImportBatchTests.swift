//
//  SQLServerImportBatchTests.swift
//  TableProTests
//
//  A SQL file imported into SQL Server reaches the server a batch at a time, the way sqlcmd sends it. The import used
//  to split it at every `;` and send each `GO` line on to the server, which ran the statement after a `GO`, refused the
//  `GO` itself with Msg 2812 or Msg 102, and lost every variable between the statement that declared it and the next.
//  A file with no `GO` line still goes a statement at a time, each statement a batch of its own.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class BatchImportDriver: PluginDatabaseDriver, @unchecked Sendable {
    let declaresBatches: Bool
    private(set) var sentBatches: [(query: String, rowCap: Int?)] = []
    private(set) var executedStatements: [String] = []

    init(declaresBatches: Bool) {
        self.declaresBatches = declaresBatches
    }

    var capabilities: PluginCapabilities {
        declaresBatches ? [.resultSetBatches] : []
    }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        executedStatements.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    /// Answers the way SQL Server does for a batch naming a table that does not exist: the error comes back with the
    /// batch's own line, counted from the batch's first line, and the rest of the batch still ran.
    func executeBatch(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginBatchResult? {
        guard declaresBatches else { return nil }
        sentBatches.append((query, rowCap))
        let lines = query.components(separatedBy: "\n")
        let errors = lines.enumerated()
            .filter { $0.element.contains("missing") }
            .map { index, _ in
                PluginBatchError(
                    message: "Invalid object name 'missing'.",
                    code: 208,
                    line: index + 1,
                    procedure: nil,
                    precedingResultSetCount: 0
                )
            }
        return PluginBatchResult(
            resultSets: [],
            rowsAffected: 1,
            errors: errors,
            discardedResultSetCount: 0,
            executionTime: 0
        )
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

/// Serialized because `SQLImportPlugin.settings` persists through plugin storage.
@Suite("SQL Server import runs each GO batch whole", .serialized)
struct SQLServerImportBatchTests {
    private func makeSink(
        declaresBatches: Bool,
        databaseType: DatabaseType = .mssql
    ) -> (ImportDataSinkAdapter, BatchImportDriver) {
        let driver = BatchImportDriver(declaresBatches: declaresBatches)
        let adapter = PluginDriverAdapter(
            connection: DatabaseConnection(name: "Test", type: databaseType),
            pluginDriver: driver
        )
        return (ImportDataSinkAdapter(driver: adapter, databaseType: databaseType), driver)
    }

    private func runImport(_ script: String, sink: ImportDataSinkAdapter) async throws -> PluginImportResult {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let plugin = SQLImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings.errorHandling = .stopAndRollback
        plugin.settings.wrapInTransaction = false
        plugin.settings.disableForeignKeyChecks = false

        return try await plugin.performImport(
            source: SqlFileImportSource(url: url, encoding: .utf8, grammar: DatabaseType.mssql.lexicalGrammar),
            sink: sink,
            progress: PluginImportProgress(progress: Progress())
        )
    }

    @Test("A batch goes to the driver whole and once, keeping no rows")
    func batchIsSentWhole() async throws {
        let (sink, driver) = makeSink(declaresBatches: true)
        let batch = "DECLARE @x INT = 1;\nINSERT INTO t (v) VALUES (@x);"
        try await sink.execute(statement: batch, line: 4)
        #expect(driver.sentBatches.map(\.query) == [batch])
        #expect(driver.sentBatches.map(\.rowCap) == [1])
        #expect(driver.executedStatements.isEmpty)
    }

    @Test("An error inside a batch fails it on the file's own line")
    func batchErrorNamesTheFileLine() async throws {
        let (sink, _) = makeSink(declaresBatches: true)
        do {
            try await sink.execute(statement: "SELECT 1\nSELECT * FROM missing", line: 10)
            Issue.record("A batch that raised an error was reported as run")
        } catch {
            #expect(error.localizedDescription == "Line 11: Invalid object name 'missing'.")
        }
    }

    @Test("A driver that cannot send a batch whole runs its statements one by one")
    func batchlessDriverRunsStatements() async throws {
        let (sink, driver) = makeSink(declaresBatches: false)
        try await sink.execute(statement: "DECLARE @x INT = 1;\nINSERT INTO t (v) VALUES (@x);", line: 1)
        #expect(driver.executedStatements == ["DECLARE @x INT = 1", "INSERT INTO t (v) VALUES (@x)"])
    }

    @Test("Another engine's statement is sent as it came")
    func otherEnginesSendTheStatement() async throws {
        let (sink, driver) = makeSink(declaresBatches: true, databaseType: .mysql)
        try await sink.execute(statement: "INSERT INTO t VALUES (1)", line: 3)
        #expect(driver.executedStatements == ["INSERT INTO t VALUES (1)"])
        #expect(driver.sentBatches.isEmpty)
    }

    @Test("An imported Compare script sends each batch whole and never a GO line")
    func compareScriptImports() async throws {
        let (sink, driver) = makeSink(declaresBatches: true)
        let script = """
        DROP PROCEDURE [dbo].[p];
        GO
        CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1;
        GO
        INSERT INTO t VALUES (1)
        GO 2
        """
        let result = try await runImport(script, sink: sink)
        #expect(driver.sentBatches.map(\.query) == [
            "DROP PROCEDURE [dbo].[p];",
            "CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1;",
            "INSERT INTO t VALUES (1)",
            "INSERT INTO t VALUES (1)",
        ])
        #expect(driver.executedStatements.isEmpty)
        #expect(result.executedStatements == 4)
    }

    @Test("A failed batch stops the import on the batch's line, with the error's line in the file")
    func failedBatchReportsBothLines() async throws {
        let (sink, _) = makeSink(declaresBatches: true)
        let script = "SELECT 1\nGO\n-- lead\nSELECT 2\nSELECT * FROM missing\nGO\nSELECT 3"
        do {
            _ = try await runImport(script, sink: sink)
            Issue.record("An import whose batch raised an error completed")
        } catch let PluginImportError.statementFailed(statement, line, underlying) {
            #expect(statement == "-- lead\nSELECT 2\nSELECT * FROM missing")
            #expect(line == 3)
            #expect(underlying.localizedDescription == "Line 5: Invalid object name 'missing'.")
        }
    }

    @Test("A script with a GO line keeps a declared variable for the statement that reads it")
    func declaredVariableReachesItsReader() async throws {
        let (sink, driver) = makeSink(declaresBatches: true)
        _ = try await runImport("DECLARE @x INT = 1;\nINSERT INTO t (v) VALUES (@x);\nGO\n", sink: sink)
        #expect(driver.sentBatches.map(\.query) == ["DECLARE @x INT = 1;\nINSERT INTO t (v) VALUES (@x);"])
    }

    /// The shape of every SQL Server dump TablePro wrote before it wrote `GO` lines. Sent as one batch, SQL Server
    /// refuses it with Msg 111 because the view is not the first statement of its batch, and runs none of it.
    @Test("A dump with no GO line sends each statement as a batch of its own")
    func dumpWithoutGoSendsEachStatement() async throws {
        let (sink, driver) = makeSink(declaresBatches: true)
        let dump = """
        CREATE TABLE [dbo].[t] ([a] int);
        INSERT INTO [dbo].[t] ([a]) VALUES (1), (2);
        -- View: v
        CREATE VIEW [dbo].[v] AS SELECT a FROM dbo.t;
        """
        let result = try await runImport(dump, sink: sink)
        #expect(driver.sentBatches.map(\.query) == [
            "CREATE TABLE [dbo].[t] ([a] int)",
            "INSERT INTO [dbo].[t] ([a]) VALUES (1), (2)",
            "CREATE VIEW [dbo].[v] AS SELECT a FROM dbo.t",
        ])
        #expect(result.executedStatements == 3)
    }

    @Test("A failed statement in a file with no GO line names the file's own line, past a comment inside it")
    func failedStatementReportsTheFileLine() async throws {
        let (sink, _) = makeSink(declaresBatches: true)
        let script = "SELECT 1;\n-- lead\nSELECT 2\n-- inner\nFROM missing;\nSELECT 3;"
        do {
            _ = try await runImport(script, sink: sink)
            Issue.record("An import whose statement raised an error completed")
        } catch let PluginImportError.statementFailed(statement, line, underlying) {
            #expect(statement == "SELECT 2\n-- inner\nFROM missing")
            #expect(line == 3)
            #expect(underlying.localizedDescription == "Line 5: Invalid object name 'missing'.")
        }
    }
}
