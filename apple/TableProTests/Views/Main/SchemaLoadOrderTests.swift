import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct SchemaLoadOrderTests {
    @Test("Completion receives the table list without waiting for the database list")
    func completionSyncRunsBeforeTheDatabaseList() async throws {
        let connection = TestFixtures.makeConnection(database: "db", type: .duckdb)
        let driver = MockDatabaseDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        let gate = AsyncGate()
        driver.fetchDatabasesGate = gate
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        let scope = try #require(fixture.coordinator.browseScope)
        let provider = SchemaProviderRegistry.shared.getOrCreate(for: scope)
        defer { SchemaProviderRegistry.shared.clear(for: connection.id) }

        let load = Task { await fixture.coordinator.loadSchema() }
        await gate.arrived(1)

        #expect(await provider.getTables().map(\.name) == ["users"])

        await gate.open()
        await load.value
    }
}
