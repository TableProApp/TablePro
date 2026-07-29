//
//  SchemaRefreshServiceTests.swift
//  TableProTests
//
//  Tests that a connection's schema refresh runs once no matter how many
//  windows request it (#1946).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class FakeMetadataDriverProvider: MetadataDriverProviding {
    let driver: MockDatabaseDriver
    var acquisitionCount = 0
    var errorToThrow: Error?

    init(driver: MockDatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        connectionId: UUID,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        acquisitionCount += 1
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
        provider: FakeMetadataDriverProvider
    ) -> SchemaRefreshService {
        SchemaRefreshService(
            schemaService: schemaService,
            metadataDriverProvider: provider,
            databaseManager: nil
        )
    }

    @Test("concurrent refreshes for one connection run a single schema load")
    func concurrentRefreshesRunOneLoad() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)]
        let provider = FakeMetadataDriverProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        async let first: Void = service.refresh(connection: connection)
        async let second: Void = service.refresh(connection: connection)
        async let third: Void = service.refresh(connection: connection)
        _ = await (first, second, third)

        #expect(driver.fetchTablesCallCount == 1)
        #expect(provider.acquisitionCount == 1)
        #expect(schemaService.state(for: connection.id) == .loaded(driver.tablesToReturn))
    }

    @Test("a refresh requested after the previous one finished loads again")
    func sequentialRefreshesReload() async {
        let driver = MockDatabaseDriver()
        let provider = FakeMetadataDriverProvider(driver: driver)
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
        let provider = FakeMetadataDriverProvider(driver: driver)
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, provider: provider)
        let connection = TestFixtures.makeConnection()

        async let scoped: Void = service.refresh(connection: connection, database: "shop")
        async let unscoped: Void = service.refresh(connection: connection, database: nil)
        _ = await (scoped, unscoped)

        #expect(provider.acquisitionCount == 2)
    }

    @Test("a metadata connection failure surfaces a failed schema state")
    func metadataFailureSurfacesFailedState() async {
        let driver = MockDatabaseDriver()
        let provider = FakeMetadataDriverProvider(driver: driver)
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
}
