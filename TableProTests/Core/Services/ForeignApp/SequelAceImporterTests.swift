//
//  SequelAceImporterTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import TableProPluginKit
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
        imp.queryFavoritesFileURL = tempDir.appendingPathComponent("com.sequel-ace.sequel-ace.plist")
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
        sshPort: Any = 22 as Int,
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

    /// `isAvailable()` answers "is Sequel Ace installed", not "is there a favorites file". #1318
    /// moved every foreign-app importer to LaunchServices and deleted this one's file-based
    /// override; the case kept asserting the old contract and was quarantined rather than updated.
    /// Its sibling below passed on CI only because Sequel Ace is not installed on the runner, which
    /// made it assert nothing. Both now drive `resolveAppURL`, so neither depends on what happens to
    /// be installed on the machine running them.
    ///
    /// DBeaver and DataGrip do keep a data-file arm on top of LaunchServices, because a Toolbox or
    /// portable install can be invisible to it. A Sequel Ace install is an ordinary `.app`, so it
    /// has no such arm and none is expected here.
    @Test("isAvailable returns true when the app is installed")
    func testIsAvailable_whenAppInstalled_returnsTrue() throws {
        var imp = importer
        imp.resolveAppURL = { _ in URL(fileURLWithPath: "/Applications/Sequel Ace.app") }
        #expect(imp.isAvailable() == true)
    }

    @Test("isAvailable is false when the app is absent, even with a favorites file present")
    func testIsAvailable_whenAppMissingButFileExists_returnsFalse() throws {
        try writeFavorites(makeFavoritesRoot(children: []))
        var imp = importer
        imp.resolveAppURL = { _ in nil }
        #expect(imp.isAvailable() == false)
    }

    // MARK: - inventory

    @Test("inventory counts connections in every group")
    func testInventory_returnsCorrectCount() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB1", id: 1),
            makeConnection(name: "DB2", id: 2),
            makeGroup(name: "Group", children: [
                makeConnection(name: "DB3", id: 3)
            ])
        ]
        try writeFavorites(makeFavoritesRoot(children: children))
        #expect(importer.inventory() == ForeignAppInventory(connections: 3, savedQueries: 0))
    }

    @Test("inventory is empty when the files are missing")
    func testInventory_fileMissing_returnsZero() {
        #expect(importer.inventory() == ForeignAppInventory(connections: 0, savedQueries: 0))
    }

    // MARK: - collect

    @Test("collect parses all connections")
    func testCollect_parsesAllConnections() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB1", id: 1),
            makeConnection(name: "DB2", id: 2)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections.count == 2)
        #expect(result.source == .foreignApp(name: "Sequel Ace"))
    }

    @Test("collect type is always MySQL")
    func testCollect_typeAlwaysMySQL() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "TCP", type: 0, id: 1),
            makeConnection(name: "Socket", type: 1, id: 2),
            makeConnection(name: "SSH", type: 2, id: 3, sshHost: "bastion.com", sshUser: "user")
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        for conn in result.connections {
            #expect(conn.type == "MySQL")
        }
    }

    @Test("collect parses SSH for type 2")
    func testCollect_parsesSSHForType2() throws {
        let children: [[String: Any]] = [
            makeConnection(
                name: "SSH DB",
                type: 2,
                id: 1,
                sshHost: "bastion.example.com",
                sshUser: "deploy",
                sshPort: 2222,
                sshKeyEnabled: 1,
                sshKeyLocation: "~/.ssh/id_ed25519"
            )
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.enabled == true)
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "~/.ssh/id_ed25519")
    }

    @Test("collect no SSH for type 0")
    func testCollect_noSSHForType0() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "TCP DB", type: 0, id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].sshConfig == nil)
    }

    @Test("collect parses SSL config")
    func testCollect_parsesSSLConfig() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Required")
        #expect(ssl?.caCertificatePath == "/path/to/ca.pem")
        #expect(ssl?.clientCertificatePath == "/path/to/client-cert.pem")
        #expect(ssl?.clientKeyPath == "/path/to/client-key.pem")
    }

    @Test("collect no SSL when useSSL is 0")
    func testCollect_noSSLWhenDisabled() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "No SSL", id: 1, useSSL: 0)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].sslConfig == nil)
    }

    @Test("collect recursive group parsing")
    func testCollect_recursiveGroupParsing() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let connections = result.connections

        #expect(connections.count == 4)
        #expect(result.groupPath(at: 0) == ["Production"])
        #expect(result.groupPath(at: 1) == ["Production"])
        #expect(result.groupPath(at: 2).isEmpty)
        #expect(result.groupPath(at: 3) == ["Staging"])
        #expect(Set(result.bundle.groups.map { $0.name }) == ["Production", "Staging"])
    }

    @Test("collect color index mapping")
    func testCollect_colorIndexMapping() throws {
        let colorMappings: [(Int, String?)] = [
            (0, "Red"),
            (1, "Orange"),
            (2, "Yellow"),
            (3, "Green"),
            (4, "Blue"),
            (5, "Purple"),
            (6, "Pink"),
            (7, "Gray"),
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

        let result = try importer.collect(.connectionsOnly)
        for (index, mapping) in colorMappings.enumerated() {
            #expect(
                result.connections[index].color == mapping.1,
                "Color index \(mapping.0) should map to \(mapping.1 ?? "nil")"
            )
        }
    }

    @Test("collect skips invalid entries gracefully")
    func testCollect_skipsInvalidEntries() throws {
        let children: [[String: Any]] = [
            makeGroup(name: "Empty Group", children: []),
            makeConnection(name: "Valid", id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections.count == 1)
        #expect(result.connections[0].name == "Valid")
    }

    @Test("collect empty favorites throws noConnectionsFound")
    func testCollect_emptyFavorites_throwsNoConnectionsFound() throws {
        try writeFavorites(makeFavoritesRoot(children: []))

        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect socket type 1 handled correctly")
    func testCollect_socketType1_handledCorrectly() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "Socket DB", type: 1, id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        let conn = result.connections[0]
        // Socket connections (type 1) should not have SSH config
        #expect(conn.sshConfig == nil)
        #expect(conn.type == "MySQL")
    }

    @Test("collect without passwords has nil credentials")
    func testCollect_withoutPasswords_credentialsNil() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB", id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.bundle.credentials.isEmpty)
    }

    @Test("collect file not found throws error")
    func testCollect_fileNotFound_throwsError() {
        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect SSH password auth when key not enabled")
    func testCollect_sshPasswordAuth() throws {
        let children: [[String: Any]] = [
            makeConnection(
                name: "SSH Password",
                type: 2,
                id: 1,
                sshHost: "bastion.com",
                sshUser: "admin",
                sshPort: 22,
                sshKeyEnabled: 0
            )
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh?.authMethod == "Password")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("collect parses default port")
    func testCollect_defaultPort() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB", port: "", id: 1)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].port == 3306)
    }

    @Test("collect stamps the bundle and keys the connection by its Sequel Ace id")
    func testCollect_bundleMetadata() throws {
        let children: [[String: Any]] = [
            makeConnection(name: "DB", id: 42)
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.bundle.appVersion == "Sequel Ace Import")
        #expect(result.bundle.tags.isEmpty)
        #expect(result.bundle.connections.map { $0.ref } == ["42"])
    }

    @Test("collect keeps the full path of nested groups")
    func testCollect_nestedGroupsPreserveGroupName() throws {
        let children: [[String: Any]] = [
            makeGroup(name: "Outer", children: [
                makeGroup(name: "Inner", children: [
                    makeConnection(name: "Nested DB", id: 1)
                ])
            ])
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.groupPath(at: 0) == ["Outer", "Inner"])
    }

    @Test("collect SSH port parsed as Int")
    func testCollect_sshPortParsedAsInt() throws {
        let children: [[String: Any]] = [
            makeConnection(
                name: "SSH Int Port",
                type: 2,
                id: 1,
                sshHost: "bastion.com",
                sshUser: "deploy",
                sshPort: 2222
            )
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh?.port == 2222)
    }

    @Test("collect SSH port parsed as String fallback")
    func testCollect_sshPortParsedAsString() throws {
        let children: [[String: Any]] = [
            makeConnection(
                name: "SSH String Port",
                type: 2,
                id: 1,
                sshHost: "bastion.com",
                sshUser: "deploy",
                sshPort: "3333"
            )
        ]
        try writeFavorites(makeFavoritesRoot(children: children))

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh?.port == 3333)
    }

    // MARK: - Query Favorites

    private func writeQueryFavorites(_ favorites: [[String: Any]]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["queryFavorites": favorites, "SomeOtherPreference": true] as [String: Any],
            format: .binary,
            options: 0
        )
        try data.write(to: importer.queryFavoritesFileURL)
    }

    @Test("collect reads query favorites as global queries, placeholders verbatim, tab trigger as keyword")
    func testCollect_readsQueryFavorites() throws {
        try writeFavorites(makeFavoritesRoot(children: [makeConnection(name: "DB", id: 1)]))
        try writeQueryFavorites([
            ["name": "Recent orders", "query": "SELECT * FROM orders WHERE id > ${1:x};", "tabtrigger": "ro"],
            ["name": "Plain", "query": "SELECT 1;"],
            ["name": "Blank", "query": "  \n  "]
        ])

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQueryNames == ["Recent orders", "Plain"])
        let recent = try #require(result.savedQuery(named: "Recent orders"))
        #expect(recent.sql == "SELECT * FROM orders WHERE id > ${1:x};")
        #expect(recent.keyword == "ro")
        #expect(recent.connectionRef == nil)
        #expect(result.folderPath(of: recent) == ["Sequel Ace"])
        #expect(result.isSuggested(recent))
        #expect(result.savedQuery(named: "Plain")?.keyword == nil)
    }

    @Test("collect reads no query favorites unless saved queries are requested")
    func testCollect_withoutSavedQueries_readsNoQueryFavorites() throws {
        try writeFavorites(makeFavoritesRoot(children: [makeConnection(name: "DB", id: 1)]))
        try writeQueryFavorites([["name": "Plain", "query": "SELECT 1;"]])

        let result = try importer.collect(.connectionsOnly)

        #expect(result.bundle.savedQueries.isEmpty)
    }

    @Test("A missing preferences file means no query favorites")
    func testCollect_missingPreferences_importsConnectionsOnly() throws {
        try writeFavorites(makeFavoritesRoot(children: [makeConnection(name: "DB", id: 1)]))

        let result = try importer.collect(.withSavedQueries)

        #expect(result.connections.count == 1)
        #expect(result.bundle.savedQueries.isEmpty)
    }

    @Test("inventory counts query favorites that have text")
    func testInventory_countsQueryFavorites() throws {
        try writeFavorites(makeFavoritesRoot(children: [makeConnection(name: "DB", id: 1)]))
        try writeQueryFavorites([
            ["name": "One", "query": "SELECT 1;"],
            ["name": "Two", "query": "SELECT 2;"],
            ["name": "Blank", "query": ""]
        ])

        #expect(importer.inventory() == ForeignAppInventory(connections: 1, savedQueries: 2))
    }
}
