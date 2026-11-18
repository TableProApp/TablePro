//
//  ConnectionSidebarCatalogTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct ConnectionSidebarCatalogTests {
    private final class PublishCounter {
        private(set) var count = 0
        private var subscription: AnyCancellable?

        init(_ catalog: ConnectionSidebarCatalog) {
            subscription = catalog.objectWillChange.sink { [weak self] _ in self?.count += 1 }
        }
    }

    @MainActor
    private struct Fixture {
        let connection: DatabaseConnection
        let schemaService: SchemaService
        let toolbarState: ConnectionToolbarState
        let catalog: ConnectionSidebarCatalog
        let counter: PublishCounter

        // Wakes are read in order, so a change of this connection landing means every earlier wake was read too.
        func settle(_ schema: String) async throws {
            toolbarState.currentSchema = schema
            try await waitUntil { catalog.drawn.toolbarSchema == schema }
        }
    }

    private func makeFixture() -> Fixture {
        let connection = TestFixtures.makeConnection(name: "Mine", database: "shop", type: .mysql)
        let schemaService = SchemaService()
        let toolbarState = ConnectionToolbarState()
        let catalog = ConnectionSidebarCatalog(
            connectionId: connection.id,
            toolbarState: toolbarState,
            schemaService: schemaService
        )
        return Fixture(
            connection: connection,
            schemaService: schemaService,
            toolbarState: toolbarState,
            catalog: catalog,
            counter: PublishCounter(catalog)
        )
    }

    @Test("Another connection's catalog load does not redraw this connection's sidebar")
    func otherConnectionIsSilent() async throws {
        let fixture = makeFixture()
        let other = TestFixtures.makeConnection(name: "Other", database: "blog", type: .mysql)
        let driver = MockDatabaseDriver(connection: other)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "posts")]

        await fixture.schemaService.reload(connectionId: other.id, driver: driver, connection: other)
        try await fixture.settle("public")

        #expect(fixture.schemaService.tables(for: other.id).map(\.name) == ["posts"])
        #expect(fixture.counter.count == 1)
    }

    @Test("This connection's tables landing redraw the sidebar")
    func ownTablesPublish() async throws {
        let fixture = makeFixture()
        let driver = MockDatabaseDriver(connection: fixture.connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]

        await fixture.schemaService.reload(
            connectionId: fixture.connection.id, driver: driver, connection: fixture.connection
        )

        try await waitUntil { fixture.catalog.drawn.lists.catalogTables.rows.rows.map(\.name) == ["orders"] }
        #expect(fixture.counter.count >= 1)
    }

    @Test("Reading the same tables again does not redraw the sidebar")
    func sameTablesAreSilent() async throws {
        let fixture = makeFixture()
        let driver = MockDatabaseDriver(connection: fixture.connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        await fixture.schemaService.reload(
            connectionId: fixture.connection.id, driver: driver, connection: fixture.connection
        )
        try await waitUntil { fixture.catalog.drawn.isRefreshing == false && !fixture.catalog.drawn.lists.catalogTables.rows.rows.isEmpty }
        try await fixture.settle("first")
        let published = fixture.counter.count

        fixture.schemaService.bumpGeneration(fixture.connection.id)
        try await fixture.settle("second")

        #expect(fixture.counter.count == published + 1)
    }

    @Test("A session's status, driver and browse position redraw the sidebar, another session's do not")
    func sessionChanges() async throws {
        let fixture = makeFixture()
        let manager = DatabaseManager.shared
        let other = TestFixtures.makeConnection(name: "Other", database: "blog", type: .mysql)
        var otherSession = ConnectionSession(connection: other, driver: MockDatabaseDriver(connection: other))
        otherSession.status = .connected
        manager.injectSession(otherSession, for: other.id)
        try await fixture.settle("quiet")
        #expect(fixture.counter.count == 1)
        #expect(fixture.catalog.drawn.status == nil)

        var session = ConnectionSession(
            connection: fixture.connection, driver: MockDatabaseDriver(connection: fixture.connection)
        )
        session.status = .connected
        manager.injectSession(session, for: fixture.connection.id)

        try await waitUntil { fixture.catalog.drawn.status == .connected }
        #expect(fixture.catalog.drawn.driver != nil)
        #expect(fixture.catalog.drawn.browseScope?.database == "shop")
        manager.removeSession(for: fixture.connection.id)
        manager.removeSession(for: other.id)
    }

    @Test("The schema the toolbar shows redraws the sidebar")
    func toolbarSchemaPublishes() async throws {
        let fixture = makeFixture()

        try await fixture.settle("sales")

        #expect(fixture.counter.count == 1)
    }
}
