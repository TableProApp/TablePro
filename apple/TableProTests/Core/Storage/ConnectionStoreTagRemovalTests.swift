import CryptoKit
import Foundation
import os
@testable import TablePro
import TableProSyncTransport
import Testing

// A build from before the record existed: it holds the key and remembers nothing.
private struct KeyOnlySource: IntegrityKeySource {
    let source: StoredIntegrityKeySource

    func key() -> SymmetricKey? { source.key() }
}

private struct StampedRow: Codable, Equatable {
    let id: Int
    let name: String
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

    private func makeStore(at fileURL: URL) -> IntegrityStampedFileStore<StampedRow> {
        IntegrityStampedFileStore(
            fileURL: fileURL,
            label: "rows.json",
            logger: Logger(subsystem: "com.TablePro", category: "ConnectionStoreTagRemovalTests"),
            userSaveEstablishesTrust: true,
            integrity: integrity
        )
    }

    private func saveTwice(_ store: IntegrityStampedFileStore<StampedRow>) {
        #expect(store.load()?.isEmpty == true)
        #expect(store.save([StampedRow(id: 1, name: "One")]))
        #expect(store.save([StampedRow(id: 1, name: "One"), StampedRow(id: 2, name: "Two")]))
    }

    @Test("A record that does not decode is skipped and written back unchanged by the next save")
    func undecodableRecordSurvivesASave() throws {
        let fileURL = try makeFileURL()
        let unreadable = #"{"id":"seven","port":5432,"ratio":0.25,"flags":[true,null],"nested":{"big":9007199254740993}}"#
        try Data(#"[{"id":1,"name":"One"},\#(unreadable),{"id":2,"name":"Two"}]"#.utf8).write(to: fileURL)
        let store = makeStore(at: fileURL)

        #expect(store.load() == [StampedRow(id: 1, name: "One"), StampedRow(id: 2, name: "Two")])
        #expect(store.save([StampedRow(id: 1, name: "One")]))

        let written = try Data(contentsOf: fileURL)
        let rows = try #require(try JSONSerialization.jsonObject(with: written) as? [NSDictionary])
        let original = try #require(try JSONSerialization.jsonObject(with: Data(unreadable.utf8)) as? NSDictionary)
        #expect(rows.count == 2)
        #expect(rows.last == original)
        let text = try #require(String(bytes: written, encoding: .utf8))
        #expect(text.contains("9007199254740993"))
        #expect(makeStore(at: fileURL).load() == [StampedRow(id: 1, name: "One")])
    }

    @Test("One connection that does not decode keeps the rest of connections.json")
    func undecodableConnectionKeepsTheLibrary() throws {
        let fileURL = try makeFileURL()
        let suite = try EphemeralDefaults()
        let connection = TestFixtures.makeConnection(name: "Kept")
        let stored = try #require(String(bytes: JSONEncoder().encode(StoredConnection(from: connection)), encoding: .utf8))
        let unreadable = #"{"id":"not-a-uuid","name":"From a newer build"}"#
        try Data("[\(stored),\(unreadable)]".utf8).write(to: fileURL)
        let storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: suite.defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults)),
            keychain: keychain,
            integrity: integrity
        )

        #expect(storage.loadConnections().map { $0.name } == ["Kept"])
        #expect(!storage.lastLoadFailed)

        var renamed = connection
        renamed.name = "Renamed"
        #expect(storage.saveConnections([renamed]))

        let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [NSDictionary])
        #expect(rows.count == 2)
        #expect(rows.last?["name"] as? String == "From a newer build")
    }

    @Test("A save keeps the file it replaces, with its tag, as the backup")
    func saveKeepsThePreviousFileAsBackup() throws {
        let fileURL = try makeFileURL()
        let store = makeStore(at: fileURL)
        #expect(store.load()?.isEmpty == true)
        #expect(store.save([StampedRow(id: 1, name: "One")]))
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
        let first = try Data(contentsOf: fileURL)
        let firstTag = try Data(contentsOf: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(store.save([StampedRow(id: 2, name: "Two")]))

        #expect(try Data(contentsOf: store.backupURL) == first)
        #expect(try Data(contentsOf: ConnectionStoreIntegrity.tagURL(for: store.backupURL)) == firstTag)
    }

    @Test("A file that no longer parses is restored from the backup, which keeps its own trust")
    func damagedFileIsRestoredFromBackup() throws {
        let fileURL = try makeFileURL()
        saveTwice(makeStore(at: fileURL))
        let damaged = Data(#"[{"id":1,"name":"One"},{"id":2"#.utf8)
        try damaged.write(to: fileURL)

        let store = makeStore(at: fileURL)

        #expect(store.load() == [StampedRow(id: 1, name: "One")])
        #expect(store.isTrusted)
        let backup = try Data(contentsOf: store.backupURL)
        #expect(try Data(contentsOf: store.unreadableURL) == damaged)
        #expect(try Data(contentsOf: fileURL) == backup)
    }

    @Test("A file that no longer parses never replaces the backup")
    func damagedFileNeverBecomesTheBackup() throws {
        let fileURL = try makeFileURL()
        let store = makeStore(at: fileURL)
        saveTwice(store)
        let backup = try Data(contentsOf: store.backupURL)
        let backupTag = try Data(contentsOf: ConnectionStoreIntegrity.tagURL(for: store.backupURL))
        try Data("not json".utf8).write(to: fileURL)

        #expect(store.save([StampedRow(id: 3, name: "Three")]))

        #expect(try Data(contentsOf: store.backupURL) == backup)
        #expect(try Data(contentsOf: ConnectionStoreIntegrity.tagURL(for: store.backupURL)) == backupTag)
    }

    @Test("A backup with no tag is restored untrusted, even on a store never tagged")
    func untaggedBackupIsRestoredUntrusted() throws {
        let stampedURL = try makeFileURL()
        let stamped = makeStore(at: stampedURL)
        saveTwice(stamped)
        try FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: stamped.backupURL))
        try Data().write(to: stampedURL)

        let reloaded = makeStore(at: stampedURL)
        #expect(reloaded.load() == [StampedRow(id: 1, name: "One")])
        #expect(!reloaded.isTrusted)

        let neverTaggedURL = try makeFileURL()
        let neverTagged = makeStore(at: neverTaggedURL)
        try JSONEncoder().encode([StampedRow(id: 1, name: "Planted")]).write(to: neverTagged.backupURL)
        try Data("not json".utf8).write(to: neverTaggedURL)

        #expect(neverTagged.load() == [StampedRow(id: 1, name: "Planted")])
        #expect(!neverTagged.isTrusted)
        #expect(!FileManager.default.fileExists(atPath: ConnectionStoreIntegrity.tagURL(for: neverTaggedURL).path))

        let loadedAgain = makeStore(at: neverTaggedURL)
        #expect(loadedAgain.load() == [StampedRow(id: 1, name: "Planted")])
        #expect(!loadedAgain.isTrusted)
    }

    @Test("A store changed outside TablePro sets its unreadable records aside, so a save never signs them")
    func untrustedStoreSetsUnreadableRecordsAside() throws {
        let fileURL = try makeFileURL()
        let store = makeStore(at: fileURL)
        #expect(store.load()?.isEmpty == true)
        #expect(store.save([StampedRow(id: 1, name: "One")]))
        let unreadable = #"{"id":"planted","command":"curl"}"#
        try Data(#"[{"id":1,"name":"One"},\#(unreadable)]"#.utf8).write(to: fileURL)

        let reloaded = makeStore(at: fileURL)
        #expect(reloaded.load() == [StampedRow(id: 1, name: "One")])
        #expect(!reloaded.isTrusted)
        #expect(reloaded.save([StampedRow(id: 1, name: "One")]))

        let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [NSDictionary])
        #expect(rows.count == 1)
        let setAside = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: reloaded.unreadableRecordsURL)) as? [NSDictionary]
        )
        #expect(setAside.first?["id"] as? String == "planted")
    }

    @Test("Loading the same changed file again sets its unreadable records aside once")
    func settingAsideTwiceKeepsOneCopy() throws {
        let fileURL = try makeFileURL()
        let store = makeStore(at: fileURL)
        #expect(store.load()?.isEmpty == true)
        #expect(store.save([StampedRow(id: 1, name: "One")]))
        try Data(#"[{"id":1,"name":"One"},{"id":"planted"}]"#.utf8).write(to: fileURL)

        _ = makeStore(at: fileURL).load()
        _ = makeStore(at: fileURL).load()

        let setAside = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.unreadableRecordsURL)) as? [NSDictionary]
        )
        #expect(setAside.count == 1)
    }

    @Test("Unreadable records that cannot be set aside are written back and never signed")
    func recordsThatCannotBeSetAsideStayUnsigned() throws {
        let fileURL = try makeFileURL()
        let store = makeStore(at: fileURL)
        #expect(store.load()?.isEmpty == true)
        #expect(store.save([StampedRow(id: 1, name: "One")]))
        try Data(#"[{"id":1,"name":"One"},{"id":"planted"}]"#.utf8).write(to: fileURL)
        try FileManager.default.createDirectory(at: store.unreadableRecordsURL, withIntermediateDirectories: true)

        let reloaded = makeStore(at: fileURL)
        #expect(reloaded.load() == [StampedRow(id: 1, name: "One")])
        #expect(reloaded.save([StampedRow(id: 1, name: "One")]))

        #expect(!reloaded.isTrusted)
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [NSDictionary])
        #expect(rows.count == 2)
        let again = makeStore(at: fileURL)
        _ = again.load()
        #expect(!again.isTrusted)
    }
}
