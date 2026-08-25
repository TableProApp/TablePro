//
//  SchemaRefreshServiceTests.swift
//  TableProTests
//
//  Tests that a connection's schema refresh runs once no matter how many
//  windows request it (#1946), and that it reads the browse scope rather than
//  any open tab's scope (#2026): the sidebar object list is the one thing that
//  genuinely follows the user's database selection.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class FakeScopedMetadataProvider: ScopedMetadataProviding {
    let driver: MockDatabaseDriver
    var acquisitionCount = 0
    var errorToThrow: Error?
    var browseDatabase: String? = "testdb"
    var browseSchema: String?
    private(set) var requestedScopes: [DatabaseScope] = []
    private(set) var requestedWorkloads: [MetadataConnectionPool.Workload] = []

    init(driver: MockDatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        acquisitionCount += 1
        requestedScopes.append(scope)
        requestedWorkloads.append(workload)
        if let errorToThrow {
            throw errorToThrow
        }
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        guard let browseDatabase else { return nil }
        return DatabaseScope(connectionId: connectionId, database: browseDatabase, schema: browseSchema)
    }
}

@MainActor
private final class ScopeRoutingMetadataProvider: ScopedMetadataProviding {
    let drivers: [DatabaseScope: MockDatabaseDriver]
    private(set) var requestedScopes: [DatabaseScope] = []

    init(drivers: [DatabaseScope: MockDatabaseDriver]) {
        self.drivers = drivers
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        guard let driver = drivers[scope] else { throw DatabaseError.notConnected }
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

@Suite("SchemaRefreshService")
@MainActor
struct SchemaRefreshServiceTests {
    private func makeService(
        schemaService: SchemaService,
        provider: FakeScopedMetadataProvider,
        providerRegistry: SchemaProviderRegistry? = nil
    ) -> SchemaRefreshService {
        SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: providerRegistry ?? SchemaProviderRegistry(),
            metadataDriverProvider: provider,
            databaseManager: nil
        )
    }

    @Test("concurrent refreshes for one connection run a single schema load")
    func concurrentRefreshesRunOneLoad() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        async let first: Void = service.refresh(connection: connection)
        async let second: Void = service.refresh(connection: connection)
        async let third: Void = service.refresh(connection: connection)
        _ = await (first, second, third)

        #expect(driver.fetchTablesCallCount == 1)
        #expect(provider.requestedWorkloads.filter { $0 == .bulk }.count == 1)
        #expect(schemaService.state(for: connection.id) == .loaded(driver.tablesToReturn))
    }

    @Test("the sidebar refresh asks for the browse scope, not a tab's scope")
    func refreshAsksForTheBrowseScope() async throws {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        provider.browseDatabase = "inventory"
        provider.browseSchema = "dbo"
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection(database: "saved_default")

        await service.refresh(connection: connection)

        let scope = try #require(provider.requestedScopes.first)
        #expect(scope.connectionId == connection.id)
        #expect(scope.database == "inventory")
        #expect(scope.schema == "dbo")
        #expect(Set(provider.requestedScopes) == [scope])
        #expect(provider.requestedWorkloads.first == .bulk)
    }

    @Test("an empty browse database is server scoped, so the refresh still runs")
    func refreshWithAnEmptyDatabaseIsServerScoped() async throws {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        provider.browseDatabase = ""
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        await service.refresh(connection: connection)

        let scope = try #require(provider.requestedScopes.first)
        #expect(scope.isServerScoped)
        #expect(driver.fetchTablesCallCount == 1)
        #expect(provider.requestedWorkloads.filter { $0 == .bulk }.count == 1)
        #expect(schemaService.state(for: connection.id) == .loaded(driver.tablesToReturn))
    }

    @Test("a connection with no browse scope fails the refresh instead of guessing")
    func refreshWithoutABrowseScopeFails() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        provider.browseDatabase = nil
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        await service.refresh(connection: connection)

