//
//  SchemaLeasingLoadTests.swift
//  TableProTests
//
//  The first load of a catalog takes one lease per read, the tables first, so a column read asked
//  for while it runs goes before the rest of the catalog instead of after all of it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private struct LeaseRefused: Error {}

private final class CatalogOrderDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var gates: [String: AsyncGate] = [:]
    private var failures: [String: any Error] = [:]

    var reads: [String] { lock.withLock { log } }

    func hold(_ read: String, on gate: AsyncGate) {
        lock.withLock { gates[read] = gate }
    }

    func fail(_ read: String, with error: any Error) {
        lock.withLock { failures[read] = error }
    }

    private func note(_ read: String) async throws {
        let (gate, failure) = lock.withLock { () -> (AsyncGate?, (any Error)?) in
            log.append(read)
            return (gates[read], failures[read])
        }
        if let gate { await gate.wait() }
        if let failure { throw failure }
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await note("tables")
        return [PluginTableInfo(
            name: "orders", comment: nil, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil
        )]
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await note("columns")
        return []
    }

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try await note("routines")
        return []
    }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await note("triggers")
        return []
    }
}

/// Hands out leases one at a time in the order they were asked for, as a pool entry does.
@MainActor
private final class SerialLeaseProvider: ScopedMetadataProviding {
    let driver: DatabaseDriver
    private(set) var leases = 0
    private var refused: [Int: any Error] = [:]
    private var tail: Task<Void, Never> = Task {}

    init(driver: DatabaseDriver) {
        self.driver = driver
    }

    func refuse(lease number: Int, with error: any Error) {
        refused[number] = error
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        leases += 1
        if let error = refused[leases] { throw error }
        let previous = tail
        let driver = driver
        let work = Task { @MainActor () async throws -> T in
            await previous.value
            return try await body(driver)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    func withMetadataRead<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withMetadataDriver(scope: scope, workload: workload, body)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

@MainActor
struct SchemaLeasingLoadTests {
    private let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
    private let plugin = CatalogOrderDriver()

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
    }

    private func load(
        _ service: SchemaService,
        from provider: SerialLeaseProvider,
        afterTables: (@MainActor () async -> Void)? = nil
    ) async throws {
        try await service.load(
            connectionId: connection.id,
            connection: connection,
            scope: scope,
            leasingFrom: provider,
            afterTables: afterTables
        )
    }

    private func makeProvider() -> SerialLeaseProvider {
        SerialLeaseProvider(driver: PluginDriverAdapter(connection: connection, pluginDriver: plugin))
    }

    @Test("The tables are read first, on a lease of their own, and every other kind on one lease each")
    func tablesFirstThenOneLeasePerKind() async throws {
        let service = SchemaService()
        let provider = makeProvider()

        try await load(service, from: provider)

        #expect(plugin.reads == ["tables", "routines", "triggers"])
        #expect(provider.leases > 2)
        #expect(service.state(for: connection.id) == .loaded(service.tables(for: connection.id)))
        #expect(service.tables(for: connection.id).map(\.name) == ["orders"])
    }

    @Test("A column read asked for while the routines are read runs before the triggers")
    func aColumnReadPassesTheRestOfTheCatalog() async throws {
        let service = SchemaService()
        let provider = makeProvider()
        let routines = AsyncGate()
        plugin.hold("routines", on: routines)

        async let loading: Void = load(service, from: provider)
        try await waitUntil { plugin.reads.contains("routines") }
        async let column = provider.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchColumns(table: "orders", schema: nil)
        }
        try await waitUntil { provider.leases == 3 }
        await routines.open()
        _ = try await (loading, column)

        #expect(plugin.reads == ["tables", "routines", "columns", "triggers"])
    }

    @Test("Completion gets the tables before any other kind is read")
    func completionSyncRunsBeforeTheSideKinds() async throws {
        let service = SchemaService()
        let provider = makeProvider()
        var readsAtSync: [String]?

        try await load(service, from: provider) { [plugin] in
            readsAtSync = plugin.reads
        }

        #expect(readsAtSync == ["tables"])
    }

    @Test("A tables lease that cannot be had throws and leaves the catalog untouched")
    func tablesLeaseFailureLeavesStateAlone() async {
        let service = SchemaService()
        let provider = makeProvider()
        provider.refuse(lease: 1, with: LeaseRefused())

        await #expect(throws: LeaseRefused.self) { try await load(service, from: provider) }

        #expect(service.state(for: connection.id) == .idle)
        #expect(plugin.reads.isEmpty)
        #expect(!service.isRefreshing(connectionId: connection.id))
    }

    @Test("A failed tables read still settles every other kind")
    func failedTablesReadSettlesTheSideKinds() async throws {
        let service = SchemaService()
        let provider = makeProvider()
        plugin.fail("tables", with: DatabaseError.queryFailed("gone"))

        try await load(service, from: provider)

        guard case .failed = service.state(for: connection.id) else {
            Issue.record("expected the tables to fail")
            return
        }
        #expect(service.routinesLoadState(for: connection.id).erased != .loading)
        #expect(service.triggersLoadState(for: connection.id).erased != .loading)
    }

    @Test("A side lease that cannot be had settles its kind and every later one as failed")
    func sideLeaseFailureSettlesTheRest() async throws {
        let service = SchemaService()
        let provider = makeProvider()
        provider.refuse(lease: 2, with: LeaseRefused())

        try await load(service, from: provider)

        #expect(service.tables(for: connection.id).map(\.name) == ["orders"])
        guard case .failed = service.routinesLoadState(for: connection.id),
              case .failed = service.triggersLoadState(for: connection.id) else {
            Issue.record("expected routines and triggers to settle failed")
            return
        }
        #expect(!service.isRefreshing(connectionId: connection.id))
    }

    @Test("A side lease that is cancelled settles the kinds not yet read as cancelled")
    func cancelledSideLeaseSettlesTheRestCancelled() async throws {
        let service = SchemaService()
        let provider = makeProvider()
        provider.refuse(lease: 2, with: CancellationError())

        try await load(service, from: provider)

        #expect(service.routinesLoadState(for: connection.id).erased != .loading)
        #expect(service.triggersLoadState(for: connection.id).erased != .loading)
    }

    @Test("A load overtaken by a newer one stops at its next lease and settles nothing")
    func supersededLoadStopsAtTheNextLease() async throws {
        let service = SchemaService()
        let provider = makeProvider()
        let routines = AsyncGate()
        plugin.hold("routines", on: routines)

        async let first: Void = load(service, from: provider)
        try await waitUntil { plugin.reads.contains("routines") }
        let newer = makeProvider()
        let second = Task { @MainActor in
            await service.reload(
                connectionId: connection.id, driver: newer.driver, connection: connection, scope: scope
            )
        }
        try await waitUntil { plugin.reads.filter { $0 == "tables" }.count == 2 }
        await routines.open()
        _ = await second.value
        try await first

        #expect(plugin.reads.filter { $0 == "triggers" }.count == 1)
    }
}
