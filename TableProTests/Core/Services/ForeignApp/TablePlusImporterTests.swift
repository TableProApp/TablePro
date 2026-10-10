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
        imp.readViewSetting = { _ in nil }
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
        imp.readViewSetting = { _ in nil }
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
        imp.readViewSetting = { _ in nil }
        imp.resolveAppURL = { _ in nil }
        #expect(imp.connectionsFileURL.path.hasSuffix(
            "Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist"
        ))
    }

    // MARK: - inventory

    @Test("inventory counts connections")
    func testInventory_countsConnections() throws {
        try writeConnections([
            makeConnection(name: "DB1", id: "c1"),
            makeConnection(name: "DB2", id: "c2"),
            makeConnection(name: "DB3", id: "c3")
        ])
        #expect(importer.inventory() == ForeignAppInventory(connections: 3, savedQueries: 0))
    }

    @Test("inventory is empty when the file is missing")
    func testInventory_fileMissing_returnsZero() {
        #expect(importer.inventory() == ForeignAppInventory(connections: 0, savedQueries: 0))
    }

    // MARK: - collect

    @Test("collect parses all connections")
    func testCollect_parsesAllConnections() throws {
        try writeConnections([
            makeConnection(name: "DB1", id: "c1"),
            makeConnection(name: "DB2", id: "c2")
        ])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections.count == 2)
        #expect(result.source == .foreignApp(name: "TablePlus"))
    }

    @Test("collect maps every driver TablePlus 26.10 writes")
    func testCollect_mapsDriverCorrectly() throws {
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

        let result = try importer.collect(.connectionsOnly)
        for (index, mapping) in driverMappings.enumerated() {
            #expect(
                result.connections[index].type == mapping.1,
                "Driver \(mapping.0) should map to \(mapping.1)"
            )
        }
    }

    @Test("collect parses SSH config and keeps an explicit key path even when the file is missing")
    func testCollect_parsesSSHConfig() throws {
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

        let result = try imp.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.enabled == true)
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2_222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "/Users/test/.ssh/id_rsa")
    }

    @Test("collect drops the empty-key placeholder instead of building a fake path")
    func testCollect_placeholderPrivateKey_producesNoPath() throws {
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

        let result = try imp.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("collect keeps a bare key name when the file exists in ~/.ssh")
    func testCollect_bareKeyName_keptWhenFileExists() throws {
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

        let result = try imp.collect(.connectionsOnly)
        #expect(result.connections[0].sshConfig?.privateKeyPath == "~/.ssh/id_rsa")
    }

    @Test("collect parses SSH config with password auth")
    func testCollect_parsesSSHConfigPasswordAuth() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.authMethod == "Password")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("collect reads TlsKeyPaths in TablePlus order: key, certificate, CA")
    func testCollect_parsesSSLConfig() throws {
        try writeConnections([
            makeConnection(
                name: "SSL DB",
                id: "ssl-1",
                tlsMode: 2,
                tlsKeyPaths: ["/path/to/client-key.pem", "/path/to/client-cert.pem", "/path/to/ca.pem"]
            )
        ])

        let result = try importer.collect(.connectionsOnly)
        let conn = result.connections[0]
        let ssl = conn.sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Required")
        #expect(ssl?.caCertificatePath == "/path/to/ca.pem")
        #expect(ssl?.clientCertificatePath == "/path/to/client-cert.pem")
        #expect(ssl?.clientKeyPath == "/path/to/client-key.pem")
    }

    @Test("collect no SSL when tLSMode key is absent")
    func testCollect_noSSLWhenTLSModeAbsent() throws {
        try writeConnections([
            makeConnection(name: "No SSL", id: "nossl-1")
        ])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].sslConfig == nil)
    }

    @Test("collect SSL mode Preferred when tLSMode is 0")
    func testCollect_sslModePreferredWhenTLSModeZero() throws {
        try writeConnections([
            makeConnection(name: "Prefer SSL", id: "ssl-prefer", tlsMode: 0)
        ])

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig
        #expect(ssl != nil)
        #expect(ssl?.mode == "Preferred")
    }

    @Test("collect reads tLSMode against the popup the driver's own form shows")
    func testCollect_sslModeFollowsDriverVocabulary() throws {
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

        let connections = try importer.collect(.connectionsOnly).connections
        for (index, testCase) in cases.enumerated() {
            #expect(
                connections[index].sslConfig?.mode == testCase.mode,
                "\(testCase.driver) tLSMode \(testCase.tlsMode) should map to \(testCase.mode)"
            )
        }
    }

    @Test("collect reads the TLS slots each driver's own form writes")
    func testCollect_tlsKeySlotsFollowDriverForm() throws {
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

        let connections = try importer.collect(.connectionsOnly).connections

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

    @Test("collect carries no TLS paths for a driver whose form has no file pickers")
    func testCollect_oracleCarriesNoTLSPaths() throws {
        try writeConnections([
            makeConnection(
                name: "Oracle TLS",
                driver: "Oracle",
                id: "tls-oracle",
                tlsMode: 1,
                tlsKeyPaths: ["/stray/a.pem", "/stray/b.pem", "/stray/c.pem"]
            )
        ])

        let ssl = try importer.collect(.connectionsOnly).connections[0].sslConfig
        #expect(ssl?.mode == "Required")
        #expect(ssl?.caCertificatePath == nil)
        #expect(ssl?.clientCertificatePath == nil)
        #expect(ssl?.clientKeyPath == nil)
    }

    @Test("collect drops an SSL mode past the end of the driver's own popup")
    func testCollect_noSSLForTLSModePastDriverVocabulary() throws {
        try writeConnections([
            makeConnection(name: "Unknown TLS", id: "ssl-unknown", tlsMode: 99),
            makeConnection(name: "Past MySQL", driver: "MySQL", id: "ssl-past-mysql", tlsMode: 5),
            makeConnection(name: "Past Oracle", driver: "Oracle", id: "ssl-past-oracle", tlsMode: 2)
        ])

        let connections = try importer.collect(.connectionsOnly).connections
        #expect(connections[0].sslConfig == nil)
        #expect(connections[1].sslConfig == nil)
        #expect(connections[2].sslConfig == nil)
    }

    @Test("collect keeps Preferred for a driver whose form has no SSL picker")
    func testCollect_driverWithoutSSLPicker_staysPreferred() throws {
        try writeConnections([
            makeConnection(name: "SQL Server", driver: "MicrosoftSQLServer", id: "ssl-mssql", tlsMode: 0),
            makeConnection(name: "Snowflake", driver: "Snowflake", id: "ssl-snowflake", tlsMode: 0)
        ])

        let connections = try importer.collect(.connectionsOnly).connections
        #expect(connections[0].sslConfig?.mode == "Preferred")
        #expect(connections[1].sslConfig?.mode == "Preferred")
    }

    @Test("collect treats empty TablePlus TLS paths as none")
    func testCollect_emptyTLSPaths_areNil() throws {
        var entry = makeConnection(name: "Empty TLS", id: "tls-empty", tlsMode: 1)
        entry["TlsKeyPaths"] = ["", "", ""]
        try writeConnections([entry])

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.caCertificatePath == nil)
        #expect(ssl?.clientCertificatePath == nil)
        #expect(ssl?.clientKeyPath == nil)
    }

    @Test("collect preserves groups")
    func testCollect_preservesGroups() throws {
        try writeGroups([
            ["ID": "group-1", "Name": "Production"],
            ["ID": "group-2", "Name": "Development"]
        ])
        try writeConnections([
            makeConnection(name: "Prod DB", id: "c1", groupId: "group-1"),
            makeConnection(name: "Dev DB", id: "c2", groupId: "group-2"),
            makeConnection(name: "Ungrouped", id: "c3", groupId: "")
        ])

        let result = try importer.collect(.connectionsOnly)
        let connections = result.connections

        #expect(connections.count == 3)
        #expect(result.groupPath(at: 0) == ["Production"])
        #expect(result.groupPath(at: 1) == ["Development"])
        #expect(result.groupPath(at: 2).isEmpty)
        #expect(Set(result.bundle.groups.map { $0.name }) == ["Production", "Development"])
    }

    @Test("collect parses port from string")
    func testCollect_parsesPortFromString() throws {
        try writeConnections([
            makeConnection(name: "Custom Port", port: "5433", id: "c1")
        ])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].port == 5433)
    }

    @Test("collect uses default port when missing")
    func testCollect_defaultPortWhenMissing() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let connections = result.connections

        #expect(connections[0].port == 3306)
        #expect(connections[1].port == 5432)
        #expect(connections[2].port == 27_017)
        #expect(connections[3].port == 6379)
        #expect(connections[4].port == 1433)
        #expect(connections[5].port == 26_257)
        #expect(connections[6].port == 5_439)
        #expect(connections[7].port == 0)
    }

    @Test("collect skips invalid entries")
    func testCollect_skipsInvalidEntries() throws {
        // Entry without ConnectionName should be skipped
        let invalidEntry: [String: Any] = [
            "Driver": "MySQL",
            "DatabaseHost": "localhost",
            "ID": "invalid-1"
        ]
        let validEntry = makeConnection(name: "Valid", id: "valid-1")
        try writeConnections([invalidEntry, validEntry])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections.count == 1)
        #expect(result.connections[0].name == "Valid")
    }

    @Test("collect without passwords has nil credentials")
    func testCollect_withoutPasswords_credentialsNil() throws {
        try writeConnections([makeConnection(name: "DB", id: "c1")])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.bundle.credentials.isEmpty)
    }

    @Test("collect empty file throws noConnectionsFound")
    func testCollect_emptyFile_throwsNoConnectionsFound() throws {
        // Write an empty array plist
        try writeConnections([])

        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect with only invalid entries throws noConnectionsFound")
    func testCollect_allInvalid_throwsNoConnectionsFound() throws {
        // All entries missing ConnectionName
        let invalid: [String: Any] = ["Driver": "MySQL", "ID": "x"]
        try writeConnections([invalid, invalid])

        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect file not found throws error")
    func testCollect_fileNotFound_throwsError() {
        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect maps environment colors")
    func testCollect_mapsEnvironmentColors() throws {
        try writeConnections([
            makeConnection(name: "Staging", id: "c1", environment: "staging"),
            makeConnection(name: "Prod", id: "c2", environment: "production"),
            makeConnection(name: "Test", id: "c3", environment: "testing"),
            makeConnection(name: "Dev", id: "c4", environment: "development"),
            makeConnection(name: "None", id: "c5", environment: "")
        ])

        let result = try importer.collect(.connectionsOnly)
        let connections = result.connections

        #expect(connections[0].color == "Yellow")
        #expect(connections[1].color == "Red")
        #expect(connections[2].color == "Blue")
        #expect(connections[3].color == "Green")
        #expect(connections[4].color == nil)
    }

    @Test("collect SQLite uses DatabasePath")
    func testCollect_sqliteUsesDatabasePath() throws {
        var entry = makeConnection(name: "Local SQLite", driver: "SQLite", id: "c1")
        entry["DatabasePath"] = "/Users/me/data.db"
        try writeConnections([entry])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].database == "/Users/me/data.db")
        #expect(result.connections[0].additionalFields == nil)
    }

    @Test("collect puts a DuckDB file in the field DuckDB reads it from")
    func testCollect_duckDBUsesItsFilePathField() throws {
        var entry = makeConnection(name: "Local DuckDB", driver: "DuckDB", port: "", database: "", id: "c1")
        entry["DatabasePath"] = "/Users/me/warehouse.duckdb"
        try writeConnections([entry])

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.type == "DuckDB")
        #expect(connection.additionalFields?["duckdbFilePath"] == "/Users/me/warehouse.duckdb")
        #expect(connection.database == "")
        #expect(connection.port == 0)
    }

    @Test("collect ignores DatabasePath for a server engine")
    func testCollect_serverEngineIgnoresDatabasePath() throws {
        var entry = makeConnection(name: "Server", driver: "MicrosoftSQLServer", database: "sales", id: "c1")
        entry["DatabasePath"] = "/tmp/stray"
        try writeConnections([entry])

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.database == "sales")
        #expect(connection.additionalFields == nil)
    }

    @Test("collect stamps the bundle and keys the connection by its TablePlus ID")
    func testCollect_bundleMetadata() throws {
        try writeConnections([makeConnection(id: "conn-7")])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.bundle.appVersion == "TablePlus Import")
        #expect(result.bundle.tags.isEmpty)
        #expect(result.bundle.connections.map { $0.ref } == ["conn-7"])
        #expect(result.source == .foreignApp(name: "TablePlus"))
    }

    // MARK: - Password Import

    @Test("collect reads the database password from the correct keychain service")
    func testCollect_readsCorrectKeychainServiceAndAccount() throws {
        try writeConnections([makeConnection(name: "DB", id: "conn-1")])
        let spy = KeychainSpy()
        spy.responses["conn-1_database"] = .found("s3cret")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.collect(.withPasswords)

        #expect(spy.calls.contains { $0.service == "com.tableplus.TablePlus" && $0.account == "conn-1_database" })
        #expect(result.credentials(at: 0)?.password == "s3cret")
        #expect(result.credentialsAborted == false)
    }

    @Test("collect queries database, SSH, and key-passphrase accounts")
    func testCollect_queriesAllCredentialAccounts() throws {
        try writeConnections([makeConnection(name: "DB", id: "conn-1")])
        let spy = KeychainSpy()

        var imp = importer
        imp.readKeychain = spy.read

        _ = try imp.collect(.withPasswords)

        let accounts = Set(spy.calls.map(\.account))
        #expect(accounts == ["conn-1_database", "conn-1_server", "conn-1_server_key"])
        #expect(spy.calls.allSatisfy { $0.service == "com.tableplus.TablePlus" })
    }

    @Test("collect leaves credentials empty and does not abort when nothing is stored")
    func testCollect_noStoredPasswords_emptyCredentialsNoAbort() throws {
        try writeConnections([makeConnection(name: "DB", id: "conn-1")])
        let spy = KeychainSpy()

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.collect(.withPasswords)

        #expect(result.bundle.credentials.isEmpty)
        #expect(result.credentialsAborted == false)
    }

    @Test("collect aborts and stops reading after a cancelled keychain prompt")
    func testCollect_cancelledPrompt_abortsAndStops() throws {
        try writeConnections([
            makeConnection(name: "A", id: "c1"),
            makeConnection(name: "B", id: "c2")
        ])
        let spy = KeychainSpy()
        spy.responses["c1_database"] = .cancelled

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.collect(.withPasswords)

        #expect(result.credentialsAborted == true)
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.account == "c1_database")
    }

    // MARK: - Password Mode

    @Test("collect carries Ask everytime across as Prompt for password")
    func testCollect_askEveryTime_setsPromptForPassword() throws {
        try writeConnections([
            makeConnection(name: "Ask", id: "c1", databasePasswordMode: 1)
        ])

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == "true")
    }

    @Test("collect leaves Store in keychain and a missing mode without a prompt")
    func testCollect_storeInKeychainOrAbsentMode_leavesNoPrompt() throws {
        try writeConnections([
            makeConnection(name: "Stored", id: "c1", databasePasswordMode: 0),
            makeConnection(name: "Absent", id: "c2"),
            makeConnection(name: "Unknown", id: "c3", databasePasswordMode: 47)
        ])

        let connections = try importer.collect(.connectionsOnly).connections
        #expect(connections[0].additionalFields?["promptForPassword"] == nil)
        #expect(connections[1].additionalFields?["promptForPassword"] == nil)
        #expect(connections[2].additionalFields?["promptForPassword"] == nil)
    }

    @Test("collect leaves No password without a prompt")
    func testCollect_noPasswordMode_leavesNoPrompt() throws {
        try writeConnections([
            makeConnection(name: "None", id: "c1", databasePasswordMode: 2)
        ])

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == nil)
    }

    @Test("collect prompts for a Command Line password TablePro cannot run")
    func testCollect_commandLineMode_setsPromptForPassword() throws {
        try writeConnections([
            makeConnection(name: "Command", id: "c1", databasePasswordMode: 3)
        ])

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == "true")
    }

    @Test("collect keeps the local file path alongside the prompt flag")
    func testCollect_promptMergesWithFilePathField() throws {
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

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.additionalFields?["libsqlFilePath"] == "/Users/me/local.db")
        #expect(connection.additionalFields?["promptForPassword"] == "true")
    }

    @Test("collect keeps a DuckDB file path without an inert prompt")
    func testCollect_duckDBAskEveryTime_keepsPathWithoutPrompt() throws {
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

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.additionalFields?["duckdbFilePath"] == "/Users/me/warehouse.duckdb")
        #expect(connection.additionalFields?["promptForPassword"] == nil)
    }

    @Test("collect skips the keychain for a database password TablePlus does not store")
    func testCollect_nonKeychainDatabaseMode_skipsKeychainRead() throws {
        try writeConnections([
            makeConnection(name: "Ask", id: "conn-1", databasePasswordMode: 1)
        ])
        let spy = KeychainSpy()
        spy.responses["conn-1_database"] = .found("stale")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.collect(.withPasswords)

        #expect(spy.calls.contains { $0.account == "conn-1_database" } == false)
        #expect(result.credentials(at: 0)?.password == nil)
    }

    @Test("collect skips the SSH password but keeps the separately stored key passphrase")
    func testCollect_nonKeychainServerMode_skipsSSHPasswordOnly() throws {
        try writeConnections([
            makeConnection(name: "Ask SSH", id: "conn-1", serverPasswordMode: 1)
        ])
        let spy = KeychainSpy()
        spy.responses["conn-1_server"] = .found("stale")
        spy.responses["conn-1_server_key"] = .found("passphrase")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.collect(.withPasswords)

        #expect(Set(spy.calls.map(\.account)) == ["conn-1_database", "conn-1_server_key"])
        #expect(result.credentials(at: 0)?.sshPassword == nil)
        #expect(result.credentials(at: 0)?.keyPassphrase == "passphrase")
    }

    @Test("collect reads the keychain for a mode index TablePlus has not shipped yet")
    func testCollect_unknownPasswordMode_readsKeychainWithoutPrompting() throws {
        try writeConnections([
            makeConnection(name: "Future", id: "conn-1", databasePasswordMode: 47)
        ])
        let spy = KeychainSpy()
        spy.responses["conn-1_database"] = .found("s3cret")

        var imp = importer
        imp.readKeychain = spy.read

        let result = try imp.collect(.withPasswords)

        #expect(spy.calls.contains { $0.account == "conn-1_database" })
        #expect(result.credentials(at: 0)?.password == "s3cret")
        #expect(result.connections[0].additionalFields?["promptForPassword"] == nil)
    }

    @Test("collect leaves an inert prompt off a driver whose password field is plugin-owned")
    func testCollect_pluginOwnedPasswordField_setsNoPrompt() throws {
        try writeConnections([
            makeConnection(name: "DynamoDB Ask", driver: "DynamoDB", id: "c1", databasePasswordMode: 1)
        ])

        let connection = try importer.collect(.connectionsOnly).connections[0]
        #expect(connection.additionalFields?["promptForPassword"] == nil)
    }

    @Test("collect carries a DynamoDB connection's region and access key into its sign-in fields")
    func testCollect_dynamoDB_mapsRegionAndAccessKey() throws {
        try writeConnections([
            makeConnection(
                name: "Orders", driver: "DynamoDB", host: " eu-west-1 ", port: "", user: "AKIAEXAMPLE",
                database: "", id: "c1"
            )
        ])

        let connection = try importer.collect(.connectionsOnly).connections[0]

        #expect(connection.type == "DynamoDB")
        #expect(connection.additionalFields?["awsRegion"] == "eu-west-1")
        #expect(connection.additionalFields?["awsAccessKeyId"] == "AKIAEXAMPLE")
        #expect(connection.additionalFields?["awsAuthMethod"] == "credentials")
    }

    @Test("collect leaves the region unset when the DynamoDB connection names none")
    func testCollect_dynamoDBWithoutRegion_leavesRegionUnset() throws {
        try writeConnections([
            makeConnection(name: "Orders", driver: "DynamoDB", host: "", port: "", user: "", database: "", id: "c1")
        ])

        let connection = try importer.collect(.connectionsOnly).connections[0]

        #expect(connection.additionalFields?["awsRegion"] == nil)
        #expect(connection.additionalFields?["awsAccessKeyId"] == nil)
        #expect(connection.additionalFields?["awsAuthMethod"] == "credentials")
    }

    @Test("collect gives no other driver AWS sign-in fields")
    func testCollect_otherDrivers_getNoAWSFields() throws {
        try writeConnections([makeConnection(name: "Shop", driver: "MySQL", host: "eu-west-1", id: "c1")])

        let connection = try importer.collect(.connectionsOnly).connections[0]

        #expect(connection.additionalFields?["awsRegion"] == nil)
        #expect(connection.additionalFields?["awsAuthMethod"] == nil)
    }

    @MainActor
    @Test("collect keeps the prompt flag through analyze and into the connection")
    func testCollect_promptFlagSurvivesTheImportPipeline() throws {
        try writeConnections([
            makeConnection(name: "Ask", id: "c1", databasePasswordMode: 1)
        ])

        let collected = try importer.collect(.connectionsOnly)
        let preview = ConnectionImportAnalyzer.analyze(
            collected,
            library: ImportLibrarySnapshot(),
            environment: ImportEnvironment(
                rules: ImportRules(maximumGroupDepth: 3, supportsSavedQueries: true, supportsCredentialProfiles: true),
                registeredTypeIds: ["MySQL"],
                fileExists: { _ in true }
            )
        )
        let connection = DatabaseConnection(
            importing: preview.connections[0].settings,
            id: UUID(),
            groupId: nil,
            tagIds: [],
            credentialProfileId: nil,
            resolvesSSHProfile: { _ in false }
        )

        #expect(connection.promptForPassword)
    }

    // MARK: - Favorites

    private var favoriteRoot: URL { tempDir.appendingPathComponent("Favorite", isDirectory: true) }

    private func writeFavoriteFixture() throws {
        try writeConnections([makeConnection(name: "Shop", id: "c1")])
        try ForeignFixture.write("SELECT 1;", to: favoriteRoot.appendingPathComponent("tp_top.sql"))
        try ForeignFixture.write("SELECT 2;", to: favoriteRoot.appendingPathComponent("tp_root_kw.sql"))
        try ForeignFixture.write("kwone,kw two", to: favoriteRoot.appendingPathComponent("tp_root_kw.sql.tag"))
        try ForeignFixture.write("", to: favoriteRoot.appendingPathComponent("Untitled.sql"))
        try ForeignFixture.write("SELECT 0;", to: favoriteRoot.appendingPathComponent(".hidden.sql"))
        try ForeignFixture.write("x", to: favoriteRoot.appendingPathComponent("orphan.sql.tag"))
        let folder = favoriteRoot.appendingPathComponent("Folder A", isDirectory: true)
        try ForeignFixture.write("-- c\nSELECT 3;\n", to: folder.appendingPathComponent("nested.sql"))
        try ForeignFixture.write("kwnested", to: folder.appendingPathComponent("nested.sql.tag"))
        try ForeignFixture.write("SELECT 4;", to: folder.appendingPathComponent("two.dots.sql"))
        try ForeignFixture.write("SELECT 5;", to: folder.appendingPathComponent("notes.txt"))
        try ForeignFixture.write("SELECT 'Việt ✓';", to: folder.appendingPathComponent("Sub/deep.sql"))
    }

    private func configuredImporter(viewSetting: [String: String], sharedFolders: [URL] = []) -> TablePlusImporter {
        var imp = importer
        let favorites = sharedFolders.map { ["path": $0.path, "uuid": UUID().uuidString] }
        imp.readViewSetting = { _ in
            var setting: [String: Any] = viewSetting
            setting["Favorites"] = favorites
            return setting
        }
        return imp
    }

    @Test("collect reads every listed favorite as a global query under the TablePlus folder")
    func testCollect_readsFavoritesAsGlobalQueries() throws {
        try writeFavoriteFixture()

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQueryNames == ["tp_top", "tp_root_kw", "nested", "two.dots", "notes", "deep"])
        let top = try #require(result.savedQuery(named: "tp_top"))
        #expect(top.sql == "SELECT 1;")
        #expect(top.keyword == nil)
        #expect(top.connectionRef == nil)
        #expect(result.folderPath(of: top) == ["TablePlus"])

        let nested = try #require(result.savedQuery(named: "nested"))
        #expect(nested.sql == "-- c\nSELECT 3;\n")
        #expect(nested.keyword == "kwnested")
        #expect(result.folderPath(of: nested) == ["TablePlus", "Folder A"])

        let deep = try #require(result.savedQuery(named: "deep"))
        #expect(deep.sql == "SELECT 'Việt ✓';")
        #expect(result.folderPath(of: deep) == ["TablePlus", "Folder A", "Sub"])

        #expect(result.bundle.savedQueries.allSatisfy { result.isSuggested($0) })
        #expect(result.oversizedQueries.isEmpty)
    }

    @Test("collect keeps the first keyword of the tag file that has no space")
    func testCollect_firstKeywordWithoutSpaceWins() throws {
        try writeFavoriteFixture()
        try ForeignFixture.write("Tp Space Kw,tpok,later", to: favoriteRoot.appendingPathComponent("tp_top.sql.tag"))

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQuery(named: "tp_root_kw")?.keyword == "kwone")
        #expect(result.savedQuery(named: "tp_top")?.keyword == "tpok")
    }

    @Test("collect reads no favorites unless saved queries are requested")
    func testCollect_withoutSavedQueries_readsNoFavorites() throws {
        try writeFavoriteFixture()

        let result = try importer.collect(.connectionsOnly)

        #expect(result.bundle.savedQueries.isEmpty)
        #expect(result.bundle.queryFolders.isEmpty)
    }

    @Test("SharedQueryPath moves the favorites root to its Favorite folder")
    func testCollect_sharedQueryPathMovesRoot() throws {
        try writeFavoriteFixture()
        let custom = tempDir.appendingPathComponent("Custom", isDirectory: true)
        try ForeignFixture.write("SELECT 6;", to: custom.appendingPathComponent("Favorite/custom.sql"))
        try ForeignFixture.write("SELECT 7;", to: custom.appendingPathComponent("ignored.sql"))

        let result = try configuredImporter(viewSetting: ["SharedQueryPath": custom.path]).collect(.withSavedQueries)

        #expect(result.savedQueryNames == ["custom"])
    }

    @Test("A shared folder lands under its own name inside the TablePlus folder")
    func testCollect_sharedFolderLandsUnderItsName() throws {
        try writeFavoriteFixture()
        let shared = tempDir.appendingPathComponent("tp_shared", isDirectory: true)
        try ForeignFixture.write("SELECT 8;", to: shared.appendingPathComponent("shared.sql"))
        try ForeignFixture.write("kwshared", to: shared.appendingPathComponent("shared.sql.tag"))
        let missing = tempDir.appendingPathComponent("gone", isDirectory: true)

        let result = try configuredImporter(viewSetting: [:], sharedFolders: [shared, missing]).collect(.withSavedQueries)

        let query = try #require(result.savedQuery(named: "shared"))
        #expect(query.keyword == "kwshared")
        #expect(result.folderPath(of: query) == ["TablePlus", "tp_shared"])
        #expect(result.bundle.savedQueries.count == 7)
    }

    @Test("SharedConnectionPath reads the connection files directly under that folder")
    func testCollect_sharedConnectionPathReadsMovedConnections() throws {
        try writeConnections([makeConnection(name: "Stale", id: "c1")])
        let moved = tempDir.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let entries = [makeConnection(name: "Moved DB", id: "c2", groupId: "g1")]
        try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
            .write(to: moved.appendingPathComponent("Connections.plist"))
        try PropertyListSerialization.data(fromPropertyList: [["ID": "g1", "Name": "Moved"]], format: .xml, options: 0)
            .write(to: moved.appendingPathComponent("ConnectionGroups.plist"))

        let imp = configuredImporter(viewSetting: ["SharedConnectionPath": moved.path])
        let result = try imp.collect(.connectionsOnly)

        #expect(imp.connectionsFileURL.deletingLastPathComponent().path == moved.path)
        #expect(result.connections.map { $0.name } == ["Moved DB"])
        #expect(result.groupPath(at: 0) == ["Moved"])
    }

    @Test("A favorite over the sync limit is listed as oversized without its text")
    func testCollect_oversizedFavorite() throws {
        try writeFavoriteFixture()
        let big = String(repeating: "x", count: SavedQuerySize.maximumSyncableByteCount + 1)
        try ForeignFixture.write(big, to: favoriteRoot.appendingPathComponent("huge.sql"))

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQuery(named: "huge") == nil)
        let oversized = try #require(result.oversizedQueries.first)
        #expect(oversized.name == "huge")
        #expect(oversized.folderPath == ["TablePlus"])
        #expect(oversized.byteCount == SavedQuerySize.maximumSyncableByteCount + 1)
        #expect(!result.bundle.savedQueries.map { $0.ref }.contains(oversized.ref))
    }

    @Test("inventory counts non-empty favorites, shared folders included")
    func testInventory_countsFavorites() throws {
        try writeFavoriteFixture()
        let shared = tempDir.appendingPathComponent("tp_shared", isDirectory: true)
        try ForeignFixture.write("SELECT 8;", to: shared.appendingPathComponent("shared.sql"))

        let inventory = configuredImporter(viewSetting: [:], sharedFolders: [shared]).inventory()

        #expect(inventory == ForeignAppInventory(connections: 1, savedQueries: 7))
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
