import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct PluginSecureFieldMigrationTests {
    private static let fieldId = "mongoAWSSessionToken"
    private static let doneKey = "com.TablePro.pluginSecureFieldsMovedToKeychain"

    private let keychain = ScopeRecordingKeychain()
    private let suite: EphemeralDefaults
    private let fileURL: URL
    private let storage: ConnectionStorage

    init() throws {
        suite = try EphemeralDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("plugin-secure-fields-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("connections.json")
        storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: suite.defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults)),
            keychain: keychain,
            appEvents: AppEvents(),
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: InMemoryKeychain()))
        )
    }

    private func tokenKey(_ id: UUID) -> String {
        "com.TablePro.plugin.\(Self.fieldId).\(id.uuidString)"
    }

    private func legacyConnection() -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(type: .mongodb)
        connection.additionalFields = [Self.fieldId: "FQoG"]
        return connection
    }

    private func fieldOnDisk(_ id: UUID) -> String? {
        storage.invalidateCache()
        return storage.loadConnection(id: id)?.additionalFields[Self.fieldId]
    }

    private var isDone: Bool {
        suite.defaults.bool(forKey: Self.doneKey)
    }

    @Test("A plain-text secure field moves to the Keychain and leaves the record")
    func fieldMovesToTheKeychain() {
        let connection = legacyConnection()
        #expect(storage.saveConnections([connection]))

        storage.migratePluginSecureFieldsIfNeeded()

        #expect(keychain.syncedValue(forKey: tokenKey(connection.id)) == "FQoG")
        #expect(fieldOnDisk(connection.id) == nil)
        #expect(isDone)
    }

    @Test("A field whose Keychain write fails stays in the record, and the next launch moves it")
    func failedWriteKeepsTheField() {
        let connection = legacyConnection()
        #expect(storage.saveConnections([connection]))
        keychain.failWrites(to: tokenKey(connection.id))

        storage.migratePluginSecureFieldsIfNeeded()

        #expect(fieldOnDisk(connection.id) == "FQoG")
        #expect(!isDone)

        keychain.allowWrites(to: tokenKey(connection.id))
        storage.migratePluginSecureFieldsIfNeeded()

        #expect(keychain.syncedValue(forKey: tokenKey(connection.id)) == "FQoG")
        #expect(fieldOnDisk(connection.id) == nil)
        #expect(isDone)
    }

    @Test("A value already in the Keychain wins over the plain-text copy, which only leaves the record")
    func storedValueWins() {
        let connection = legacyConnection()
        #expect(storage.saveConnections([connection]))
        keychain.seedSynced("saved-on-another-device", forKey: tokenKey(connection.id))

        storage.migratePluginSecureFieldsIfNeeded()

        #expect(keychain.syncedValue(forKey: tokenKey(connection.id)) == "saved-on-another-device")
        #expect(fieldOnDisk(connection.id) == nil)
        #expect(isDone)
    }

    @Test("A Keychain item that cannot be read keeps the plain-text field until it can")
    func unreadableItemKeepsTheField() {
        let connection = legacyConnection()
        #expect(storage.saveConnections([connection]))
        keychain.seedSynced("saved-on-another-device", forKey: tokenKey(connection.id))
        keychain.makeUnreadable(tokenKey(connection.id))

        storage.migratePluginSecureFieldsIfNeeded()

        #expect(keychain.syncedValue(forKey: tokenKey(connection.id)) == "saved-on-another-device")
        #expect(fieldOnDisk(connection.id) == "FQoG")
        #expect(!isDone)
    }

    @Test("An unreadable connections.json is not marked done, so the move runs once it reads again")
    func unreadableLibraryRetries() throws {
        try Data("not json".utf8).write(to: fileURL)

        storage.migratePluginSecureFieldsIfNeeded()
        #expect(!isDone)

        try FileManager.default.removeItem(at: fileURL)
        storage.invalidateCache()
        let connection = legacyConnection()
        #expect(storage.saveConnections([connection]))
        storage.migratePluginSecureFieldsIfNeeded()

        #expect(keychain.syncedValue(forKey: tokenKey(connection.id)) == "FQoG")
        #expect(fieldOnDisk(connection.id) == nil)
    }

    @Test("A connection whose plugin is not registered keeps the move pending")
    func unregisteredPluginKeepsItPending() {
        let known = legacyConnection()
        let unknown = TestFixtures.makeConnection(type: DatabaseType(rawValue: "UnregisteredEngine-\(UUID().uuidString)"))
        #expect(storage.saveConnections([known, unknown]))

        storage.migratePluginSecureFieldsIfNeeded()

        #expect(keychain.syncedValue(forKey: tokenKey(known.id)) == "FQoG")
        #expect(fieldOnDisk(known.id) == nil)
        #expect(!isDone)
    }

    @Test("A connections.json changed outside TablePro moves nothing into the Keychain")
    func untrustedLibraryMovesNothing() throws {
        let connection = legacyConnection()
        #expect(storage.saveConnections([connection]))
        var edited = try Data(contentsOf: fileURL)
        edited.append(contentsOf: Array(" ".utf8))
        try edited.write(to: fileURL)
        storage.invalidateCache()

        storage.migratePluginSecureFieldsIfNeeded()

        #expect(!storage.storeIsTrusted)
        #expect(keychain.syncedValue(forKey: tokenKey(connection.id)) == nil)
        #expect(fieldOnDisk(connection.id) == "FQoG")
        #expect(!isDone)
    }
}
