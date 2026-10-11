//
//  CSVImportEncodingFailureTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private final class RecordingSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "mock"
    let targetTable: String? = "people"

    private(set) var insertedRows = 0
    private(set) var deletedAll = false

    func execute(statement: String) async throws {}
    func insertRow(_ values: [String: PluginCellValue]) async throws { insertedRows += 1 }
    func insertRows(_ rows: [[String: PluginCellValue]]) async throws { insertedRows += rows.count }
    func deleteAllRowsFromTargetTable() async throws { deletedAll = true }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}

private final class FileSource: PluginImportSource, @unchecked Sendable {
    private let url: URL

    init(url: URL) { self.url = url }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fileURL() -> URL { url }
    func fileSizeBytes() -> Int64 { 0 }
}

@Suite("CSV import refuses text it cannot read", .serialized)
struct CSVImportEncodingFailureTests {
    private func runImport(_ bytes: Data) async throws -> (Result<PluginImportResult, any Error>, RecordingSink) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-import-\(UUID().uuidString).csv")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let plugin = CSVImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings = CSVImportOptions()
        plugin.settings.deleteExistingRows = true

        let sink = RecordingSink()
        do {
            let result = try await plugin.performImport(
                source: FileSource(url: url),
                sink: sink,
                progress: PluginImportProgress(progress: Progress())
            )
            return (.success(result), sink)
        } catch {
            return (.failure(error), sink)
        }
    }

    @Test("A Shift JIS file with a broken line is refused before any row is deleted or inserted")
    func brokenShiftJISIsRefused() async throws {
        var bytes = try #require("氏名,住所\n山田太郎,東京都港区\n鈴木花子,大阪市北区\n".data(using: .shiftJIS))
        bytes.append(contentsOf: [0xA0, 0x2C, 0x78, 0x0A])
        let (outcome, sink) = try await runImport(bytes)
        guard case .failure(let error) = outcome else {
            Issue.record("The import went ahead over a line it could not read")
            return
        }
        #expect(error.localizedDescription.contains("Line 4"))
        #expect(error.localizedDescription.contains("Shift JIS"))
        #expect(!sink.deletedAll)
        #expect(sink.insertedRows == 0)
    }

    @Test("A UTF-8 file with an invalid byte is refused before any row is deleted or inserted")
    func brokenUTF8IsRefused() async throws {
        var bytes = Data("name,city\nJürgen,Köln\nZoë,Paris\n".utf8)
        bytes.append(contentsOf: [0x43, 0x61, 0x66, 0xE9, 0x2C, 0x78, 0x0A])
        let (outcome, sink) = try await runImport(bytes)
        guard case .failure = outcome else {
            Issue.record("The import went ahead over a line it could not read")
            return
        }
        #expect(!sink.deletedAll)
        #expect(sink.insertedRows == 0)
    }

    @Test("A clean Shift JIS file imports every row")
    func cleanShiftJISImports() async throws {
        let bytes = try #require("氏名,住所\n山田太郎,東京都港区\n鈴木花子,大阪市北区\n".data(using: .shiftJIS))
        let (outcome, sink) = try await runImport(bytes)
        guard case .success = outcome else {
            Issue.record("A readable Shift JIS file must import")
            return
        }
        #expect(sink.insertedRows == 2)
    }
}
