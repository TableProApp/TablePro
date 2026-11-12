//
//  BulkReadTimeoutTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct BulkReadTimeoutTests {
    private struct Failure: Error {}

    @Test("A bulk read runs with the timeout off and puts the connection's own back")
    func liftsAndRestores() async throws {
        var connection = TestFixtures.makeConnection()
        connection.queryTimeoutSeconds = 17
        let source = MockDatabaseDriver(connection: connection)
        let target = MockDatabaseDriver()
        let configured = AppSettingsManager.shared.general.queryTimeoutSeconds

        let value = try await BulkReadTimeout.lifted(on: [source, target]) { 42 }

        #expect(value == 42)
        #expect(source.applyQueryTimeoutValues == [0, 17])
        #expect(target.applyQueryTimeoutValues == [0, configured])
    }

    @Test("A bulk read that fails still puts the timeout back")
    func restoresAfterFailure() async {
        var connection = TestFixtures.makeConnection()
        connection.queryTimeoutSeconds = 9
        let source = MockDatabaseDriver(connection: connection)

        await #expect(throws: Failure.self) {
            try await BulkReadTimeout.lifted(on: [source]) { () async throws -> Int in throw Failure() }
        }
        #expect(source.applyQueryTimeoutValues == [0, 9])
    }
}
