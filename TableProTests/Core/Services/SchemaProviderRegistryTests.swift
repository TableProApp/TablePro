//
//  SchemaProviderRegistryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SchemaProviderRegistry")
@MainActor
struct SchemaProviderRegistryTests {
    private func scope(
        _ connectionId: UUID = UUID(),
        database: String = "shop",
        schema: String? = nil
    ) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    @Test("getOrCreate returns new provider for unknown scope")
    func getOrCreateNewProvider() {
        let registry = SchemaProviderRegistry()
        let scoped = scope()
        let provider = registry.getOrCreate(for: scoped)
        #expect(registry.provider(for: scoped) === provider)
    }

    @Test("getOrCreate returns same provider for same scope")
    func getOrCreateReturnsSameProvider() {
        let registry = SchemaProviderRegistry()
        let scoped = scope()
        #expect(registry.getOrCreate(for: scoped) === registry.getOrCreate(for: scoped))
    }

    @Test("provider(for:) returns nil for unknown scope")
    func providerForUnknownReturnsNil() {
        let registry = SchemaProviderRegistry()
        #expect(registry.provider(for: scope()) == nil)
    }

    @Test("scopes on one connection get their own providers")
    func scopesOnOneConnectionAreIndependent() {
        let registry = SchemaProviderRegistry()
        let connectionId = UUID()
        let sales = scope(connectionId, database: "shop", schema: "sales")
        let audit = scope(connectionId, database: "shop", schema: "audit")
        let warehouse = scope(connectionId, database: "warehouse")
        let salesProvider = registry.getOrCreate(for: sales)
        let auditProvider = registry.getOrCreate(for: audit)
        let warehouseProvider = registry.getOrCreate(for: warehouse)
        #expect(salesProvider !== auditProvider)
        #expect(salesProvider !== warehouseProvider)
        #expect(auditProvider !== warehouseProvider)
    }

    @Test("retain increments refcount, prevents purge")
    func retainPreventsRemoval() {
        let registry = SchemaProviderRegistry()
        let scoped = scope()
        _ = registry.getOrCreate(for: scoped)
        registry.retain(for: scoped.connectionId)
        registry.purgeUnused()
        #expect(registry.provider(for: scoped) != nil)
    }

    @Test("release decrements refcount to zero, schedules deferred removal")
    func releaseSchedulesDeferredRemoval() {
        let registry = SchemaProviderRegistry()
        let scoped = scope()
        _ = registry.getOrCreate(for: scoped)
        registry.retain(for: scoped.connectionId)
        registry.release(for: scoped.connectionId)
        #expect(registry.provider(for: scoped) != nil)
    }

    @Test("clear removes every scope of the connection, its refcount and pending removal")
    func clearRemovesEverything() {
        let registry = SchemaProviderRegistry()
        let connectionId = UUID()
        let shop = scope(connectionId, database: "shop")
        let warehouse = scope(connectionId, database: "warehouse")
        _ = registry.getOrCreate(for: shop)
        _ = registry.getOrCreate(for: warehouse)
        registry.retain(for: connectionId)
        registry.clear(for: connectionId)
        #expect(registry.provider(for: shop) == nil)
        #expect(registry.provider(for: warehouse) == nil)
    }

    @Test("purgeUnused removes orphaned providers with zero refcount and no pending task")
    func purgeRemovesOrphans() {
        let registry = SchemaProviderRegistry()
        let scoped = scope()
        _ = registry.getOrCreate(for: scoped)
        registry.purgeUnused()
        #expect(registry.provider(for: scoped) == nil)
    }

    @Test("purgeUnused does not remove providers with pending removal task")
    func purgeKeepsProvidersWithPendingTask() {
        let registry = SchemaProviderRegistry()
        let scoped = scope()
        _ = registry.getOrCreate(for: scoped)
        registry.retain(for: scoped.connectionId)
        registry.release(for: scoped.connectionId)
        registry.purgeUnused()
        #expect(registry.provider(for: scoped) != nil)
    }

    @Test("multiple connections are independent")
    func multipleConnectionsIndependent() {
        let registry = SchemaProviderRegistry()
        let first = scope()
        let second = scope()
        let firstProvider = registry.getOrCreate(for: first)
        let secondProvider = registry.getOrCreate(for: second)
        #expect(firstProvider !== secondProvider)
        registry.clear(for: first.connectionId)
        #expect(registry.provider(for: first) == nil)
        #expect(registry.provider(for: second) != nil)
    }

    // MARK: - Population

    @Test("prepare fills the scope's namespaces so qualified completion works off the browse scope")
    func prepareFillsNamespaces() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        driver.schemasToReturn = ["sales", "audit"]
        let metadata = CountingScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        let target = scope(database: "warehouse", schema: "sales")

        let provider = await registry.prepare(for: target, connection: TestFixtures.makeConnection())

