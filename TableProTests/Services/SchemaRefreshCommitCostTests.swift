//
//  SchemaRefreshCommitCostTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Records every catalog read it answers, so a test can count the queries a refresh costs.
final class CatalogReadCountingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var schemasToReturn: [String] = []
    var tablesBySchema: [String: [TableInfo]] = [:]
    var tablesError: Error?
    var allSchemaTables: [TableInfo]?
    private(set) var reads: [String] = []

    var pausesNextTableFetch = false
    var onTableFetchPaused: (@Sendable () -> Void)?
    private var tableFetchGate: CheckedContinuation<Void, Never>?

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func resumeTableFetch() {
        tableFetchGate?.resume()
        tableFetchGate = nil
    }

    func forgetReads() {
        reads.removeAll()
    }

    func reads(ofSchema schema: String) -> [String] {
        reads.filter { $0.hasSuffix(":\(schema)") }
    }

    var perSchemaReads: [String] {
        reads.filter { $0.contains(":") }
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchSchemas() async throws -> [String] {
        reads.append("schemas")
        return schemasToReturn
    }

    func fetchTables() async throws -> [TableInfo] {
        reads.append("tables")
        return []
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let schema = schema ?? ""
        reads.append("tables:\(schema)")
        if let tablesError { throw tablesError }
        let snapshot = tablesBySchema[schema] ?? []
        if pausesNextTableFetch {
            pausesNextTableFetch = false
            await withCheckedContinuation { continuation in
                tableFetchGate = continuation
                onTableFetchPaused?()
            }
            try Task.checkCancellation()
        }
        return snapshot
    }

    func fetchTablesInAllSchemas() async throws -> [TableInfo]? {
        reads.append("allSchemaTables")
        return allSchemaTables
    }

    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] {
        reads.append(schema.map { "routines:\($0)" } ?? "routines")
        return []
    }

    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo] {
        reads.append(schema.map { "triggers:\($0)" } ?? "triggers")
        return []
    }

    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] {
        reads.append(schema.map { "types:\($0)" } ?? "types")
        return []
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchViewDefinition(view: String) async throws -> String { "" }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
            avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
            collation: nil, createTime: nil, updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] { [] }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }

    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@MainActor
final class SingleDriverMetadataProvider: ScopedMetadataProviding {
    let driver: CatalogReadCountingDriver
    let scope: DatabaseScope

    init(driver: CatalogReadCountingDriver, scope: DatabaseScope) {
        self.driver = driver
        self.scope = scope
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        scope
    }
}

/// Oracle lists its objects one schema at a time, and a sidebar search used to leave every schema
/// of the database loaded.
@Suite("SchemaRefreshService commit cost")
@MainActor
struct SchemaRefreshCommitCostTests {
    private let connectionId = UUID()

    private var connection: DatabaseConnection {
        TestFixtures.makeConnection(id: connectionId, type: .oracle)
    }

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "ORCL", schema: "S0")
    }

    private func driver(schemas: [String]) -> CatalogReadCountingDriver {
        let driver = CatalogReadCountingDriver(connection: connection)
        driver.schemasToReturn = schemas
        for schema in schemas {
            driver.tablesBySchema[schema] = [TableInfo(name: "\(schema)_ORDERS", type: .table, rowCount: nil, schema: schema)]
        }
        return driver
    }

    /// The measured case: a search on the old sidebar left every schema of the database loaded, and
    /// each COMMIT then read all of them again, one after another.
    @Test("A COMMIT on a connection with 200 loaded schemas reads the browsed schema alone")
    func commitReadsTheBrowsedSchemaAlone() async {
        let schemas = (0..<200).map { "S\($0)" }
        let driver = driver(schemas: schemas)
        let schemaService = SchemaService()
        let refreshService = SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: SchemaProviderRegistry(),
            metadataDriverProvider: SingleDriverMetadataProvider(driver: driver, scope: scope),
            databaseManager: nil
        )
        await refreshService.refresh(connection: connection)
        for schema in schemas {
            await schemaService.loadSchemaObjects(schema: schema, in: scope, driver: driver)
        }
        driver.forgetReads()

        await refreshService.refreshAfterWrite(connection: connection)

        #expect(Set(driver.perSchemaReads) == ["tables:S0", "routines:S0"])
        #expect(driver.perSchemaReads.count == 2)
        #expect(schemaService.tables(for: connectionId, schema: "S199").map(\.name) == ["S199_ORDERS"])
    }
}
