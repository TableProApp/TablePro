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

private final class HugeCountDriver: DatabaseDriver, @unchecked Sendable {
    let connection = TestFixtures.makeConnection(type: .postgresql)
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    func execute(query: String) async throws -> QueryResult {
        let count = PluginCellValue.text(String(Int.max))
        return QueryResult(
            columns: ["c"], columnTypes: [.integer(rawType: "BIGINT")],
            rows: query.contains("COUNT(") ? [[count], [count]] : [],
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

    @Test("Two tables whose counts add past Int.max total Int.max instead of crashing")
    func countsSaturate() async throws {
        let driver = HugeCountDriver()
        let format = StructureAndDataFormat()
        let service = ExportService(driver: driver, databaseType: .postgresql) { _ in format }
        var config = ExportConfiguration()
        config.formatId = StructureAndDataFormat.formatId
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.export(objects: [
            ExportObjectItem(name: "orders", kind: .table, optionValues: [true, true]),
            ExportObjectItem(name: "customers", kind: .table, optionValues: [true, true])
        ], config: config, to: url)

        #expect(service.state.totalRows == Int.max)
    }
}
