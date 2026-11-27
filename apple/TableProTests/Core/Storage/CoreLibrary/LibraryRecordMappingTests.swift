//
//  LibraryRecordMappingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProPluginKit
@testable import TableProSSHConfig
import TableProSSHTransport
import Testing

@MainActor
struct LibraryRecordMappingTests {
    private let fixture: CoreLibraryFixture

    init() throws {
        fixture = try CoreLibraryFixture()
    }

    // Through the core's own store and back, with nothing of the previous stable's files left to read from.
    private func throughTheCore(_ connections: [DatabaseConnection]) throws -> [DatabaseConnection] {
        let storage = fixture.launch()
        #expect(storage.saveConnections(connections))
        return try fixture.launchFromCoreOnly().loadConnections()
    }

    // The fixture's tunnel follows its profile, as every save of the form makes it (ConnectionRecordInvariants).
    private func fullyPopulated() throws -> DatabaseConnection {
        var connection = ConnectionCoverageFixture.fullyPopulated()
        var ssh = connection.sshConfig
        ssh.agentSocketPath = "~/.1password/agent.sock"
        ssh.totpAlgorithm = .sha256
        ssh.totpDigits = 8
        ssh.totpPeriod = 60
        ssh.remoteFilePath = "/srv/app.sqlite"
        ssh.remoteFileAccess = .onServer
        connection.sshConfig = ssh
        connection.sshTunnelMode = .profile(id: try #require(connection.sshProfileId), snapshot: ssh)
        return connection
    }

    @Test("Every stored property of a connection survives the core's store")
    func everyPropertySurvivesTheCore() throws {
        let source = try fullyPopulated()

        let restored = try #require(try throughTheCore([source]).first)
        let lost = ConnectionCoverageFixture.differingProperties(restored, source)

        #expect(lost.isEmpty, "The core's store loses \(lost.sorted().joined(separator: ", ")).")
    }

    @Test("A query timeout moves to the core's own field and comes back among the connection's fields")
    func queryTimeoutSurvives() throws {
        var timed = DatabaseConnection(name: "timed", type: .postgresql, additionalFields: ["schema": "public"])
        timed.queryTimeoutSeconds = 45
        let untimed = DatabaseConnection(name: "untimed", type: .postgresql)

        let restored = try throughTheCore([timed, untimed])

        #expect(restored.map(\.queryTimeoutSeconds) == [45, nil])
        #expect(restored.map(\.additionalFields) == [timed.additionalFields, untimed.additionalFields])
    }

    @Test("Every password source lands where the core keeps it and comes back")
    func everyPasswordSourceSurvives() throws {
        let sources: [PasswordSource] = [
            .file(path: "~/.secrets/db"),
            .command(shell: "pass show db", reuseSeconds: 300),
            .env(variable: "PGPASSWORD"),
            .onePassword(reference: "op://vault/item/password"),
            .vault(path: "secret/db", field: "password"),
            .awsSecretsManager(secretId: "prod/db", jsonKey: "password"),
            .vaultDatabaseRole(VaultDatabaseRole(
                address: "https://vault.internal",
                mount: "database",
                role: "readonly",
                auth: .appRole(mount: "approle", roleId: "role", secretIdPath: "~/.vault/secret-id")
            ))
        ]
        let connections = sources.enumerated().map { index, source in
            DatabaseConnection(name: "source \(index)", type: .postgresql, passwordSource: source)
        }

        #expect(try throughTheCore(connections).map(\.passwordSource) == sources)
    }

    @Test("A tunnel turned off keeps what was typed, and a key file stays while auth is not a key")
    func aTunnelTurnedOffKeepsItsSettings() throws {
        var ssh = SSHConfiguration(enabled: false, host: "bastion", port: 2_222, username: "ops")
        ssh.authMethod = .password
        ssh.privateKeyPath = "~/.ssh/id_ed25519"
        ssh.jumpHosts = [SSHJumpHost(host: "edge", port: 22, username: "hop", authMethod: .privateKey, privateKeyPath: "~/.ssh/edge")]
        let source = DatabaseConnection(name: "off", type: .postgresql, sshConfig: ssh)

        let restored = try #require(try throughTheCore([source]).first)

        #expect(restored.sshTunnelMode == .disabled)
        #expect(restored.sshConfig == ssh)
    }

    @Test("Each Safe Mode level, AI policy and TLS mode comes back as it was")
    func everyLevelSurvives() throws {
        let levels = SafeModeLevel.allCases
        let policies: [AIConnectionPolicy?] = [nil, .alwaysAllow, .askEachTime, .never]
        let modes: [SSLMode] = [.disabled, .preferred, .required, .verifyCa, .verifyIdentity]
        let count = max(levels.count, policies.count, modes.count)
        let connections = (0..<count).map { index in
            DatabaseConnection(
                name: "level \(index)",
                type: .postgresql,
                sslConfig: SSLConfiguration(mode: modes[index % modes.count]),
                safeModeLevel: levels[index % levels.count],
                aiPolicy: policies[index % policies.count]
            )
        }

        let restored = try throughTheCore(connections)

        #expect(restored.map(\.preferredSafeModeLevel) == connections.map(\.preferredSafeModeLevel))
        #expect(restored.map(\.aiPolicy) == connections.map(\.aiPolicy))
        #expect(restored.map(\.sslConfig.mode) == connections.map(\.sslConfig.mode))
    }

    @Test("A colour, TLS mode and origin only the core names stay in the core while the Mac's value reads as them")
    func valuesOnlyTheCoreNamesAreKept() async throws {
        let storage = fixture.launch()
        let source = DatabaseConnection(name: "from Linux", type: .postgresql)
        #expect(storage.saveConnections([source]))
        let library = try Core(
            config: HostConfig(clientVersion: "test", storageDir: fixture.coreURL.deletingLastPathComponent().path),
            secrets: ConnectionKeychainSecrets(keychain: fixture.keychain) { _ in false }
        ).library()
        var contents = try await library.libraryContents()
        contents.connections[0].connection.color = "teal"
        contents.connections[0].connection.tls.mode = .strict
        contents.connections[0].device.origin = "shared_vault"
        _ = try await library.replaceLibrary(
            library: LibraryWriteRecord(
                connections: contents.connections,
                groups: contents.groups,
                tags: contents.tags,
                favorites: contents.favorites,
                projects: contents.projects,
                sshProfiles: contents.sshProfiles,
                credentialProfiles: contents.credentialProfiles,
                removing: []
            ),
            over: contents.digest
        )
        // As a TablePro build that wrote these values tags the store.
        #expect(fixture.stampCore(try Data(contentsOf: fixture.coreURL)))
        try FileManager.default.removeItem(at: fixture.legacyURL)

        let relaunched = fixture.launch()
        let read = try #require(relaunched.loadConnections().first)
        #expect(read.color == .none)
        #expect(read.sslConfig.mode == .verifyIdentity)
        #expect(read.origin == .thisMac)
        #expect(relaunched.mutateConnections(ids: [source.id]) { $0.name = "renamed on the Mac" })

        let kept = try await library.libraryContents().connections[0]
        #expect(kept.connection.name == "renamed on the Mac")
        #expect(kept.connection.color == "teal")
        #expect(kept.connection.tls.mode == .strict)
        #expect(kept.device.origin == "shared_vault")
    }

    @Test("Groups and tags keep their ids, icons, colours and presets")
    func groupsAndTagsSurvive() throws {
        let parent = ConnectionGroup(name: "Clients", color: .gray, iconName: "server.rack", sortOrder: 3)
        let child = ConnectionGroup(name: "Acme", color: .none, iconName: "cylinder.split.1x2", parentId: parent.id, sortOrder: 1)
        let storage = fixture.launch()
        #expect(fixture.groups(storage).saveGroups([parent, child]))
        let tags = ConnectionTag.presets + [ConnectionTag(name: "uncoloured", color: .none)]
        #expect(fixture.tags(storage).saveTags(tags))

        let reopened = try fixture.launchFromCoreOnly()

        #expect(fixture.groups(reopened).loadGroups() == [parent, child])
        #expect(fixture.tags(reopened).loadTags() == tags)
    }
}

struct ConnectionKeychainSecretsTests {
    @Test("A profile the core takes out loses every Keychain item this Mac wrote for it, and an id no profile has is not this Mac's")
    func profileSecretsGoWithTheProfile() throws {
        let keychain = InMemoryKeychain()
        let secrets = ProfileKeychainSecrets(keychain: keychain)
        let server = UUID()
        let reader = CredentialProfile(name: "Reader", secureFieldIds: ["token"])
        for secret in SSHSecret.allCases {
            #expect(keychain.writeString("s", forKey: SSHProfileStorage.key(secret, server)))
        }
        #expect(keychain.writeString("p", forKey: CredentialProfileStorage.passwordKey(reader.id)))
        #expect(keychain.writeString("f", forKey: CredentialProfileStorage.fieldKey("token", reader.id)))
        secrets.remember([reader])

        #expect(secrets.delete(profileId: server.uuidString.lowercased(), kind: .ssh) == .deleted)
        #expect(secrets.delete(profileId: reader.id.uuidString.lowercased(), kind: .credential) == .deleted)
        #expect(secrets.delete(profileId: "not an id", kind: .ssh) == .notOwned)

        for secret in SSHSecret.allCases {
            #expect(keychain.readString(forKey: SSHProfileStorage.key(secret, server)) == nil)
        }
        #expect(keychain.readString(forKey: CredentialProfileStorage.passwordKey(reader.id)) == nil)
        #expect(keychain.readString(forKey: CredentialProfileStorage.fieldKey("token", reader.id)) == nil)
    }

