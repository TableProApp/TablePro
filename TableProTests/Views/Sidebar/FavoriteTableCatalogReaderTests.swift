//
//  FavoriteTableCatalogReaderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CatalogStubDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var schemas: [String] = []
    var browsedTables: [TableInfo] = []
    var tablesBySchema: [String: [TableInfo]] = [:]

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult { .empty }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { .empty }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult { .empty }

    func fetchSchemas() async throws -> [String] { schemas }
    func fetchTables() async throws -> [TableInfo] { browsedTables }
    func fetchTables(schema: String?) async throws -> [TableInfo] { tablesBySchema[schema ?? ""] ?? [] }

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
struct FavoriteTableCatalogReaderTests {
    private let connectionId = UUID()

    private func table(_ name: String, schema: String?, type: TableInfo.TableType = .table) -> TableInfo {
        TableInfo(name: name, type: type, rowCount: nil, schema: schema)
    }

    private func entry(_ name: String, schema: String?, database: String?) -> FavoriteTablesStorage.FavoriteEntry {
        FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
    }

    private func reader(
        _ service: SchemaService,
        type: DatabaseType,
        isConnected: Bool = false
    ) -> FavoriteTableCatalogReader {
        FavoriteTableCatalogReader(
            connectionId: connectionId,
            grouping: PluginManager.shared.databaseGroupingStrategy(for: type),
            isConnected: isConnected,
            schemaService: service
        )
    }

    private func scope(database: String?, schema: String?, type: DatabaseType) -> FavoriteTableBrowseScope {
        FavoriteTableBrowseScope(
            database: database,
            schema: schema,
            listsTablesPerSchema: DatabaseTreeMetadataService.listsTablesPerSchema(
                PluginManager.shared.databaseGroupingStrategy(for: type)
            )
        )
    }

    /// Oracle-class engines load no flat list at all: every table lives in its own schema's list.
    private func hierarchicalService(loadedDatabase: String) async -> SchemaService {
        let service = SchemaService()
        let connection = TestFixtures.makeConnection(id: connectionId, database: loadedDatabase, type: .bigQuery)
        let driver = CatalogStubDriver(connection: connection)
        driver.schemas = ["HR", "SALES", "FINANCE"]
        driver.tablesBySchema = [
            "SALES": [table("ORDERS", schema: "SALES", type: .view), table("CUSTOMERS", schema: "SALES")]
        ]
        let loadedScope = DatabaseScope(connectionId: connectionId, database: loadedDatabase, schema: "HR")
        await service.load(connectionId: connectionId, driver: driver, connection: connection, scope: loadedScope)
        await service.loadSchemaObjects(schema: "SALES", in: loadedScope, driver: driver)
        return service
    }

    @Test("A hierarchical engine lists a favorite from the schema's own list, with an empty flat list")
    func hierarchicalFavoriteIsListed() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")
        #expect(service.tables(for: connectionId).isEmpty)

        let read = reader(service, type: .bigQuery).read(
            [entry("ORDERS", schema: "SALES", database: "PROD")],
            scope: scope(database: "PROD", schema: "HR", type: .bigQuery),
            search: SidebarSearch("")
        )

