//
//  SafeModeMigrationTests.swift
//  TableProTests
//
//  Tests for safeModeLevel persistence and migration from old isReadOnly format.
//

import Foundation
import Testing
@testable import TablePro

@Suite("SafeModeMigration")
struct SafeModeMigrationTests {
    // MARK: - Round-Trip Through ConnectionStorage API

    @Test("DatabaseConnection with silent level survives save and load cycle")
    func roundTripSilent() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "Silent Test", host: "127.0.0.1", port: 3306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .silent
        )

        ConnectionStorage.shared.addConnection(connection)
        defer { ConnectionStorage.shared.deleteConnection(connection) }

        let found = ConnectionStorage.shared.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .silent)
    }

    @Test("DatabaseConnection with alert level survives save and load cycle")
    func roundTripAlert() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "Alert Test", host: "127.0.0.1", port: 5432,
            database: "test", username: "postgres", type: .postgresql,
            safeModeLevel: .alert
        )

        ConnectionStorage.shared.addConnection(connection)
        defer { ConnectionStorage.shared.deleteConnection(connection) }

        let found = ConnectionStorage.shared.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .alert)
    }

    @Test("DatabaseConnection with alertFull level survives save and load cycle")
    func roundTripAlertFull() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "AlertFull Test", host: "127.0.0.1", port: 3306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .alertFull
        )

        ConnectionStorage.shared.addConnection(connection)
        defer { ConnectionStorage.shared.deleteConnection(connection) }

        let found = ConnectionStorage.shared.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .alertFull)
    }

    @Test("DatabaseConnection with safeMode level survives save and load cycle")
    func roundTripSafeMode() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "SafeMode Test", host: "127.0.0.1", port: 3306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .safeMode
        )

        ConnectionStorage.shared.addConnection(connection)
        defer { ConnectionStorage.shared.deleteConnection(connection) }

        let found = ConnectionStorage.shared.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .safeMode)
    }

    @Test("DatabaseConnection with safeModeFull level survives save and load cycle")
    func roundTripSafeModeFull() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "SafeModeFull Test", host: "127.0.0.1", port: 3306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .safeModeFull
        )

        ConnectionStorage.shared.addConnection(connection)
        defer { ConnectionStorage.shared.deleteConnection(connection) }

        let found = ConnectionStorage.shared.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .safeModeFull)
    }

    @Test("DatabaseConnection with readOnly level survives save and load cycle")
    func roundTripReadOnly() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "ReadOnly Test", host: "127.0.0.1", port: 3306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .readOnly
        )

        ConnectionStorage.shared.addConnection(connection)
        defer { ConnectionStorage.shared.deleteConnection(connection) }

        let found = ConnectionStorage.shared.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .readOnly)
    }

    // MARK: - Default Level

    @Test("New connection defaults to silent safe mode level")
    func defaultLevel() {
        let connection = TestFixtures.makeConnection()
        #expect(connection.safeModeLevel == .silent)
    }
}
