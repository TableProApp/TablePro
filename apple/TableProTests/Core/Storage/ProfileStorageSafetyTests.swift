import Foundation
import TableProSSHConfig
import TableProSyncTransport
import Testing

@testable import TablePro

@MainActor
struct ProfileStorageSafetyTests {
    private let pool = EphemeralDefaultsPool()
    private let directory: URL
    private let keychain = InMemoryKeychain()
    private let tracker: SyncJournalRecorder
    private let integrity: ConnectionStoreIntegrity

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tracker = SyncJournalRecorder()
        integrity = ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
    }

    private func makeConnections(unreadable: Bool = false, keychain: (any KeychainStoring)? = nil) throws -> ConnectionStorage {
        let fileURL = directory.appendingPathComponent("connections.json")
        if unreadable {
            try Data("not json".utf8).write(to: fileURL)
        }
        return ConnectionStorage(
            fileURL: fileURL,
            userDefaults: try pool.make().defaults,
            syncJournal: tracker.journal,
            keychain: keychain ?? self.keychain,
            integrity: integrity
        )
    }

    private func makeCredentialStorage(
        connections: ConnectionStorage,
        keychain: (any KeychainStoring)? = nil
    ) -> CredentialProfileStorage {
        CredentialProfileStorage(
            keychain: keychain ?? self.keychain,
            syncJournal: tracker.journal,
            connectionStorage: connections
        )
    }

    private func makeSSHStorage(
        connections: ConnectionStorage,
        keychain: (any KeychainStoring)? = nil
    ) throws -> SSHProfileStorage {
        SSHProfileStorage(
            keychain: keychain ?? self.keychain,
            syncJournal: tracker.journal,
            connectionStorage: connections
        )
    }

    private func makeModel(
        credentials: CredentialProfileStorage,
        ssh: SSHProfileStorage,
        connections: ConnectionStorage
    ) -> ProfilesSettingsModel {
        ProfilesSettingsModel(
            credentialStorage: credentials,
            sshStorage: ssh,
            connectionStorage: connections,
            appEvents: AppEvents(),
            notificationCenter: NotificationCenter()
        )
    }

    private func makeSSHProfile(name: String = "Bastion", host: String = "bastion.example.com") -> SSHProfile {
        SSHProfile(name: name, host: host, port: 22, username: "deploy", authMethod: .password)
    }

    @Test(
        "A secret is written only when it applies and has a value, and an unreadable one is never deleted",
        arguments: [
            (true, "new", ProfileSecretRead.absent, ProfileSecretChange.write("new")),
            (true, "new", .found("old"), .write("new")),
            (true, "same", .found("same"), .keep),
            (true, "new", .unreadable, .write("new")),
            (true, "", .found("old"), .delete),
            (true, "", .unreadable, .keep),
            (true, "", .absent, .delete),
            (false, "typed", .found("old"), .delete),
            (false, "", .unreadable, .keep),
            (false, "", .absent, .delete),
        ]
    )
    func secretDecision(applies: Bool, value: String, read: ProfileSecretRead, expected: ProfileSecretChange) {
        #expect(ProfileSecretChange.decide(applies: applies, value: value, read: read) == expected)
    }

    @Test(
        "A Keychain read sorts into found, absent and unreadable",
        arguments: [
            (KeychainStringResult.found("hunter2"), ProfileSecretRead.found("hunter2")),
            (.found(""), .absent),
            (.notFound, .absent),
            (.locked, .unreadable),
            (.userCancelled, .unreadable),
            (.authFailed, .unreadable),
            (.error(-25_300), .unreadable),
        ]
    )
    func secretRead(result: KeychainStringResult, expected: ProfileSecretRead) {
        #expect(ProfileSecretRead(result) == expected)
    }

    // The profiles live in the library with the connections that use them, so one that cannot be read holds both.
    @Test("A credential profile is neither added nor deleted while the library can't be read")
    func credentialDeleteRefusesUnreadableLibrary() throws {
        let connections = try makeConnections(unreadable: true)
        let storage = makeCredentialStorage(connections: connections)
        let profile = CredentialProfile(name: "Prod reader", username: "app_reader")
        #expect(!storage.addProfile(profile))

        #expect(!storage.unlinkConnections(from: profile, byUser: true))
        #expect(!storage.deleteProfile(profile))
        #expect(try Data(contentsOf: directory.appendingPathComponent("connections.json")) == Data("not json".utf8))
    }

    @Test("An SSH profile is neither added nor deleted while the library can't be read")
    func sshDeleteRefusesUnreadableLibrary() throws {
        let connections = try makeConnections(unreadable: true)
        let storage = try makeSSHStorage(connections: connections)
        let profile = makeSSHProfile()
        #expect(!storage.addProfile(profile))

        #expect(!storage.unlinkConnections(fromProfile: profile, byUser: true))
        #expect(!storage.deleteProfile(profile))
        #expect(try Data(contentsOf: directory.appendingPathComponent("connections.json")) == Data("not json".utf8))
    }

    @Test("Adding a credential profile under an id already taken is refused")
    func credentialAddRefusesDuplicateId() throws {
        let storage = makeCredentialStorage(connections: try makeConnections())
        let profile = CredentialProfile(name: "Prod reader")
        #expect(storage.addProfile(profile))

        var renamed = profile
        renamed.name = "Replacement"
        #expect(!storage.addProfile(renamed))
        #expect(storage.loadProfiles().map(\.name) == ["Prod reader"])
    }

    @Test("Adding an SSH profile under an id already taken is refused")
    func sshAddRefusesDuplicateId() throws {
        let storage = try makeSSHStorage(connections: try makeConnections())
        let profile = makeSSHProfile()
        #expect(storage.addProfile(profile))

        var moved = profile
        moved.host = "elsewhere.example.com"
        #expect(!storage.addProfile(moved))
        #expect(storage.loadProfiles().map(\.host) == ["bastion.example.com"])
    }

    @Test("Deleting with an out-of-date copy hands linked connections the stored SSH configuration")
    func sshDeleteUsesTheStoredRecord() throws {
        let connections = try makeConnections()
        let storage = try makeSSHStorage(connections: connections)
        var profile = makeSSHProfile(host: "old.example.com")
        #expect(storage.addProfile(profile))
        let stale = profile
        var connection = TestFixtures.makeConnection()
        connection.sshTunnelMode = .profile(id: profile.id, snapshot: profile.toSSHConfiguration())
        connection.sshConfig = profile.toSSHConfiguration()
        connection.sshProfileId = profile.id
        connections.addConnection(connection)
        profile.host = "new.example.com"
        #expect(storage.updateProfile(profile))

        #expect(storage.deleteProfile(stale))

        let converted = connections.loadConnection(id: connection.id)
        #expect(converted?.sshProfileId == nil)
        #expect(converted?.resolvedSSHConfig.host == "new.example.com")
    }

    @Test("Deleting with an out-of-date copy still removes secrets the stored record gained")
    func credentialDeleteUsesTheStoredRecord() throws {
        let storage = makeCredentialStorage(connections: try makeConnections())
        var profile = CredentialProfile(name: "Prod reader")
        #expect(storage.addProfile(profile))
        let stale = profile
        profile.secureFieldIds = ["awsSecretAccessKey"]
        #expect(storage.updateProfile(profile))
        #expect(storage.saveSecureField("secret", fieldId: "awsSecretAccessKey", for: profile.id))

        #expect(storage.deleteProfile(stale))

        #expect(storage.readSecureField(fieldId: "awsSecretAccessKey", for: profile.id) == .absent)
    }

    @Test("A copy's name never matches another profile, ignoring case and accents")
    func copyNamesAreFree() {
        #expect(ProfileNames.available(basedOn: "Prod", taken: ["Prod"]) == "Prod (Copy)")
        #expect(ProfileNames.available(basedOn: "Prod", taken: ["Prod", "prod (copy)"]) == "Prod (Copy 2)")
        #expect(ProfileNames.available(basedOn: "Café", taken: ["Café", "CAFE (COPY)", "cafe (copy 2)"]) == "Café (Copy 3)")
    }

    @Test("Duplicating a credential profile copies its password and secure fields under a new id")
    func credentialDuplicateCopiesSecrets() throws {
        let connections = try makeConnections()
        let credentials = makeCredentialStorage(connections: connections)
        let model = makeModel(credentials: credentials, ssh: try makeSSHStorage(connections: connections), connections: connections)
        let source = CredentialProfile(name: "Prod reader", username: "app_reader", secureFieldIds: ["awsSecretAccessKey"])
        #expect(credentials.addProfile(source))
        #expect(credentials.savePassword("hunter2", for: source.id))
        #expect(credentials.saveSecureField("secret", fieldId: "awsSecretAccessKey", for: source.id))

        #expect(model.duplicateCredentialProfile(id: source.id))

        let copy = try #require(credentials.loadProfiles().first { $0.id != source.id })
        #expect(copy.name == "Prod reader (Copy)")
        #expect(copy.username == "app_reader")
        #expect(credentials.readPassword(for: copy.id) == .found("hunter2"))
        #expect(credentials.readSecureField(fieldId: "awsSecretAccessKey", for: copy.id) == .found("secret"))
    }

    @Test("A credential profile whose secrets can't be read is not duplicated")
    func credentialDuplicateRefusesUnreadableSecrets() throws {
        let locked = UnreadableSecretKeychain()
        let connections = try makeConnections()
        let credentials = makeCredentialStorage(connections: connections, keychain: locked)
        let model = makeModel(credentials: credentials, ssh: try makeSSHStorage(connections: connections), connections: connections)
        let source = CredentialProfile(name: "Prod reader", passwordMode: .stored)
        #expect(credentials.addProfile(source))

        #expect(!model.duplicateCredentialProfile(id: source.id))
        #expect(credentials.loadProfiles().count == 1)
    }

    @Test("An SSH profile whose secrets can't be read is not duplicated")
    func sshDuplicateRefusesUnreadableSecrets() throws {
        let connections = try makeConnections()
        let ssh = try makeSSHStorage(connections: connections, keychain: UnreadableSecretKeychain())
        let model = makeModel(credentials: makeCredentialStorage(connections: connections), ssh: ssh, connections: connections)
        let source = makeSSHProfile()
        #expect(ssh.addProfile(source))

        #expect(!model.duplicateSSHProfile(id: source.id))
        #expect(ssh.loadProfiles().count == 1)
    }

    @Test("Duplicating an SSH profile copies its configuration and all three secrets")
    func sshDuplicateCopiesSecrets() throws {
        let connections = try makeConnections()
        let ssh = try makeSSHStorage(connections: connections)
        let model = makeModel(credentials: makeCredentialStorage(connections: connections), ssh: ssh, connections: connections)
        let source = makeSSHProfile()
        #expect(ssh.addProfile(source))
        #expect(ssh.saveSSHPassword("pw", for: source.id))
        #expect(ssh.saveKeyPassphrase("phrase", for: source.id))
        #expect(ssh.saveTOTPSecret("JBSWY3DP", for: source.id))

        #expect(model.duplicateSSHProfile(id: source.id))

        let copy = try #require(ssh.loadProfiles().first { $0.id != source.id })
        #expect(copy.name == "Bastion (Copy)")
        #expect(copy.host == source.host)
        #expect(ssh.readSecret(.password, for: copy.id) == .found("pw"))
        #expect(ssh.readSecret(.keyPassphrase, for: copy.id) == .found("phrase"))
        #expect(ssh.readSecret(.totpSecret, for: copy.id) == .found("JBSWY3DP"))
    }

    @Test("Usage is unknown, and Delete is not offered, while the connections can't be read")
    func usageUnknownWithUnreadableLibrary() throws {
        let connections = try makeConnections(unreadable: true)
        let credentials = makeCredentialStorage(connections: connections)
        let model = makeModel(credentials: credentials, ssh: try makeSSHStorage(connections: connections), connections: connections)
        let profile = CredentialProfile(name: "Prod reader")
        #expect(!credentials.addProfile(profile))

        model.refresh()

        #expect(model.usageUnknown)
        #expect(model.usageCount(for: profile.id) == nil)
        #expect(model.pendingDeletion(of: .credential, id: profile.id, name: profile.name) == nil)
    }

    @Test("Usage counts each profile's linked connections")
    func usageCountsLinkedConnections() throws {
        let connections = try makeConnections()
        let credentials = makeCredentialStorage(connections: connections)
        let ssh = try makeSSHStorage(connections: connections)
        let model = makeModel(credentials: credentials, ssh: ssh, connections: connections)
        let credential = CredentialProfile(name: "Prod reader")
        let server = makeSSHProfile()
        #expect(credentials.addProfile(credential))
        #expect(ssh.addProfile(server))
        for _ in 0..<2 {
            var connection = TestFixtures.makeConnection()
            connection.credentialMode = .profile(id: credential.id)
            connection.sshTunnelMode = .profile(id: server.id, snapshot: server.toSSHConfiguration())
            connections.addConnection(connection)
        }

        model.refresh()

        #expect(model.usageCount(for: credential.id) == 2)
        #expect(model.usageCount(for: server.id) == 2)
        #expect(model.pendingDeletion(of: .ssh, id: server.id, name: server.name)?.dependentCount == 2)
    }
}
