//
//  SchemaRefreshCommitCostTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Records every catalog read it answers, so a test can count the queries a refresh costs.
///
/// A schema load reads tables, routines, triggers and types concurrently, so the read log and the
/// pause gate are locked rather than isolated: an unlocked append from those reads raced and
/// crashed the test host.
final class CatalogReadCountingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var schemasToReturn: [String] = []
    var tablesBySchema: [String: [TableInfo]] = [:]
    var tablesError: Error?
    var allSchemaTables: [TableInfo]?
    var answersTablesInSchemas = false
    var partitionsByTable: [String: [PartitionInfo]] = [:]

    private let lock = NSLock()
    private var readLog: [String] = []
    private var pauseNextTableFetch = false
    private var tableFetchPausedHandler: (@Sendable () -> Void)?
    private var tableFetchGate: CheckedContinuation<Void, Never>?

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    var reads: [String] {
        lock.withLock { readLog }
    }

    var pausesNextTableFetch: Bool {
        get { lock.withLock { pauseNextTableFetch } }
        set { lock.withLock { pauseNextTableFetch = newValue } }
    }

    var onTableFetchPaused: (@Sendable () -> Void)? {
        get { lock.withLock { tableFetchPausedHandler } }
        set { lock.withLock { tableFetchPausedHandler = newValue } }
    }

    func resumeTableFetch() {
        let gate = lock.withLock {
            let gate = tableFetchGate
            tableFetchGate = nil
            return gate
        }
        gate?.resume()
    }

    func forgetReads() {
        lock.withLock { readLog.removeAll() }
    }

    private func record(_ read: String) {
        lock.withLock { readLog.append(read) }
    }

    private func takeTableFetchPause() -> Bool {
        lock.withLock {
            let pauses = pauseNextTableFetch
            pauseNextTableFetch = false
            return pauses
        }
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        let handler = lock.withLock {
            tableFetchGate = continuation
            return tableFetchPausedHandler
        }
        handler?()
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
        record("schemas")
        return schemasToReturn
    }

    func fetchTables() async throws -> [TableInfo] {
        record("tables")
        return []
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let schema = schema ?? ""
        record("tables:\(schema)")
        if let tablesError { throw tablesError }
        let snapshot = tablesBySchema[schema] ?? []
        if takeTableFetchPause() {
            await withCheckedContinuation { continuation in
                park(continuation)
            }
            try Task.checkCancellation()
        }
        return snapshot
    }

    func fetchTablesInAllSchemas() async throws -> [TableInfo]? {
        record("allSchemaTables")
        return allSchemaTables
    }

    /// Recorded without a colon, so `perSchemaReads` counts only one-schema reads.
    func fetchTables(inSchemas schemas: [String]) async throws -> [TableInfo]? {
        guard answersTablesInSchemas else { return nil }
        record("tablesIn(\(schemas.joined(separator: ",")))")
        if let tablesError { throw tablesError }
        return schemas.flatMap { tablesBySchema[$0] ?? [] }
    }

    func fetchPartitionDetails(table: String, schema: String?) async throws -> [PartitionInfo] {
        record("partitions:\(table)")
        return partitionsByTable[table] ?? []
    }

    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] {
        record(schema.map { "routines:\($0)" } ?? "routines")
        return []
    }

    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo] {
        record(schema.map { "triggers:\($0)" } ?? "triggers")
        return []
    }

    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] {
        record(schema.map { "types:\($0)" } ?? "types")
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

/// PGlite groups by schema and cannot pool, so the tree's reads and the refresh's reads land on the
/// one counting driver. Each test also shows the refresh it measures did read, so an empty log
/// cannot pass for a refresh that never ran.
@MainActor
struct SchemaGroupedRefreshCostTests {
    private let tree = DatabaseTreeMetadataService.shared

    private func connect(schemas: [String]) -> (DatabaseConnection, CatalogReadCountingDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = CatalogReadCountingDriver(connection: connection)
        driver.schemasToReturn = schemas
        for schema in schemas {
            driver.tablesBySchema[schema] = [TableInfo(name: "\(schema)_orders", type: .table, rowCount: nil, schema: schema)]
        }
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await tree.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func refreshService(
        _ driver: CatalogReadCountingDriver,
        connection: DatabaseConnection,
        browsing schema: String?
    ) -> SchemaRefreshService {
        let provider = SingleDriverMetadataProvider(
            driver: driver,
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: schema)
        )
        return SchemaRefreshService(
            schemaService: SchemaService(),
            providerRegistry: SchemaProviderRegistry(metadataDriverProvider: provider),
            metadataDriverProvider: provider,
            databaseManager: .shared
        )
    }

    private func loadTree(_ connection: DatabaseConnection, schemas: [String]) async {
        for schema in schemas {
            await tree.loadTables(connectionId: connection.id, database: connection.database, schema: schema)
        }
    }

    @Test("A schema switch on a schema-grouped engine reads only the new browsed schema")
    func schemaSwitchReadsTheBrowsedSchemaAlone() async {
        let schemas = (0..<20).map { "s\($0)" }
        let (connection, driver) = connect(schemas: schemas)
        await loadTree(connection, schemas: schemas)
        driver.forgetReads()

        await refreshService(driver, connection: connection, browsing: "s5")
            .refreshForSchemaSwitch(connectionId: connection.id)

        #expect(driver.reads.contains("tables"))
        #expect(driver.perSchemaReads.isEmpty)
        #expect(tree.isTablesCurrent(connectionId: connection.id, database: connection.database, schema: "s3"))
        await disconnect(connection)
    }

    @Test("A database switch reads no tree list")
    func databaseSwitchReadsNoTreeList() async {
        let schemas = (0..<5).map { "s\($0)" }
        let (connection, driver) = connect(schemas: schemas)
        await loadTree(connection, schemas: schemas)
        driver.forgetReads()

        await refreshService(driver, connection: connection, browsing: nil)
            .refresh(connection: connection, database: connection.database)

        #expect(driver.reads.contains("tables"))
        #expect(driver.perSchemaReads.isEmpty)
        await disconnect(connection)
    }

    @Test("Discarding staged edits sends no catalog read, while a refresh on the same window does")
    func discardReadsNothing() async throws {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = CatalogReadCountingDriver(connection: connection)
        let provider = SingleDriverMetadataProvider(
            driver: driver,
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: "public")
        )
        let schemaService = SchemaService()
        let refresh = SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: SchemaProviderRegistry(metadataDriverProvider: provider),
            metadataDriverProvider: provider,
            databaseManager: nil
        )
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState(),
            services: Self.services(schemaService: schemaService, schemaRefreshService: refresh)
        )
        var truncates = Set<DatabaseTreeTableRef>()
        var deletes = Set<DatabaseTreeTableRef>()

        coordinator.handleDiscard(pendingTruncates: &truncates, pendingDeletes: &deletes)
        try await Task.sleep(for: .milliseconds(200))
        #expect(driver.reads.isEmpty)

        await coordinator.refreshTables()
        #expect(driver.reads.contains("tables"))
    }

    private static func services(schemaService: SchemaService, schemaRefreshService: SchemaRefreshService) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: live.connectionStorage,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: SchemaProviderRegistry(),
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            tableFolderStorage: live.tableFolderStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: live.groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            credentialProfileStorage: live.credentialProfileStorage,
            licenseManager: live.licenseManager,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            themeEngine: live.themeEngine,
            welcomeRouter: live.welcomeRouter
        )
    }
}
