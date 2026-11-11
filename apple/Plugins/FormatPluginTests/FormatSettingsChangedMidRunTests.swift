//
//  FormatSettingsChangedMidRunTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

// One plugin instance serves every window, so a dialog open in another window changes `settings` while a run reads.
// Each source here changes them between its first and second batch, the way that dialog would.
private final class TwoBatchSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "SQLite"
    private let header: PluginStreamHeader
    private let batches: [[PluginRow]]
    private let betweenBatches: @Sendable () -> Void

    init(columns: [String], batches: [[PluginRow]], betweenBatches: @escaping @Sendable () -> Void) {
        header = PluginStreamHeader(columns: columns, columnTypeNames: columns.map { _ in "TEXT" })
        self.batches = batches
        self.betweenBatches = betweenBatches
    }

    // Pulled, so the change lands only after the plugin has written the first batch.
    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let header = header
        let batches = batches
        let betweenBatches = betweenBatches
        let pulls = Counter()
        return AsyncThrowingStream(unfolding: {
            let pull = pulls.next()
            if pull == 0 { return .header(header) }
            guard pull <= batches.count else { return nil }
            if pull == 2 { betweenBatches() }
            return .rows(batches[pull - 1])
        })
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }

    func escapeStringLiteral(_ value: String) -> String { value }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

private final class ForeignKeyRecordingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "SQLite"
    var onExecute: () -> Void = {}
    private(set) var disabled = 0
    private(set) var enabled = 0

    func execute(statement: String) async throws { onExecute() }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func disableForeignKeyChecks() async throws { disabled += 1 }
    func enableForeignKeyChecks() async throws { enabled += 1 }
}

private final class OneStatementSource: PluginImportSource, @unchecked Sendable {
    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        AsyncThrowingStream { continuation in
            continuation.yield((statement: "INSERT INTO t VALUES (1);", lineNumber: 1))
            continuation.finish()
        }
    }

    func fileURL() -> URL { URL(fileURLWithPath: "/dev/null") }

    func fileSizeBytes() -> Int64 { 0 }
}

@Suite(.serialized)
struct FormatSettingsChangedMidRunTests {
    private let table = PluginExportTable(name: "t", databaseName: "", tableType: "table", schema: nil, kind: .table)
    private let rowWithNull: PluginRow = [.text("1"), .null]

    private func export(
        _ plugin: any ExportFormatPlugin,
        from source: TwoBatchSource,
        fileExtension: String
    ) async throws -> Data {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await plugin.export(
            tables: [table],
            dataSource: source,
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return try Data(contentsOf: destination)
    }

    @Test("JSON keeps writing null keys after another window turns Include NULL values off")
    func jsonKeepsItsNullChoice() async throws {
        let plugin = JSONExportPlugin()
        let stored = plugin.settings
        defer { plugin.settings = stored }
        var options = JSONExportOptions()
        options.layout = .newlineDelimited
        options.includeNullValues = true
        plugin.settings = options

        let source = TwoBatchSource(columns: ["id", "note"], batches: [[rowWithNull], [rowWithNull]]) {
            plugin.settings.includeNullValues = false
        }
        let text = String(decoding: try await export(plugin, from: source, fileExtension: "ndjson"), as: UTF8.self)
        #expect(text == "{\"id\": \"1\", \"note\": null}\n{\"id\": \"1\", \"note\": null}\n")
    }

    @Test("Markdown keeps its NULL placeholder after another window changes it")
    func markdownKeepsItsPlaceholder() async throws {
        let plugin = MarkdownExportPlugin()
        let stored = plugin.settings
        defer { plugin.settings = stored }
        var options = MarkdownExportOptions()
        options.alignsColumns = false
        options.includesTableNames = false
        options.nullPlaceholder = "NULL"
        plugin.settings = options

        let source = TwoBatchSource(columns: ["id", "note"], batches: [[rowWithNull], [rowWithNull]]) {
            plugin.settings.nullPlaceholder = "(none)"
        }
        let text = String(decoding: try await export(plugin, from: source, fileExtension: "md"), as: UTF8.self)
        #expect(!text.contains("(none)"))
        #expect(text.components(separatedBy: "| 1 | NULL |").count == 3)
    }

    @Test("XLSX keeps writing NULL as an empty cell after another window turns the option off")
    func xlsxKeepsItsNullChoice() async throws {
        let plugin = XLSXExportPlugin()
        let stored = plugin.settings
        defer { plugin.settings = stored }
        var options = XLSXExportOptions()
        options.convertNullToEmpty = true
        plugin.settings = options

        let source = TwoBatchSource(columns: ["id", "note"], batches: [[rowWithNull], [rowWithNull]]) {
            plugin.settings.convertNullToEmpty = false
        }
        let written = try await export(plugin, from: source, fileExtension: "xlsx")
        let text = try #require(String(bytes: written, encoding: .isoLatin1))
        #expect(!text.contains("<t>NULL</t>"))
    }

    @Test("A SQL import turns foreign key checks back on after another window unticks the option")
    func sqlImportRestoresTheChecksItTurnedOff() async throws {
        let plugin = SQLImportPlugin()
        let stored = plugin.settings
        defer { plugin.settings = stored }
        var options = SQLImportOptions()
        options.disableForeignKeyChecks = true
        plugin.settings = options

        let sink = ForeignKeyRecordingSink()
        sink.onExecute = { plugin.settings.disableForeignKeyChecks = false }
        _ = try await plugin.performImport(
            source: OneStatementSource(),
            sink: sink,
            progress: PluginImportProgress(progress: Progress())
        )
        #expect(sink.disabled == 1)
        #expect(sink.enabled == 1)
    }
}
