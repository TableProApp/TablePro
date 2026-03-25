//
//  ConnectionStoragePersistenceTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("ConnectionStorage Persistence", .serialized)
struct ConnectionStoragePersistenceTests {
    private let storage = ConnectionStorage.shared

    @Test("loading empty storage does not write back to UserDefaults")
    func loadEmptyDoesNotWrite() {
        let original = storage.loadConnections()
        defer { storage.saveConnections(original) }

        // Clear all connections
        storage.saveConnections([])

        // Force cache clear by saving then loading
        let loaded = storage.loadConnections()
        #expect(loaded.isEmpty)

        // Add a connection directly, bypassing cache
        let connection = DatabaseConnection(name: "Persistence Test")
        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        // Loading again should return the connection, not overwrite with empty
        let reloaded = storage.loadConnections()
        #expect(reloaded.contains { $0.id == connection.id })
    }

    @Test("round-trip save and load preserves connections")
    func roundTripSaveLoad() {
        let original = storage.loadConnections()
        defer { storage.saveConnections(original) }

        let connection = DatabaseConnection(
            name: "Round Trip Test",
            host: "127.0.0.1",
            port: 5432,
            type: .postgresql
        )

        storage.saveConnections([connection])
        let loaded = storage.loadConnections()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == connection.id)
        #expect(loaded.first?.name == "Round Trip Test")
        #expect(loaded.first?.host == "127.0.0.1")
    }
}
