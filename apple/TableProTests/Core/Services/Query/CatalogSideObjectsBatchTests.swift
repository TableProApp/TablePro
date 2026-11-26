//
//  CatalogSideObjectsBatchTests.swift
//  TableProTests
//
//  After the table list, each side kind took a lease and a round trip of its own, one after another:
//  schemas, routines, triggers, types and server objects cost five round trips on PostgreSQL where one
//  Query answers them all (#4543).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct RoutinesRefused: Error {}

private final class BatchingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [PluginCatalogSideRequest] = []
    private let failsRoutines: Bool

    init(failsRoutines: Bool = false) {
        self.failsRoutines = failsRoutines
    }

    var requests: [PluginCatalogSideRequest] { lock.withLock { asked } }

    var supportsSchemas: Bool { true }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        [PluginTableInfo(name: "orders", comment: nil, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil)]
    }

    func fetchCatalogSideObjects(_ request: PluginCatalogSideRequest) async -> PluginCatalogSideObjects {
        lock.withLock { asked.append(request) }
        let routines: Result<[PluginRoutineInfo], any Error> = failsRoutines
            ? .failure(RoutinesRefused())
            : .success([
                PluginRoutineInfo(name: "zeta", kind: .function),
                PluginRoutineInfo(name: "alpha", kind: .function)
            ])
        return PluginCatalogSideObjects(
            schemas: request.schemas ? .success(["public", "sales"]) : nil,
            routines: request.routines ? routines : nil,
            triggers: request.triggers ? .success([]) : nil
        )
    }
}

@MainActor
private final class OneDriverProvider: ScopedMetadataProviding {
    let driver: DatabaseDriver
    private(set) var leases = 0

    init(driver: DatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        leases += 1
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

@MainActor
struct CatalogSideObjectsBatchTests {
    private let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "shop", schema: "public")
    }

    private func load(_ plugin: BatchingDriver) async throws -> (SchemaService, OneDriverProvider) {
        let service = SchemaService()
        let provider = OneDriverProvider(driver: PluginDriverAdapter(connection: connection, pluginDriver: plugin))
        try await service.load(connectionId: connection.id, connection: connection, scope: scope, leasingFrom: provider)
        return (service, provider)
    }

    @Test("A load asks the driver for every side kind in one call, on one lease after the tables")
    func sideKindsAreOneCall() async throws {
        let plugin = BatchingDriver()

        let (service, provider) = try await load(plugin)

        #expect(provider.leases == 2)
        #expect(plugin.requests.count == 1)
        #expect(plugin.requests.first?.schemas == true)
        #expect(plugin.requests.first?.routines == true)
        #expect(plugin.requests.first?.schema == "public")
        #expect(service.schemas(for: connection.id) == ["public", "sales"])
        #expect(service.routines(for: connection.id).map(\.name) == ["alpha", "zeta"])
    }

    @Test("A kind the batch failed settles failed and leaves the kinds that answered committed")
    func oneKindFailsAlone() async throws {
        let plugin = BatchingDriver(failsRoutines: true)

        let (service, _) = try await load(plugin)

        guard case .failed = service.routinesLoadState(for: connection.id) else {
            Issue.record("expected the routines to settle failed")
            return
        }
        #expect(service.schemas(for: connection.id) == ["public", "sales"])
        #expect(service.tables(for: connection.id).map(\.name) == ["orders"])
    }
}
