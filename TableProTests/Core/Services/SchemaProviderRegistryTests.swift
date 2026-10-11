//
//  SchemaProviderRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

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
        let first = registry.getOrCreate(for: scoped)
        #expect(registry.getOrCreate(for: scoped) === first)
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
    @Test("a catalog change leaves the browse scope to its owner")
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

        await registry.refreshCatalog(for: CatalogChange(connectionId: connectionId, kinds: .tables))

        #expect(!metadata.requestedScopes.isEmpty)
        #expect(metadata.requestedScopes.allSatisfy { $0 == tab })
    }

    @Test("a catalog change reaches only providers in the database it names")
    func catalogChangeReachesItsDatabaseOnly() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let connectionId = UUID()
        let browse = scope(connectionId, database: "shop")
        let warehouse = scope(connectionId, database: "warehouse")
        let archive = scope(connectionId, database: "archive")
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: browse)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        _ = registry.getOrCreate(for: warehouse)
        _ = registry.getOrCreate(for: archive)

        await registry.refreshCatalog(
            for: CatalogChange(connectionId: connectionId, database: "warehouse", kinds: .tables)
        )

        #expect(metadata.requestedScopes.contains(warehouse))
        #expect(!metadata.requestedScopes.contains(archive))
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

    // MARK: - Column preload

    @Test("prepare on the browse scope leaves its table list to its owner")
    func prepareLeavesTheBrowseScopeToItsOwner() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let target = scope()
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: target)
        let registry = SchemaProviderRegistry(
            metadataDriverProvider: metadata,
            browseCatalogState: { _ in .loaded([]) }
        )

        let provider = await registry.prepare(for: target)

        #expect(driver.fetchScopedTablesCallCount == 0)
        #expect(await provider.getTables().isEmpty)
    }

    @Test("prepare fills the browse scope itself when its catalog failed to load")
    func prepareFillsTheBrowseScopeAfterAFailedLoad() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let target = scope()
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: target)
        let registry = SchemaProviderRegistry(
            metadataDriverProvider: metadata,
            browseCatalogState: { _ in .failed("connection lost") }
        )

        let provider = await registry.prepare(for: target)

        #expect(driver.fetchScopedTablesCallCount == 1)
        #expect(await provider.getTables().map(\.name) == ["orders"])
    }

    @Test("an editor on the browse scope gets one column read once its owner fills it")
    func browseEditorReadsColumnsOnceTheOwnerFillsIt() async {
        let driver = MockDatabaseDriver()
        let target = scope()
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: target)
        let registry = SchemaProviderRegistry(
            metadataDriverProvider: metadata,
            browseCatalogState: { _ in .loading }
        )

        let provider = await registry.prepare(for: target)
        await provider.waitForEagerColumnLoad()
        #expect(driver.fetchAllColumnsCallCount == 0)

        await provider.resetForDatabase("shop", tables: [TestFixtures.makeTableInfo(name: "orders")], driver: driver)
        await registry.notePopulatedExternally(scope: target)?.value
        await provider.waitForEagerColumnLoad()

        #expect(driver.fetchScopedTablesCallCount == 0)
        #expect(driver.fetchAllColumnsCallCount == 1)
    }

    @Test("a tab restored before its browse catalog loads leaves the table list to the owner and reads columns once")
    func restoredBrowseEditorBeforeLoadReadsColumnsOnce() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let target = scope()
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: target)
        let registry = SchemaProviderRegistry(
            metadataDriverProvider: metadata,
            browseCatalogState: { _ in .idle }
        )

        let provider = await registry.prepare(for: target)
        await provider.waitForEagerColumnLoad()
        await provider.resetForDatabase("shop", tables: [TestFixtures.makeTableInfo(name: "orders")], driver: driver)
        await registry.notePopulatedExternally(scope: target)?.value
        await provider.waitForEagerColumnLoad()

        #expect(driver.fetchScopedTablesCallCount == 0)
        #expect(driver.fetchAllColumnsCallCount == 1)
    }

    @Test("prepare reads a tab scope's columns once across repeated activations")
    func repeatedPrepareReadsColumnsOnce() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let metadata = CountingScopedMetadataProvider(driver: driver)
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata)
        let target = scope(database: "warehouse")

        for _ in 0 ..< 3 {
            let provider = await registry.prepare(for: target)
            await provider.waitForEagerColumnLoad()
        }

        #expect(driver.fetchScopedTablesCallCount == 1)
        #expect(driver.fetchAllColumnsCallCount == 1)
    }

    @Test("a catalog change reads no columns for a scope no editor asked about")
    func catalogChangeReadsNoColumnsWithoutAnEditor() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        let connectionId = UUID()
        let tab = scope(connectionId, database: "warehouse")
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: scope(connectionId))
        let liveScopes = StubLiveScopeProvider(scopes: [tab])
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata, liveScopeProvider: liveScopes)
        let provider = registry.getOrCreate(for: tab)

        await registry.refreshCatalog(for: CatalogChange(connectionId: connectionId, kinds: .tables))
        await provider.waitForEagerColumnLoad()

        #expect(driver.fetchScopedTablesCallCount == 1)
        #expect(driver.fetchAllColumnsCallCount == 0)
        withExtendedLifetime(liveScopes) {}
    }

    @Test("a catalog change re-reads a rendered editor's columns once and keeps them cached")
    func catalogChangeRenewsARenderedEditorsColumns() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        driver.allColumnsToReturn = ["orders": [TestFixtures.makeColumnInfo(name: "id")]]
        let connectionId = UUID()
        let tab = scope(connectionId, database: "warehouse")
        let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: scope(connectionId))
        let liveScopes = StubLiveScopeProvider(scopes: [tab])
        let registry = SchemaProviderRegistry(metadataDriverProvider: metadata, liveScopeProvider: liveScopes)
        let provider = await registry.prepare(for: tab)
        await provider.waitForEagerColumnLoad()

        await registry.refreshCatalog(for: CatalogChange(connectionId: connectionId, kinds: .tables))
        await provider.waitForEagerColumnLoad()

        #expect(driver.fetchScopedTablesCallCount == 2)
        #expect(driver.fetchAllColumnsCallCount == 2)
        _ = await provider.getColumns(for: "orders")
        #expect(driver.fetchColumnsCallCount == 0)
        withExtendedLifetime(liveScopes) {}
    }

    @Test("the owner's refill re-reads the browse editor's columns only while something renders it")
    func ownerRefillRenewsOnlyARenderedBrowseScope() async {
        for rendered in [true, false] {
            let driver = MockDatabaseDriver()
            driver.allColumnsToReturn = ["orders": [TestFixtures.makeColumnInfo(name: "id")]]
            let target = scope()
            let metadata = CountingScopedMetadataProvider(driver: driver, browseScope: target)
            let liveScopes = StubLiveScopeProvider(scopes: rendered ? [target] : [])
            let registry = SchemaProviderRegistry(
                metadataDriverProvider: metadata,
                liveScopeProvider: liveScopes,
                browseCatalogState: { _ in .loaded([]) }
            )
            let tables = [TestFixtures.makeTableInfo(name: "orders")]
            let provider = await registry.prepare(for: target)
            await provider.resetForDatabase("shop", tables: tables, driver: driver)
            await registry.notePopulatedExternally(scope: target)?.value
            await provider.waitForEagerColumnLoad()
            #expect(driver.fetchAllColumnsCallCount == 1)

            await provider.resetForDatabase("shop", tables: tables, driver: driver)
            await registry.notePopulatedExternally(scope: target)?.value
            await provider.waitForEagerColumnLoad()

            #expect(driver.fetchAllColumnsCallCount == (rendered ? 2 : 1), "rendered: \(rendered)")
            withExtendedLifetime(liveScopes) {}
        }
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
