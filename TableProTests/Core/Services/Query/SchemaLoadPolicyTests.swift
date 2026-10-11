//
//  SchemaLoadPolicyTests.swift
//  TableProTests
//
//  A failed object-list load has to end somewhere the user can see. Deferring one that
//  failed while the driver was still there is what turned an Oracle metadata timeout into
//  an endless silent retry behind a spinner (#2294).
//

import Foundation
@testable import TablePro
import Testing

struct SchemaLoadPolicyTests {
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "Switching to schema 'APP_SCHEMA' timed out." }
    }

    @Test("a failure with a live driver surfaces to the sidebar")
    func liveDriverSurfaces() {
        let disposition = SchemaLoadPolicy.disposition(for: Boom(), hasLiveDriver: true)

        #expect(disposition == .surface("Switching to schema 'APP_SCHEMA' timed out."))
    }

    @Test("a failure without a driver waits for the connection")
    func missingDriverWaits() {
        let disposition = SchemaLoadPolicy.disposition(for: Boom(), hasLiveDriver: false)

        #expect(disposition == .awaitConnection)
    }

    @Test("a cancelled load neither surfaces nor waits")
    func cancellationIsIgnored() {
        #expect(SchemaLoadPolicy.disposition(for: CancellationError(), hasLiveDriver: true) == .ignore)
        #expect(SchemaLoadPolicy.disposition(for: CancellationError(), hasLiveDriver: false) == .ignore)
    }

    @Test("a pool timeout on a connected session never defers")
    func poolTimeoutNeverDefers() {
        let error = DatabaseError.connectionFailed("Switching to schema 'APP_SCHEMA' timed out.")

        let disposition = SchemaLoadPolicy.disposition(for: error, hasLiveDriver: true)

        #expect(disposition != .awaitConnection)
    }

    @Test("a not-connected error still surfaces while the driver is live")
    func notConnectedWithLiveDriverSurfaces() {
        let disposition = SchemaLoadPolicy.disposition(for: DatabaseError.notConnected, hasLiveDriver: true)

        #expect(disposition == .surface(DatabaseError.notConnected.localizedDescription))
    }

    private static let loaded = SchemaState.loaded([TestFixtures.makeTableInfo(name: "users")])

    private static func activation(
        hasLiveDriver: Bool = true,
        catalog: SchemaState,
        autocompletePopulated: Bool = false,
        loadInFlight: Bool = false
    ) -> SchemaActivationAction {
        SchemaLoadPolicy.activationAction(
            hasLiveDriver: hasLiveDriver,
            catalog: catalog,
            autocompletePopulated: autocompletePopulated,
            loadInFlight: loadInFlight
        )
    }

    @Test("coming back to a loaded connection loads nothing")
    func loadedAndPopulatedIsLeftAlone() {
        #expect(Self.activation(catalog: Self.loaded, autocompletePopulated: true) == .none)
    }

    @Test("a loaded catalog without an autocomplete provider still fills it")
    func loadedButUnpopulatedLoads() {
        #expect(Self.activation(catalog: Self.loaded, autocompletePopulated: false) == .load)
    }

    @Test("a connection whose catalog never loaded loads on activation")
    func idleLoads() {
        #expect(Self.activation(catalog: .idle) == .load)
    }

    @Test("a failed catalog waits for Retry instead of reloading on every switch")
    func failedWaitsForRetry() {
        #expect(Self.activation(catalog: .failed("timed out")) == .none)
    }

    @Test("a catalog already loading is not loaded a second time")
    func loadingIsNotRepeated() {
        #expect(Self.activation(catalog: .loading) == .none)
    }

    @Test("a load already in flight is joined, not repeated")
    func inFlightIsNotRepeated() {
        #expect(Self.activation(catalog: .idle, loadInFlight: true) == .none)
    }

    @Test("no driver yet waits for the connection")
    func noDriverWaits() {
        #expect(Self.activation(hasLiveDriver: false, catalog: .idle) == .awaitConnection)
        #expect(Self.activation(hasLiveDriver: false, catalog: Self.loaded, autocompletePopulated: true) == .awaitConnection)
    }

    @Test("a load on the driver that just connected answers the connect")
    func loadOnTheConnectedDriverCoversConnect() {
        let driver = MockDatabaseDriver()

        #expect(SchemaLoadPolicy.inFlightLoadCoversConnect(loadDriver: driver, connectedDriver: driver))
    }

    /// A reconnect replaces the driver while a load started on the old one may still be running.
    /// Waiting on that load and trusting its catalog skipped the refresh the new driver needed.
    @Test("a load still running on a replaced driver does not answer a reconnect")
    func loadOnAReplacedDriverDoesNotCoverReconnect() {
        let replaced = MockDatabaseDriver()
        let reconnected = MockDatabaseDriver()

        #expect(!SchemaLoadPolicy.inFlightLoadCoversConnect(loadDriver: replaced, connectedDriver: reconnected))
        #expect(!SchemaLoadPolicy.inFlightLoadCoversConnect(loadDriver: nil, connectedDriver: reconnected))
        #expect(!SchemaLoadPolicy.inFlightLoadCoversConnect(loadDriver: replaced, connectedDriver: nil))
    }
}
