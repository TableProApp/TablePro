//
//  CatalogObjectListSourceTests.swift
//  TableProTests
//

import Combine
import Foundation
import TableProTestSupport
import Testing

@testable import TablePro

private struct ListRefused: Error, LocalizedError {
    var errorDescription: String? { "permission denied for schema public" }
}

/// PGlite cannot open a pooled connection, so a read stays on the injected session driver.
@MainActor
struct CatalogObjectListSourceTests {
    private let service = DatabaseTreeMetadataService.shared

    private func connect() -> (DatabaseConnection, MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func scope(_ connection: DatabaseConnection) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: connection.database, schema: "public")
    }

    private func fetched(_ outcome: MetadataFetchOutcome<CatalogObjectList>) -> CatalogObjectList? {
        if case .fetched(let list) = outcome { return list }
        return nil
    }

    private func failure(_ outcome: MetadataFetchOutcome<CatalogObjectList>) -> String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    @Test("A kind is read into the sidebar's own list, and asking again takes that list without a second read")
    func readsIntoTheSidebarsList() async {
        let (connection, driver) = connect()
        let orders = TestFixtures.makeTableInfo(name: "orders", schema: "public")
        driver.schemaTablesToReturn = ["public": [orders]]

        let first = await service.objects(.table, in: scope(connection), rereading: false)
        let second = await service.objects(.table, in: scope(connection), rereading: false)

        #expect(fetched(first) == .relations([orders]))
        #expect(fetched(second) == .relations([orders]))
        #expect(driver.fetchScopedTablesCallCount == 1)
        #expect(service.tables(connectionId: connection.id, database: connection.database, schema: "public") == [orders])
        await disconnect(connection)
    }

    @Test("A refresh reads the kind again, so a change made elsewhere shows")
    func refreshRereads() async {
        let (connection, driver) = connect()
        let orders = TestFixtures.makeTableInfo(name: "orders", schema: "public")
        let customers = TestFixtures.makeTableInfo(name: "customers", schema: "public")
        driver.schemaTablesToReturn = ["public": [orders]]
        _ = await service.objects(.table, in: scope(connection), rereading: false)

        driver.schemaTablesToReturn = ["public": [orders, customers]]
        let refreshed = await service.objects(.table, in: scope(connection), rereading: true)

        #expect(fetched(refreshed) == .relations([orders, customers]))
        await disconnect(connection)
    }

    @Test("Routines come from the sidebar's routine list")
    func routinesComeFromTheRoutineList() async {
        let (connection, driver) = connect()
        let touch = RoutineInfo(name: "touch", kind: .function, schema: "public")
        driver.schemaRoutinesToReturn = ["public": [touch]]

        let outcome = await service.objects(.routine, in: scope(connection), rereading: false)

        #expect(fetched(outcome) == .routines([touch]))
        await disconnect(connection)
    }

    @Test("A tab follows the sidebar's own list: a read the sidebar commits reaches it")
    func changesFollowTheSidebarsList() async {
        let (connection, driver) = connect()
        let touch = RoutineInfo(name: "touch", kind: .function, schema: "public")
        let audit = RoutineInfo(name: "audit", kind: .function, schema: "public")
        driver.schemaRoutinesToReturn = ["public": [touch]]
        var seen: [CatalogObjectList] = []
        let subscription = service.objectListChanges(.routine, in: scope(connection)).sink { seen.append($0) }
        defer { subscription.cancel() }

        _ = await service.objects(.routine, in: scope(connection), rereading: false)
        #expect(seen.last == .routines([touch]))

        driver.schemaRoutinesToReturn = ["public": [touch, audit]]
        await service.refreshRoutineObjects(connectionId: connection.id, database: connection.database, schema: "public")

        #expect(seen.last == .routines([touch, audit]))
        await disconnect(connection)
    }

    /// The list keeps its rows while a newer read runs, so taking it as it stood handed the tab the
    /// rows from before either read began, as if they were fresh.
    @Test("A refresh a newer sidebar read overtakes waits for that read and returns its rows")
    func overtakenRefreshTakesTheNewerRead() async {
        let (connection, driver) = connect()
        let touch = RoutineInfo(name: "touch", kind: .function, schema: "public")
        let audit = RoutineInfo(name: "audit", kind: .function, schema: "public")
        let purge = RoutineInfo(name: "purge", kind: .function, schema: "public")
        driver.schemaRoutinesToReturn = ["public": [touch]]
        _ = await service.objects(.routine, in: scope(connection), rereading: false)
        let tabRead = HeldDriverRead()
        let sidebarRead = HeldDriverRead()
        driver.routineFetchHolds = [tabRead, sidebarRead]

        driver.schemaRoutinesToReturn = ["public": [touch, audit]]
        let refresh = Task { await service.objects(.routine, in: scope(connection), rereading: true) }
        await tabRead.reached.wait()
        driver.schemaRoutinesToReturn = ["public": [touch, audit, purge]]
        let sidebar = Task {
            await service.refreshRoutineObjects(connectionId: connection.id, database: connection.database, schema: "public")
        }
        await tabRead.cancelled.wait()
        await tabRead.release.open()
        await sidebarRead.reached.wait()
        await sidebarRead.release.open()

        #expect(fetched(await refresh.value) == .routines([touch, audit, purge]))
        _ = await sidebar.value
        await disconnect(connection)
    }

    @Test("A read the server refused says why")
    func refusedReadSaysWhy() async {
        let (connection, driver) = connect()
        driver.schemaTablesErrors = ["public": ListRefused()]

        let outcome = await service.objects(.table, in: scope(connection), rereading: false)

        #expect(failure(outcome) == ListRefused().localizedDescription)
        await disconnect(connection)
    }

    @Test("With the connection down the read says so instead of leaving a spinner")
    func notConnectedSaysSo() async {
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

        let outcome = await service.objects(.routine, in: scope, rereading: false)

        #expect(failure(outcome) == DatabaseError.notConnected.localizedDescription)
    }
}
