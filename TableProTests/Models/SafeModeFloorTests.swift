//
//  SafeModeFloorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Safe Mode floor")
@MainActor
struct SafeModeFloorTests {
    private func remoteFileConnection(preferred: SafeModeLevel = .silent) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Remote", type: .sqlite, safeModeLevel: preferred)
        connection.sshTunnelMode = .inline(
            SSHConfiguration(enabled: true, host: "ssh.example.com", remoteFilePath: "/srv/app.db")
        )
        return connection
    }

    @Test("A read-only engine outranks a remote file, and both outrank the profile")
    func resolveOrder() {
        let engine = SafeModeFloor.resolve(isEngineReadOnly: true, opensRemoteDatabaseFile: true, managedMinimum: .alert)
        let remote = SafeModeFloor.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: true, managedMinimum: .alert)
        let managed = SafeModeFloor.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: false, managedMinimum: .alert)

        #expect(engine == SafeModeFloor(level: .readOnly, reason: .readOnlyEngine))
        #expect(remote == SafeModeFloor(level: .readOnly, reason: .remoteDatabaseFile))
        #expect(managed == SafeModeFloor(level: .alert, reason: .managedPolicy))
    }

    @Test("No condition and no profile, or a profile at Silent, leaves no floor", arguments: [nil, SafeModeLevel.silent])
    func noFloor(managedMinimum: SafeModeLevel?) {
        #expect(
            SafeModeFloor.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: false, managedMinimum: managedMinimum)
                == nil
        )
    }

    @Test("A floor allows its own level and every stricter one", arguments: SafeModeLevel.allCases)
    func allowsStricterLevels(candidate: SafeModeLevel) {
        let floor = SafeModeFloor(level: .safeMode, reason: .managedPolicy)
        let stricter: Set<SafeModeLevel> = [.safeMode, .safeModeFull, .readOnly]

        #expect(floor.allows(candidate) == stricter.contains(candidate))
        #expect(floor.raising(candidate) == (stricter.contains(candidate) ? candidate : .safeMode))
    }

    @Test("The choosable levels are the ones at or above the floor")
    func choosableLevels() {
        #expect(SafeModeFloor.levels(allowedBy: nil) == SafeModeLevel.allCases)
        #expect(SafeModeFloor.levels(allowedBy: SafeModeFloor(level: .readOnly, reason: .readOnlyEngine)) == [.readOnly])
        #expect(
            SafeModeFloor.levels(allowedBy: SafeModeFloor(level: .alertFull, reason: .managedPolicy))
                == [.alertFull, .safeMode, .safeModeFull, .readOnly]
        )
    }

    @Test("The profile's explanation names the level it requires")
    func managedExplanationNamesLevel() {
        let floor = SafeModeFloor(level: .safeModeFull, reason: .managedPolicy)
        #expect(floor.explanation.contains(SafeModeLevel.safeModeFull.displayName))
    }

    @Test("A read-only engine reads as Read-Only and keeps the user's own level", arguments: [
        DatabaseType.cloudflareR2SQL, DatabaseType.beancount
    ])
    func readOnlyEngine(type: DatabaseType) {
        let connection = DatabaseConnection(name: "Engine", type: type, safeModeLevel: .alert)

        #expect(connection.safeModeFloor?.reason == .readOnlyEngine)
        #expect(connection.safeModeLevel == .readOnly)
        #expect(connection.preferredSafeModeLevel == .alert)
    }

    @Test("An engine that takes writes reads as the user's own level")
    func writableEngine() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .alert)

        #expect(connection.safeModeFloor == nil)
        #expect(connection.safeModeLevel == .alert)
    }

    @Test("A connection that opens a remote database file reads as Read-Only")
    func remoteFile() {
        let connection = remoteFileConnection()

        #expect(connection.safeModeFloor?.reason == .remoteDatabaseFile)
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

    @Test("Picking the level already in force on a held connection leaves the saved level alone")
    func chooseOnHeldConnectionKeepsPreference() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .silent)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.chooseSafeModeLevel(.readOnly, for: connection.id)

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.connection.preferredSafeModeLevel == .silent)
        #expect(session?.safeModeLevel == .readOnly)
    }

    @Test("Picking a level below the floor changes nothing")
    func chooseBelowFloorIsIgnored() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .alert)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.chooseSafeModeLevel(.silent, for: connection.id)

        #expect(DatabaseManager.shared.session(for: connection.id)?.connection.preferredSafeModeLevel == .alert)
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
