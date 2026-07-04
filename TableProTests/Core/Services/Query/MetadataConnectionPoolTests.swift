//
//  MetadataConnectionPoolTests.swift
//  TableProTests
//
//  Tests for the pool's bounded connect and schema-switch steps: a hanging
//  driver must fail within the deadline instead of stalling the pool entry.
//

import Foundation
@testable import TablePro
import Testing

@Suite("MetadataConnectionPool timeouts")
@MainActor
struct MetadataConnectionPoolTests {
    @Test("connect passes through when the driver responds in time")
    func connectPassesThrough() async throws {
        let driver = MockDatabaseDriver()

        try await MetadataConnectionPool.connect(driver, database: "db", timeoutSeconds: 1)
    }

    @Test("connect fails with a connection error when the driver hangs")
    func connectTimesOut() async {
        let driver = MockDatabaseDriver()
        driver.connectDelaySeconds = 5

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.connect(driver, database: "db", timeoutSeconds: 0.05)
        }
    }

    @Test("connect force-disconnects a driver that ignores cancellation")
    func connectUnsticksCancellationDeafDriver() async {
        let driver = MockDatabaseDriver()
        driver.hangsUntilDisconnect = true

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.connect(driver, database: "db", timeoutSeconds: 0.05)
        }
    }

    @Test("schema switch passes through when the driver responds in time")
    func switchSchemaPassesThrough() async throws {
        let driver = MockDatabaseDriver()

        try await MetadataConnectionPool.switchSchema(driver, to: "HR", timeoutSeconds: 1)

        #expect(driver.currentSchema == "HR")
    }

    @Test("schema switch fails with a connection error when the driver hangs")
    func switchSchemaTimesOut() async {
        let driver = MockDatabaseDriver()
        driver.switchSchemaDelaySeconds = 5

        await #expect(throws: DatabaseError.self) {
            try await MetadataConnectionPool.switchSchema(driver, to: "HR", timeoutSeconds: 0.05)
        }
        #expect(driver.currentSchema == nil)
    }
}
