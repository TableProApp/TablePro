//
//  CredentialProfileStorageTests.swift
//  TableProTests
//

import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

@Suite("Credential profile storage")
@MainActor
struct CredentialProfileStorageTests {
    private let storage: CredentialProfileStorage
    private let connections: ConnectionStorage
    private let keychain: InMemoryKeychain
    private let metadata: SyncMetadataStorage
    private let directory: URL

    init() {
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        keychain = InMemoryKeychain()
        metadata = SyncMetadataStorage(
            userDefaults: UserDefaults(suiteName: "com.TablePro.tests.CredProfileSync.\(unique)")!
        )
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let connectionStorage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: UserDefaults(suiteName: "com.TablePro.tests.CredProfileConn.\(unique)")!,
            syncTracker: tracker,
            keychain: keychain
        )
        connections = connectionStorage
        storage = CredentialProfileStorage(
            fileURL: directory.appendingPathComponent("credentialProfiles.json"),
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connectionStorage
        )
    }

    private func makeProfile(name: String = "Prod reader", username: String = "app_reader") -> CredentialProfile {
        CredentialProfile(name: name, username: username, passwordMode: .stored)
    }

    private func linkConnection(to profile: CredentialProfile) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection()
        connection.credentialMode = .profile(id: profile.id)
        connection.username = profile.username
        connections.addConnection(connection)
        return connection
    }

    @Test("A profile round trips through the file")
    func roundTrip() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))

        let reloaded = storage.profile(for: profile.id)
        #expect(reloaded?.name == "Prod reader")
        #expect(reloaded?.username == "app_reader")
        #expect(reloaded?.passwordMode == .stored)
    }

    @Test("Rotating the username reaches every connection linked to the profile")
    func usernameIsWrittenThrough() {
        var profile = makeProfile()
        #expect(storage.addProfile(profile))
        let first = linkConnection(to: profile)
        let second = linkConnection(to: profile)

        profile.username = "rotated_reader"
        #expect(storage.updateProfile(profile))

        #expect(connections.loadConnection(id: first.id)?.username == "rotated_reader")
        #expect(connections.loadConnection(id: second.id)?.username == "rotated_reader")
    }

    @Test("A connection using another profile is untouched by the edit")
    func unrelatedConnectionsAreUntouched() {
        var edited = makeProfile()
        let other = makeProfile(name: "Analytics", username: "analytics")
        #expect(storage.addProfile(edited))
        #expect(storage.addProfile(other))
        let unrelated = linkConnection(to: other)

        edited.username = "rotated"
        #expect(storage.updateProfile(edited))

        #expect(connections.loadConnection(id: unrelated.id)?.username == "analytics")
    }

    @Test("The password lives once, under the profile")
    func passwordIsStoredOnce() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        #expect(storage.savePassword("hunter2", for: profile.id))
        let connection = linkConnection(to: profile)

        #expect(storage.loadPassword(for: profile.id) == "hunter2")
        #expect(connections.loadPassword(for: connection.id) == nil)
    }

    @Test("Deleting a profile leaves its connections with the same credentials, inline")
    func deleteConvertsLinkedConnectionsToInline() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        #expect(storage.savePassword("hunter2", for: profile.id))
        let connection = linkConnection(to: profile)

        #expect(storage.deleteProfile(profile))

        let reloaded = connections.loadConnection(id: connection.id)
        #expect(reloaded?.credentialMode == .inline)
        #expect(reloaded?.username == "app_reader")
        #expect(connections.loadPassword(for: connection.id) == "hunter2")
        #expect(storage.loadPassword(for: profile.id) == nil)
    }

    @Test("Deleting a profile records its tombstone after the file is written")
    func deleteRecordsTombstoneAfterPersisting() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        #expect(metadata.tombstones(for: .credentialProfile).isEmpty)

        #expect(storage.deleteProfile(profile))

        #expect(metadata.tombstones(for: .credentialProfile).contains { $0.id == profile.id.uuidString })
    }

    @Test("A profile whose secrets cannot be read is not deleted")
    func deleteRefusesWhenSecretsAreUnreadable() {
        let unique = UUID().uuidString
        let lockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
        try? FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)

        let lockedKeychain = UnreadableSecretKeychain()
        let lockedConnections = ConnectionStorage(
            fileURL: lockedDirectory.appendingPathComponent("connections.json"),
            userDefaults: UserDefaults(suiteName: "com.TablePro.tests.CredLockedConn.\(unique)")!,
            keychain: lockedKeychain
        )
        let lockedStorage = CredentialProfileStorage(
            fileURL: lockedDirectory.appendingPathComponent("credentialProfiles.json"),
            keychain: lockedKeychain,
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: lockedConnections
        )

        let profile = makeProfile()
        #expect(lockedStorage.addProfile(profile))
        var connection = TestFixtures.makeConnection()
        connection.credentialMode = .profile(id: profile.id)
        lockedConnections.addConnection(connection)

        #expect(!lockedStorage.deleteProfile(profile))
        #expect(lockedStorage.profile(for: profile.id) != nil)
        #expect(lockedConnections.loadConnection(id: connection.id)?.credentialMode == .profile(id: profile.id))
    }

    @Test("A file that will not decode is never overwritten with an empty list")
    func corruptFileRefusesEveryWrite() {
        let unique = UUID().uuidString
        let corruptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
        try? FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let fileURL = corruptDirectory.appendingPathComponent("credentialProfiles.json")
        try? Data("not json".utf8).write(to: fileURL)

        let corrupted = CredentialProfileStorage(
            fileURL: fileURL,
            keychain: InMemoryKeychain(),
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: connections
        )

        #expect(corrupted.loadProfiles().isEmpty)
        #expect(corrupted.lastLoadFailed)
        #expect(!corrupted.addProfile(makeProfile()))
        #expect(!corrupted.updateProfile(makeProfile()))
        #expect(!corrupted.deleteProfile(makeProfile()))
        #expect((try? Data(contentsOf: fileURL)) == Data("not json".utf8))
    }

    /// The file carries its own tag because a profile can name a shell command to read the
    /// password from, and `ConnectionCredentialResolver` refuses to run one from a file something
    /// else wrote.
    @Test("A profiles file edited outside TablePro is not trusted")
    func editedFileIsNotTrusted() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        #expect(storage.storeIsTrusted)

        let fileURL = directory.appendingPathComponent("credentialProfiles.json")
        var raw = try? Data(contentsOf: fileURL)
        raw?.append(contentsOf: [0x20])
        try? raw?.write(to: fileURL)

        let reopened = CredentialProfileStorage(
            fileURL: fileURL,
            keychain: keychain,
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: connections
        )
        _ = reopened.loadProfiles()

        #expect(!reopened.storeIsTrusted)
    }

    /// Both halves of one hazard: a profiles file something else wrote holds a password source
    /// that can name a shell command, and `connections.json` treats a user save as consent to
    /// trust itself. Nothing may move a source from the first into the second, and no save of the
    /// first may sign the rest of what is in it.
    @Test("A save never blesses a profiles file TablePro did not write")
    func saveDoesNotEstablishTrustForAPlantedFile() {
        let fileURL = directory.appendingPathComponent("planted.json")
        let planted = CredentialProfile(
            name: "Planted",
            passwordMode: .source(.command(shell: "echo owned"))
        )
        try? JSONEncoder().encode([planted]).write(to: fileURL)

        let store = CredentialProfileStorage(
            fileURL: fileURL,
            keychain: keychain,
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: connections
        )
        #expect(store.loadProfiles().count == 1)
        #expect(!store.storeIsTrusted)

        #expect(store.addProfile(makeProfile(name: "Mine")))
        #expect(!store.storeIsTrusted)
    }

    @Test("Deleting an untrusted profile never hands its password source to a connection")
    func deleteDoesNotCarryAnUntrustedPasswordSource() {
        let fileURL = directory.appendingPathComponent("planted-linked.json")
        let planted = CredentialProfile(
            name: "Planted",
            passwordMode: .source(.command(shell: "echo owned"))
        )
        try? JSONEncoder().encode([planted]).write(to: fileURL)

        let store = CredentialProfileStorage(
            fileURL: fileURL,
            keychain: keychain,
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: connections
        )
        var connection = TestFixtures.makeConnection()
        connection.credentialMode = .profile(id: planted.id)
        connections.addConnection(connection)
        #expect(store.loadProfiles().count == 1)
        #expect(!store.storeIsTrusted)

        #expect(store.deleteProfile(planted))

        let reloaded = connections.loadConnection(id: connection.id)
        #expect(reloaded?.passwordSource == nil)
        #expect(reloaded?.promptForPassword == true)
    }

    @Test("Duplicating a linked connection shares the profile instead of copying the password")
    func duplicateSharesTheProfile() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        #expect(storage.savePassword("hunter2", for: profile.id))
        let connection = linkConnection(to: profile)

        let duplicate = connections.duplicateConnection(connection)

        #expect(duplicate?.credentialMode == .profile(id: profile.id))
        #expect(connections.loadPassword(for: duplicate?.id ?? UUID()) == nil)
    }

    @Test("Counting the connections that use a profile reads storage, not a cached list")
    func connectionsUsingCountsLinkedConnections() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        _ = linkConnection(to: profile)
        _ = linkConnection(to: profile)

        #expect(storage.connectionsUsing(profile.id).count == 2)
    }
}
