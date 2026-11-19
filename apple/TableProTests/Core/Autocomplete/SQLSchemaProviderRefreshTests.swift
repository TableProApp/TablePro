import Foundation
@testable import TablePro
import TableProAutocomplete
import TableProTestSupport
import Testing

struct SQLSchemaProviderRefreshTests {
    private static let users = TestFixtures.makeTableInfo(name: "users")

    private static func column(_ name: String) -> ColumnInfo {
        TestFixtures.makeColumnInfo(name: name)
    }

    private static func names(_ provider: SQLSchemaProvider, _ table: String = "users") async -> [String] {
        await provider.getColumns(for: table).map(\.name)
    }

    private static func loaded(_ driver: MockDatabaseDriver, tables: [TableInfo]? = nil) async -> SQLSchemaProvider {
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase("db", tables: tables ?? [users], driver: driver)
        return provider
    }

    @Test("A refresh keeps the old columns for completion before a table, and a named table waits for its fresh read")
    func refreshKeepsColumnsUntilTheReadLands() async throws {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": [Self.column("id")]]
        let provider = await Self.loaded(driver)
        #expect(await Self.names(provider) == ["id"])

        driver.columnsToReturn = ["users": [Self.column("id"), Self.column("email")]]
        let gate = AsyncGate()
        driver.fetchColumnsGate = gate
        await provider.resetForDatabase("db", tables: [Self.users], driver: driver)

        #expect(await provider.allColumnsFromCachedTables().map(\.label) == ["id"])
        let named = Task { await Self.names(provider) }
        await gate.arrived(1)
        #expect(await provider.allColumnsFromCachedTables().map(\.label) == ["id"])

        await gate.open()
        #expect(await named.value == ["id", "email"])
        #expect(await provider.allColumnsFromCachedTables().map(\.label) == ["id", "email"])
        #expect(driver.fetchColumnsCallCount == 2)
    }

    @Test("A refresh read that fails keeps the columns and is not sent again for each keystroke")
    func failedRefreshKeepsColumns() async throws {
        let reads = ReadCounter()
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in
                guard await reads.next() == 1 else { throw DatabaseError.queryFailed("connection lost") }
                return [Self.column("id")]
            },
            fetchAllColumns: { [:] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        let driver = MockDatabaseDriver()
        await provider.resetForDatabase("db", tables: [Self.users], driver: driver)
        #expect(await Self.names(provider) == ["id"])

        await provider.resetForDatabase("db", tables: [Self.users], driver: driver)
        #expect(await Self.names(provider) == ["id"])
        try await waitUntil { await reads.count == 2 }

        #expect(await Self.names(provider) == ["id"])
        #expect(await Self.names(provider) == ["id"])
        #expect(await reads.count == 2)
    }

    @Test("A table the refreshed list no longer names loses its columns")
    func droppedTableLosesItsColumns() async {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": [Self.column("id")]]
        let provider = await Self.loaded(driver)
        _ = await Self.names(provider)

        driver.columnsToReturn = [:]
        await provider.resetForDatabase("db", tables: [TestFixtures.makeTableInfo(name: "orders")], driver: driver)

        #expect(await Self.names(provider).isEmpty)
    }

    @Test("Dropping the last table of the scope drops its columns")
    func emptiedScopeDropsColumns() async {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": [Self.column("id")]]
        let provider = await Self.loaded(driver)
        _ = await Self.names(provider)

        driver.columnsToReturn = [:]
        await provider.resetForDatabase("db", tables: [], driver: driver)

        #expect(await provider.allColumnsFromCachedTables().isEmpty)
        #expect(await Self.names(provider).isEmpty)
    }

    @Test("A bulk read replaces an entry whose own re-read failed")
    func bulkReadReplacesAFailedReread() async throws {
        let reads = ReadCounter()
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in
                guard await reads.next() == 1 else { throw DatabaseError.queryFailed("connection lost") }
                return [Self.column("id")]
            },
            fetchAllColumns: { ["users": [Self.column("id"), Self.column("email")]] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        let driver = MockDatabaseDriver()
        await provider.resetForDatabase("db", tables: [Self.users], driver: driver)
        #expect(await Self.names(provider) == ["id"])
        await provider.requestColumnPreload()
        await provider.waitForEagerColumnLoad()

        await provider.resetForDatabase("db", tables: [Self.users], driver: driver)
        #expect(await Self.names(provider) == ["id"])
        try await waitUntil { await reads.count == 2 }
        await provider.renewColumnPreload()
        await provider.waitForEagerColumnLoad()

        #expect(await Self.names(provider) == ["id", "email"])
    }

    @Test("A table of a schema the refreshed list no longer names loses its columns")
    func unlistedSchemaLosesItsColumns() async {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["orders": [Self.column("id")]]
        let listed = TestFixtures.makeTableInfo(name: "users", schema: "public")
        let orders = TestFixtures.makeTableInfo(name: "orders", schema: "sales")
        let provider = await Self.loaded(driver, tables: [listed, orders])
        #expect(await provider.getColumns(for: "orders", schema: "sales").map(\.name) == ["id"])

        driver.columnsToReturn = [:]
        await provider.resetForDatabase("db", tables: [listed], driver: driver)

        #expect(await provider.allColumnsFromCachedTables().isEmpty)
        #expect(await provider.getColumns(for: "orders", schema: "sales").isEmpty)
    }

    @Test("Moving to another database drops the columns at once")
    func anotherDatabaseDropsColumns() async {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": [Self.column("id")]]
        let provider = await Self.loaded(driver)
        _ = await Self.names(provider)

        driver.columnsToReturn = ["users": [Self.column("other")]]
        await provider.resetForDatabase("other", tables: [Self.users], driver: driver)

        #expect(await Self.names(provider) == ["other"])
    }

    @Test("A bulk read replaces every stale entry of its schema, and a table it no longer returns is gone")
    func bulkReadReplacesStaleEntries() async {
        let driver = MockDatabaseDriver()
        driver.allColumnsToReturn = ["users": [Self.column("id")], "orders": [Self.column("total")]]
        let tables = [Self.users, TestFixtures.makeTableInfo(name: "orders")]
        let provider = await Self.loaded(driver, tables: tables)
        await provider.requestColumnPreload()
        await provider.waitForEagerColumnLoad()
        #expect(await Self.names(provider) == ["id"])

        driver.allColumnsToReturn = ["users": [Self.column("id"), Self.column("email")]]
        await provider.resetForDatabase("db", tables: tables, driver: driver)
        await provider.renewColumnPreload()
        await provider.waitForEagerColumnLoad()

        #expect(await Self.names(provider) == ["id", "email"])
        #expect(await Self.names(provider, "orders").isEmpty)
    }
}

private actor ReadCounter {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
