//
//  ExportServiceStopTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class RecordingFormat: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Recording"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Records whether it was asked to write"
    static let formatId = "recording-stop"
    static let formatDisplayName = "Recording"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"

    private(set) var wasAskedToWrite = false

    required init() {}

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        wasAskedToWrite = true
        try progress.checkCancellation()
        try Data().write(to: destination)
        return ExportFormatResult()
    }
}

private final class CountingDriver: DatabaseDriver, @unchecked Sendable {
    let connection = TestFixtures.makeConnection(type: .postgresql)
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }
    var onCount: (@MainActor () -> Void)?
    private(set) var countQueries = 0

    func execute(query: String) async throws -> QueryResult {
        let isCount = query.contains("COUNT(")
        if isCount {
            countQueries += 1
            if let onCount { await onCount() }
        }
        return QueryResult(
            columns: ["c"], columnTypes: [.integer(rawType: "BIGINT")],
            rows: isCount ? [[.text("10")]] : [],
            rowsAffected: 0, executionTime: 0, error: nil
        )
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        try await execute(query: query)
    }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        try await execute(query: query)
    }
    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func cancelQuery() throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}
    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil, avgRowLength: nil,
            rowCount: nil, comment: nil, engine: nil, collation: nil, createTime: nil, updateTime: nil
        )
    }
    func fetchViewDefinition(view: String) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

// The progress a Stop cancels did not exist until the row count finished, so a Stop pressed during the count was lost.
@MainActor
struct ExportServiceStopTests {
    private let objects = [
        ExportObjectItem(name: "orders", kind: .table),
        ExportObjectItem(name: "customers", kind: .table)
    ]

    private func export(with service: ExportService) async throws {
        var config = ExportConfiguration()
        config.formatId = RecordingFormat.formatId
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.export(objects: objects, config: config, to: url)
    }

    @Test("A Stop during the row count ends the export before the format writes anything")
    func stopDuringTheCount() async throws {
        let driver = CountingDriver()
        let format = RecordingFormat()
        let service = ExportService(driver: driver, databaseType: .postgresql) { _ in format }
        driver.onCount = { service.cancelExport() }

        await #expect(throws: PluginExportCancellationError.self) {
            try await self.export(with: service)
        }

        #expect(driver.countQueries == 1)
        #expect(!format.wasAskedToWrite)
        #expect(!service.state.isExporting)
    }

    @Test("A Stop before the export starts counts nothing")
    func stopBeforeTheExport() async throws {
        let driver = CountingDriver()
        let format = RecordingFormat()
        let service = ExportService(driver: driver, databaseType: .postgresql) { _ in format }
        service.cancelExport()

        await #expect(throws: PluginExportCancellationError.self) {
            try await self.export(with: service)
        }

        #expect(driver.countQueries == 0)
        #expect(!format.wasAskedToWrite)
    }
}
