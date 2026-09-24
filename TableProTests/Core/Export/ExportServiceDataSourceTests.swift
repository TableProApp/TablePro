//
//  ExportServiceDataSourceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class TwoRowDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = DataSourceExportRequest.dataFileTypeId

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["id", "note"], columnTypeNames: ["", ""])))
            continuation.yield(.rows([["1", "first"], ["2", "it's second"]]))
            continuation.finish()
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        throw ExportError.exportFailed("No queries")
    }

    func quoteIdentifier(_ identifier: String) -> String { SQLEscaping.quoteIdentifier(identifier) }

    func escapeStringLiteral(_ value: String) -> String { SQLEscaping.escapeStringLiteral(value) }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { 2 }
}

private final class LineWritingFormat: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Line Writer"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Writes each streamed row as one line"
    static let formatId = "lines"
    static let formatDisplayName = "Lines"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"
    static let perTableOptionColumns = [
        PluginExportOptionColumn(id: "structure", label: "Structure", width: 40),
        PluginExportOptionColumn(id: "data", label: "Data", width: 40)
    ]

    private(set) var receivedTables: [PluginExportTable] = []

    required init() {}

    func defaultTableOptionValues() -> [Bool] { [true, true] }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        receivedTables = tables
        var lines: [String] = []
        for table in tables {
            progress.setCurrentTable(table.name, index: 1)
            for try await element in dataSource.streamRows(for: table) {
                switch element {
                case .header(let header):
                    lines.append(header.columns.map(dataSource.quoteIdentifier).joined(separator: ","))
                case .rows(let rows):
                    for row in rows {
                        lines.append(row.map { Self.render($0, in: dataSource) }.joined(separator: ","))
                        progress.incrementRow()
                    }
                }
            }
            progress.finalizeTable()
        }
        try lines.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
        return ExportFormatResult(warnings: [], notes: ["\(lines.count - 1) rows"])
    }

    private static func render(_ value: PluginCellValue, in dataSource: any PluginExportDataSource) -> String {
        switch value {
        case .text(let text): return "'\(dataSource.escapeStringLiteral(text))'"
        case .null: return "NULL"
        case .bytes: return "?"
        }
    }
}

@Suite("Export service data source entry")
@MainActor
struct ExportServiceDataSourceTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("export-data-source-\(UUID().uuidString)")
            .appendingPathExtension("txt")
    }

    private func config(formatId: String = LineWritingFormat.formatId) -> ExportConfiguration {
        var config = ExportConfiguration()
        config.formatId = formatId
        config.fileName = "orders"
        return config
    }

    @Test("A data source handed to the service streams its rows into the chosen format's file")
    func streamsRowsIntoTheFile() async throws {
        let format = LineWritingFormat()
        let service = ExportService { $0 == LineWritingFormat.formatId ? format : nil }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await service.export(dataSource: TwoRowDataSource(), config: config(), to: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == "\"id\",\"note\"\n'1','first'\n'2','it''s second'")
        #expect(service.state.totalRows == 2)
        #expect(service.state.processedRows == 2)
        #expect(service.state.notes == ["2 rows"])
        #expect(!service.state.isExporting)
    }

    @Test("The service names the one table after the file and asks for data without structure")
    func exportsOneDataOnlyTable() async throws {
        let format = LineWritingFormat()
        let service = ExportService { _ in format }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await service.export(dataSource: TwoRowDataSource(), config: config(), to: url)

        let table = try #require(format.receivedTables.first)
        #expect(format.receivedTables.count == 1)
        #expect(table.name == "orders")
        #expect(table.databaseName.isEmpty)
        #expect(table.optionValues == [false, true])
    }

    @Test("A format that is not installed fails before anything is written")
    func missingFormatThrows() async {
        let service = ExportService { _ in nil }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExportError.self) {
            try await service.export(dataSource: TwoRowDataSource(), config: config(formatId: "gone"), to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(!service.state.isExporting)
    }
}
