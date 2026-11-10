import Foundation
import Testing

@testable import TablePro

@MainActor
struct TabPersistenceSessionGateTests {
    @Test("Closing a connection's last window closes the gate its restore opened")
    func lastTeardownClosesTheGate() {
        let fixture = CoordinatorFixture()
        let persistence = TabPersistenceCoordinator.forConnection(fixture.connection.id)
        persistence.markObservedTabs()
        #expect(fixture.coordinator.persistence === persistence)

        fixture.coordinator.teardown()

        #expect(!persistence.hasObservedTabs)
    }

    @Test("A lost session keeps the gate open for the workspace that reconnects")
    func sessionReleaseKeepsTheGate() {
        let fixture = CoordinatorFixture()
        let persistence = TabPersistenceCoordinator.forConnection(fixture.connection.id)
        persistence.markObservedTabs()

        fixture.coordinator.teardown(endsTabSession: false)

        #expect(persistence.hasObservedTabs)

        // The workspace then closes with no coordinator left to tear down.
        MainContentCoordinator.endTabSessionIfUnhosted(for: fixture.connection.id)
        #expect(!persistence.hasObservedTabs)
    }

    private func disconnectedWorkspace(for connection: DatabaseConnection) -> ConnectionWorkspace {
        ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .idle
        )
    }

    @Test("A disconnected workspace in another window holds the gate when a window closes")
    func disconnectedWorkspaceElsewhereHoldsTheGate() {
        let connection = TestFixtures.makeConnection()
        let closing = disconnectedWorkspace(for: connection)
        let remaining = disconnectedWorkspace(for: connection)
        let persistence = TabPersistenceCoordinator.forConnection(connection.id)
        persistence.markObservedTabs()

        MainContentCoordinator.endTabSessionIfUnhosted(
            for: connection.id, closing: closing, hosted: [closing, remaining]
        )
        #expect(persistence.hasObservedTabs)

        MainContentCoordinator.endTabSessionIfUnhosted(for: connection.id, closing: remaining, hosted: [remaining])
        #expect(!persistence.hasObservedTabs)
    }

    @Test("The gate stays open while another window still hosts the connection")
    func gateStaysOpenForARemainingWindow() {
        let connection = TestFixtures.makeConnection()
        let closing = CoordinatorFixture(connection: connection)
        let remaining = CoordinatorFixture(connection: connection)
        remaining.coordinator.registerEagerly()
        remaining.coordinator.hasRestoredTabs = true
        let persistence = TabPersistenceCoordinator.forConnection(connection.id)
        persistence.markObservedTabs()

        closing.coordinator.teardown()
        #expect(persistence.hasObservedTabs)

        remaining.coordinator.teardown()
        #expect(!persistence.hasObservedTabs)
    }
}