        #expect(read.resolution.rows.map(\.entry.name) == ["ORDERS"])
        #expect(read.resolution.rows.first?.isVerified == true)
        #expect(read.resolution.rows.first?.knownType == .view)
        #expect(read.resolution.rows.first?.otherSchema == "SALES")
    }

    @Test("A hierarchical favorite that its schema's current list lacks is hidden")
    func hierarchicalMissingFavoriteIsHidden() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")

        let read = reader(service, type: .bigQuery).read(
            [entry("REFUNDS", schema: "SALES", database: "PROD")],
            scope: scope(database: "PROD", schema: "HR", type: .bigQuery),
            search: SidebarSearch("")
        )

        #expect(read.resolution.rows.isEmpty)
        #expect(read.resolution.missingCount == 1)
    }

    @Test("A favorite in a schema nothing loaded is asked for, and one in a loaded schema is not")
    func unloadedSchemaIsRequested() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")

        let read = reader(service, type: .bigQuery, isConnected: true).read(
            [entry("ORDERS", schema: "SALES", database: "PROD"), entry("LEDGER", schema: "FINANCE", database: "PROD")],
            scope: scope(database: "PROD", schema: "HR", type: .bigQuery),
            search: SidebarSearch("")
        )

        #expect(read.loadRequest == FavoriteTableLoadRequest(database: "PROD", schemas: ["FINANCE"]))
        #expect(read.resolution.rows.map(\.entry.name) == ["LEDGER", "ORDERS"])
    }

    @Test("Nothing is asked for while the session is not connected")
    func disconnectedRequestsNothing() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")

        let read = reader(service, type: .bigQuery, isConnected: false).read(
            [entry("LEDGER", schema: "FINANCE", database: "PROD")],
            scope: scope(database: "PROD", schema: "HR", type: .bigQuery),
            search: SidebarSearch("")
        )

        #expect(read.loadRequest == .none)
    }

    /// While a database switch settles, the schema service still answers for the database being
    /// left. Read as the browsed one, its SALES list would vouch for, or hide, tables it never saw.
    @Test("The schema service's lists are refused while they describe another database")
    func databaseSwitchInFlightIsRefused() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")

        let read = reader(service, type: .bigQuery, isConnected: true).read(
            [entry("ORDERS", schema: "SALES", database: "STAGING"), entry("REFUNDS", schema: "SALES", database: "STAGING")],
            scope: scope(database: "STAGING", schema: "HR", type: .bigQuery),
            search: SidebarSearch("")
        )

        #expect(read.resolution.rows.map(\.entry.name) == ["ORDERS", "REFUNDS"])
        #expect(read.resolution.rows.allSatisfy { !$0.isVerified && $0.knownType == nil })
        #expect(read.resolution.missingCount == 0)
        #expect(read.loadRequest == .none)
    }

    @Test("Opening a listed favorite carries its kind, and a missing one opens nothing")
    func openingUsesTheListedKind() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")
        let opener = reader(service, type: .bigQuery)
        let browsing = scope(database: "PROD", schema: "HR", type: .bigQuery)

        let listed = await opener.rowForOpening(entry("ORDERS", schema: "SALES", database: "PROD"), scope: browsing)
        let missing = await opener.rowForOpening(entry("REFUNDS", schema: "SALES", database: "PROD"), scope: browsing)

        #expect(listed?.knownType == .view)
        #expect(listed?.opensReadOnly == true)
        #expect(missing == nil)
    }

    @Test("A favorite whose kind cannot be learned opens read-only")
    func unlearnableKindOpensReadOnly() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")

        let row = await reader(service, type: .bigQuery, isConnected: false).rowForOpening(
            entry("LEDGER", schema: "FINANCE", database: "PROD"),
            scope: scope(database: "PROD", schema: "HR", type: .bigQuery)
        )

        #expect(row?.knownType == nil)
        #expect(row?.opensReadOnly == true)
    }

    @Test("A kind only a stale list vouches for never opens editable")
    func staleKindOpensReadOnly() async {
        let service = await hierarchicalService(loadedDatabase: "PROD")
        service.markLoadedSchemaObjectsStale(connectionId: connectionId)

        let row = await reader(service, type: .bigQuery, isConnected: false).rowForOpening(
            entry("CUSTOMERS", schema: "SALES", database: "PROD"),
            scope: scope(database: "PROD", schema: "HR", type: .bigQuery)
        )

        #expect(row?.knownType == .table)
        #expect(row?.isVerified == false)
        #expect(row?.opensReadOnly == true)
    }

    @Test("A schema-grouped engine's flat list vouches for the browsed schema only")
    func bySchemaFlatListCoversTheBrowsedSchema() async {
        let service = SchemaService()
        let connection = TestFixtures.makeConnection(id: connectionId, database: "shop", type: .postgresql)
        let driver = CatalogStubDriver(connection: connection)
        driver.browsedTables = [table("users", schema: "public")]
        await service.load(
            connectionId: connectionId,
            driver: driver,
            connection: connection,
            scope: DatabaseScope(connectionId: connectionId, database: "shop", schema: "public")
        )

        let read = reader(service, type: .postgresql, isConnected: true).read(
            [
                entry("users", schema: "public", database: "shop"),
                entry("sessions", schema: "public", database: "shop"),
                entry("orders", schema: "sales", database: "shop")
            ],
            scope: scope(database: "shop", schema: "public", type: .postgresql),
            search: SidebarSearch("")
        )

        #expect(read.resolution.rows.map(\.entry.name) == ["orders", "users"])
        #expect(read.resolution.rows.first { $0.entry.name == "users" }?.isVerified == true)
        #expect(read.resolution.rows.first { $0.entry.name == "orders" }?.isVerified == false)
        #expect(read.resolution.missingCount == 1)
        #expect(read.loadRequest == FavoriteTableLoadRequest(database: "shop", schemas: ["sales"]))
    }

    @Test("A flat engine's table list decides for the whole database and asks for nothing")
    func flatEngineListDecides() async {
        let service = SchemaService()
        let connection = TestFixtures.makeConnection(id: connectionId, database: "shop", type: .mysql)
        let driver = CatalogStubDriver(connection: connection)
        driver.browsedTables = [table("users", schema: nil)]
        await service.load(
            connectionId: connectionId,
            driver: driver,
            connection: connection,
            scope: DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
        )

        let read = reader(service, type: .mysql, isConnected: true).read(
            [entry("users", schema: nil, database: "shop"), entry("gone", schema: nil, database: "shop")],
            scope: scope(database: "shop", schema: nil, type: .mysql),
            search: SidebarSearch("")
        )

        #expect(read.resolution.rows.map(\.entry.name) == ["users"])
        #expect(read.resolution.missingCount == 1)
        #expect(read.loadRequest == .none)
    }
}
