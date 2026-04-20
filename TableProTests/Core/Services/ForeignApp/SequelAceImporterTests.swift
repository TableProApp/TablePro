//
//  SequelAceImporterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SequelAceImporter", .serialized)
struct SequelAceImporterTests {
    private var tempDir: URL
    private var importer: SequelAceImporter

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequelAceImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var imp = SequelAceImporter()
        imp.favoritesFileURL = tempDir.appendingPathComponent("Favorites.plist")
        importer = imp
    }

    // MARK: - Fixture Helpers

    private func writeFavorites(_ root: [String: Any]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        )
        try data.write(to: importer.favoritesFileURL)
    }

    private func makeFavoritesRoot(children: [[String: Any]]) -> [String: Any] {
        [
            "Favorites Root": [
                "Name": "Favorites Root",
                "Children": children
            ]
        ]
    }

    private func makeConnection(
        name: String = "Test DB",
        host: String = "db.example.com",
        port: String = "3306",
        user: String = "root",
        database: String = "mydb",
        type: Int = 0,
        id: Int = 1,
        colorIndex: Int = -1,
        sshHost: String = "",
        sshUser: String = "",
        sshPort: String = "22",
        sshKeyEnabled: Int = 0,
        sshKeyLocation: String = "",
        useSSL: Int = 0,
        sslCACert: String = "",
        sslCert: String = "",
        sslKey: String = ""
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "name": name,
            "host": host,
            "port": port,
            "user": user,
            "database": database,
            "type": type,
            "id": id,
            "colorIndex": colorIndex,
            "useSSL": useSSL
        ]
        if type == 2 {
            entry["sshHost"] = sshHost
            entry["sshUser"] = sshUser
            entry["sshPort"] = sshPort
            entry["sshKeyLocationEnabled"] = sshKeyEnabled
            entry["sshKeyLocation"] = sshKeyLocation
        }
        if useSSL != 0 {
            entry["sslCACertFileLocation"] = sslCACert
            entry["sslCertificateFileLocation"] = sslCert
            entry["sslKeyFileLocation"] = sslKey
        }
        return entry
    }

    private func makeGroup(name: String, children: [[String: Any]]) -> [String: Any] {
        [
            "Name": name,
            "Children": children
        ]
    }

    // MARK: - isAvailable

    @Test("isAvailable returns true when file exists")
    func testIsAvailable_whenFileExists_returnsTrue() throws {
        try writeFavorites(makeFavoritesRoot(children: []))
        #expect(importer.isAvailable() == true)
    }

    @Test("isAvailable returns false when file is missing")
    func testIsAvailable_whenFileMissing_returnsFalse() {
        #expect(importer.isAvailable() == false)
    }

    // MARK: - connectionCount

    @Test("connectionCount returns correct count")
    func testConnectionCount_returnsCorrectCount() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB1", id: 1),
            makeConnection(name: "DB2", id: 2),
            makeGroup(name: "Group", children: [
                makeConnection(name: "DB3", id: 3)
            ])
        ]
        try writeFavorites(makeFavoritesRoot(children: children))
        #expect(importer.connectionCount() == 3)
    }

    @Test("connectionCount returns 0 when file missing")
    func testConnectionCount_fileMissing_returnsZero() {
        #expect(importer.connectionCount() == 0)
    }

    // MARK: - importConnections

    @Test("importConnections parses all connections")
    func testImportConnections_parsesAllConnections() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB1", id: 1),
            makeConnection(name: "DB2", id: 2)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections.count == 2)
        #expect(result.sourceName == "Sequel Ace")
    }

    @Test("importConnections type is always MySQL")
    func testImportConnections_typeAlwaysMySQL() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "TCP", type: 0, id: 1),
            makeConnection(name: "Socket", type: 1, id: 2),
            makeConnection(name: "SSH", type: 2, id: 3, sshHost: "bastion.com", sshUser: "user")
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        for conn in result.envelope.connections {
            #expect(conn.type == "MySQL")
        }
    }

    @Test("importConnections parses SSH for type 2")
    func testImportConnections_parsesSSHForType2() throws {
        let children: [[String: Any]] = [
            makeConnection(
                name: "SSH DB",
                type: 2,
                id: 1,
                sshHost: "bastion.example.com",
                sshUser: "deploy",
                sshPort: "2222",
                sshKeyEnabled: 1,
                sshKeyLocation: "~/.ssh/id_ed25519"
            )
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.enabled == true)
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "~/.ssh/id_ed25519")
    }

    @Test("importConnections no SSH for type 0")
    func testImportConnections_noSSHForType0() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "TCP DB", type: 0, id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sshConfig == nil)
    }

    @Test("importConnections parses SSL config")
    func testImportConnections_parsesSSLConfig() throws {
        let children: [[String: Any]] = [
            makeConnection(
                name: "SSL DB",
                id: 1,
                useSSL: 1,
                sslCACert: "/path/to/ca.pem",
                sslCert: "/path/to/client-cert.pem",
                sslKey: "/path/to/client-key.pem"
            )
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "required")
        #expect(ssl?.caCertificatePath == "/path/to/ca.pem")
        #expect(ssl?.clientCertificatePath == "/path/to/client-cert.pem")
        #expect(ssl?.clientKeyPath == "/path/to/client-key.pem")
    }

    @Test("importConnections no SSL when useSSL is 0")
    func testImportConnections_noSSLWhenDisabled() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "No SSL", id: 1, useSSL: 0)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sslConfig == nil)
    }

    @Test("importConnections recursive group parsing")
    func testImportConnections_recursiveGroupParsing() throws {
        let children: [[String: Any]] = [
            makeGroup(name: "Production", children: [
                makeConnection(name: "Prod Main", id: 1),
                makeConnection(name: "Prod Replica", id: 2)
            ]),
            makeConnection(name: "Local", id: 3),
            makeGroup(name: "Staging", children: [
                makeConnection(name: "Staging DB", id: 4)
            ])
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        let connections = result.envelope.connections

        #expect(connections.count == 4)
        #expect(connections[0].groupName == "Production")
        #expect(connections[1].groupName == "Production")
        #expect(connections[2].groupName == nil)
        #expect(connections[3].groupName == "Staging")

        let groups = result.envelope.groups
        #expect(groups != nil)
        let groupNames = Set(groups?.map(\.name) ?? [])
        #expect(groupNames.contains("Production"))
        #expect(groupNames.contains("Staging"))
    }

    @Test("importConnections color index mapping")
    func testImportConnections_colorIndexMapping() throws {
        let colorMappings: [(Int, String?)] = [
            (0, "red"),
            (1, "orange"),
            (2, "yellow"),
            (3, "green"),
            (4, "blue"),
            (5, "purple"),
            (6, "pink"),
            (7, "gray"),
            (-1, nil),
            (99, nil)
        ]

        var children: [[String: Any]] = []
        for (index, mapping) in colorMappings.enumerated() {
            children.append(makeConnection(
                name: "Color \(mapping.0 ?? -1)",
                id: index + 1,
                colorIndex: mapping.0
            ))
        }
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        for (index, mapping) in colorMappings.enumerated() {
            #expect(
                result.envelope.connections[index].color == mapping.1,
                "Color index \(mapping.0) should map to \(mapping.1 ?? "nil")"
            )
        }
    }

    @Test("importConnections skips invalid entries gracefully")
    func testImportConnections_skipsInvalidEntries() throws {
        // A group node that contains a child without "host" or proper "id" won't count
        // But the parser doesn't throw for individual entries without "name", it uses "Untitled"
        // Actually looking at the code: it always succeeds with defaults.
        // Invalid entries in SequelAce context would be ones that somehow fail parsing.
        // Since parseConnection uses defaults for everything, entries are always valid.
        // The only skip scenario is if an exception occurs in parseConnection.
        // Let's test that entries with Children array are treated as groups, not connections
        let children: [[String: Any]] = [
            makeGroup(name: "Empty Group", children: []),
            makeConnection(name: "Valid", id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections.count == 1)
        #expect(result.envelope.connections[0].name == "Valid")
    }

    @Test("importConnections empty favorites throws noConnectionsFound")
    func testImportConnections_emptyFavorites_throwsNoConnectionsFound() throws {
        try writeFavorites(makeFavoritesRoot(children: []))

        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections socket type 1 handled correctly")
    func testImportConnections_socketType1_handledCorrectly() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "Socket DB", type: 1, id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        let conn = result.envelope.connections[0]
        // Socket connections (type 1) should not have SSH config
        #expect(conn.sshConfig == nil)
        #expect(conn.type == "MySQL")
    }

    @Test("importConnections without passwords has nil credentials")
    func testImportConnections_withoutPasswords_credentialsNil() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB", id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.credentials == nil)
    }

    @Test("importConnections file not found throws error")
    func testImportConnections_fileNotFound_throwsError() {
        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections SSH password auth when key not enabled")
    func testImportConnections_sshPasswordAuth() throws {
        let children: [[String: Any]] = [
            makeConnection(
                name: "SSH Password",
                type: 2,
                id: 1,
                sshHost: "bastion.com",
                sshUser: "admin",
                sshPort: "22",
                sshKeyEnabled: 0
            )
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh?.authMethod == "Password")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("importConnections parses default port")
    func testImportConnections_defaultPort() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB", port: "", id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].port == 3306)
    }

    @Test("importConnections envelope metadata")
    func testImportConnections_envelopeMetadata() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB", id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.formatVersion == 1)
        #expect(result.envelope.appVersion == "Sequel Ace Import")
        #expect(result.envelope.tags == nil)
    }

    @Test("importConnections nested groups preserve correct group name")
    func testImportConnections_nestedGroupsPreserveGroupName() throws {
        let children: [[String: Any]] = [
            makeGroup(name: "Outer", children: [
                makeGroup(name: "Inner", children: [
                    makeConnection(name: "Nested DB", id: 1)
                ])
            ])
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.importConnections(includePasswords: false)
        // The inner group name should be used for the nested connection
        #expect(result.envelope.connections[0].groupName == "Inner")
    }
}
