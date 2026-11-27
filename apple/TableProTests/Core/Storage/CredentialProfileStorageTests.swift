//
//  CredentialProfileStorageTests.swift
//  TableProTests
//

import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

@MainActor
struct CredentialProfileStorageTests {
    private let pool = EphemeralDefaultsPool()
    private let storage: CredentialProfileStorage
    private let connections: ConnectionStorage
    private let keychain: InMemoryKeychain
    private let directory: URL
    /// The system keychain is out of reach in a test host, so every store it stamps would read back
    /// untrusted and the trust assertions here would pass or fail on the environment.
    private let integrity: ConnectionStoreIntegrity

    private let tracker = SyncJournalRecorder()

    init() throws {
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        keychain = InMemoryKeychain()
        integrity = ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        let connectionStorage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: try pool.make().defaults,
            syncJournal: tracker.journal,
            keychain: keychain,
            integrity: integrity
        )
        connections = connectionStorage
        storage = CredentialProfileStorage(
            keychain: keychain,
            syncJournal: tracker.journal,
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
        #expect(tracker.tombstones(for: .credentialProfile).isEmpty)

        #expect(storage.deleteProfile(profile))

        #expect(tracker.tombstones(for: .credentialProfile).contains { $0.id == profile.id.uuidString })
    }

    @Test("A profile whose secrets cannot be read is not deleted")
    func deleteRefusesWhenSecretsAreUnreadable() throws {
        let unique = UUID().uuidString
        let lockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
        try? FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)

        let lockedKeychain = UnreadableSecretKeychain()
        let lockedConnections = ConnectionStorage(
            fileURL: lockedDirectory.appendingPathComponent("connections.json"),
            userDefaults: try pool.make().defaults,
            keychain: lockedKeychain
        )
        let lockedStorage = CredentialProfileStorage(
            keychain: lockedKeychain,
            syncJournal: SyncHostJournal(),
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

    // A library of its own in a new folder, first read with `profiles` already in its credentialProfiles.json, as a
    // build before the core left it.
    private func freshLibrary(
        credentialProfiles: Data? = nil
    ) throws -> (connections: ConnectionStorage, profiles: CredentialProfileStorage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let credentialProfiles {
            try credentialProfiles.write(to: folder.appendingPathComponent("credentialProfiles.json"))
        }
        let connections = ConnectionStorage(
            fileURL: folder.appendingPathComponent("connections.json"),
            userDefaults: try pool.make().defaults,
            syncJournal: SyncHostJournal(),
            keychain: keychain,
            integrity: integrity
        )
        let profiles = CredentialProfileStorage(keychain: keychain, syncJournal: SyncHostJournal(), connectionStorage: connections)
        return (connections, profiles, folder)
    }

    @Test("A profiles file that will not decode leaves the library unread and never written over")
    func corruptFileRefusesEveryWrite() throws {
        let library = try freshLibrary(credentialProfiles: Data("not json".utf8))

        #expect(library.profiles.loadProfiles().isEmpty)
        #expect(library.profiles.lastLoadFailed)
        #expect(!library.profiles.addProfile(makeProfile()))
        #expect(!library.profiles.updateProfile(makeProfile()))
        #expect(!library.profiles.deleteProfile(makeProfile()))
        #expect((try? Data(contentsOf: library.folder.appendingPathComponent("credentialProfiles.json"))) == Data("not json".utf8))
    }

    // A profile can name a shell command to read the password from, and `ConnectionCredentialResolver` refuses to run
    // one from profiles something else wrote.
    @Test("A profiles file edited outside TablePro is not trusted once the library takes the edit in")
    func editedFileIsNotTrusted() throws {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        #expect(storage.storeIsTrusted)

        let fileURL = directory.appendingPathComponent("credentialProfiles.json")
        var raw = try Data(contentsOf: fileURL)
        raw.append(contentsOf: [0x20])
        try raw.write(to: fileURL)

        let reopened = CredentialProfileStorage(
            keychain: keychain,
            syncJournal: SyncHostJournal(),
            connectionStorage: ConnectionStorage(
                fileURL: directory.appendingPathComponent("connections.json"),
                userDefaults: try pool.make().defaults,
                syncJournal: SyncHostJournal(),
                keychain: keychain,
                integrity: integrity
            )
        )

        #expect(reopened.profile(for: profile.id) != nil)
        #expect(!reopened.storeIsTrusted)
    }

    // A profiles file something else wrote holds a password source that can name a shell command, and a person's
    // connection save vouches for the library. Neither that save nor a profile save may vouch for the profiles.
    @Test("No save vouches for profiles TablePro did not write")
    func saveDoesNotEstablishTrustForAPlantedFile() throws {
        let planted = CredentialProfile(name: "Planted", passwordMode: .source(.command(shell: "echo owned")))
        let library = try freshLibrary(credentialProfiles: try JSONEncoder().encode([planted]))

        #expect(library.profiles.loadProfiles().count == 1)
        #expect(!library.profiles.storeIsTrusted)

        #expect(library.profiles.addProfile(makeProfile(name: "Mine")))
        #expect(library.connections.addConnection(TestFixtures.makeConnection()))
        #expect(library.connections.storeIsTrusted)
        #expect(!library.profiles.storeIsTrusted)
    }

    @Test("Deleting an untrusted profile never hands its password source to a connection")
    func deleteDoesNotCarryAnUntrustedPasswordSource() throws {
        let planted = CredentialProfile(name: "Planted", passwordMode: .source(.command(shell: "echo owned")))
        let library = try freshLibrary(credentialProfiles: try JSONEncoder().encode([planted]))
        var connection = TestFixtures.makeConnection()
        connection.credentialMode = .profile(id: planted.id)
        library.connections.addConnection(connection)
        #expect(library.profiles.loadProfiles().count == 1)
        #expect(!library.profiles.storeIsTrusted)

        #expect(library.profiles.deleteProfile(planted))

        let reloaded = library.connections.loadConnection(id: connection.id)
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
