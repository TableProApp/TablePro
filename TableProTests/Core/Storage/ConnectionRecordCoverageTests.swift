//
//  ConnectionRecordCoverageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSyncTransport
import Testing

/// Every stored property of a connection set away from its default, so a copy that drops one
/// shows up as a difference rather than as two defaults that happen to match.
enum ConnectionCoverageFixture {
    static func storedValues(of connection: DatabaseConnection) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Mirror(reflecting: connection).children.compactMap { child in
            child.label.map { ($0, String(describing: child.value)) }
        })
    }

    static func differingProperties(_ lhs: DatabaseConnection, _ rhs: DatabaseConnection) -> Set<String> {
        let left = storedValues(of: lhs)
        let right = storedValues(of: rhs)
        return Set(left.keys.filter { left[$0] != right[$0] })
    }

    /// Sets and dictionaries hold one element each, because two equal ones can describe themselves
    /// in different orders.
    static func fullyPopulated() -> DatabaseConnection {
        var ssh = SSHConfiguration()
        ssh.enabled = true
        ssh.host = "bastion.example.com"
        ssh.port = 2_222
        ssh.username = "deploy"
        ssh.authMethod = .privateKey
        ssh.privateKeyPath = "~/.ssh/id_ed25519"
        ssh.jumpHosts = [
            SSHJumpHost(host: "jump.example.com", port: 22, username: "hop", authMethod: .sshAgent, privateKeyPath: "")
        ]
        ssh.totpMode = .promptAtConnect

        return DatabaseConnection(
            name: "Production",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: .postgresql,
            sshConfig: ssh,
            sslConfig: SSLConfiguration(mode: .verifyCa, caCertificatePath: "/etc/ssl/ca.pem"),
            color: .blue,
            iconName: "server.rack",
            tagIds: [UUID(), UUID()],
            groupId: UUID(),
            sshProfileId: UUID(),
            sshTunnelMode: .inline(ssh),
            credentialMode: .profile(id: UUID()),
            cloudflareTunnelMode: .inline(CloudflareConfiguration(accessHostname: "db.access.example.com")),
            cloudSQLProxyMode: .inline(CloudSQLProxyConfiguration(instanceConnectionName: "project:region:instance")),
            socksProxyMode: .inline(SOCKSProxyConfiguration(host: "proxy.internal", port: 1_080, username: "relay")),
            tunnelCommandMode: .inline(
                TunnelCommandConfiguration(kubernetesNamespace: "data", kubernetesResource: "svc/postgres")
            ),
            safeModeLevel: .alertFull,
            aiPolicy: .askEachTime,
            aiRules: "Never drop tables",
            aiAlwaysAllowedTools: ["listTables"],
            externalAccess: .blocked,
            redisDatabase: 3,
            startupCommands: "SET search_path TO public",
            sortOrder: 7,
            localOnly: true,
            isSample: true,
            isFavorite: true,
            passwordSource: .env(variable: "PGPASSWORD"),
            additionalFields: ["schema": "public"]
        )
    }
}

struct ConnectionCoverageFixtureTests {
    @Test("The fixture sets every stored property away from its default")
    func fixtureCoversEveryProperty() {
        let defaults = ConnectionCoverageFixture.storedValues(of: DatabaseConnection(name: ""))
        let fixture = ConnectionCoverageFixture.storedValues(of: ConnectionCoverageFixture.fullyPopulated())

        let leftAtDefault = fixture.keys.filter { fixture[$0] == defaults[$0] }

        #expect(
            leftAtDefault.isEmpty,
            "Set \(leftAtDefault.sorted().joined(separator: ", ")) in ConnectionCoverageFixture.fullyPopulated()."
        )
    }
}

struct StoredConnectionCoverageTests {
    /// Properties connections.json deliberately does not keep. None today.
    private static let notPersisted: Set<String> = []

