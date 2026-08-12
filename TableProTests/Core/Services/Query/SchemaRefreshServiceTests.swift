//
//  SchemaRefreshServiceTests.swift
//  TableProTests
//
//  Tests that a schema refresh runs once no matter how many windows request the same
//  container (#1946), that it runs on the scope it is handed rather than on any open tab's
//  scope (#2026), and that two windows browsing different containers of one connection each
//  fill their own cache instead of joining one load (#2088).
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

    private func browseScope(
        _ connection: DatabaseConnection,
        database: String = "testdb",
        schema: String? = nil
    ) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: database, schema: schema)
    }

    @Test("concurrent refreshes for one scope run a single schema load")
    func concurrentRefreshesRunOneLoad() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()
        let scope = browseScope(connection)

        async let first: Void = service.refresh(connection: connection, scope: scope)
        async let second: Void = service.refresh(connection: connection, scope: scope)
        async let third: Void = service.refresh(connection: connection, scope: scope)
        _ = await (first, second, third)

        #expect(driver.fetchTablesCallCount == 1)
        #expect(provider.acquisitionCount == 1)
        #expect(schemaService.state(for: scope) == .loaded(driver.tablesToReturn))
    }

    @Test("the refresh runs on the scope it is handed, never on a resolved one")
    func refreshUsesTheScopeItIsHanded() async throws {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection(database: "saved_default")
        let scope = browseScope(connection, database: "inventory", schema: "dbo")

        await service.refresh(connection: connection, scope: scope)

        #expect(provider.requestedScopes == [scope])
        #expect(provider.requestedWorkloads == [.bulk])
        #expect(schemaService.state(for: scope) == .loaded(driver.tablesToReturn))
    }

    @Test("an empty browse database is server scoped, so the refresh still runs")
    func refreshWithAnEmptyDatabaseIsServerScoped() async throws {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()
        let scope = browseScope(connection, database: "")

        await service.refresh(connection: connection, scope: scope)

        let requested = try #require(provider.requestedScopes.first)
        #expect(requested.isServerScoped)
        #expect(driver.fetchTablesCallCount == 1)
        #expect(schemaService.state(for: scope) == .loaded(driver.tablesToReturn))
    }

    @Test("two windows on different databases of one connection each load their own scope")
    func windowsOnDifferentDatabasesDoNotJoin() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()
        let shop = browseScope(connection, database: "shop")
        let inventory = browseScope(connection, database: "inventory")

        async let first: Void = service.refresh(connection: connection, scope: shop)
        async let second: Void = service.refresh(connection: connection, scope: inventory)
        _ = await (first, second)

        #expect(provider.acquisitionCount == 2)
        #expect(Set(provider.requestedScopes) == [shop, inventory])
        #expect(schemaService.hasLoadedContent(for: shop))
        #expect(schemaService.hasLoadedContent(for: inventory))
    }

    @Test("two windows on different schemas of one database each load their own scope")
    func windowsOnDifferentSchemasDoNotJoin() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let sales = browseScope(connection, schema: "sales")
        let hr = browseScope(connection, schema: "hr")

        async let first: Void = service.refresh(connection: connection, scope: sales)
        async let second: Void = service.refresh(connection: connection, scope: hr)
        _ = await (first, second)

        #expect(provider.acquisitionCount == 2)
        #expect(Set(provider.requestedScopes) == [sales, hr])
    }

    @Test("a refresh pushes the loaded tables into the autocomplete provider")
    func refreshPopulatesTheAutocompleteProvider() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [
            TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil),
            TableInfo(name: "customers", type: .table, rowCount: 0, schema: nil)
        ]
        let provider = FakeScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry()
        let connection = TestFixtures.makeConnection()
        let scope = browseScope(connection)
        let schemaProvider = registry.getOrCreate(for: scope)
        let service = makeService(
            schemaService: SchemaService(),
            provider: provider,
            providerRegistry: registry
        )

        await service.refresh(connection: connection, scope: scope)

        let names = await schemaProvider.getTables().map(\.name)
        #expect(names.sorted() == ["customers", "orders"])
    }

    @Test("syncing a scope with no loaded schema keeps the cached tables instead of clearing them")
    func autocompleteSyncForAnUnloadedScopeKeepsTheCachedTables() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let provider = FakeScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry()
        let connection = TestFixtures.makeConnection()
        let scope = browseScope(connection)
        let schemaProvider = registry.getOrCreate(for: scope)
        let service = makeService(
            schemaService: SchemaService(),
            provider: provider,
            providerRegistry: registry
        )
        await service.refresh(connection: connection, scope: scope)

        await service.syncAutocompleteProvider(scope: browseScope(connection, database: "never_loaded"))

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
        let scope = browseScope(connection)

        await service.refresh(connection: connection, scope: scope)
        await service.refresh(connection: connection, scope: scope)

        #expect(driver.fetchTablesCallCount == 2)
    }

    @Test("refreshes scoped to different databases do not join each other")
    func differentDatabaseScopesDoNotJoin() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()
        let scope = browseScope(connection)

        async let scoped: Void = service.refresh(connection: connection, scope: scope, database: "shop")
        async let unscoped: Void = service.refresh(connection: connection, scope: scope, database: nil)
        _ = await (scoped, unscoped)

        #expect(provider.acquisitionCount == 2)
    }

    @Test("a metadata connection failure surfaces a failed schema state")
    func metadataFailureSurfacesFailedState() async {
        let driver = MockDatabaseDriver()
        let provider = FakeScopedMetadataProvider(driver: driver)
        provider.errorToThrow = DatabaseError.connectionFailed("pool exhausted")
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()
        let scope = browseScope(connection)

        await service.refresh(connection: connection, scope: scope)

        var isFailed = false
        if case .failed = schemaService.state(for: scope) {
            isFailed = true
        }
        #expect(isFailed)
    }
}
