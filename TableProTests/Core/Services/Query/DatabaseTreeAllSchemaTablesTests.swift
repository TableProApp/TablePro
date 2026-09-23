//
//  DatabaseTreeAllSchemaTablesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Uses PGlite because it cannot open a pooled connection, so every read stays on the injected
/// session driver, and because it groups by schema with `pg_catalog` as a system schema.
@Suite("DatabaseTreeMetadataService all-schema tables")
@MainActor
struct DatabaseTreeAllSchemaTablesTests {
    private struct ListingFailed: Error {}

    private let service = DatabaseTreeMetadataService.shared

    private func connect(_ configure: (MockDatabaseDriver) -> Void) -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        configure(driver)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func listing(_ connection: DatabaseConnection) -> CatalogTableListing.Result? {
        service.allSchemaTablesLoadState(connectionId: connection.id, database: connection.database).value
    }

    private func load(_ connection: DatabaseConnection) async {
        await service.loadAllSchemaTables(connectionId: connection.id, database: connection.database)
    }

    private func table(_ name: String, _ schema: String) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, schema: schema)
    }

    @Test("An engine with a single call is asked once, and system schemas stay out")
    func singleCall() async {
        let (connection, driver) = connect { driver in
            driver.allSchemaTablesToReturn = [
                table("users", "public"), table("timesheet", "attendance"), table("pg_class", "pg_catalog")
            ]
        }
        await load(connection)

        #expect(listing(connection)?.tables.map(\.name) == ["users", "timesheet"])
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        #expect(driver.fetchSchemasCallCount == 0)
        await disconnect(connection)
    }

    @Test("Any other engine is asked schema by schema, skipping system schemas")
    func perSchemaFallback() async {
        let (connection, driver) = connect { driver in
            driver.schemasToReturn = ["public", "attendance", "pg_catalog"]
            driver.schemaTablesToReturn = [
                "public": [table("users", "public")],
                "attendance": [table("timesheet", "attendance")],
                "pg_catalog": [table("pg_class", "pg_catalog")]
            ]
        }
        await load(connection)

        #expect(listing(connection)?.tables.map(\.name) == ["users", "timesheet"])
        #expect(driver.fetchSchemaTablesCalls == ["public", "attendance"])
        await disconnect(connection)
    }

    @Test("A schema that cannot be listed is named, and the rest are still listed")
    func unlistedSchema() async {
        let (connection, _) = connect { driver in
            driver.schemasToReturn = ["public", "attendance"]
            driver.schemaTablesToReturn = ["public": [table("users", "public")]]
            driver.schemaTablesErrors = ["attendance": ListingFailed()]
        }
        await load(connection)

        #expect(listing(connection)?.tables.map(\.name) == ["users"])
        #expect(listing(connection)?.unlistedSchemas == ["attendance"])
        await disconnect(connection)
    }

    @Test("A schema that could not be listed is asked for again on the next read, alone")
    func unlistedSchemaIsRetriedAlone() async {
        let (connection, driver) = connect { driver in
            driver.schemasToReturn = ["public", "attendance"]
            driver.schemaTablesToReturn = [
                "public": [table("users", "public")],
                "attendance": [table("timesheet", "attendance")]
            ]
            driver.schemaTablesErrors = ["attendance": ListingFailed()]
        }
        await load(connection)
        #expect(listing(connection)?.unlistedSchemas == ["attendance"])

        driver.schemaTablesErrors = [:]
        await load(connection)

        #expect(driver.fetchSchemaTablesCalls == ["public", "attendance", "attendance"])
        #expect(driver.fetchSchemasCallCount == 1)
        #expect(listing(connection)?.tables.map(\.name) == ["users", "timesheet"])
        #expect(listing(connection)?.unlistedSchemas.isEmpty == true)
        await disconnect(connection)
    }

    @Test("A second read is served without fetching again")
    func secondReadIsCached() async {
        let (connection, driver) = connect { $0.allSchemaTablesToReturn = [table("users", "public")] }
        await load(connection)
        await load(connection)

        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        await disconnect(connection)
    }

    @Test("A catalog change marks the listing stale without fetching, and the next read refetches")
    func catalogChangeMarksStale() async {
        let (connection, driver) = connect { $0.allSchemaTablesToReturn = [table("users", "public")] }
        await load(connection)

        driver.allSchemaTablesToReturn = [table("users", "public"), table("timesheet", "attendance")]
        await service.refreshCatalog(for: CatalogChange(connectionId: connection.id, kinds: .tables))
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        #expect(listing(connection)?.tables.map(\.name) == ["users"])

        await load(connection)
        #expect(driver.fetchTablesInAllSchemasCallCount == 2)
        #expect(listing(connection)?.tables.map(\.name) == ["users", "timesheet"])
        await disconnect(connection)
    }

    @Test("A change that cannot touch the tables leaves the listing current")
    func unrelatedChangeKeepsListing() async {
        let (connection, driver) = connect { $0.allSchemaTablesToReturn = [table("users", "public")] }
        await load(connection)

        await service.refreshCatalog(for: CatalogChange(connectionId: connection.id, kinds: .routines))
        await service.refreshCatalog(
            for: CatalogChange(connectionId: connection.id, database: "elsewhere", kinds: .tables)
        )
        await load(connection)

        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        await disconnect(connection)
    }

    @Test("A failed refresh keeps the rows it had and is retried on the next read")
    func failedRefreshKeepsRows() async {
        let (connection, driver) = connect { $0.allSchemaTablesToReturn = [table("users", "public")] }
        await load(connection)
        await service.refreshCatalog(for: CatalogChange(connectionId: connection.id, kinds: .tables))

        driver.allSchemaTablesError = ListingFailed()
        await load(connection)
        #expect(listing(connection)?.tables.map(\.name) == ["users"])

        driver.allSchemaTablesError = nil
        driver.allSchemaTablesToReturn = [table("orders", "public")]
        await load(connection)
        #expect(listing(connection)?.tables.map(\.name) == ["orders"])
        #expect(driver.fetchTablesInAllSchemasCallCount == 3)
        await disconnect(connection)
    }

    @Test("A first read that fails reports the failure")
    func firstReadFails() async {
        let (connection, _) = connect { $0.allSchemaTablesError = ListingFailed() }
        await load(connection)

        guard case .failed = service.allSchemaTablesLoadState(
            connectionId: connection.id, database: connection.database
        ) else {
            Issue.record("expected a failed state")
            await disconnect(connection)
            return
        }
        await disconnect(connection)
    }

    @Test("A fetch that started before a catalog change delivers its rows but leaves the listing stale")
    func fetchOvertakenByChange() async {
        let (connection, driver) = connect { driver in
            driver.allSchemaTablesToReturn = [table("users", "public")]
            driver.pausesNextAllSchemaTablesFetch = true
        }
        var first: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            driver.onAllSchemaTablesFetchPaused = { paused.resume() }
            first = Task { await load(connection) }
        }
        await service.refreshCatalog(for: CatalogChange(connectionId: connection.id, kinds: .tables))
        driver.resumeAllSchemaTablesFetch()
        await first?.value
        #expect(listing(connection)?.tables.map(\.name) == ["users"])

        driver.allSchemaTablesToReturn = [table("users", "public"), table("orders", "public")]
        await load(connection)
        #expect(driver.fetchTablesInAllSchemasCallCount == 2)
        #expect(listing(connection)?.tables.map(\.name) == ["users", "orders"])
        await disconnect(connection)
    }

    @Test("A disconnect drops the listing")
    func disconnectDropsListing() async {
        let (connection, _) = connect { $0.allSchemaTablesToReturn = [table("users", "public")] }
        await load(connection)
        await disconnect(connection)

        #expect(listing(connection) == nil)
    }
}