        #expect(await provider.isKnownSchema("sales"))
        #expect(await provider.isKnownSchema("audit"))
        #expect(await provider.getConnectionInfo() != nil)
        #expect(await provider.getTables().map(\.name) == ["orders"])
    }

    @Test("two callers on one scope share a single catalog fetch")
    func concurrentPrepareFetchesOnce() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let metadata = CountingScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        let target = scope()

        async let first = registry.prepare(for: target)
        async let second = registry.prepare(for: target)
        _ = await (first, second)

        #expect(driver.fetchScopedTablesCallCount == 1)
        #expect(driver.fetchSchemasCallCount == 1)
    }

    /// A database with no tables is loaded and empty. Asking the provider whether it holds any
    /// made every activation of that tab refetch its catalog, forever.
    @Test("an empty catalog is fetched once, not on every activation")
    func emptyCatalogIsNotRefetched() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = []
        let metadata = CountingScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        let target = scope()

        await registry.prepare(for: target)
        await registry.prepare(for: target)

        #expect(driver.fetchScopedTablesCallCount == 1)
    }

    @Test("a failed population is retried on the next prepare")
    func failedPopulationIsRetried() async {
        let driver = MockDatabaseDriver()
        driver.fetchTablesError = DatabaseError.notConnected
        let metadata = CountingScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        let target = scope()

        await registry.prepare(for: target)
        driver.fetchTablesError = nil
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let provider = await registry.prepare(for: target)

        #expect(await provider.getTables().map(\.name) == ["orders"])
    }

    /// `SchemaRefreshService` owns the browse scope and fills it with the union of every expanded
    /// schema. Repopulating it here too gave one provider two writers and two different answers.
    @Test("refresh leaves the browse scope to its owner")
    func refreshSkipsTheBrowseScope() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let connectionId = UUID()
        let browse = scope(connectionId, database: "shop")
        let tab = scope(connectionId, database: "warehouse")
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: browse)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        _ = registry.getOrCreate(for: browse)
        _ = registry.getOrCreate(for: tab)

        registry.refresh(request: DataRefreshRequest(connectionId: connectionId))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(metadata.requestedScopes.allSatisfy { $0 == tab })
    }

    /// A tab can sit on the browse scope, whose provider `SchemaRefreshService` fills with the
    /// union of every expanded schema. Refilling it here with one schema's tables would narrow it.
    @Test("prepare leaves a scope its owner has already filled")
    func prepareSkipsAnExternallyPopulatedScope() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let metadata = CountingScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        let target = scope()
        _ = registry.getOrCreate(for: target)
        registry.notePopulatedExternally(scope: target)

        await registry.prepare(for: target)

        #expect(driver.fetchScopedTablesCallCount == 0)
    }

    // MARK: - Eviction

    @Test("eviction drops the scopes nothing renders and keeps the ones it does")
    func evictionKeepsHeldScopes() {
        let connectionId = UUID()
        let browse = scope(connectionId, database: "shop")
        let live = scope(connectionId, database: "warehouse")
        let metadata = CountingScopedMetadataProvider(driver: MockDatabaseDriver(), browseScope: browse)
        let liveScopes = StubLiveScopeProvider(scopes: [live])
        let registry = SchemaProviderRegistry(
            metadataDriverProvider: metadata,
            liveScopeProvider: liveScopes
        )
        _ = registry.getOrCreate(for: browse)
        _ = registry.getOrCreate(for: live)
        let stale = (0..<10).map { scope(connectionId, database: "stale-\($0)") }
        for staleScope in stale {
            _ = registry.getOrCreate(for: staleScope)
        }

        #expect(registry.provider(for: browse) != nil)
        #expect(registry.provider(for: live) != nil)
        #expect(stale.contains { registry.provider(for: $0) == nil })
    }

    @Test("eviction never touches another connection")
    func evictionIsScopedToOneConnection() {
        let connectionId = UUID()
        let other = scope(UUID(), database: "elsewhere")
        let metadata = CountingScopedMetadataProvider(driver: MockDatabaseDriver())
        let registry = SchemaProviderRegistry(
            metadataDriverProvider: metadata,
            liveScopeProvider: StubLiveScopeProvider(scopes: [])
        )
        _ = registry.getOrCreate(for: other)
        for index in 0..<12 {
            _ = registry.getOrCreate(for: scope(connectionId, database: "db-\(index)"))
        }

        #expect(registry.provider(for: other) != nil)
    }
}

@MainActor
private final class CountingScopedMetadataProvider: ScopedMetadataProviding {
    private let driver: MockDatabaseDriver
    private let browse: DatabaseScope?
    private(set) var requestedScopes: [DatabaseScope] = []

    init(driver: MockDatabaseDriver, browseScope: DatabaseScope? = nil) {
        self.driver = driver
        self.browse = browseScope
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { browse }
}

@MainActor
private final class StubLiveScopeProvider: LiveScopeProviding {
    private let scopes: Set<DatabaseScope>

    init(scopes: Set<DatabaseScope>) {
        self.scopes = scopes
    }

    func liveScopes(for connectionId: UUID) -> Set<DatabaseScope> { scopes }
}
