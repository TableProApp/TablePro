import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSyncTransport
import Testing

private final class PostgreSQLStandInPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "PostgreSQL Stand-In"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Builds PostgreSQL fields without a driver"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PostgreSQL"
    static let databaseDisplayName = "PostgreSQL"
    static let iconName = "postgresql-icon"
    static let defaultPort = 5_432

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@MainActor
struct DriverOpenSecretReadTests {
    private let keychain = ScopeRecordingKeychain()
    private let suite: EphemeralDefaults
    private let connections: ConnectionStorage
    private let profiles: CredentialProfileStorage

    init() throws {
        suite = try EphemeralDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("driver-open-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults))
        // Its own keychain, so the store's integrity reads stay out of the reads under test.
        let integrity = ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: InMemoryKeychain()))
        let connectionStorage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: suite.defaults,
            syncTracker: tracker,
            keychain: keychain,
            appEvents: AppEvents(),
            integrity: integrity
        )
        connections = connectionStorage
        profiles = CredentialProfileStorage(
            fileURL: directory.appendingPathComponent("credentialProfiles.json"),
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            integrity: integrity
        )
    }

    private func passwordKey(_ id: UUID) -> String { "com.TablePro.password.\(id.uuidString)" }
    private func sslKey(_ id: UUID) -> String { "com.TablePro.sslkeypassphrase.\(id.uuidString)" }
    private func fieldKey(_ fieldId: String, _ id: UUID) -> String { "com.TablePro.plugin.\(fieldId).\(id.uuidString)" }
    private func profilePasswordKey(_ id: UUID) -> String { "com.TablePro.credprofile.password.\(id.uuidString)" }
    private func profileFieldKey(_ fieldId: String, _ id: UUID) -> String {
        "com.TablePro.credprofile.field.\(fieldId).\(id.uuidString)"
    }

    private func secureFieldIds() throws -> [String] {
        let ids = PluginManager.shared.secureConnectionFieldIds(for: .postgresql)
        try #require(!ids.isEmpty)
        return ids
    }

    // One driver open: the fields `prepareConfiguration` reads, then the sign-in.
    private func open(_ connection: DatabaseConnection) async throws -> (fields: [String: String], password: String) {
        let fields = await DatabaseDriverFactory.readAdditionalFields(
            for: connection,
            plugin: PostgreSQLStandInPlugin(),
            connectionStorage: connections,
            profileStorage: profiles
        )
        let signIn = try await ConnectionCredentialResolver.resolveSignIn(
            for: connection,
            fields: fields,
            connectionStorage: connections,
            profileStorage: profiles
        )
        return (fields, signIn.password)
    }

    private func keychainReads(since start: Int) -> [ScopeRecordingKeychain.Read] {
        Array(keychain.reads.dropFirst(start))
    }

    @Test("A driver open reads every secret the connection needs, none on the main thread")
    func connectionSecretsAreReadOffTheMainThread() async throws {
        let fieldIds = try secureFieldIds()
        let fieldId = try #require(fieldIds.first)
        let connection = TestFixtures.makeConnection(type: .postgresql)
        #expect(connections.addConnection(connection, password: "hunter2"))
        #expect(connections.saveSSLClientKeyPassphrase("passphrase", for: connection.id))
        #expect(connections.savePluginSecureField("secret", fieldId: fieldId, for: connection.id))
        let start = keychain.reads.count

        let opened = try await open(connection)

        let reads = keychainReads(since: start)
        let readKeys = reads.map { $0.key }
        let expectedKeys = fieldIds.map { fieldKey($0, connection.id) } + [sslKey(connection.id), passwordKey(connection.id)]
        #expect(opened.password == "hunter2")
        #expect(opened.fields["sslClientKeyPassphrase"] == "passphrase")
        #expect(opened.fields[fieldId] == "secret")
        #expect(readKeys.count == expectedKeys.count)
        #expect(Set(readKeys) == Set(expectedKeys))
        #expect(reads.allSatisfy { !$0.onMainThread })
    }

    @Test("A driver open with a linked profile reads the profile's secrets, none on the main thread")
    func profileSecretsAreReadOffTheMainThread() async throws {
        let fieldIds = try secureFieldIds()
        let profileFieldId = try #require(fieldIds.first)
        let profile = CredentialProfile(name: "Reader", username: "app_reader", secureFieldIds: [profileFieldId])
        #expect(profiles.addProfile(profile))
        #expect(profiles.savePassword("profile-pass", for: profile.id))
        #expect(profiles.saveSecureField("profile-secret", fieldId: profileFieldId, for: profile.id))
        var connection = TestFixtures.makeConnection(type: .postgresql)
        connection.credentialMode = .profile(id: profile.id)
        #expect(connections.addConnection(connection))
        let start = keychain.reads.count

        let opened = try await open(connection)

        let reads = keychainReads(since: start)
        let readKeys = reads.map { $0.key }
        let expectedKeys = [profileFieldKey(profileFieldId, profile.id), sslKey(connection.id), profilePasswordKey(profile.id)]
            + fieldIds.dropFirst().map { fieldKey($0, connection.id) }
        #expect(opened.password == "profile-pass")
        #expect(opened.fields[profileFieldId] == "profile-secret")
        #expect(readKeys.count == expectedKeys.count)
        #expect(Set(readKeys) == Set(expectedKeys))
        #expect(reads.allSatisfy { !$0.onMainThread })
    }

    @Test("A field the profile declares but holds no value for comes from the connection's own item")
    func profileWithoutTheValueFallsBackToTheConnection() async throws {
        let fieldIds = try secureFieldIds()
        let fieldId = try #require(fieldIds.first)
        let profile = CredentialProfile(name: "Reader", username: "app_reader", secureFieldIds: [fieldId])
        #expect(profiles.addProfile(profile))
        var connection = TestFixtures.makeConnection(type: .postgresql)
        connection.credentialMode = .profile(id: profile.id)
        #expect(connections.addConnection(connection))
        #expect(connections.savePluginSecureField("own-secret", fieldId: fieldId, for: connection.id))
        let start = keychain.reads.count

        let opened = try await open(connection)

        let reads = keychainReads(since: start)
        let readKeys = reads.map { $0.key }
        #expect(opened.fields[fieldId] == "own-secret")
        #expect(readKeys.count == fieldIds.count + 3)
        #expect(readKeys.contains(profileFieldKey(fieldId, profile.id)))
        #expect(readKeys.contains(fieldKey(fieldId, connection.id)))
        #expect(reads.allSatisfy { !$0.onMainThread })
    }

    @Test("A locked Keychain signs in with an empty password after a single read")
    func lockedPasswordSignsInEmpty() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        #expect(connections.addConnection(connection, password: "hunter2"))
        keychain.makeUnreadable(passwordKey(connection.id))
        let start = keychain.reads.count

        let opened = try await open(connection)

        let passwordReads = keychainReads(since: start).filter { $0.key == passwordKey(connection.id) }
        #expect(opened.password.isEmpty)
        #expect(passwordReads.count == 1)
        #expect(passwordReads.allSatisfy { !$0.onMainThread })
    }

    @Test("A Local only connection's open reads this Mac's item before the iCloud Keychain one")
    func localOnlyReadsThisMacsItemFirst() async throws {
        var connection = TestFixtures.makeConnection(type: .postgresql)
        connection.localOnly = true
        #expect(connections.addConnection(connection))
        keychain.seedSynced("icloud-pass", forKey: passwordKey(connection.id))
        keychain.seedLocal("mac-pass", forKey: passwordKey(connection.id))
        keychain.seedSynced("icloud-phrase", forKey: sslKey(connection.id))
        keychain.seedLocal("mac-phrase", forKey: sslKey(connection.id))
        let start = keychain.reads.count

        let opened = try await open(connection)

        let reads = keychainReads(since: start)
        #expect(opened.password == "mac-pass")
        #expect(opened.fields["sslClientKeyPassphrase"] == "mac-phrase")
        #expect(!reads.isEmpty)
        #expect(reads.allSatisfy { $0.deviceOnly && !$0.onMainThread })
    }
}
