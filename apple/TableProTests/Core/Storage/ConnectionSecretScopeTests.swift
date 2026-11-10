import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

// One synced and one local value per key, as the keychain holds them. Nothing here removes a synced value except delete.
private final class ScopeRecordingKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var synced: [String: String] = [:]
    private var local: [String: String] = [:]
    private var unreadableKeys: Set<String> = []
    private var failingKeys: Set<String> = []

    func seedSynced(_ value: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        synced[key] = value
    }

    func seedLocal(_ value: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        local[key] = value
    }

    func makeUnreadable(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        unreadableKeys.insert(key)
    }

    func makeReadable(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        unreadableKeys.remove(key)
    }

    func failWrites(to key: String) {
        lock.lock()
        defer { lock.unlock() }
        failingKeys.insert(key)
    }

    func syncedValue(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return synced[key]
    }

    func localValue(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return local[key]
    }

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        writeString(value, forKey: key, deviceOnly: false)
    }

    // Password sync is on in this model, so a write that is not device-only is a synced one.
    @discardableResult
    func writeString(_ value: String, forKey key: String, deviceOnly: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failingKeys.contains(key) else { return false }
        if deviceOnly {
            local[key] = value
        } else {
            synced[key] = value
            local[key] = nil
        }
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        readStringResult(forKey: key, deviceOnly: false)
    }

    func readStringResult(forKey key: String, deviceOnly: Bool) -> KeychainStringResult {
        lock.lock()
        defer { lock.unlock() }
        guard !unreadableKeys.contains(key) else { return .locked }
        let value = deviceOnly ? local[key] ?? synced[key] : synced[key] ?? local[key]
        return value.map { .found($0) } ?? .notFound
    }

    func delete(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        synced[key] = nil
        local[key] = nil
    }
}

@MainActor
struct ConnectionSecretScopeTests {
    private let keychain = ScopeRecordingKeychain()
    private let suite: EphemeralDefaults
    private let storage: ConnectionStorage

