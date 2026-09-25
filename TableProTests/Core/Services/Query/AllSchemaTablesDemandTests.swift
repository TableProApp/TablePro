//
//  AllSchemaTablesDemandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct AllSchemaTablesDemandTests {
    private let service = DatabaseTreeMetadataService.shared

    private func connectedListing() async -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        driver.allSchemaTablesToReturn = [TestFixtures.makeTableInfo(name: "users", schema: "public")]
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        await service.loadAllSchemaTables(connectionId: connection.id, database: connection.database)
        return connection
    }

    private func disconnect(_ connection: DatabaseConnection) async {
        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("A listing nobody holds is asked for")
    func idleListingIsRequested() {
        let demand = AllSchemaTablesDemand()
        #expect(demand.needsRequest(connectionId: UUID(), database: "shop", service: service))
    }

    @Test("A listing is not asked for twice at one revision, and is asked again once it moves")
    func oncePerRevision() async {
        let connection = await connectedListing()
        var demand = AllSchemaTablesDemand()
        demand.noteRequested(connectionId: connection.id, database: connection.database, service: service)
        #expect(!demand.needsRequest(connectionId: connection.id, database: connection.database, service: service))

        service.markAllSchemaTablesChanged([
            DatabaseTreeMetadataService.DatabaseKey(connectionId: connection.id, database: connection.database)
        ])
        #expect(demand.needsRequest(connectionId: connection.id, database: connection.database, service: service))
        await disconnect(connection)
    }

    /// A reconnect moves the revision while the session is still connecting. Counting that revision
    /// as asked for, when the load could not start, left the search stale once the session was back.
    @Test("A request while not connected is not counted, so the next one after connecting goes out")
    func notConnectedIsNotCounted() async {
        let connection = await connectedListing()
        var demand = AllSchemaTablesDemand()
        demand.noteRequested(connectionId: connection.id, database: connection.database, service: service)
        service.markAllSchemaTablesChanged([
            DatabaseTreeMetadataService.DatabaseKey(connectionId: connection.id, database: connection.database)
        ])

        demand.requestIfNeeded(
            connectionId: connection.id, database: connection.database, isConnected: false, service: service
        )

        #expect(demand.needsRequest(connectionId: connection.id, database: connection.database, service: service))
        await disconnect(connection)
    }

    @Test("Starting a new search asks again whatever was asked before")
    func resetForgetsEarlierRequests() async {
        let connection = await connectedListing()
        var demand = AllSchemaTablesDemand()
        demand.noteRequested(connectionId: connection.id, database: connection.database, service: service)

        demand.reset()

        #expect(demand.needsRequest(connectionId: connection.id, database: connection.database, service: service))
        await disconnect(connection)
    }
}
