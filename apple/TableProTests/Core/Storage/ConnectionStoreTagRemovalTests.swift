import CryptoKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

// A build from before the record existed: it holds the key and remembers nothing.
private struct KeyOnlySource: IntegrityKeySource {
    let source: StoredIntegrityKeySource

    func key() -> SymmetricKey? { source.key() }
}

@MainActor
struct ConnectionStoreTagRemovalTests {
    private let keychain = InMemoryKeychain()

    private var integrity: ConnectionStoreIntegrity {
        ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
    }

    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("tag-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("connections.json")
    }

    @Test("A store this device tagged reads as modified once its tag is deleted")
    func deletedTagIsNotAnUnstampedStore() throws {
        let fileURL = try makeFileURL()
        let data = Data(#"[{"name":"Prod"}]"#.utf8)
        try #require(integrity.stamp(data, fileURL: fileURL))

        try FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(integrity.verify(data, fileURL: fileURL) == .modified)
    }

    @Test("An emptied tag on a tagged store reads as modified")
    func emptiedTagIsModified() throws {
        let fileURL = try makeFileURL()
        let data = Data("[]".utf8)
        try #require(integrity.stamp(data, fileURL: fileURL))

        try Data().write(to: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(integrity.verify(data, fileURL: fileURL) == .modified)
    }

    @Test("A store that was never tagged still reads as unstamped")
    func neverTaggedStoreIsUnstamped() throws {
        let fileURL = try makeFileURL()

        #expect(integrity.verify(Data("[]".utf8), fileURL: fileURL) == .unstamped)
    }

    @Test("A tag an older build wrote is recorded the first time it verifies")
    func olderBuildTagIsRecordedOnVerify() throws {
        let fileURL = try makeFileURL()
        let data = Data(#"[{"name":"Prod"}]"#.utf8)
        let older = ConnectionStoreIntegrity(keySource: KeyOnlySource(source: StoredIntegrityKeySource(store: keychain)))
        try #require(older.stamp(data, fileURL: fileURL))

        #expect(integrity.verify(data, fileURL: fileURL) == .trusted)
        try FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(integrity.verify(data, fileURL: fileURL) == .modified)
    }

    @Test("connections.json rewritten with its tag deleted is not trusted on the next load")
    func rewrittenStoreWithoutTagIsUntrusted() throws {
        let fileURL = try makeFileURL()
        let suite = try EphemeralDefaults()
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults))
        let first = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: suite.defaults,
            syncTracker: tracker,
            keychain: keychain,
            integrity: integrity
        )
        var connection = TestFixtures.makeConnection()
        connection.localOnly = true
        #expect(first.saveConnections([connection]))
        #expect(first.storeIsTrusted)

        var planted = connection
        planted.name = "Planted"
        try JSONEncoder().encode([StoredConnection(from: planted)]).write(to: fileURL)
        try FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: fileURL))

        let reloaded = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: suite.defaults,
            syncTracker: tracker,
            keychain: keychain,
            integrity: integrity
        )
        #expect(reloaded.loadConnections().first?.name == "Planted")
        #expect(!reloaded.storeIsTrusted)
    }

    @Test("connections.json from before the tag existed is adopted and trusted")
    func untaggedUpgradeIsAdopted() throws {
        let fileURL = try makeFileURL()
        let suite = try EphemeralDefaults()
        try JSONEncoder().encode([StoredConnection(from: TestFixtures.makeConnection())]).write(to: fileURL)

        let storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: suite.defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults)),
            keychain: keychain,
            integrity: integrity
        )

        #expect(storage.loadConnections().count == 1)
        #expect(storage.storeIsTrusted)
    }
}
