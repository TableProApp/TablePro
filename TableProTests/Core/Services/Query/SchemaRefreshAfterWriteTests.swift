//
//  SchemaRefreshAfterWriteTests.swift
//  TableProTests
//
//  A refresh asked for after a write must answer with the catalog after the write. Joining a
//  fetch that began before it handed the sidebar the pre-write table list (#2819).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class DirectMetadataProvider: ScopedMetadataProviding {
    let driver: MockDatabaseDriver

    init(driver: MockDatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        DatabaseScope(connectionId: connectionId, database: "testdb", schema: nil)
    }
}

@Suite("SchemaRefreshService after a write", .serialized)
@MainActor
struct SchemaRefreshAfterWriteTests {
    private let orders = TableInfo(name: "orders", type: .table, rowCount: 0, schema: nil)
    private let probe = TableInfo(name: "sidebar_probe", type: .table, rowCount: 0, schema: nil)

    private func makeService(schemaService: SchemaService, driver: MockDatabaseDriver) -> SchemaRefreshService {
        let provider = DirectMetadataProvider(driver: driver)
        return SchemaRefreshService(
            schemaService: schemaService,
            providerRegistry: SchemaProviderRegistry(metadataDriverProvider: provider),
            metadataDriverProvider: provider,
            databaseManager: nil
        )
    }

    @Test("a refresh after a write does not adopt the fetch that started before it")
    func postWriteRefreshSupersedesPreWriteFetch() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [orders, probe]
        driver.pausesNextFetchTables = true
        let paused = AsyncStream.makeStream(of: Void.self)
        driver.onFetchTablesPaused = { paused.continuation.yield() }
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, driver: driver)
        let connection = TestFixtures.makeConnection()

        let preWrite = Task { await service.refresh(connection: connection) }
        for await _ in paused.stream { break }

        driver.tablesToReturn = [orders]
        await service.refreshAfterWrite(connection: connection)

        #expect(schemaService.state(for: connection.id) == .loaded([orders]))
        #expect(driver.fetchTablesCallCount == 2)

        driver.resumeFetchTables()
        await preWrite.value

        #expect(
            schemaService.state(for: connection.id) == .loaded([orders]),
            "The pre-write fetch finishing last must not put the dropped table back"
        )
    }

    @Test("a plain refresh asked for during a post-write refresh joins it")
    func plainRefreshJoinsThePostWriteRefresh() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [orders]
        driver.pausesNextFetchTables = true
        let paused = AsyncStream.makeStream(of: Void.self)
        driver.onFetchTablesPaused = { paused.continuation.yield() }
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, driver: driver)
        let connection = TestFixtures.makeConnection()

        let postWrite = Task { await service.refreshAfterWrite(connection: connection) }
        for await _ in paused.stream { break }
        let joined = Task { await service.refresh(connection: connection) }
        await Task.yield()
        driver.resumeFetchTables()
        await postWrite.value
        await joined.value

        #expect(driver.fetchTablesCallCount == 1)
        #expect(schemaService.state(for: connection.id) == .loaded([orders]))
    }

    @Test("a refresh after the post-write one finished loads again")
    func laterRefreshIsNotLeftJoinedToAFinishedEntry() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [orders]
        let schemaService = SchemaService()
        let service = makeService(schemaService: schemaService, driver: driver)
        let connection = TestFixtures.makeConnection()

        await service.refreshAfterWrite(connection: connection)
        await service.refresh(connection: connection)

        #expect(driver.fetchTablesCallCount == 2)
    }
}
