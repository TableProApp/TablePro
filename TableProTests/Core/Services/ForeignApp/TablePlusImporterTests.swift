//
//  TablePlusImporterTests.swift
//  TableProTests
//

import Foundation
import TableProImport
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
        imp.dataDirectoryOverride = tempDir
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
        environment: String = "",
        databasePasswordMode: Int? = nil,
        serverPasswordMode: Int? = nil
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
        if let databasePasswordMode {
            entry["DatabasePasswordMode"] = databasePasswordMode
        }
        if let serverPasswordMode {
            entry["ServerPasswordMode"] = serverPasswordMode
        }
        return entry
    }

    // MARK: - Edition detection

    @Test("isAvailable returns true when the standalone app is installed")
    func testIsAvailable_whenStandaloneInstalled_returnsTrue() {
        var imp = TablePlusImporter()
        imp.resolveAppURL = { $0 == "com.tinyapp.TablePlus" ? URL(fileURLWithPath: "/Applications/TablePlus.app") : nil }
        #expect(imp.isAvailable() == true)
    }

    @Test("isAvailable returns true when only the Setapp edition is installed")
    func testIsAvailable_whenSetappInstalled_returnsTrue() {
        var imp = TablePlusImporter()
        imp.resolveAppURL = {
            $0 == "com.tinyapp.TablePlus-setapp"
                ? URL(fileURLWithPath: "/Applications/Setapp/TablePlus.app")
                : nil
        }
        #expect(imp.isAvailable() == true)
        #expect(imp.installedAppURL() == URL(fileURLWithPath: "/Applications/Setapp/TablePlus.app"))
    }

    @Test("isAvailable returns false when no edition is installed")
    func testIsAvailable_whenNoEditionInstalled_returnsFalse() {
        var imp = TablePlusImporter()
        imp.resolveAppURL = { _ in nil }
        #expect(imp.isAvailable() == false)
        #expect(imp.installedAppURL() == nil)
    }

    @Test("installedAppURL prefers the standalone edition when both are installed")
    func testInstalledAppURL_prefersStandaloneWhenBothInstalled() {
        let standalone = URL(fileURLWithPath: "/Applications/TablePlus.app")
        let setapp = URL(fileURLWithPath: "/Applications/Setapp/TablePlus.app")
        var imp = TablePlusImporter()
        imp.resolveAppURL = { $0 == "com.tinyapp.TablePlus" ? standalone : setapp }
        #expect(imp.installedAppURL() == standalone)
    }

    @Test("dataDirectory derives from the Setapp bundle identifier")
    func testDataDirectory_forSetappEdition() {
        let home = URL(fileURLWithPath: "/Users/test")
        let dir = TablePlusImporter.dataDirectory(forBundleIdentifier: "com.tinyapp.TablePlus-setapp", home: home)
        #expect(dir.path == "/Users/test/Library/Application Support/com.tinyapp.TablePlus-setapp/Data")
    }

    @Test("connectionsFileURL follows the installed Setapp edition")
    func testConnectionsFileURL_followsSetappEdition() {
        var imp = TablePlusImporter()
        imp.resolveAppURL = {
            $0 == "com.tinyapp.TablePlus-setapp"
                ? URL(fileURLWithPath: "/Applications/Setapp/TablePlus.app")
                : nil
        }
        #expect(imp.connectionsFileURL.path.hasSuffix(
            "Library/Application Support/com.tinyapp.TablePlus-setapp/Data/Connections.plist"
        ))
        #expect(imp.groupsFileURL.path.hasSuffix(
            "Library/Application Support/com.tinyapp.TablePlus-setapp/Data/ConnectionGroups.plist"
        ))
    }

    @Test("connectionsFileURL falls back to the standalone edition when none is installed")
    func testConnectionsFileURL_fallsBackToStandalone() {
        var imp = TablePlusImporter()
        imp.resolveAppURL = { _ in nil }
        #expect(imp.connectionsFileURL.path.hasSuffix(
            "Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist"
        ))
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

    @Test("importConnections maps every driver TablePlus 26.10 writes")
    func testImportConnections_mapsDriverCorrectly() throws {
        let driverMappings: [(String, String)] = [
            ("MicrosoftSQLServer", "SQL Server"),
            ("Mongo", "MongoDB"),
            ("Cockroach", "CockroachDB"),
            ("CloudflareD1", "Cloudflare D1"),
            ("LibSQL", "libSQL"),
            ("ElasticSearch", "Elasticsearch"),
            ("MySQL", "MySQL"),
            ("MariaDB", "MariaDB"),
            ("PostgreSQL", "PostgreSQL"),
            ("Redshift", "Redshift"),
            ("Redis", "Redis"),
            ("Oracle", "Oracle"),
            ("SQLite", "SQLite"),
            ("DuckDB", "DuckDB"),
            ("ClickHouse", "ClickHouse"),
            ("BigQuery", "BigQuery"),
            ("DynamoDB", "DynamoDB"),
            ("Snowflake", "Snowflake"),
            ("Cassandra", "Cassandra"),
            ("Vertica", "Vertica"),
            ("Greenplum", "Greenplum")
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

    @Test("importConnections parses SSH config and keeps an explicit key path even when the file is missing")
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
                privateKeyPath: "/Users/test/.ssh/id_rsa"
            )
        ])

        var imp = importer
        imp.keyFileExists = { _ in false }

        let result = try imp.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.enabled == true)
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2_222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "/Users/test/.ssh/id_rsa")
    }

    @Test("importConnections drops the empty-key placeholder instead of building a fake path")
    func testImportConnections_placeholderPrivateKey_producesNoPath() throws {
        try writeConnections([
            makeConnection(
                name: "SSH Placeholder",
                id: "ssh-placeholder",
                isOverSSH: true,
                sshHost: "bastion.example.com",
                sshUser: "deploy",
                usePrivateKey: true,
                privateKeyPath: "Import a private key..."
            )
        ])

        var imp = importer
        imp.keyFileExists = { _ in false }

        let result = try imp.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("importConnections keeps a bare key name when the file exists in ~/.ssh")
    func testImportConnections_bareKeyName_keptWhenFileExists() throws {
        try writeConnections([
            makeConnection(
                name: "SSH Bare Key",
                id: "ssh-bare",
                isOverSSH: true,
                sshHost: "bastion.example.com",
                sshUser: "deploy",
                usePrivateKey: true,
                privateKeyPath: "id_rsa"
            )
        ])

        var imp = importer
        imp.keyFileExists = { _ in true }

        let result = try imp.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sshConfig?.privateKeyPath == "~/.ssh/id_rsa")
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

    @Test("importConnections reads TlsKeyPaths in TablePlus order: key, certificate, CA")
    func testImportConnections_parsesSSLConfig() throws {
        try writeConnections([
            makeConnection(
                name: "SSL DB",
                id: "ssl-1",
                tlsMode: 2,
                tlsKeyPaths: ["/path/to/client-key.pem", "/path/to/client-cert.pem", "/path/to/ca.pem"]
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

    @Test("importConnections reads tLSMode against the popup the driver's own form shows")
    func testImportConnections_sslModeFollowsDriverVocabulary() throws {
        let cases: [(driver: String, tlsMode: Int, mode: String)] = [
            ("MySQL", 0, "Preferred"),
            ("MySQL", 1, "Disabled"),
            ("MySQL", 2, "Required"),
            ("MySQL", 3, "Verify CA"),
            ("MySQL", 4, "Verify Identity"),
            ("MariaDB", 1, "Required"),
            ("MariaDB", 2, "Verify Identity"),
            ("PostgreSQL", 1, "Disabled"),
            ("PostgreSQL", 2, "Required"),
            ("PostgreSQL", 3, "Preferred"),
            ("PostgreSQL", 4, "Verify CA"),
            ("PostgreSQL", 5, "Verify Identity"),
            ("Cockroach", 5, "Verify Identity"),
            ("Redshift", 4, "Verify CA"),
            ("Cassandra", 0, "Disabled"),
            ("Cassandra", 2, "Verify CA"),
            ("Cassandra", 4, "Verify Identity"),
            ("Redis", 0, "Disabled"),
            ("Redis", 2, "Verify CA"),
            ("ClickHouse", 1, "Verify Identity"),
            ("ClickHouse", 2, "Required"),
            ("Mongo", 1, "Verify Identity"),
            ("ElasticSearch", 1, "Verify Identity"),
            ("ElasticSearch", 2, "Verify CA"),
            ("ElasticSearch", 3, "Required"),
            ("Oracle", 1, "Required")
        ]

        try writeConnections(cases.enumerated().map { index, testCase in
            makeConnection(
                name: "\(testCase.driver) \(testCase.tlsMode)",
                driver: testCase.driver,
                id: "ssl-\(index)",
                tlsMode: testCase.tlsMode
            )
        })

        let connections = try importer.importConnections(includePasswords: false).envelope.connections
        for (index, testCase) in cases.enumerated() {
            #expect(
                connections[index].sslConfig?.mode == testCase.mode,
                "\(testCase.driver) tLSMode \(testCase.tlsMode) should map to \(testCase.mode)"
            )
        }
    }

    @Test("importConnections reads the TLS slots each driver's own form writes")
    func testImportConnections_tlsKeySlotsFollowDriverForm() throws {
        try writeConnections([
            makeConnection(
                name: "Cassandra TLS",
                driver: "Cassandra",
                id: "tls-cassandra",
                tlsMode: 2,
                tlsKeyPaths: ["/path/to/cass-key.pem", "/path/to/cass-cert.pem", "/path/to/cass-ca.pem"]
            ),
            makeConnection(
                name: "Cassandra CA only",
                driver: "Cassandra",
                id: "tls-cassandra-ca",
                tlsMode: 3,
                tlsKeyPaths: ["", "", "/path/to/cass-ca.pem"]
            ),
            makeConnection(
                name: "Mongo TLS",
                driver: "Mongo",
                id: "tls-mongo",
                tlsMode: 1,
                tlsKeyPaths: ["/path/to/mongo-certkey.pem", "/path/to/mongo-ca.pem"]
            ),
            makeConnection(
                name: "ClickHouse TLS",
                driver: "ClickHouse",
                id: "tls-clickhouse",
                tlsMode: 1,
                tlsKeyPaths: ["/path/to/clickhouse-ca.pem"]
            ),
            makeConnection(
                name: "Elasticsearch TLS",
                driver: "ElasticSearch",
                id: "tls-es",
                tlsMode: 2,
                tlsKeyPaths: ["/path/to/es-ca.pem"]
            )
        ])

        let connections = try importer.importConnections(includePasswords: false).envelope.connections

        #expect(connections[0].sslConfig?.clientKeyPath == "/path/to/cass-key.pem")
        #expect(connections[0].sslConfig?.clientCertificatePath == "/path/to/cass-cert.pem")
        #expect(connections[0].sslConfig?.caCertificatePath == "/path/to/cass-ca.pem")

        #expect(connections[1].sslConfig?.caCertificatePath == "/path/to/cass-ca.pem")
        #expect(connections[1].sslConfig?.clientKeyPath == nil)
        #expect(connections[1].sslConfig?.clientCertificatePath == nil)

        #expect(connections[2].sslConfig?.clientCertificatePath == "/path/to/mongo-certkey.pem")
        #expect(connections[2].sslConfig?.caCertificatePath == "/path/to/mongo-ca.pem")
        #expect(connections[2].sslConfig?.clientKeyPath == nil)

        #expect(connections[3].sslConfig?.caCertificatePath == "/path/to/clickhouse-ca.pem")
        #expect(connections[3].sslConfig?.clientCertificatePath == nil)
        #expect(connections[3].sslConfig?.clientKeyPath == nil)

        #expect(connections[4].sslConfig?.caCertificatePath == "/path/to/es-ca.pem")
        #expect(connections[4].sslConfig?.clientCertificatePath == nil)
    }

    @Test("importConnections carries no TLS paths for a driver whose form has no file pickers")
    func testImportConnections_oracleCarriesNoTLSPaths() throws {
        try writeConnections([
            makeConnection(
                name: "Oracle TLS",
                driver: "Oracle",
                id: "tls-oracle",
                tlsMode: 1,
                tlsKeyPaths: ["/stray/a.pem", "/stray/b.pem", "/stray/c.pem"]
            )
        ])

        let ssl = try importer.importConnections(includePasswords: false).envelope.connections[0].sslConfig
        #expect(ssl?.mode == "Required")
        #expect(ssl?.caCertificatePath == nil)
        #expect(ssl?.clientCertificatePath == nil)
        #expect(ssl?.clientKeyPath == nil)
    }

    @Test("importConnections drops an SSL mode past the end of the driver's own popup")
    func testImportConnections_noSSLForTLSModePastDriverVocabulary() throws {
        try writeConnections([
            makeConnection(name: "Unknown TLS", id: "ssl-unknown", tlsMode: 99),
            makeConnection(name: "Past MySQL", driver: "MySQL", id: "ssl-past-mysql", tlsMode: 5),
            makeConnection(name: "Past Oracle", driver: "Oracle", id: "ssl-past-oracle", tlsMode: 2)
        ])

        let connections = try importer.importConnections(includePasswords: false).envelope.connections
        #expect(connections[0].sslConfig == nil)
        #expect(connections[1].sslConfig == nil)
        #expect(connections[2].sslConfig == nil)
    }

    @Test("importConnections keeps Preferred for a driver whose form has no SSL picker")
    func testImportConnections_driverWithoutSSLPicker_staysPreferred() throws {
        try writeConnections([
            makeConnection(name: "SQL Server", driver: "MicrosoftSQLServer", id: "ssl-mssql", tlsMode: 0),
            makeConnection(name: "Snowflake", driver: "Snowflake", id: "ssl-snowflake", tlsMode: 0)
        ])

        let connections = try importer.importConnections(includePasswords: false).envelope.connections
        #expect(connections[0].sslConfig?.mode == "Preferred")
        #expect(connections[1].sslConfig?.mode == "Preferred")
    }

    @Test("importConnections treats empty TablePlus TLS paths as none")
    func testImportConnections_emptyTLSPaths_areNil() throws {
        var entry = makeConnection(name: "Empty TLS", id: "tls-empty", tlsMode: 1)
        entry["TlsKeyPaths"] = ["", "", ""]
        try writeConnections([entry])

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.caCertificatePath == nil)
        #expect(ssl?.clientCertificatePath == nil)
        #expect(ssl?.clientKeyPath == nil)
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
            makeConnection(name: "SQL Server No Port", driver: "MicrosoftSQLServer", port: "", id: "c5"),
            makeConnection(name: "Cockroach No Port", driver: "Cockroach", port: "", id: "c6"),
            makeConnection(name: "Redshift No Port", driver: "Redshift", port: "", id: "c7"),
            makeConnection(name: "Vertica No Port", driver: "Vertica", port: "", id: "c8")
        ])

        let result = try importer.importConnections(includePasswords: false)
        let connections = result.envelope.connections

        #expect(connections[0].port == 3306)
        #expect(connections[1].port == 5432)
        #expect(connections[2].port == 27_017)
        #expect(connections[3].port == 6379)
        #expect(connections[4].port == 1433)
        #expect(connections[5].port == 26_257)
        #expect(connections[6].port == 5_439)
        #expect(connections[7].port == 0)
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
        #expect(result.envelope.connections[0].additionalFields == nil)
    }

    @Test("importConnections puts a DuckDB file in the field DuckDB reads it from")
    func testImportConnections_duckDBUsesItsFilePathField() throws {
        var entry = makeConnection(name: "Local DuckDB", driver: "DuckDB", port: "", database: "", id: "c1")
        entry["DatabasePath"] = "/Users/me/warehouse.duckdb"
        try writeConnections([entry])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.type == "DuckDB")
        #expect(connection.additionalFields?["duckdbFilePath"] == "/Users/me/warehouse.duckdb")
        #expect(connection.database == "")
        #expect(connection.port == 0)
    }

    @Test("importConnections ignores DatabasePath for a server engine")
    func testImportConnections_serverEngineIgnoresDatabasePath() throws {
        var entry = makeConnection(name: "Server", driver: "MicrosoftSQLServer", database: "sales", id: "c1")
        entry["DatabasePath"] = "/tmp/stray"
        try writeConnections([entry])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.database == "sales")
        #expect(connection.additionalFields == nil)
    }

    @Test("importConnections envelope metadata")
    func testImportConnections_envelopeMetadata() throws {
        try writeConnections([makeConnection()])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.formatVersion == 1)
        #expect(result.envelope.appVersion == "TablePlus Import")
        #expect(result.envelope.tags == nil)
    }

    // MARK: - Password Import

    @Test("importConnections reads the database password from the correct keychain service")
    func testImportConnections_readsCorrectKeychainServiceAndAccount() throws {
        try writeConnections([makeConnection(name: "DB", id: "conn-1")])
        let spy = KeychainSpy()
        spy.responses["conn-1_database"] = .found("s3cret")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.importConnections(includePasswords: true)

        #expect(spy.calls.contains { $0.service == "com.tableplus.TablePlus" && $0.account == "conn-1_database" })
        #expect(result.envelope.credentials?["0"]?.password == "s3cret")
        #expect(result.credentialsAborted == false)
    }

    @Test("importConnections queries database, SSH, and key-passphrase accounts")
    func testImportConnections_queriesAllCredentialAccounts() throws {
        try writeConnections([makeConnection(name: "DB", id: "conn-1")])
        let spy = KeychainSpy()

        var imp = importer
        imp.readKeychain = spy.read

        _ = try imp.importConnections(includePasswords: true)

        let accounts = Set(spy.calls.map(\.account))
        #expect(accounts == ["conn-1_database", "conn-1_server", "conn-1_server_key"])
        #expect(spy.calls.allSatisfy { $0.service == "com.tableplus.TablePlus" })
    }

    @Test("importConnections leaves credentials empty and does not abort when nothing is stored")
    func testImportConnections_noStoredPasswords_emptyCredentialsNoAbort() throws {
        try writeConnections([makeConnection(name: "DB", id: "conn-1")])
        let spy = KeychainSpy()

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.importConnections(includePasswords: true)

        #expect(result.envelope.credentials == nil)
        #expect(result.credentialsAborted == false)
    }

    @Test("importConnections aborts and stops reading after a cancelled keychain prompt")
    func testImportConnections_cancelledPrompt_abortsAndStops() throws {
        try writeConnections([
            makeConnection(name: "A", id: "c1"),
            makeConnection(name: "B", id: "c2")
        ])
        let spy = KeychainSpy()
        spy.responses["c1_database"] = .cancelled

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.importConnections(includePasswords: true)

        #expect(result.credentialsAborted == true)
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.account == "c1_database")
    }

    // MARK: - Password Mode

    @Test("importConnections carries Ask everytime across as Prompt for password")
    func testImportConnections_askEveryTime_setsPromptForPassword() throws {
        try writeConnections([
            makeConnection(name: "Ask", id: "c1", databasePasswordMode: 1)
        ])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == "true")
    }

    @Test("importConnections leaves Store in keychain and a missing mode without a prompt")
    func testImportConnections_storeInKeychainOrAbsentMode_leavesNoPrompt() throws {
        try writeConnections([
            makeConnection(name: "Stored", id: "c1", databasePasswordMode: 0),
            makeConnection(name: "Absent", id: "c2"),
            makeConnection(name: "Unknown", id: "c3", databasePasswordMode: 47)
        ])

        let connections = try importer.importConnections(includePasswords: false).envelope.connections
        #expect(connections[0].additionalFields?["promptForPassword"] == nil)
        #expect(connections[1].additionalFields?["promptForPassword"] == nil)
        #expect(connections[2].additionalFields?["promptForPassword"] == nil)
    }

    @Test("importConnections leaves No password without a prompt")
    func testImportConnections_noPasswordMode_leavesNoPrompt() throws {
        try writeConnections([
            makeConnection(name: "None", id: "c1", databasePasswordMode: 2)
        ])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == nil)
    }

    @Test("importConnections prompts for a Command Line password TablePro cannot run")
    func testImportConnections_commandLineMode_setsPromptForPassword() throws {
        try writeConnections([
            makeConnection(name: "Command", id: "c1", databasePasswordMode: 3)
        ])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == "true")
    }

    @Test("importConnections keeps the local file path alongside the prompt flag")
    func testImportConnections_promptMergesWithFilePathField() throws {
        var entry = makeConnection(
            name: "libSQL Ask",
            driver: "LibSQL",
            port: "",
            database: "",
            id: "c1",
            databasePasswordMode: 1
        )
        entry["DatabasePath"] = "/Users/me/local.db"
        try writeConnections([entry])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.additionalFields?["libsqlFilePath"] == "/Users/me/local.db")
        #expect(connection.additionalFields?["promptForPassword"] == "true")
    }

    @Test("importConnections keeps a DuckDB file path without an inert prompt")
    func testImportConnections_duckDBAskEveryTime_keepsPathWithoutPrompt() throws {
        var entry = makeConnection(
            name: "DuckDB Ask",
            driver: "DuckDB",
            port: "",
            database: "",
            id: "c1",
            databasePasswordMode: 1
        )
        entry["DatabasePath"] = "/Users/me/warehouse.duckdb"
        try writeConnections([entry])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.additionalFields?["duckdbFilePath"] == "/Users/me/warehouse.duckdb")
        #expect(connection.additionalFields?["promptForPassword"] == nil)
    }

    @Test("importConnections skips the keychain for a database password TablePlus does not store")
    func testImportConnections_nonKeychainDatabaseMode_skipsKeychainRead() throws {
        try writeConnections([
            makeConnection(name: "Ask", id: "conn-1", databasePasswordMode: 1)
        ])
        let spy = KeychainSpy()
        spy.responses["conn-1_database"] = .found("stale")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.importConnections(includePasswords: true)

        #expect(spy.calls.contains { $0.account == "conn-1_database" } == false)
        #expect(result.envelope.credentials?["0"]?.password == nil)
    }

    @Test("importConnections skips the SSH password but keeps the separately stored key passphrase")
    func testImportConnections_nonKeychainServerMode_skipsSSHPasswordOnly() throws {
        try writeConnections([
            makeConnection(name: "Ask SSH", id: "conn-1", serverPasswordMode: 1)
        ])
        let spy = KeychainSpy()
        spy.responses["conn-1_server"] = .found("stale")
        spy.responses["conn-1_server_key"] = .found("passphrase")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.importConnections(includePasswords: true)

        #expect(Set(spy.calls.map(\.account)) == ["conn-1_database", "conn-1_server_key"])
        #expect(result.envelope.credentials?["0"]?.sshPassword == nil)
        #expect(result.envelope.credentials?["0"]?.keyPassphrase == "passphrase")
    }

    @Test("importConnections reads the keychain for a mode index TablePlus has not shipped yet")
    func testImportConnections_unknownPasswordMode_readsKeychainWithoutPrompting() throws {
        try writeConnections([
            makeConnection(name: "Future", id: "conn-1", databasePasswordMode: 47)
        ])
        let spy = KeychainSpy()
        spy.responses["conn-1_database"] = .found("s3cret")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.importConnections(includePasswords: true)

        #expect(spy.calls.contains { $0.account == "conn-1_database" })
        #expect(result.envelope.credentials?["0"]?.password == "s3cret")
        #expect(result.envelope.connections[0].additionalFields?["promptForPassword"] == nil)
    }

    @Test("importConnections leaves an inert prompt off a driver whose password field is plugin-owned")
    func testImportConnections_pluginOwnedPasswordField_setsNoPrompt() throws {
        try writeConnections([
            makeConnection(name: "DynamoDB Ask", driver: "DynamoDB", id: "c1", databasePasswordMode: 1)
        ])

        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == nil)
    }

    @MainActor
    @Test("importConnections keeps the prompt flag through analyze and into the connection")
    func testImportConnections_promptFlagSurvivesTheImportPipeline() throws {
        try writeConnections([
            makeConnection(name: "Ask", id: "c1", databasePasswordMode: 1)
        ])

        let envelope = try importer.importConnections(includePasswords: false).envelope
        let preview = ConnectionExportService.analyzeImport(
            envelope,
            existingConnections: [],
            registeredTypeIds: ["MySQL"],
            fileExists: { _ in true }
        )
        let connection = ConnectionExportService.buildDatabaseConnection(
            id: UUID(),
            from: preview.items[0].connection,
            name: "Ask",
            tagIdsByName: [:],
            groupIdsByName: [:]
        )

        #expect(connection.promptForPassword)
    }
}

private final class KeychainSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [(service: String, account: String)] = []
    private var storedResponses: [String: KeychainReadResult] = [:]

    var calls: [(service: String, account: String)] {
        lock.withLock { recordedCalls }
    }

    var responses: [String: KeychainReadResult] {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }

    var read: ForeignKeychainRead {
        { [self] service, account in
            lock.withLock {
                recordedCalls.append((service: service, account: account))
                return storedResponses[account] ?? .notFound
            }
        }
    }
}
