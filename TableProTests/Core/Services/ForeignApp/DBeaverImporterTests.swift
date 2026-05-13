//
//  DBeaverImporterTests.swift
//  TableProTests
//

import CommonCrypto
import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DBeaverImporter", .serialized)
struct DBeaverImporterTests {
    private var tempDir: URL
    private var projectDir: URL
    private var importer: DBeaverImporter

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBeaverImporterTests-\(UUID().uuidString)")

        // DBeaver workspace structure: workspace6/<project>/.dbeaver/data-sources.json
        projectDir = tempDir.appendingPathComponent("General/.dbeaver")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var imp = DBeaverImporter()
        imp.workspaceBaseURL = tempDir
        importer = imp
    }

    // MARK: - Fixture Helpers

    private func writeDataSources(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try data.write(to: projectDir.appendingPathComponent("data-sources.json"))
    }

    private func writeCredentials(_ credentials: [String: Any]) throws {
        let plaintext = try JSONSerialization.data(withJSONObject: credentials, options: .prettyPrinted)
        let encrypted = encryptWithDBeaverKey(plaintext)
        try encrypted.write(to: projectDir.appendingPathComponent("credentials-config.json"))
    }

    private func encryptWithDBeaverKey(_ data: Data) -> Data {
        let key: [UInt8] = [
            0xBA, 0xBB, 0x4A, 0x9F, 0x77, 0x4A, 0xB8, 0x53,
            0xC9, 0x6C, 0x2D, 0x65, 0x3D, 0xFE, 0x54, 0x4A
        ]
        var iv = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &iv)

        let plainBytes = Array(data)
        var encryptedBytes = [UInt8](repeating: 0, count: plainBytes.count + kCCBlockSizeAES128)
        var encryptedLength = 0

        CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            plainBytes,
            plainBytes.count,
            &encryptedBytes,
            encryptedBytes.count,
            &encryptedLength
        )

        var result = Data(iv)
        result.append(Data(encryptedBytes.prefix(encryptedLength)))
        return result
    }

    private func makeConnection(
        name: String = "Test DB",
        provider: String = "postgresql",
        host: String = "db.example.com",
        port: Any? = 5432,
        user: String = "admin",
        database: String = "mydb",
        folder: String? = nil,
        sshEnabled: Bool = false,
        sshHost: String = "",
        sshPort: Any? = 22,
        sshUsername: String = "",
        sshAuthType: String = "PASSWORD",
        sshKeyPath: String = "",
        sslEnabled: Bool = false,
        sslMode: String = "",
        sslCaCertPath: String = "",
        sslClientCertPath: String = "",
        sslClientKeyPath: String = "",
        color: String? = nil
    ) -> [String: Any] {
        var config: [String: Any] = [
            "host": host,
            "user": user,
            "database": database
        ]
        if let port = port {
            config["port"] = port
        }
        if let color = color {
            config["color"] = color
        }

        var handlers: [String: Any] = [:]
        if sshEnabled {
            handlers["ssh_tunnel"] = [
                "enabled": true,
                "properties": [
                    "host": sshHost,
                    "port": sshPort as Any,
                    "username": sshUsername,
                    "authType": sshAuthType,
                    "keyPath": sshKeyPath
                ] as [String: Any]
            ] as [String: Any]
        }
        if sslEnabled {
            var sslProperties: [String: Any] = [:]
            if !sslMode.isEmpty {
                sslProperties["sslMode"] = sslMode
            }
            if !sslCaCertPath.isEmpty {
                sslProperties["caCertPath"] = sslCaCertPath
            }
            if !sslClientCertPath.isEmpty {
                sslProperties["clientCertPath"] = sslClientCertPath
            }
            if !sslClientKeyPath.isEmpty {
                sslProperties["clientKeyPath"] = sslClientKeyPath
            }
            handlers["ssl"] = [
                "enabled": true,
                "properties": sslProperties
            ] as [String: Any]
        }
        if !handlers.isEmpty {
            config["handlers"] = handlers
        }

        var dict: [String: Any] = [
            "name": name,
            "provider": provider,
            "configuration": config
        ]
        if let folder = folder {
            dict["folder"] = folder
        }
        return dict
    }

    private func makeDataSourcesJSON(
        connections: [String: [String: Any]],
        folders: [String: [String: Any]] = [:]
    ) -> [String: Any] {
        var json: [String: Any] = ["connections": connections]
        if !folders.isEmpty {
            json["folders"] = folders
        }
        return json
    }

    // MARK: - isAvailable

    @Test("isAvailable returns true when data-sources.json exists")
    func testIsAvailable_whenFileExists_returnsTrue() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [:]))
        #expect(importer.isAvailable() == true)
    }

    @Test("isAvailable returns false when file is missing")
    func testIsAvailable_whenFileMissing_returnsFalse() throws {
        // Delete the file if it exists
        try? FileManager.default.removeItem(at: projectDir.appendingPathComponent("data-sources.json"))
        #expect(importer.isAvailable() == false)
    }

    // MARK: - connectionCount

    @Test("connectionCount returns correct count")
    func testConnectionCount_returnsCorrectCount() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG1"),
            "pg-2": makeConnection(name: "PG2"),
            "mysql-1": makeConnection(name: "MySQL1", provider: "mysql")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        #expect(importer.connectionCount() == 3)
    }

    @Test("connectionCount returns 0 when file missing")
    func testConnectionCount_fileMissing_returnsZero() throws {
        try? FileManager.default.removeItem(at: projectDir.appendingPathComponent("data-sources.json"))
        #expect(importer.connectionCount() == 0)
    }

    // MARK: - importConnections

    @Test("importConnections parses all connections")
    func testImportConnections_parsesAllConnections() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG1"),
            "mysql-1": makeConnection(name: "MySQL1", provider: "mysql")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections.count == 2)
        #expect(result.sourceName == "DBeaver")
    }

    @Test("importConnections maps provider correctly")
    func testImportConnections_mapsProviderCorrectly() throws {
        let providerMappings: [(String, String)] = [
            ("mysql", "MySQL"),
            ("postgresql", "PostgreSQL"),
            ("sqlite", "SQLite"),
            ("sqlserver", "SQL Server"),
            ("oracle", "Oracle"),
            ("mongodb", "MongoDB"),
            ("redis", "Redis"),
            ("clickhouse", "ClickHouse"),
            ("mariadb", "MariaDB"),
            ("cassandra", "Cassandra")
        ]

        var connections: [String: [String: Any]] = [:]
        for (index, mapping) in providerMappings.enumerated() {
            connections["conn-\(index)"] = makeConnection(
                name: "Conn \(mapping.0)",
                provider: mapping.0
            )
        }
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let typeSet = Set(result.envelope.connections.map(\.type))

        for mapping in providerMappings {
            #expect(typeSet.contains(mapping.1), "Provider \(mapping.0) should map to \(mapping.1)")
        }
    }

    @Test("importConnections parses port as Int")
    func testImportConnections_parsesPortAsInt() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", port: 5433)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].port == 5433)
    }

    @Test("importConnections parses port as String")
    func testImportConnections_parsesPortAsString() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", port: "5433")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].port == 5433)
    }

    @Test("importConnections uses default port when missing")
    func testImportConnections_defaultPortWhenMissing() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", provider: "postgresql", port: nil),
            "mysql-1": makeConnection(name: "MySQL", provider: "mysql", port: nil),
            "mongo-1": makeConnection(name: "Mongo", provider: "mongodb", port: nil),
            "redis-1": makeConnection(name: "Redis", provider: "redis", port: nil),
            "mssql-1": makeConnection(name: "MSSQL", provider: "sqlserver", port: nil),
            "oracle-1": makeConnection(name: "Oracle", provider: "oracle", port: nil),
            "ch-1": makeConnection(name: "ClickHouse", provider: "clickhouse", port: nil),
            "cass-1": makeConnection(name: "Cassandra", provider: "cassandra", port: nil)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let portMap = Dictionary(
            uniqueKeysWithValues: result.envelope.connections.map { ($0.type, $0.port) }
        )

        #expect(portMap["PostgreSQL"] == 5432)
        #expect(portMap["MySQL"] == 3306)
        #expect(portMap["MongoDB"] == 27_017)
        #expect(portMap["Redis"] == 6379)
        #expect(portMap["SQL Server"] == 1433)
        #expect(portMap["Oracle"] == 1521)
        #expect(portMap["ClickHouse"] == 8123)
        #expect(portMap["Cassandra"] == 9042)
    }

    @Test("importConnections parses SSH tunnel with PUBLIC_KEY auth")
    func testImportConnections_parsesSSHTunnel_publicKey() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(
                name: "SSH PG",
                sshEnabled: true,
                sshHost: "bastion.example.com",
                sshPort: 2222,
                sshUsername: "deploy",
                sshAuthType: "PUBLIC_KEY",
                sshKeyPath: "~/.ssh/id_rsa"
            )
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.enabled == true)
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "~/.ssh/id_rsa")
    }

    @Test("importConnections parses SSH tunnel with AGENT auth")
    func testImportConnections_parsesSSHTunnel_agent() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(
                name: "SSH Agent PG",
                sshEnabled: true,
                sshHost: "bastion.example.com",
                sshPort: 22,
                sshUsername: "admin",
                sshAuthType: "AGENT"
            )
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh?.authMethod == "SSH Agent")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("importConnections parses SSH tunnel with PASSWORD auth")
    func testImportConnections_parsesSSHTunnel_password() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(
                name: "SSH Password PG",
                sshEnabled: true,
                sshHost: "bastion.example.com",
                sshPort: 22,
                sshUsername: "admin",
                sshAuthType: "PASSWORD"
            )
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssh = result.envelope.connections[0].sshConfig

        #expect(ssh?.authMethod == "Password")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("importConnections no SSH when handler missing")
    func testImportConnections_noSSHWhenHandlerMissing() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "No SSH PG", sshEnabled: false)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sshConfig == nil)
    }

    @Test("importConnections preserves folders")
    func testImportConnections_preservesFolders() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "Prod PG", folder: "Production"),
            "pg-2": makeConnection(name: "Dev PG", folder: "Development"),
            "pg-3": makeConnection(name: "Local PG")
        ]
        let folders: [String: [String: Any]] = [
            "Production": ["description": "Production Servers"],
            "Development": ["description": "Development Servers"]
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections, folders: folders))

        let result = try importer.importConnections(includePasswords: false)
        let connsByName = Dictionary(uniqueKeysWithValues: result.envelope.connections.map { ($0.name, $0) })

        #expect(connsByName["Prod PG"]?.groupName == "Production Servers")
        #expect(connsByName["Dev PG"]?.groupName == "Development Servers")
        #expect(connsByName["Local PG"]?.groupName == nil)

        let groups = result.envelope.groups
        #expect(groups != nil)
        #expect(groups?.count == 2)
    }

    @Test("importConnections folder without description uses path component")
    func testImportConnections_folderWithoutDescription() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", folder: "team/backend")
        ]
        let folders: [String: [String: Any]] = [
            "team/backend": ["description": ""]
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections, folders: folders))

        let result = try importer.importConnections(includePasswords: false)
        // Should use last path component
        #expect(result.envelope.connections[0].groupName == "backend")
    }

    @Test("importConnections decrypts credentials")
    func testImportConnections_decryptsCredentials() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG with password")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let credentials: [String: Any] = [
            "pg-1": [
                "#connection": [
                    "password": "s3cr3t_p4ss"
                ]
            ]
        ]
        try writeCredentials(credentials)

        let result = try importer.importConnections(includePasswords: true)
        #expect(result.envelope.credentials != nil)
        #expect(result.envelope.credentials?["0"]?.password == "s3cr3t_p4ss")
    }

    @Test("importConnections without passwords skips decryption")
    func testImportConnections_withoutPasswords_skipsDecryption() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        // Even if credentials file exists, it should not be read
        try writeCredentials(["pg-1": ["#connection": ["password": "secret"]]])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.credentials == nil)
    }

    @Test("importConnections invalid JSON throws parse error")
    func testImportConnections_invalidJSON_throwsParseError() throws {
        // Write invalid data to data-sources.json
        let invalidData = "not valid json {{{".data(using: .utf8)!
        try invalidData.write(to: projectDir.appendingPathComponent("data-sources.json"))

        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections empty connections throws noConnectionsFound")
    func testImportConnections_emptyConnections_throws() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [:]))

        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections color mapping from RGB")
    func testImportConnections_colorMapping() throws {
        let connections: [String: [String: Any]] = [
            "c1": makeConnection(name: "Red", color: "255,0,0"),
            "c2": makeConnection(name: "Orange", color: "220,150,50"),
            "c3": makeConnection(name: "Yellow", color: "230,220,50"),
            "c4": makeConnection(name: "Green", color: "50,180,50"),
            "c5": makeConnection(name: "Blue", color: "50,50,220"),
            "c6": makeConnection(name: "Purple", color: "150,50,200"),
            "c7": makeConnection(name: "No Color")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let colorMap = Dictionary(uniqueKeysWithValues: result.envelope.connections.map { ($0.name, $0.color) })

        #expect(colorMap["Red"] == "Red")
        #expect(colorMap["Orange"] == "Orange")
        #expect(colorMap["Yellow"] == "Yellow")
        #expect(colorMap["Green"] == "Green")
        #expect(colorMap["Blue"] == "Blue")
        #expect(colorMap["Purple"] == "Purple")
        #expect(colorMap["No Color"] == Optional<String>.none)
    }

    @Test("importConnections file not found throws error")
    func testImportConnections_fileNotFound_throwsError() throws {
        // Remove the workspace directory entirely
        try FileManager.default.removeItem(at: tempDir)

        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    @Test("importConnections envelope metadata")
    func testImportConnections_envelopeMetadata() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.formatVersion == 1)
        #expect(result.envelope.appVersion == "DBeaver Import")
        #expect(result.envelope.tags == nil)
    }

    @Test("importConnections SSH port as string")
    func testImportConnections_sshPortAsString() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(
                name: "SSH String Port",
                sshEnabled: true,
                sshHost: "bastion.com",
                sshPort: "2222",
                sshUsername: "user",
                sshAuthType: "PASSWORD"
            )
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sshConfig?.port == 2222)
    }

    @Test("importConnections unknown provider passes through")
    func testImportConnections_unknownProvider() throws {
        let connections: [String: [String: Any]] = [
            "x-1": makeConnection(name: "Unknown DB", provider: "exoticdb")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].type == "exoticdb")
    }

    // MARK: - SSL Parsing

    @Test("importConnections parses SSL with require mode")
    func testImportConnections_parsesSSLRequireMode() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Require", sslEnabled: true, sslMode: "require")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Required")
    }

    @Test("importConnections parses SSL with verify-ca mode")
    func testImportConnections_parsesSSLVerifyCaMode() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Verify CA", sslEnabled: true, sslMode: "verify-ca")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Verify CA")
    }

    @Test("importConnections parses SSL with verify-full mode")
    func testImportConnections_parsesSSLVerifyFullMode() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Verify Full", sslEnabled: true, sslMode: "verify-full")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Verify Identity")
    }

    @Test("importConnections SSL enabled with empty mode defaults to Preferred")
    func testImportConnections_sslEnabledEmptyModeDefaultsToPreferred() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Default", sslEnabled: true, sslMode: "")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Preferred")
    }

    @Test("importConnections parses SSL certificate paths")
    func testImportConnections_parsesSSLCertPaths() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(
                name: "SSL Certs",
                sslEnabled: true,
                sslMode: "verify-full",
                sslCaCertPath: "/path/to/ca.pem",
                sslClientCertPath: "/path/to/cert.pem",
                sslClientKeyPath: "/path/to/key.pem"
            )
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        let ssl = result.envelope.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.caCertificatePath == "/path/to/ca.pem")
        #expect(ssl?.clientCertificatePath == "/path/to/cert.pem")
        #expect(ssl?.clientKeyPath == "/path/to/key.pem")
    }

    @Test("importConnections no SSL when handler missing")
    func testImportConnections_noSSLWhenHandlerMissing() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "No SSL", sslEnabled: false)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sslConfig == nil)
    }

    @Test("importConnections no SSL when handler disabled")
    func testImportConnections_noSSLWhenHandlerDisabled() throws {
        var connDict = makeConnection(name: "SSL Disabled")
        guard var config = connDict["configuration"] as? [String: Any] else {
            Issue.record("Expected configuration dict")
            return
        }
        config["handlers"] = [
            "ssl": [
                "enabled": false,
                "properties": [
                    "sslMode": "require"
                ] as [String: Any]
            ] as [String: Any]
        ]
        connDict["configuration"] = config

        let connections: [String: [String: Any]] = ["pg-1": connDict]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections[0].sslConfig == nil)
    }
}
