//
//  DatabaseManagerObserverTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("DatabaseManager Observer Management")
@MainActor
struct DatabaseManagerObserverTests {
    @Test("DatabaseManager singleton is accessible")
    func singletonAccessible() {
        let manager = DatabaseManager.shared
        #expect(manager != nil)
    }

    @Test("activeSessions starts empty for fresh UUIDs")
    func activeSessionsEmpty() {
        let id = UUID()
        #expect(DatabaseManager.shared.activeSessions[id] == nil)
    }

    @Test("driver returns nil for non-existent session")
    func driverNilForNonExistent() {
        #expect(DatabaseManager.shared.driver(for: UUID()) == nil)
    }
}