        #expect(provider.requestedScopes.isEmpty)
        #expect(driver.fetchTablesCallCount == 0)
        var isFailed = false
        if case .failed = schemaService.state(for: connection.id) {
            isFailed = true
        }
        #expect(isFailed)
    }

    @Test("a refresh pushes the loaded tables into the autocomplete provider")
    func refreshPopulatesTheAutocompleteProvider() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [
            TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil),
            TableInfo(name: "customers", type: .table, rowCount: 0, schema: nil)
        ]
        let provider = FakeScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: provider)
        let connection = TestFixtures.makeConnection()
        let scope = DatabaseScope(connectionId: connection.id, database: "testdb", schema: nil)
        let schemaProvider = registry.getOrCreate(for: scope)
        let service = makeService(
            schemaService: SchemaService(),
            provider: provider,
            providerRegistry: registry
        )

        await service.refresh(connection: connection)

        let names = await schemaProvider.getTables().map(\.name)
        #expect(names.sorted() == ["customers", "orders"])
    }

    @Test("the sync creates the browse scope's provider when no tab has one yet")
    func autocompleteSyncCreatesTheBrowseScopeProvider() async throws {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let provider = FakeScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: provider)
        let connection = TestFixtures.makeConnection()
        let service = makeService(
            schemaService: SchemaService(),
            provider: provider,
            providerRegistry: registry
        )

        await service.refresh(connection: connection)

        let scope = DatabaseScope(connectionId: connection.id, database: "testdb", schema: nil)
        let schemaProvider = try #require(registry.provider(for: scope))
        let names = await schemaProvider.getTables().map(\.name)
        #expect(names == ["orders"])
        #expect(driver.fetchTablesCallCount == 1)
    }

    @Test("no browse scope leaves the autocomplete provider untouched instead of clearing it")
    func autocompleteSyncWithoutABrowseScopeKeepsTheCachedTables() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let provider = FakeScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: provider)
        let connection = TestFixtures.makeConnection()
        let scope = DatabaseScope(connectionId: connection.id, database: "testdb", schema: nil)
        let schemaProvider = registry.getOrCreate(for: scope)
        let service = makeService(
            schemaService: SchemaService(),
            provider: provider,
            providerRegistry: registry
        )
        await service.refresh(connection: connection)

        provider.browseDatabase = nil
        await service.syncAutocompleteProvider(connectionId: connection.id)

        let names = await schemaProvider.getTables().map(\.name)
        #expect(names == ["orders"])
    }

    @Test("a refresh requested after the previous one finished loads again")
    func sequentialRefreshesReload() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        await service.refresh(connection: connection)
        await service.refresh(connection: connection)

        #expect(driver.fetchTablesCallCount == 2)
    }

    @Test("refreshes scoped to different databases do not join each other")
    func differentDatabaseScopesDoNotJoin() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        async let scoped: Void = service.refresh(connection: connection, database: "shop")
        async let unscoped: Void = service.refresh(connection: connection, database: nil)
        _ = await (scoped, unscoped)

        #expect(provider.requestedWorkloads.filter { $0 == .bulk }.count == 2)
    }

    @Test("a metadata connection failure surfaces a failed schema state")
    func metadataFailureSurfacesFailedState() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        provider.errorToThrow = DatabaseError.connectionFailed("pool exhausted")
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        await service.refresh(connection: connection)

        var isFailed = false
        if case .failed = schemaService.state(for: connection.id) {
            isFailed = true
        }
        #expect(isFailed)
    }

    @Test("query tabs on one connection keep schema providers isolated by full scope")
    func queryTabProvidersAreIsolatedByScope() async {
        let connectionId = UUID()
        let salesScope = DatabaseScope(connectionId: connectionId, database: "shop", schema: "sales")
        let auditScope = DatabaseScope(connectionId: connectionId, database: "shop", schema: "audit")
        let salesDriver = MockDatabaseDriver()
        salesDriver.tablesToReturn = [
            TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales")
        ]
        let auditDriver = MockDatabaseDriver()
        auditDriver.tablesToReturn = [
            TableInfo(name: "events", type: .table, rowCount: 0, schema: "audit")
        ]
        let metadataProvider = ScopeRoutingMetadataProvider(
            drivers: [salesScope: salesDriver, auditScope: auditDriver]
        )
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadataProvider)

        let salesProvider = await registry.prepare(for: salesScope)
        let auditProvider = await registry.prepare(for: auditScope)

        let salesNames = await salesProvider.getTables().map(\.name)
        let auditNames = await auditProvider.getTables().map(\.name)
        #expect(salesProvider !== auditProvider)
        #expect(salesNames == ["orders"])
        #expect(auditNames == ["events"])
        #expect(registry.provider(for: salesScope) === salesProvider)
        #expect(registry.provider(for: auditScope) === auditProvider)
        #expect(Set(metadataProvider.requestedScopes) == [salesScope, auditScope])
    }
}
