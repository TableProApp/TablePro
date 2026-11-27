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

// Answers each table's catalog estimate and records every statement and estimate it was asked for.
private final class EstimatingDriver: DatabaseDriver, @unchecked Sendable {
    let connection = TestFixtures.makeConnection(type: .postgresql)
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }
    var estimates: [String: Int] = [:]
    private(set) var executedQueries: [String] = []
    private(set) var estimatedTables: [String] = []

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        estimatedTables.append(table)
        return estimates[table]
    }

    func execute(query: String) async throws -> QueryResult {
        executedQueries.append(query)
        return QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
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
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns(schema: String?) async throws -> [CatalogName: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(tableName: String, schema: String?) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil, avgRowLength: nil,
            rowCount: nil, comment: nil, engine: nil, collation: nil, createTime: nil, updateTime: nil
        )
    }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

// A driver with a schema-wide metadata read, which counts how often each read runs.
private final class BulkMetadataPluginDriver: PluginDriverStub, @unchecked Sendable {
    var rowCounts: [String: Int64] = [:]
    private(set) var bulkReads = 0
    private(set) var tableEstimates = 0
    private(set) var statements: [String] = []

    var providesBulkTableMetadataFetch: Bool { true }

    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        bulkReads += 1
        return rowCounts.reduce(into: [:]) { result, entry in
            result[entry.key] = PluginTableMetadata(tableName: entry.key, rowCount: entry.value)
        }
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        tableEstimates += 1
        return rowCounts[table].map { Int($0) }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        statements.append(query)
        return .empty
    }
}

@MainActor
struct ExportServiceRowCountTests {
    private func run(
        _ objects: [ExportObjectItem],
        on driver: any DatabaseDriver = EstimatingDriver(),
        format: any ExportFormatPlugin = StructureAndDataFormat()
    ) async throws -> ExportService {
        let formatId = type(of: format).formatId
        let service = ExportService(driver: driver, databaseType: .postgresql) { requested in
            requested == formatId ? format : nil
        }
        var config = ExportConfiguration()
        config.formatId = formatId
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await service.export(objects: objects, config: config, to: url)
        return service
    }

    private func table(_ name: String, data: Bool = true, scope: PluginExportRowScope = .unrestricted) -> ExportObjectItem {
        ExportObjectItem(name: name, kind: .table, optionValues: [true, data], rowScope: scope)
    }

    @Test("An export that writes no rows estimates none, and reports its progress in objects")
    func structureOnlyEstimatesNothing() async throws {
        let driver = EstimatingDriver()
        let service = try await run([table("orders", data: false), table("customers", data: false)], on: driver)

        #expect(driver.estimatedTables.isEmpty)
        #expect(!service.state.readsRows)
        #expect(service.state.totalRows == 0)
    }

    @Test("A row format exporting views reads rows, though a view is never estimated up front")
    func viewsAreReadButNotEstimated() async throws {
        let driver = EstimatingDriver()
        let service = try await run(
            [ExportObjectItem(name: "recent_orders", kind: .view)], on: driver, format: RowsOnlyFormat())

        #expect(driver.estimatedTables.isEmpty)
        #expect(service.state.readsRows)
    }

    @Test("A table export runs no COUNT(*) and takes its total from the catalog's estimate")
    func totalIsTheCatalogEstimate() async throws {
        let driver = EstimatingDriver()
        driver.estimates = ["orders": 10_000_000, "customers": 2_500]
        let service = try await run([table("orders"), table("customers")], on: driver)

        #expect(!driver.executedQueries.contains { $0.uppercased().contains("COUNT(") })
        #expect(service.state.totalRows == 10_002_500)
        #expect(service.state.rowTotalIsEstimate)
    }

    @Test("Only the tables whose rows are written are estimated")
    func onlyDataTablesAreEstimated() async throws {
        let driver = EstimatingDriver()
        driver.estimates = ["orders": 40, "customers": 7]
        let service = try await run([table("orders"), table("customers", data: false)], on: driver)

        #expect(driver.estimatedTables == ["orders"])
        #expect(service.state.totalRows == 40)
        #expect(service.state.readsRows)
    }

    @Test("A row limit caps the table's share of the total at the limit")
    func rowLimitCapsTheEstimate() async throws {
        let driver = EstimatingDriver()
        driver.estimates = ["orders": 10_000_000, "customers": 300]
        let service = try await run([
            table("orders", scope: PluginExportRowScope(rowLimit: 1_000)),
            table("customers", scope: PluginExportRowScope(rowLimit: 1_000))
        ], on: driver)

        #expect(service.state.totalRows == 1_300)
        #expect(service.state.rowTotalIsEstimate)
    }

    @Test("A filtered table leaves the export with no total, so progress counts rows done")
    func filterLeavesNoTotal() async throws {
        let driver = EstimatingDriver()
        driver.estimates = ["orders": 10_000_000, "customers": 300]
        let service = try await run([
            table("orders", scope: PluginExportRowScope(filter: "status = 'open'", rowLimit: 50)),
            table("customers")
        ], on: driver)

        #expect(driver.estimatedTables.isEmpty)
        #expect(service.state.totalRows == 0)
        #expect(!service.state.rowTotalIsEstimate)
    }

    @Test("A table the catalog has no estimate for leaves the total unset")
    func missingEstimateLeavesNoTotal() async throws {
        let service = try await run([table("orders")], on: EstimatingDriver())

        #expect(service.state.totalRows == 0)
        #expect(!service.state.rowTotalIsEstimate)
    }

    @Test("One table without an estimate leaves the whole total unset, so the bar never parks at its ceiling")
    func oneMissingEstimateLeavesNoTotal() async throws {
        let driver = EstimatingDriver()
        driver.estimates = ["orders": 10_000]
        let service = try await run([table("orders"), table("fresh")], on: driver)

        #expect(service.state.totalRows == 0)
        #expect(!service.state.rowTotalIsEstimate)
    }

    @Test("Two tables of one schema take the driver's schema-wide read once, not one read each")
    func bulkReadRunsOncePerSchema() async throws {
        let plugin = BulkMetadataPluginDriver()
        plugin.rowCounts = ["orders": 900, "customers": 100, "unrelated": 5]
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: plugin)
        let service = try await run([table("orders"), table("customers")], on: adapter)

        #expect(plugin.bulkReads == 1)
        #expect(plugin.tableEstimates == 0)
        #expect(!plugin.statements.contains { $0.uppercased().contains("COUNT(") })
        #expect(service.state.totalRows == 1_000)
    }

    @Test("Two tables whose estimates add past Int.max total Int.max instead of crashing")
    func estimatesSaturate() async throws {
        let driver = EstimatingDriver()
        driver.estimates = ["orders": Int.max, "customers": Int.max]
        let service = try await run([table("orders"), table("customers")], on: driver)

        #expect(service.state.totalRows == Int.max)
    }
}
