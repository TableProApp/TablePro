//
//  DatabaseManagerTests.swift
//  TableProTests
//
//  Tests for DatabaseManager session-scoped accessors.
//

import Foundation
@testable import TablePro
import Testing

@Suite("DatabaseManager Session-Scoped Accessors")
@MainActor
struct DatabaseManagerSessionTests {
    @Test("driver(for:) returns nil for unknown connection ID")
    func driverReturnsNilForUnknown() {
        let unknownId = UUID()
        #expect(DatabaseManager.shared.driver(for: unknownId) == nil)
    }

    @Test("session(for:) returns nil for unknown connection ID")
    func sessionReturnsNilForUnknown() {
        let unknownId = UUID()
        #expect(DatabaseManager.shared.session(for: unknownId) == nil)
    }

    @Test("activeSessions is accessible and starts empty for unknown IDs")
    func activeSessionsAccessible() {
        let unknownId = UUID()
        let session = DatabaseManager.shared.activeSessions[unknownId]
        #expect(session == nil)
    }
}