    @Test("A project name goes to the core with no control character in it")
    func projectNamesLoseControlCharacters() {
        #expect(LibraryRecordMapping.projectName("Acme") == "Acme")
        #expect(LibraryRecordMapping.projectName("Acme\tWest") == "Acme West")
        #expect(LibraryRecordMapping.projectName("\u{01}") == "\\u{1}")
    }

    @Test("Profiles round trip through the core's records")
    func profilesRoundTrip() {
        let server = SSHProfile(
            name: "Bastion", host: "bastion.example.com", port: 2_222, username: "deploy", authMethod: .privateKey,
            privateKeyPath: "~/.ssh/id_ed25519", totpMode: .autoGenerate
        )
        let readers = [
            CredentialProfile(name: "Stored", username: "a", passwordMode: .stored, secureFieldIds: ["t"], sortOrder: 2),
            CredentialProfile(name: "Command", passwordMode: .source(.command(shell: "op read x", reuseSeconds: 60))),
            CredentialProfile(name: "Env", passwordMode: .source(.env(variable: "PGPASSWORD"))),
            CredentialProfile(name: "Pgpass", passwordMode: .pgpass),
        ]

        #expect(LibraryRecordMapping.sshProfile(LibraryRecordMapping.record(server, keeping: nil)) == server)
        #expect(readers.map { LibraryRecordMapping.credentialProfile(LibraryRecordMapping.record($0)) } == readers)
    }

