//
//  TablePlusImporterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("TablePlusImporter", .serialized)
struct TablePlusImporterTests {
    private var tempDir: URL
    private var importer: TablePlusImporter

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TablePlusImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var imp = TablePlusImporter()
        imp.connectionsFileURL = tempDir.appendingPathComponent("Connections.plist")
        imp.groupsFileURL = tempDir.appendingPathComponent("ConnectionGroups.plist")
        importer = imp
    }

    // MARK: - Fixture Helpers

    private func writeConnections(_ entries: [[String: Any]]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries,
            format: .xml,
            options: 0
        )
        try data.write(to: importer.connectionsFileURL)
    }

    private func writeGroups(_ groups: [[String: Any]]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: groups,
            format: .xml,
            options: 0
        )
        try data.write(to: importer.groupsFileURL)
    }

    private func makeConnection(
        name: String = "Test DB",
        driver: String = "MySQL",
        host: String = "db.example.com",
        port: String = "3306",
        user: String = "admin",
        database: String = "mydb",
        id: String = "conn-1",
        groupId: String = "",
        isOverSSH: Bool = false,
        sshHost: String = "",
        sshPort: String = "22",
        sshUser: String = "",
        usePrivateKey: Bool = false,
        privateKeyPath: String = "",
        tlsMode: Int? = nil,
        tlsKeyPaths: [String] = [],
        environment: String = ""
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "ConnectionName": name,
            "Driver": driver,
            "DatabaseHost": host,
            "DatabasePort": port,
            "DatabaseUser": user,
            "DatabaseName": database,
            "ID": id,
            "GroupID": groupId,
            "isOverSSH": isOverSSH,
            "Enviroment": environment
        ]
        if let tlsMode {
            entry["tLSMode"] = tlsMode
        }
        if isOverSSH {
            entry["ServerAddress"] = sshHost
            entry["ServerPort"] = sshPort
            entry["ServerUser"] = sshUser
            entry["isUsePrivateKey"] = usePrivateKey
            entry["ServerPrivateKeyName"] = privateKeyPath
        }
        if !tlsKeyPaths.isEmpty {
            entry["TlsKeyPaths"] = tlsKeyPaths
        }
        return entry
    }

    // MARK: - isAvailable

    @Test("isAvailable returns true when file exists")
    func testIsAvailable_whenFileExists_returnsTrue() throws {
        try writeConnections([makeConnection()])
        #expect(importer.isAvailable() == true)
    }

    @Test("isAvailable returns false when file is missing")
    func testIsAvailable_whenFileMissing_returnsFalse() {
        #expect(importer.isAvailable() == false)
    }

    // MARK: - connectionCount

    @Test("connectionCount returns correct count")
    func testConnectionCount_returnsCorrectCount() throws {
        try writeConnections([
            makeConnection(name: "DB1", id: "c1"),
            makeConnection(name: "DB2", id: "c2"),
            makeConnection(name: "DB3", id: "c3")
        ])
        #expect(importer.connectionCount() == 3)
    }

    @Test("connectionCount returns 0 when file missing")
    func testConnectionCount_fileMissing_returnsZero() {
        #expect(importer.connectionCount() == 0)
    }

    // MARK: - importConnections

    @Test("importConnections parses all connections")
    func testImportConnections_parsesAllConnections() throws {
        try writeConnections([
            makeConnection(name: "DB1", id: "c1"),
            makeConnection(name: "DB2", id: "c2")
        ])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections.count == 2)
        #expect(result.sourceName == "TablePlus")
    }

    @Test("importConnections maps driver correctly")
    func testImportConnections_mapsDriverCorrectly() throws {
        let driverMappings: [(String, String)] = [
            ("MySQL", "MySQL"),
            ("PostgreSQL", "PostgreSQL"),
            ("Mongo", "MongoDB"),
            ("SQLite", "SQLite"),
            ("Redis", "Redis"),
            ("MSSQL", "SQL Server"),
            ("Redshift", "Redshift"),
            ("MariaDB", "MariaDB"),
            ("CockroachDB", "PostgreSQL")
        ]

        var entries: [[String: Any]] = []
        for (index, mapping) in driverMappings.enumerated() {
            entries.append(makeConnection(
                name: "Conn \(mapping.0)",
                driver: mapping.0,
                id: "c\(index)"
            ))
        }
        try writeConnections(entries)

        let result = try importer.importConnections(includePasswords: false)
        for (index, mapping) in driverMappings.enumerated() {
            #expect(
                result.envelope.connections[index].type == mapping.1,
                "Driver \(mapping.0) should map to \(mapping.1)"
            )
        }
    }

    @Test("importConnections parses SSH config")
    func testImportConnections_parsesSSHConfig() throws {
        try writeConnections([
            makeConnection(
                name: "SSH DB",
                id: "ssh-1",
                isOverSSH: true,
                sshHost: "bastion.example.com",
                sshPort: "2222",
                sshUser: "deploy",
                usePrivateKey: true,
                privateKeyPath: "~/.ssh/id_rsa"
            )
        ])

        let result = try importer.importConnections(includePasswords: false)
        let conn = result.envelope.connections[0]
        let ssh = conn.sshConfig

        #expect(ssh != nil)
        #expect(ssh?.enabled == true)
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "~/.ssh/id_rsa")
    }

    @Test("importConnections parses SSH config with password auth")
    func testImportConnections_parsesSSHConfigPasswordAuth() throws {
        try writeConnections([
            makeConnection(
                name: "SSH Password DB",
                id: "ssh-2",
                isOverSSH: true,
                sshHost: "jump.example.com",
                sshPort: "22",
                sshUser: "admin",
                usePrivateKey: false
            )
        ])

        let result = try importer.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.authMethod == "Password")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("importConnections parses SSL config")
    func testImportConnections_parsesSSLConfig() throws {
        try writeConnections([
            makeConnection(
                name: "SSL DB",
                id: "ssl-1",
                tlsMode: 1,
                tlsKeyPaths: ["/path/to/ca.pem", "/path/to/client-cert.pem", "/path/to/client-key.pem"]
            )
        ])

        let result = try importer.importConnections(includePasswords: false)
        let conn = result.envelope.connections[0]
        let ssl = conn.sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Required")
        #expect(ssl?.caCertificatePath == "/path/to/ca.pem")
        #expect(ssl?.clientCertificatePath == "/path/to/client-cert.pem")
        #expect(ssl?.clientKeyPath == "/path/to/client-key.pem")
    }

    @Test("importConnections no SSL when tLSMode key is absent")
    func testImportConnections_noSSLWhenTLSModeAbsent() throws {
        try writeConnections([
            makeConnection(name: "No SSL", id: "nossl-1")
        ])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sslConfig == nil)
    }

    @Test("importConnections SSL mode Preferred when tLSMode is 0")
    func testImportConnections_sslModePreferredWhenTLSModeZero() throws {
        try writeConnections([
            makeConnection(name: "Prefer SSL", id: "ssl-prefer", tlsMode: 0)
        ])

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig
        #expect(ssl != nil)
        #expect(ssl?.mode == "Preferred")
    }

    @Test("importConnections SSL mode Verify CA when tLSMode is 2")
    func testImportConnections_sslModeVerifyCA() throws {
        try writeConnections([
            makeConnection(name: "Verify CA", id: "ssl-ca", tlsMode: 2)
        ])

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig
        #expect(ssl != nil)
        #expect(ssl?.mode == "Verify CA")
    }

    @Test("importConnections SSL mode Verify Identity when tLSMode is 3")
    func testImportConnections_sslModeVerifyIdentity() throws {
        try writeConnections([
            makeConnection(name: "Verify Identity", id: "ssl-identity", tlsMode: 3)
        ])

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig
        #expect(ssl != nil)
        #expect(ssl?.mode == "Verify Identity")
    }

    @Test("importConnections no SSL for unknown tLSMode value")
    func testImportConnections_noSSLForUnknownTLSMode() throws {
        try writeConnections([
            makeConnection(name: "Unknown TLS", id: "ssl-unknown", tlsMode: 99)
        ])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sslConfig == nil)
    }

    @Test("importConnections preserves groups")
    func testImportConnections_preservesGroups() throws {
        try writeGroups([
            ["ID": "group-1", "Name": "Production"],
            ["ID": "group-2", "Name": "Development"]
        ])
        try writeConnections([
            makeConnection(name: "Prod DB", id: "c1", groupId: "group-1"),
            makeConnection(name: "Dev DB", id: "c2", groupId: "group-2"),
            makeConnection(name: "Ungrouped", id: "c3", groupId: "")
        ])

        let result = try importer.importConnections(includePasswords: false)
        let connections = result.envelope.connections

        #expect(connections[0].groupName == "Production")
        #expect(connections[1].groupName == "Development")
        #expect(connections[2].groupName == nil)

        let groups = result.envelope.groups
        #expect(groups != nil)
        #expect(groups?.count == 2)
        let groupNameSet = Set(groups?.map(\.name) ?? [])
        #expect(groupNameSet.contains("Production"))
        #expect(groupNameSet.contains("Development"))
    }

    @Test("importConnections parses port from string")
    func testImportConnections_parsesPortFromString() throws {
        try writeConnections([
            makeConnection(name: "Custom Port", port: "5433", id: "c1")
        ])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].port == 5433)
    }

    @Test("importConnections uses default port when missing")
    func testImportConnections_defaultPortWhenMissing() throws {
        try writeConnections([
            makeConnection(name: "MySQL No Port", driver: "MySQL", port: "", id: "c1"),
            makeConnection(name: "PG No Port", driver: "PostgreSQL", port: "", id: "c2"),
            makeConnection(name: "Mongo No Port", driver: "Mongo", port: "", id: "c3"),
            makeConnection(name: "Redis No Port", driver: "Redis", port: "", id: "c4"),
            makeConnection(name: "MSSQL No Port", driver: "MSSQL", port: "", id: "c5")
        ])

        let result = try importer.importConnections(includePasswords: false)
        let connections = result.envelope.connections

        #expect(connections[0].port == 3306)
        #expect(connections[1].port == 5432)
        #expect(connections[2].port == 27_017)
        #expect(connections[3].port == 6379)
        #expect(connections[4].port == 1433)
    }

    @Test("importConnections skips invalid entries")
    func testImportConnections_skipsInvalidEntries() throws {
        // Entry without ConnectionName should be skipped
        let invalidEntry: [String: Any] = [
            "Driver": "MySQL",
            "DatabaseHost": "localhost",
            "ID": "invalid-1"
        ]
        let validEntry = makeConnection(name: "Valid", id: "valid-1")
        try writeConnections([invalidEntry, validEntry])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections.count == 1)
        #expect(result.envelope.connections[0].name == "Valid")
    }

    @Test("importConnections without passwords has nil credentials")
    func testImportConnections_withoutPasswords_credentialsNil() throws {
        try writeConnections([makeConnection(name: "DB", id: "c1")])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.credentials == nil)
    }

    @Test("importConnections empty file throws noConnectionsFound")
    func testImportConnections_emptyFile_throwsNoConnectionsFound() throws {
        // Write an empty array plist
        try writeConnections([])

        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections with only invalid entries throws noConnectionsFound")
    func testImportConnections_allInvalid_throwsNoConnectionsFound() throws {
        // All entries missing ConnectionName
        let invalid: [String: Any] = ["Driver": "MySQL", "ID": "x"]
        try writeConnections([invalid, invalid])

        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections file not found throws error")
    func testImportConnections_fileNotFound_throwsError() {
        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections maps environment colors")
    func testImportConnections_mapsEnvironmentColors() throws {
        try writeConnections([
            makeConnection(name: "Staging", id: "c1", environment: "staging"),
            makeConnection(name: "Prod", id: "c2", environment: "production"),
            makeConnection(name: "Test", id: "c3", environment: "testing"),
            makeConnection(name: "Dev", id: "c4", environment: "development"),
            makeConnection(name: "None", id: "c5", environment: "")
        ])

        let result = try importer.importConnections(includePasswords: false)
        let connections = result.envelope.connections

        #expect(connections[0].color == "Yellow")
        #expect(connections[1].color == "Red")
        #expect(connections[2].color == "Blue")
        #expect(connections[3].color == "Green")
        #expect(connections[4].color == nil)
    }

    @Test("importConnections SQLite uses DatabasePath")
    func testImportConnections_sqliteUsesDatabasePath() throws {
        var entry = makeConnection(name: "Local SQLite", driver: "SQLite", id: "c1")
        entry["DatabasePath"] = "/Users/me/data.db"
        try writeConnections([entry])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].database == "/Users/me/data.db")
    }

    @Test("importConnections envelope metadata")
    func testImportConnections_envelopeMetadata() throws {
        try writeConnections([makeConnection()])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.formatVersion == 1)
        #expect(result.envelope.appVersion == "TablePlus Import")
        #expect(result.envelope.tags == nil)
    }
}
