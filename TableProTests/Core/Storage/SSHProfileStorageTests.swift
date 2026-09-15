//
//  SSHProfileStorageTests.swift
//  TableProTests
//

import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

@Suite("SSH profile storage")
@MainActor
struct SSHProfileStorageTests {
    private let storage: SSHProfileStorage
    private let connections: ConnectionStorage
    private let keychain: InMemoryKeychain
    private let metadata: SyncMetadataStorage

    init() {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let connectionDefaults = UserDefaults(suiteName: "com.TablePro.tests.SSHProfileConn.\(unique)")!
        let profileDefaults = UserDefaults(suiteName: "com.TablePro.tests.SSHProfile.\(unique)")!
        let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.SSHProfileSync.\(unique)")!

        keychain = InMemoryKeychain()
        metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let connectionStorage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: connectionDefaults,
            syncTracker: tracker,
            keychain: keychain
        )
        connections = connectionStorage
        storage = SSHProfileStorage(
            userDefaults: profileDefaults,
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connectionStorage
        )
    }

    private func makeProfile(host: String = "bastion.example.com") -> SSHProfile {
        SSHProfile(
            name: "Bastion",
            host: host,
            port: 22,
            username: "deploy",
            authMethod: .password
        )
    }

    private func linkConnection(to profile: SSHProfile) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: profile.toSSHConfiguration())
        connection.sshConfig = profile.toSSHConfiguration()
        connection.sshProfileId = profile.id
        connections.addConnection(connection)
        return connection
    }

    @Test("Editing a profile rewrites the configuration of every connection linked to it")
    func editFansOutToLinkedConnections() {
        var profile = makeProfile()
        #expect(storage.addProfile(profile))
        let first = linkConnection(to: profile)
        let second = linkConnection(to: profile)

        profile.host = "new.example.com"
        #expect(storage.updateProfile(profile))

        #expect(connections.loadConnection(id: first.id)?.resolvedSSHConfig.host == "new.example.com")
        #expect(connections.loadConnection(id: second.id)?.resolvedSSHConfig.host == "new.example.com")
    }

    @Test("A connection using another profile is untouched by the edit")
    func editLeavesUnrelatedConnectionsAlone() {
        var edited = makeProfile()
        let other = makeProfile(host: "other.example.com")
        #expect(storage.addProfile(edited))
        #expect(storage.addProfile(other))
        let unrelated = linkConnection(to: other)

        edited.host = "new.example.com"
        #expect(storage.updateProfile(edited))

        #expect(connections.loadConnection(id: unrelated.id)?.resolvedSSHConfig.host == "other.example.com")
    }

    @Test("Deleting a profile leaves its connections with the same tunnel, inline")
    func deleteConvertsLinkedConnectionsToInline() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        storage.saveSSHPassword("hunter2", for: profile.id)
        let connection = linkConnection(to: profile)

        #expect(storage.deleteProfile(profile))

        let reloaded = connections.loadConnection(id: connection.id)
        #expect(reloaded?.sshProfileId == nil)
        #expect(reloaded?.resolvedSSHConfig.host == "bastion.example.com")
        #expect(reloaded?.resolvedSSHConfig.enabled == true)
        if case .inline = reloaded?.sshTunnelMode {} else {
            Issue.record("Expected the connection to fall back to an inline tunnel")
        }
    }

    @Test("Deleting a profile moves its secrets into the connections that were using it")
    func deleteAdoptsSecretsIntoConnections() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        storage.saveSSHPassword("hunter2", for: profile.id)
        let connection = linkConnection(to: profile)

        #expect(storage.deleteProfile(profile))

        #expect(connections.loadSSHPassword(for: connection.id) == "hunter2")
        #expect(storage.loadSSHPassword(for: profile.id) == nil)
    }

    @Test("Deleting a profile removes every keychain item it owns")
    func deleteRemovesAllProfileSecrets() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        storage.saveSSHPassword("hunter2", for: profile.id)
        storage.saveKeyPassphrase("passphrase", for: profile.id)
        storage.saveTOTPSecret("BASE32SECRET", for: profile.id)

        #expect(storage.deleteProfile(profile))

        #expect(storage.loadSSHPassword(for: profile.id) == nil)
        #expect(storage.loadKeyPassphrase(for: profile.id) == nil)
        #expect(storage.loadTOTPSecret(for: profile.id) == nil)
    }

    @Test("Deleting a profile records its tombstone after the profile list is persisted")
    func deleteRecordsTombstoneAfterPersisting() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        #expect(metadata.tombstones(for: .sshProfile).isEmpty)

        #expect(storage.deleteProfile(profile))

        #expect(metadata.tombstones(for: .sshProfile).contains { $0.id == profile.id.uuidString })
    }

    @Test("A save that cannot run reports the failure instead of returning silently")
    func saveReportsFailureAfterFailedLoad() {
        let profileDefaults = UserDefaults(
            suiteName: "com.TablePro.tests.SSHProfileCorrupt.\(UUID().uuidString)"
        )!
        profileDefaults.set(Data("not json".utf8), forKey: "com.TablePro.sshProfiles")
        let corrupted = SSHProfileStorage(
            userDefaults: profileDefaults,
            keychain: InMemoryKeychain(),
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: connections
        )

        #expect(corrupted.loadProfiles().isEmpty)
        #expect(corrupted.lastLoadFailed)
        #expect(!corrupted.addProfile(makeProfile()))
        #expect(!corrupted.updateProfile(makeProfile()))
        #expect(!corrupted.deleteProfile(makeProfile()))
    }

    @Test("A stale snapshot is replaced by the profile's current values before the link is cut")
    func deleteConvertsFromTheCurrentProfileNotTheStaleSnapshot() {
        let profile = makeProfile(host: "current.example.com")
        #expect(storage.addProfile(profile))
        storage.saveSSHPassword("rotated", for: profile.id)

        var stale = profile.toSSHConfiguration()
        stale.host = "decommissioned.example.com"
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: stale)
        connection.sshConfig = stale
        connection.sshProfileId = profile.id
        connections.addConnection(connection)

        #expect(storage.deleteProfile(profile))

        let reloaded = connections.loadConnection(id: connection.id)
        #expect(reloaded?.resolvedSSHConfig.host == "current.example.com")
        #expect(connections.loadSSHPassword(for: connection.id) == "rotated")
    }

    @Test("A profile whose secrets cannot be read is not deleted, and its connections keep the link")
    func deleteRefusesWhenSecretsAreUnreadable() {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lockedKeychain = UnreadableSecretKeychain()
        let lockedConnections = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: UserDefaults(suiteName: "com.TablePro.tests.SSHProfileLockedConn.\(unique)")!,
            keychain: lockedKeychain
        )
        let lockedStorage = SSHProfileStorage(
            userDefaults: UserDefaults(suiteName: "com.TablePro.tests.SSHProfileLocked.\(unique)")!,
            keychain: lockedKeychain,
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: lockedConnections
        )

        let profile = makeProfile()
        #expect(lockedStorage.addProfile(profile))
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: profile.toSSHConfiguration())
        connection.sshProfileId = profile.id
        lockedConnections.addConnection(connection)

        #expect(!lockedStorage.deleteProfile(profile))
        #expect(lockedStorage.profile(for: profile.id) != nil)
        #expect(lockedConnections.loadConnection(id: connection.id)?.sshProfileId == profile.id)
    }

    @Test("Resolving a linked profile answers with the profile's current values")
    func refreshingLinkedProfileReadsThroughToTheProfile() {
        var profile = makeProfile()
        #expect(storage.addProfile(profile))
        var stale = profile.toSSHConfiguration()
        stale.host = "old.example.com"
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: stale)

        profile.host = "new.example.com"
        #expect(storage.updateProfile(profile))

        #expect(storage.refreshingLinkedProfile(connection).resolvedSSHConfig.host == "new.example.com")
    }
}