    @Test("Every stored property survives connections.json unless it is listed as not persisted")
    func everyPropertySurvivesTheFile() throws {
        let source = ConnectionCoverageFixture.fullyPopulated()

        let data = try JSONEncoder().encode(StoredConnection(from: source))
        let restored = try JSONDecoder().decode(StoredConnection.self, from: data).toConnection()
        let lost = ConnectionCoverageFixture.differingProperties(restored, source)
            .subtracting(Self.notPersisted)

        #expect(
            lost.isEmpty,
            """
            connections.json loses \(lost.sorted().joined(separator: ", ")).
            Add each one to StoredConnection: the property, init(from:), CodingKeys, encode, \
            init(from decoder:) and toConnection(). A property missing from any of them is reset \
            on every launch.
            """
        )
    }

    @Test("Every stored property survives the connection's own Codable")
    func everyPropertySurvivesConnectionCodable() throws {
        let source = ConnectionCoverageFixture.fullyPopulated()

        let restored = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(source))
        let lost = ConnectionCoverageFixture.differingProperties(restored, source)

        #expect(lost.isEmpty, "DatabaseConnection's Codable loses \(lost.sorted().joined(separator: ", ")).")
    }

    @Test("A connections.json written before icons existed decodes with the engine icon")
    func legacyFileDecodesWithoutIcon() throws {
        var connection = DatabaseConnection(name: "Legacy")
        connection.iconName = "star"
        let written = try JSONEncoder().encode(StoredConnection(from: connection))
        var object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let removedIcon = object.removeValue(forKey: "iconName") as? String
        #expect(removedIcon == "star")

        let data = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(StoredConnection.self, from: data).toConnection()

        #expect(restored.iconName == nil)
    }

    @Test("No icon key is written for a connection that draws its engine icon")
    func noIconWritesNoKey() throws {
        let data = try JSONEncoder().encode(StoredConnection(from: DatabaseConnection(name: "Plain")))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["iconName"] == nil)
    }

    @Test("A malformed icon in the file is dropped, and a well-formed one this Mac cannot draw is kept")
    func storedIconIsNormalizedNotFiltered() throws {
        func restored(_ iconName: String) throws -> String? {
            var connection = DatabaseConnection(name: "Edited by hand")
            connection.iconName = iconName
            let data = try JSONEncoder().encode(StoredConnection(from: connection))
            return try JSONDecoder().decode(StoredConnection.self, from: data).toConnection().iconName
        }

        #expect(try restored("made.up.symbol") == "made.up.symbol")
        #expect(try restored("../../etc/passwd") == nil)
        #expect(try restored("") == nil)
    }
}

@MainActor
struct ConnectionDuplicateCoverageTests {
    /// The copy is a new connection of the user's own: a new identity and name, placed after its
    /// source, and never a favorite or a sample because its source was.
    private static let resetByDuplicate: Set<String> = ["id", "name", "sortOrder", "isFavorite", "isSample"]

    private let storage: ConnectionStorage

    init() throws {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("duplicate_coverage_\(unique).json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.DuplicateCoverage.\(unique)"))
        let syncDefaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.DuplicateCoverage.sync.\(unique)"))
        storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults)),
            keychain: InMemoryKeychain()
        )
    }

    @Test("Duplicate carries every stored property it does not deliberately reset")
    func duplicateCarriesEveryProperty() throws {
        let source = ConnectionCoverageFixture.fullyPopulated()
        storage.saveConnections([source])

        let duplicate = try #require(storage.duplicateConnection(source))
        let dropped = ConnectionCoverageFixture.differingProperties(duplicate, source)
            .subtracting(Self.resetByDuplicate)

        #expect(
            dropped.isEmpty,
            """
            Duplicate drops \(dropped.sorted().joined(separator: ", ")).
            Pass each one in ConnectionStorage.duplicateConnection, or add it to resetByDuplicate \
            with the reason the copy should not have it.
            """
        )
    }

    @Test("Duplicate gives the copy a new identity and name and clears the favorite and sample marks")
    func duplicateResetsIdentity() throws {
        let source = ConnectionCoverageFixture.fullyPopulated()
        storage.saveConnections([source])

        let duplicate = try #require(storage.duplicateConnection(source))

        #expect(duplicate.id != source.id)
        #expect(duplicate.name != source.name)
        #expect(duplicate.name.contains(source.name))
        #expect(!duplicate.isFavorite)
        #expect(!duplicate.isSample)
    }
}
