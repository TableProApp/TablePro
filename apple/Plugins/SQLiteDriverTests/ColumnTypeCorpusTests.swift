//
//  ColumnTypeCorpusTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// SQLite needs no server, so its corpus runs here; the server engines run theirs through
// scripts/probes/check-column-type-corpus.sh.
struct ColumnTypeCorpusTests {
    private static let corpusFile: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { directory.deleteLastPathComponent() }
        return directory.appendingPathComponent("ColumnTypeCorpus/Corpus/sqlite.json")
    }()

    @Test("Every SQLite column type reads, saves, reads back and exports as the table tab shows it")
    func sqliteCorpus() async throws {
        let corpus = try ColumnTypeCorpus.load(Self.corpusFile)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: work.appendingPathComponent("corpus.sqlite").path
        ))
        try await driver.connect()
        defer { driver.disconnect() }

        // The exporters keep their options in the shared defaults, so each runs on the defaults and gets its own back.
        let csv = CSVExportPlugin()
        let json = JSONExportPlugin()
        let sql = SQLExportPlugin()
        let stored = (csv.settings, json.settings, sql.settings)
        csv.settings = CSVExportOptions()
        json.settings = JSONExportOptions()
        sql.settings = SQLExportOptions()
        defer {
            csv.settings = stored.0
            json.settings = stored.1
            sql.settings = stored.2
        }

        let runner = ColumnTypeCorpusRunner(
            corpus: corpus,
            driver: driver,
            listedTypes: SQLitePlugin.columnTypesByCategory,
            dialect: SQLitePlugin.sqlDialect,
            supportsCascadeDrop: SQLitePlugin.supportsCascadeDrop,
            exports: [
                ColumnTypeCorpusExport(formatId: "csv", optionValues: []) { tables, source, destination in
                    _ = try await csv.export(tables: tables, dataSource: source, destination: destination, progress: Self.progress)
                },
                ColumnTypeCorpusExport(formatId: "json", optionValues: []) { tables, source, destination in
                    _ = try await json.export(tables: tables, dataSource: source, destination: destination, progress: Self.progress)
                },
                ColumnTypeCorpusExport(formatId: "sql", optionValues: [false, false, true]) { tables, source, destination in
                    _ = try await sql.export(tables: tables, dataSource: source, destination: destination, progress: Self.progress)
                },
            ],
            workDirectory: work
        )
        let report = await runner.run { _ in }
        #expect(report.failures.isEmpty, "\(report.failures.joined(separator: "\n"))")
        #expect(report.entries.count == corpus.columns.count * ColumnTypeCorpus.Step.allCases.count + 1)
    }

    private static var progress: PluginExportProgress {
        PluginExportProgress(progress: Progress(totalUnitCount: 1))
    }
}