    @Test("Until the library first reads, the core gets no connection secret, since no scope is known")
    func noScopeBeforeTheFirstRead() throws {
        let localOnly = LocalOnlyConnections()
        let keychain = ScopeRecordingKeychain()
        let secrets = ConnectionKeychainSecrets(keychain: keychain) { localOnly.isLocalOnly($0) }
        let id = UUID()

        #expect(throws: HostSecretError.self) {
            try secrets.store(connectionId: id.uuidString, kind: .databasePassword, secret: "p1", label: "")
        }
        #expect(keychain.localValue(forKey: "com.TablePro.password.\(id.uuidString)") == nil)

        localOnly.set([id])
        try secrets.store(connectionId: id.uuidString, kind: .databasePassword, secret: "p1", label: "")

        #expect(keychain.localValue(forKey: "com.TablePro.password.\(id.uuidString)") == "p1")
    }

    @Test("The core's secrets use the keys and scope earlier builds read")
    func secretsUseTheMacsItems() throws {
        let keychain = ScopeRecordingKeychain()
        let localOnly = UUID()
        let synced = UUID()
        let secrets = ConnectionKeychainSecrets(keychain: keychain) { $0 == localOnly }

        try secrets.store(connectionId: localOnly.uuidString.lowercased(), kind: .databasePassword, secret: "p1", label: "")
        try secrets.store(connectionId: synced.uuidString.lowercased(), kind: .sshPassphrase, secret: "p2", label: "")

        #expect(keychain.localValue(forKey: "com.TablePro.password.\(localOnly.uuidString)") == "p1")
        #expect(keychain.syncedValue(forKey: "com.TablePro.password.\(localOnly.uuidString)") == nil)
        #expect(keychain.syncedValue(forKey: "com.TablePro.keypassphrase.\(synced.uuidString)") == "p2")
        #expect(try secrets.load(connectionId: synced.uuidString.lowercased(), kind: .sshPassphrase) == "p2")
        #expect(try secrets.load(connectionId: synced.uuidString, kind: .sshPassword) == nil)
    }

    @Test("A connection the core deletes for another device leaves the iCloud Keychain items to that device")
    func deletingAConnectionRemovesItsDeviceItemsOnly() throws {
        let keychain = ScopeRecordingKeychain()
        let id = UUID()
        let key = "com.TablePro.password.\(id.uuidString)"
        keychain.seedSynced("synced", forKey: key)
        keychain.seedLocal("local", forKey: key)
        let secrets = ConnectionKeychainSecrets(keychain: keychain) { _ in false }

        try secrets.deleteConnection(connectionId: id.uuidString)

        #expect(keychain.localValue(forKey: key) == nil)
        #expect(keychain.syncedValue(forKey: key) == "synced")
    }

    @Test("A locked keychain is an answer the core can tell apart from no password")
    func aLockedKeychainIsNotAMissingPassword() {
        let keychain = ScopeRecordingKeychain()
        let id = UUID()
        keychain.makeUnreadable("com.TablePro.password.\(id.uuidString)")
        let secrets = ConnectionKeychainSecrets(keychain: keychain) { _ in false }

        #expect(throws: HostSecretError.Locked) {
            try secrets.load(connectionId: id.uuidString, kind: .databasePassword)
        }
    }
}
