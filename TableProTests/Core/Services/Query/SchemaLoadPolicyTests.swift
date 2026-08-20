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

@Suite("SchemaLoadPolicy")
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
}
