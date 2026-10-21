import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StructureAndDataFormat: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Structure and Data"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Writes structure, and rows when Data is checked"
    static let formatId = "structure-and-data"
    static let formatDisplayName = "Structure and Data"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"
    static let perTableOptionColumns = [
        PluginExportOptionColumn(id: "structure", label: "Structure", width: 40),
        PluginExportOptionColumn(id: "data", label: "Data", width: 40)
    ]

    required init() {}

    func defaultTableOptionValues() -> [Bool] { [true, true] }

    func readsRows(optionValues: [Bool], kind: PluginExportObjectKind) -> Bool {
        kind.carriesRows && optionValues.count > 1 && optionValues[1]
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        try Data().write(to: destination)
        return ExportFormatResult()
    }
}

private final class RowsOnlyFormat: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Rows Only"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Streams the rows of every object it is handed"
    static let formatId = "rows-only"
    static let formatDisplayName = "Rows Only"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"

    required init() {}

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        try Data().write(to: destination)
        return ExportFormatResult()
    }
}

@MainActor
struct ExportServiceRowCountTests {
    private func run(
        _ objects: [ExportObjectItem],
        format: any ExportFormatPlugin = StructureAndDataFormat()
    ) async throws -> (ExportService, [String]) {
        let driver = MockDatabaseDriver(connection: TestFixtures.makeConnection(type: .postgresql))
        let formatId = type(of: format).formatId
        let service = ExportService(driver: driver, databaseType: .postgresql) { requested in
            requested == formatId ? format : nil
        }
        var config = ExportConfiguration()
        config.formatId = formatId
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.export(objects: objects, config: config, to: url)
        return (service, driver.executedQueries.filter { $0.contains("COUNT(") })
    }

    @Test("An export that writes no rows counts none, and reports its progress in objects")
    func structureOnlyCountsNothing() async throws {
        let (service, counts) = try await run([
            ExportObjectItem(name: "orders", kind: .table, optionValues: [true, false]),
            ExportObjectItem(name: "customers", kind: .table, optionValues: [true, false])
        ])

        #expect(counts.isEmpty)
        #expect(!service.state.readsRows)
        #expect(service.state.totalRows == 0)
    }

    @Test("A row format exporting views reads rows, though a view is never counted up front")
    func viewsAreReadButNotCounted() async throws {
        let (service, counts) = try await run(
            [ExportObjectItem(name: "recent_orders", kind: .view)], format: RowsOnlyFormat())

        #expect(counts.isEmpty)
        #expect(service.state.readsRows)
    }

    @Test("Only the tables whose rows are written are counted")
    func onlyDataTablesAreCounted() async throws {
        let (service, counts) = try await run([
            ExportObjectItem(name: "orders", kind: .table, optionValues: [true, true]),
            ExportObjectItem(name: "customers", kind: .table, optionValues: [true, false])
        ])

        #expect(counts.count == 1)
        #expect(counts.first?.contains("orders") == true)
        #expect(counts.first?.contains("customers") == false)
        #expect(service.state.readsRows)
    }
}
