//
//  SchemaServiceStaleSchemaTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Oracle lists its objects one schema at a time, and every COMMIT reports a catalog change.
@MainActor
struct SchemaServiceStaleSchemaTests {
    private let connectionId = UUID()
    private let boom = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])

    private var connection: DatabaseConnection {
        TestFixtures.makeConnection(id: connectionId, type: .oracle)
    }

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "ORCL", schema: "S0")
    }

    private func schemaNames(_ count: Int) -> [String] {
        (0..<count).map { "S\($0)" }
    }

    private func driver(schemas: [String]) -> CatalogReadCountingDriver {
        let driver = CatalogReadCountingDriver(connection: connection)
        driver.schemasToReturn = schemas
        for schema in schemas {
            driver.tablesBySchema[schema] = [TableInfo(name: "\(schema)_ORDERS", type: .table, rowCount: nil, schema: schema)]
        }
        return driver
    }

    private func loaded(_ schemas: [String], driver: CatalogReadCountingDriver) async -> SchemaService {
        let service = SchemaService()
        await service.reload(connectionId: connectionId, driver: driver, connection: connection, scope: scope)
        for schema in schemas {
            await service.loadSchemaObjects(schema: schema, in: scope, driver: driver)
        }
        driver.forgetReads()
        return service
    }

    private func tableReads(_ driver: CatalogReadCountingDriver, schema: String) -> Int {
        driver.reads(ofSchema: schema).filter { $0.hasPrefix("tables") }.count
    }

    @Test("A catalog change reads no schema again, and every one keeps what it shows")
    func changeReadsNothing() async {
        let schemas = schemaNames(50)
        let driver = driver(schemas: schemas)
        let service = await loaded(schemas, driver: driver)

        await service.refreshLoadedSchemaObjects(in: scope, fetchingNow: [], driver: driver)

        #expect(driver.reads.isEmpty)
        #expect(service.tables(for: connectionId, schema: "S7").map(\.name) == ["S7_ORDERS"])
        #expect(!service.isSchemaCurrent(for: connectionId, schema: "S7"))
        #expect(service.schemaObjectsNeedFetch(for: connectionId, schema: "S7"))
        #expect(service.schemasWithCurrentTables(for: connectionId).isEmpty)
    }

    @Test("A schema something is about to judge is read at once, and only that one")
    func awaitedSchemaIsRead() async {
        let schemas = schemaNames(50)
        let driver = driver(schemas: schemas)
        let service = await loaded(schemas, driver: driver)

        await service.refreshLoadedSchemaObjects(in: scope, fetchingNow: ["S0", "NEVER_LOADED"], driver: driver)

        #expect(Set(driver.perSchemaReads) == ["tables:S0", "routines:S0"])
        #expect(service.schemasWithCurrentTables(for: connectionId) == ["S0"])
        #expect(!service.schemaObjectsNeedFetch(for: connectionId, schema: "S0"))
        #expect(service.schemaObjectsNeedFetch(for: connectionId, schema: "S1"))
    }

    @Test("A reader reads a schema a change overtook once")
    func staleSchemaIsReadOnce() async {
        let driver = driver(schemas: ["S1"])
        let service = await loaded(["S1"], driver: driver)
        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        driver.tablesBySchema["S1"] = [TableInfo(name: "S1_REFUNDS", type: .table, rowCount: nil, schema: "S1")]

        await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver)
        await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver)

        #expect(tableReads(driver, schema: "S1") == 1)
        #expect(service.tables(for: connectionId, schema: "S1").map(\.name) == ["S1_REFUNDS"])
        #expect(service.isSchemaCurrent(for: connectionId, schema: "S1"))
    }

    @Test("A read that fails after a change keeps the rows and waits for the next change")
    func failedReadWaitsForTheNextChange() async {
        let driver = driver(schemas: ["S1"])
        let service = await loaded(["S1"], driver: driver)
        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        driver.tablesError = boom

        await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver)

        #expect(service.tables(for: connectionId, schema: "S1").map(\.name) == ["S1_ORDERS"])
        #expect(!service.schemaObjectsNeedFetch(for: connectionId, schema: "S1"))
        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        #expect(service.schemaObjectsNeedFetch(for: connectionId, schema: "S1"))
    }

    @Test("A fetch that began before a change shows its rows, and the next read fetches again")
    func fetchOvertakenByAChangeIsNotCurrent() async {
        let driver = driver(schemas: ["S1"])
        let service = await loaded([], driver: driver)
        driver.pausesNextTableFetch = true
        var first: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            driver.onTableFetchPaused = { paused.resume() }
            first = Task { await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver) }
        }
        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        driver.resumeTableFetch()
        await first?.value

        #expect(service.tables(for: connectionId, schema: "S1").map(\.name) == ["S1_ORDERS"])
        #expect(!service.isSchemaCurrent(for: connectionId, schema: "S1"))
        #expect(service.schemaObjectsNeedFetch(for: connectionId, schema: "S1"))

        await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver)
        #expect(tableReads(driver, schema: "S1") == 2)
        #expect(service.isSchemaCurrent(for: connectionId, schema: "S1"))
    }

    @Test("A read after a change starts its own fetch instead of joining the one before it")
    func readAfterAChangeDoesNotJoinTheEarlierFetch() async {
        let driver = driver(schemas: ["S1"])
        let service = await loaded(["S1"], driver: driver)
        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        driver.pausesNextTableFetch = true
        var earlier: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            driver.onTableFetchPaused = { paused.resume() }
            earlier = Task { await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver) }
        }

        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        driver.tablesBySchema["S1"] = [TableInfo(name: "S1_REFUNDS", type: .table, rowCount: nil, schema: "S1")]
        await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver)
        driver.resumeTableFetch()
        await earlier?.value

        #expect(tableReads(driver, schema: "S1") == 2)
        #expect(service.tables(for: connectionId, schema: "S1").map(\.name) == ["S1_REFUNDS"])
        #expect(service.isSchemaCurrent(for: connectionId, schema: "S1"))
    }

    /// A queued truncate or drop is pruned when its table is missing from the refreshed catalog. A
    /// list read before the last change lacks every table created since, so it cannot say one is gone.
    @Test("Only a schema read since the last change can say a queued table is gone")
    func staleListsJudgeNoQueuedTable() async throws {
        let driver = driver(schemas: ["S0", "S1"])
        let service = await loaded(["S0", "S1"], driver: driver)
        let databaseManager = DatabaseManager()
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = scope.database
        session.browseSchema = scope.schema
        databaseManager.injectSession(session, for: connectionId)
        defer { databaseManager.removeSession(for: connectionId) }
        let adoption = CatalogEditAdoption(databaseManager: databaseManager, schemaService: service)
        let createdSinceRead = DatabaseTreeTableRef(
            database: scope.database,
            schema: "S1",
            table: TableInfo(name: "S1_REFUNDS", type: .table, rowCount: nil, schema: "S1")
        )
        let dropped = DatabaseTreeTableRef(
            database: scope.database,
            schema: "S0",
            table: TableInfo(name: "S0_GONE", type: .table, rowCount: nil, schema: "S0")
        )

        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        let stale = try #require(adoption.loadedBrowseCatalog(connectionId: connectionId))
        #expect(stale.schemas.isEmpty)
        #expect(stale.staleRefs(in: [createdSinceRead, dropped]).isEmpty)

        await service.loadSchemaObjects(schema: "S0", in: scope, driver: driver)
        let refreshed = try #require(adoption.loadedBrowseCatalog(connectionId: connectionId))
        #expect(refreshed.schemas == ["S0"])
        #expect(refreshed.staleRefs(in: [createdSinceRead, dropped]) == [dropped])
    }

    @Test("A read cancelled by a reload is asked for again")
    func cancelledReadIsAskedForAgain() async {
        let driver = driver(schemas: ["S1"])
        let service = await loaded(["S1"], driver: driver)
        service.markLoadedSchemaObjectsStale(connectionId: connectionId)
        driver.pausesNextTableFetch = true
        var read: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            driver.onTableFetchPaused = { paused.resume() }
            read = Task { await service.loadSchemaObjects(schema: "S1", in: scope, driver: driver) }
        }

        await service.prepareForReload(connectionId: connectionId)
        driver.resumeTableFetch()
        await read?.value

        #expect(service.tables(for: connectionId, schema: "S1").map(\.name) == ["S1_ORDERS"])
        #expect(service.schemaObjectsNeedFetch(for: connectionId, schema: "S1"))
    }
}
