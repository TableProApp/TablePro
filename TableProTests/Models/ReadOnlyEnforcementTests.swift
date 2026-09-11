//
//  ReadOnlyEnforcementTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Read-only enforcement")
@MainActor
struct ReadOnlyEnforcementTests {
    private func remoteFileConnection(preferred: SafeModeLevel = .silent) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Remote", type: .sqlite, safeModeLevel: preferred)
        connection.sshTunnelMode = .inline(
            SSHConfiguration(enabled: true, host: "ssh.example.com", remoteFilePath: "/srv/app.db")
        )
        return connection
    }

    @Test("A read-only engine outranks a remote file, and neither leaves no enforcement")
    func resolveOrder() {
        #expect(ReadOnlyEnforcement.resolve(isEngineReadOnly: true, opensRemoteDatabaseFile: true) == .readOnlyEngine)
        #expect(ReadOnlyEnforcement.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: true) == .remoteDatabaseFile)
        #expect(ReadOnlyEnforcement.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: false) == nil)
    }

    @Test("Only Read-Only can be chosen while enforcement applies", arguments: SafeModeLevel.allCases)
    func allowsChoosing(level: SafeModeLevel) {
        #expect(ReadOnlyEnforcement.allowsChoosing(level, under: nil))
        #expect(ReadOnlyEnforcement.allowsChoosing(level, under: .readOnlyEngine) == (level == .readOnly))
        #expect(ReadOnlyEnforcement.allowsChoosing(level, under: .remoteDatabaseFile) == (level == .readOnly))
    }

    @Test("A read-only engine reads as Read-Only and keeps the user's own level", arguments: [
        DatabaseType.cloudflareR2SQL, DatabaseType.beancount
    ])
    func readOnlyEngine(type: DatabaseType) {
        let connection = DatabaseConnection(name: "Engine", type: type, safeModeLevel: .alert)

        #expect(connection.readOnlyEnforcement == .readOnlyEngine)
        #expect(connection.safeModeLevel == .readOnly)
        #expect(connection.preferredSafeModeLevel == .alert)
    }

    @Test("An engine that takes writes reads as the user's own level")
    func writableEngine() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .alert)

        #expect(connection.readOnlyEnforcement == nil)
        #expect(connection.safeModeLevel == .alert)
    }

    @Test("A connection that opens a remote database file reads as Read-Only")
    func remoteFile() {
        let connection = remoteFileConnection()

        #expect(connection.readOnlyEnforcement == .remoteDatabaseFile)
        #expect(connection.safeModeLevel == .readOnly)
        #expect(connection.preferredSafeModeLevel == .silent)
    }

    @Test("Assigning the level sets the user's own choice")
    func assignmentSetsPreference() {
        var connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL)
        connection.safeModeLevel = .safeMode

        #expect(connection.preferredSafeModeLevel == .safeMode)
        #expect(connection.safeModeLevel == .readOnly)
    }

    @Test("Encoding writes the user's own level, never the enforced one")
    func codableRoundTrip() throws {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .silent)

        let data = try JSONEncoder().encode(connection)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(object["safeModeLevel"] as? String == SafeModeLevel.silent.rawValue)
        #expect(decoded.preferredSafeModeLevel == .silent)
        #expect(decoded.safeModeLevel == .readOnly)
    }

    @Test("The stored record carries the user's own level")
    func persistenceCarriesPreference() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .alert)

        #expect(StoredConnection(from: connection).safeModeLevel == SafeModeLevel.alert.rawValue)
    }

    @Test("A session starts at the enforced level")
    func sessionSeedsEnforcedLevel() {
        #expect(ConnectionSession(connection: remoteFileConnection()).safeModeLevel == .readOnly)
        let engine = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .silent)
        #expect(ConnectionSession(connection: engine).safeModeLevel == .readOnly)
    }


    @Test("Choosing a weaker level on an enforced session keeps it Read-Only")
    func setSafeModeLevelKeepsEnforcement() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .readOnly)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.setSafeModeLevel(.silent, for: connection.id)

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.safeModeLevel == .readOnly)
        #expect(session?.connection.safeModeLevel == .readOnly)
        #expect(session?.connection.preferredSafeModeLevel == .silent)
    }

    @Test("Picking Read-Only on a held connection leaves the saved level alone")
    func chooseOnHeldConnectionKeepsPreference() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .silent)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.chooseSafeModeLevel(.readOnly, for: connection.id)

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.connection.preferredSafeModeLevel == .silent)
        #expect(session?.safeModeLevel == .readOnly)
    }

    @Test("Picking a level on an ordinary connection applies it")
    func chooseOnOrdinaryConnectionApplies() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .silent)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.chooseSafeModeLevel(.safeMode, for: connection.id)

        #expect(DatabaseManager.shared.session(for: connection.id)?.safeModeLevel == .safeMode)
    }

    @Test("Choosing a level on an ordinary session applies it")
    func setSafeModeLevelOnWritableEngine() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .silent)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.setSafeModeLevel(.alert, for: connection.id)

        #expect(DatabaseManager.shared.session(for: connection.id)?.safeModeLevel == .alert)
    }
}
