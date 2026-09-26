//
//  ERDiagramLoadFixture.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit

internal actor CatalogLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    internal func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    internal func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

internal struct CatalogReadHold: Sendable {
    internal let reached = CatalogLatch()
    internal let release = CatalogLatch()
}

internal struct CatalogReadFailure: LocalizedError {
    internal var errorDescription: String? { "The catalog could not be read" }
}

internal final class ERDiagramCatalogDriver: DatabaseDriver, @unchecked Sendable {
    internal let connection: DatabaseConnection
    internal var status: ConnectionStatus = .connected
    internal var serverVersion: String? { nil }

    private let columns: [String: [ColumnInfo]]
    private let holds: [CatalogReadHold]
    private let failingReads: Int
    private let lock = NSLock()
    private var reads = 0

    internal init(
        connection: DatabaseConnection,
        columns: [String: [ColumnInfo]],
        holds: [CatalogReadHold],
        failingReads: Int
    ) {
        self.connection = connection
        self.columns = columns
        self.holds = holds
        self.failingReads = failingReads
    }

    internal var catalogReadCount: Int {
        lock.withLock { reads }
    }

    internal func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        let index = lock.withLock {
            defer { reads += 1 }
            return reads
        }
        if index < holds.count {
            await holds[index].reached.open()
            await holds[index].release.wait()
        }
        guard index >= failingReads else { throw CatalogReadFailure() }
        return columns
    }

    internal func fetchAllForeignKeys() async throws -> [String: [ForeignKeyInfo]] { [:] }

    internal func connect() async throws {}
    internal func disconnect() {}
    internal func testConnection() async throws -> Bool { true }
    internal func ping() async throws {}
    internal func cancelQuery() throws {}
    internal func applyQueryTimeout(_ seconds: Int) async throws {}

    internal func execute(query: String) async throws -> QueryResult { Self.emptyResult }
    internal func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        Self.emptyResult
    }

    internal func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        Self.emptyResult
    }

    internal func fetchTables() async throws -> [TableInfo] { [] }
    internal func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    internal func fetchColumns(table: String) async throws -> [ColumnInfo] { columns[table] ?? [] }
    internal func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    internal func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    internal func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    internal func fetchDatabases() async throws -> [String] { [] }
    internal func fetchTableDDL(table: String) async throws -> String { "" }
    internal func fetchViewDefinition(view: String) async throws -> String { "" }

    internal func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database,
            name: database,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: false,
            icon: "cylinder"
        )
    }

    internal func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    internal func beginTransaction() async throws {}
    internal func commitTransaction() async throws {}
    internal func rollbackTransaction() async throws {}

    private static let emptyResult = QueryResult(
        columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil
    )
}

@MainActor
internal struct ERDiagramLoadFixture {
    internal let viewModel: ERDiagramViewModel
    internal let driver: ERDiagramCatalogDriver
    private let databaseManager: DatabaseManager
    private let connectionId: UUID

    internal init(
        tableCount: Int = 3,
        columnsPerTable: Int = 50,
        holds: [CatalogReadHold] = [],
        failingReads: Int = 0
    ) {
        let connection = TestFixtures.makeConnection(database: "main", type: .duckdb)
        let columns = Dictionary(uniqueKeysWithValues: (0 ..< tableCount).map { table in
            let columns = (0 ..< columnsPerTable).map { column in
                TestFixtures.makeColumnInfo(name: "column_\(column)", isPrimaryKey: column == 0)
            }
            return ("table_\(table)", columns)
        })
        let driver = ERDiagramCatalogDriver(
            connection: connection,
            columns: columns,
            holds: holds,
            failingReads: failingReads
        )
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        let databaseManager = DatabaseManager()
        databaseManager.injectSession(session, for: connection.id)

        self.driver = driver
        self.databaseManager = databaseManager
        self.connectionId = connection.id
        self.viewModel = ERDiagramViewModel(
            connectionId: connection.id,
            databaseName: connection.database,
            schemaKey: "\(connection.database).default",
            services: Self.services(with: databaseManager)
        )
    }

    internal func tearDown() {
        databaseManager.removeSession(for: connectionId)
    }

    internal static func exactFit(of scrollView: NSScrollView) -> CGFloat? {
        guard let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView.frame.size
        let content = document.frame.size
        guard content.width > 0, content.height > 0 else { return nil }
        return min(1, clip.width / content.width, clip.height / content.height)
    }

    private static func services(with databaseManager: DatabaseManager) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: live.connectionStorage,
            databaseManager: databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
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