    init() throws {
        suite = try EphemeralDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("secret-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: suite.defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults)),
            keychain: keychain,
            appEvents: AppEvents(),
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: InMemoryKeychain()))
        )
    }

    private func passwordKey(_ id: UUID) -> String { "com.TablePro.password.\(id.uuidString)" }
    private func totpKey(_ id: UUID) -> String { "com.TablePro.totpsecret.\(id.uuidString)" }
    private func sslKey(_ id: UUID) -> String { "com.TablePro.sslkeypassphrase.\(id.uuidString)" }

    private func makeConnection(localOnly: Bool) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection()
        connection.localOnly = localOnly
        return connection
    }

    @Test("A Local only connection's secrets are written device-only")
    func localOnlySecretsStayOnDevice() {
        let connection = makeConnection(localOnly: true)
        #expect(storage.addConnection(connection, password: "hunter2"))
        storage.saveTOTPSecret("JBSWY3DP", for: connection.id)
        storage.saveCloudSQLProxyServiceAccountKey("{}", for: connection.id)
        let serviceAccountKey = "com.TablePro.cloudsqlproxyserviceaccountkey.\(connection.id.uuidString)"

        #expect(keychain.localValue(forKey: passwordKey(connection.id)) == "hunter2")
        #expect(keychain.localValue(forKey: totpKey(connection.id)) == "JBSWY3DP")
        #expect(keychain.localValue(forKey: serviceAccountKey) == "{}")
        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == nil)
        #expect(keychain.syncedValue(forKey: totpKey(connection.id)) == nil)
        #expect(keychain.syncedValue(forKey: serviceAccountKey) == nil)
    }

    @Test("A synced connection's secrets follow the password sync setting")
    func syncedSecretsFollowTheSetting() {
        let connection = makeConnection(localOnly: false)
        #expect(storage.addConnection(connection, password: "hunter2"))

        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "hunter2")
        #expect(keychain.localValue(forKey: passwordKey(connection.id)) == nil)
    }

    @Test("Marking a connection Local only copies its secrets to this Mac and leaves the synced ones for other devices")
    func markingLocalOnlyCopiesAndKeepsTheSyncedSecrets() {
        let connection = makeConnection(localOnly: false)
        #expect(storage.addConnection(connection, password: "hunter2"))
        storage.saveSSLClientKeyPassphrase("passphrase", for: connection.id)

        let marked = storage.mutateConnections(ids: [connection.id]) { $0.localOnly = true }
        #expect(marked)

        #expect(keychain.localValue(forKey: passwordKey(connection.id)) == "hunter2")
        #expect(keychain.localValue(forKey: sslKey(connection.id)) == "passphrase")
        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "hunter2")
        #expect(keychain.syncedValue(forKey: sslKey(connection.id)) == "passphrase")
    }

    @Test("A Local only connection reads and changes its own copy, never the one another device synced")
    func localOnlyUsesItsOwnCopy() {
        let connection = makeConnection(localOnly: true)
        #expect(storage.saveConnections([connection]))
        keychain.seedSynced("from-another-device", forKey: passwordKey(connection.id))

        #expect(storage.loadPassword(for: connection.id) == "from-another-device")
        storage.savePassword("mine", for: connection.id)

        #expect(storage.loadPassword(for: connection.id) == "mine")
        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "from-another-device")
    }

    @Test("Putting a connection back in sync keeps the password changed while it was Local only")
    func unmarkingLocalOnlyKeepsTheNewerSecret() {
        let connection = makeConnection(localOnly: false)
        #expect(storage.addConnection(connection, password: "v1"))
        let marked = storage.mutateConnections(ids: [connection.id]) { $0.localOnly = true }
        #expect(marked)
        storage.savePassword("v2", for: connection.id)
        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "v1")

        let unmarked = storage.mutateConnections(ids: [connection.id]) { $0.localOnly = false }
        #expect(unmarked)

        #expect(storage.loadPassword(for: connection.id) == "v2")
        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "v2")

        storage.savePassword(storage.loadPassword(for: connection.id) ?? "", for: connection.id)
        #expect(storage.loadPassword(for: connection.id) == "v2")
    }

    @Test("Putting a connection back in sync leaves a secret only another device holds as it is")
    func unmarkingLocalOnlyKeepsASyncedOnlySecret() {
        let connection = makeConnection(localOnly: true)
        #expect(storage.saveConnections([connection]))
        keychain.seedSynced("from-another-device", forKey: passwordKey(connection.id))

        let unmarked = storage.mutateConnections(ids: [connection.id]) { $0.localOnly = false }
        #expect(unmarked)

        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "from-another-device")
    }

    @Test("Marking a connection Local only copies the value it was using, not an older local one")
    func markingLocalOnlyCopiesTheValueInUse() {
        let connection = makeConnection(localOnly: false)
        #expect(storage.saveConnections([connection]))
        keychain.seedLocal("older-local", forKey: passwordKey(connection.id))
        keychain.seedSynced("in-use", forKey: passwordKey(connection.id))
        #expect(storage.loadPassword(for: connection.id) == "in-use")

        let marked = storage.mutateConnections(ids: [connection.id]) { $0.localOnly = true }
        #expect(marked)

        #expect(storage.loadPassword(for: connection.id) == "in-use")
        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "in-use")
    }

    @Test("The launch move copies an older Local only connection's secrets and leaves the synced ones in place")
    func launchMoveCopiesAndKeepsTheSyncedSecrets() {
        let connection = makeConnection(localOnly: true)
        #expect(storage.saveConnections([connection]))
        keychain.seedSynced("hunter2", forKey: passwordKey(connection.id))
        keychain.seedSynced("JBSWY3DP", forKey: totpKey(connection.id))

        storage.keepLocalOnlySecretsOnDeviceIfNeeded()

        #expect(keychain.localValue(forKey: passwordKey(connection.id)) == "hunter2")
        #expect(keychain.localValue(forKey: totpKey(connection.id)) == "JBSWY3DP")
        #expect(keychain.syncedValue(forKey: passwordKey(connection.id)) == "hunter2")
        #expect(keychain.syncedValue(forKey: totpKey(connection.id)) == "JBSWY3DP")
    }

    @Test("The launch move runs again when a secret could not be read")
    func launchMoveRetriesAfterAnUnreadableSecret() {
        let connection = makeConnection(localOnly: true)
        #expect(storage.saveConnections([connection]))
        keychain.seedSynced("hunter2", forKey: passwordKey(connection.id))
        keychain.makeUnreadable(passwordKey(connection.id))

        storage.keepLocalOnlySecretsOnDeviceIfNeeded()
        #expect(keychain.localValue(forKey: passwordKey(connection.id)) == nil)

        keychain.makeReadable(passwordKey(connection.id))
        storage.keepLocalOnlySecretsOnDeviceIfNeeded()
        #expect(keychain.localValue(forKey: passwordKey(connection.id)) == "hunter2")
    }

    @Test("A staged delete waits for the caller, so a failed record save removes nothing")
    func stagedDeleteWaitsForTheRecord() {
        let id = UUID()
        keychain.seedSynced("JBSWY3DP", forKey: totpKey(id))

        let staged = storage.stagingSecretEdits(for: id, deviceOnly: false) {
            storage.deleteTOTPSecret(for: id)
        }
        #expect(keychain.syncedValue(forKey: totpKey(id)) == "JBSWY3DP")

        storage.applyStagedDeletions(staged)
        #expect(keychain.syncedValue(forKey: totpKey(id)) == nil)
    }

    @Test("A secret the prefill read could not read is never deleted by an empty field")
    func unreadableSecretIsKept() {
        let connection = makeConnection(localOnly: false)
        let tokenKey = "com.TablePro.plugin.apiToken.\(connection.id.uuidString)"
        keychain.seedSynced("JBSWY3DP", forKey: totpKey(connection.id))
        keychain.seedSynced("passphrase", forKey: sslKey(connection.id))
        keychain.seedSynced("token", forKey: tokenKey)
        keychain.seedSynced("proxy", forKey: "com.TablePro.socksproxypassword.\(connection.id.uuidString)")
        for key in [totpKey(connection.id), sslKey(connection.id), tokenKey] {
            keychain.makeUnreadable(key)
        }

        let unreadable = storage.recordingUnreadableSecrets {
            #expect(storage.loadTOTPSecret(for: connection.id) == nil)
            #expect(storage.loadSSLClientKeyPassphrase(for: connection.id) == nil)
            #expect(storage.loadPluginSecureField(fieldId: "apiToken", for: connection.id) == nil)
            #expect(storage.loadSOCKSProxyPassword(for: connection.id) == "proxy")
        }
        #expect(unreadable == [totpKey(connection.id), sslKey(connection.id), tokenKey])

        // Readable again by the time of the save: only the prefill read counts.
        for key in unreadable {
            keychain.makeReadable(key)
        }
        let staged = storage.stagingSecretEdits(for: connection.id, deviceOnly: false, keeping: unreadable) {
            storage.deleteTOTPSecret(for: connection.id)
            storage.deleteSSLClientKeyPassphrase(for: connection.id)
            storage.deletePluginSecureField(fieldId: "apiToken", for: connection.id)
            storage.deleteSOCKSProxyPassword(for: connection.id)
        }
        storage.applyStagedDeletions(staged)

        #expect(keychain.syncedValue(forKey: totpKey(connection.id)) == "JBSWY3DP")
        #expect(keychain.syncedValue(forKey: sslKey(connection.id)) == "passphrase")
        #expect(keychain.syncedValue(forKey: tokenKey) == "token")
        #expect(storage.loadSOCKSProxyPassword(for: connection.id) == nil)
    }

    @Test("A staged write that the keychain refuses is reported")
    func failedStagedWriteIsReported() {
        let id = UUID()
        keychain.failWrites(to: passwordKey(id))

        let failed = storage.stagingSecretEdits(for: id, deviceOnly: false) {
            storage.savePassword("hunter2", for: id)
            storage.saveSOCKSProxyPassword("proxy", for: id)
        }
        let succeeded = storage.stagingSecretEdits(for: id, deviceOnly: false) {
            storage.saveSOCKSProxyPassword("proxy", for: id)
        }

        #expect(failed.writeFailed)
        #expect(!succeeded.writeFailed)
    }

    @Test("Staged writes take the scope the unsaved record will have")
    func stagedWritesTakeTheGivenScope() {
        let id = UUID()
        let tokenSecretKey = "com.TablePro.cloudflaretokensecret.\(id.uuidString)"

        _ = storage.stagingSecretEdits(for: id, deviceOnly: true) {
            storage.savePassword("hunter2", for: id)
            storage.saveCloudflareTokenSecret("secret", for: id)
        }

        #expect(keychain.localValue(forKey: passwordKey(id)) == "hunter2")
        #expect(keychain.localValue(forKey: tokenSecretKey) == "secret")
        #expect(keychain.syncedValue(forKey: passwordKey(id)) == nil)
        #expect(keychain.syncedValue(forKey: tokenSecretKey) == nil)
    }
}
