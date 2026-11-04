//
//  DBeaverImporterTests.swift
//  TableProTests
//

import CommonCrypto
import Foundation
import TableProImport
import TableProPluginKit
@testable import TablePro
import Testing

struct DBeaverImporterTests {
    private var tempDir: URL
    private var projectDir: URL
    private var importer: DBeaverImporter

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBeaverImporterTests-\(UUID().uuidString)")

        // DBeaver layout: <root>/workspace6/<project>/.dbeaver/data-sources.json
        projectDir = tempDir.appendingPathComponent("workspace6/General/.dbeaver")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var imp = DBeaverImporter()
        imp.dbeaverDataRoot = tempDir
        imp.resolveAppURL = { _ in nil }
        importer = imp
    }

    // MARK: - Fixture Helpers

    private func writeDataSources(_ json: [String: Any], named fileName: String = "data-sources.json") throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try data.write(to: projectDir.appendingPathComponent(fileName))
    }

    private func writeCredentials(
        _ credentials: [String: Any],
        named fileName: String = "credentials-config.json"
    ) throws {
        let plaintext = try JSONSerialization.data(withJSONObject: credentials, options: .prettyPrinted)
        let encrypted = encryptWithDBeaverKey(plaintext)
        try encrypted.write(to: projectDir.appendingPathComponent(fileName))
    }

    private func urlConnection(
        _ name: String,
        provider: String = "postgresql",
        configuration: [String: Any]
    ) -> [String: Any] {
        ["provider": provider, "name": name, "configuration": configuration]
    }

    private func tlsConnection(
        _ name: String,
        provider: String = "postgresql",
        handler: String,
        properties: [String: Any]
    ) -> [String: Any] {
        urlConnection(name, provider: provider, configuration: [
            "host": "db.example.com",
            "handlers": [handler: ["type": "CONFIG", "enabled": true, "properties": properties] as [String: Any]]
        ])
    }

    private func collectByName(_ request: ForeignImportRequest = .connectionsOnly) throws -> [String: ExportableConnection] {
        Dictionary(uniqueKeysWithValues: try importer.collect(request).connections.map { ($0.name, $0) })
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
        user: String? = "admin",
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
            "database": database
        ]
        if let user = user {
            config["user"] = user
        }
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

    @Test("isAvailable returns true when data-sources.json exists for any edition")
    func testIsAvailable_whenFileExists_returnsTrue() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [:]))
        #expect(importer.isAvailable() == true)
    }

    @Test("isAvailable returns false when no app and no data exist")
    func testIsAvailable_whenFileMissing_returnsFalse() throws {
        try? FileManager.default.removeItem(at: projectDir.appendingPathComponent("data-sources.json"))
        #expect(importer.isAvailable() == false)
    }

    @Test("isAvailable returns true when a DBeaver app is installed even without data")
    func testIsAvailable_whenAppInstalledWithoutData_returnsTrue() throws {
        try? FileManager.default.removeItem(at: projectDir.appendingPathComponent("data-sources.json"))
        var imp = importer
        imp.resolveAppURL = { _ in URL(fileURLWithPath: "/Applications/DBeaver.app") }
        #expect(imp.isAvailable() == true)
    }

    // MARK: - inventory

    @Test("inventory counts connections")
    func testInventory_returnsCorrectCount() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG1"),
            "pg-2": makeConnection(name: "PG2"),
            "mysql-1": makeConnection(name: "MySQL1", provider: "mysql")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        #expect(importer.inventory() == ForeignAppInventory(connections: 3, savedQueries: 0))
    }

    @Test("inventory is empty when the file is missing")
    func testInventory_fileMissing_returnsZero() throws {
        try? FileManager.default.removeItem(at: projectDir.appendingPathComponent("data-sources.json"))
        #expect(importer.inventory() == ForeignAppInventory(connections: 0, savedQueries: 0))
    }

    // MARK: - collect

    @Test("collect parses all connections")
    func testCollect_parsesAllConnections() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG1"),
            "mysql-1": makeConnection(name: "MySQL1", provider: "mysql")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections.count == 2)
        #expect(result.source == .foreignApp(name: "DBeaver"))
    }

    @Test("collect maps provider correctly")
    func testCollect_mapsProviderCorrectly() throws {
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
            ("tidb", "TiDB"),
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

        let result = try importer.collect(.connectionsOnly)
        let typeSet = Set(result.connections.map(\.type))

        for mapping in providerMappings {
            #expect(typeSet.contains(mapping.1), "Provider \(mapping.0) should map to \(mapping.1)")
        }
    }

    @Test("DBeaver's TiDB Lakehouse provider is not imported as TiDB")
    func testCollect_tidbLakeIsNotTiDB() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "lake": makeConnection(name: "Lake", provider: "tidblake")
        ]))
        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections.first?.type != "TiDB")
    }

    @Test("collect parses port as Int")
    func testCollect_parsesPortAsInt() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", port: 5433)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].port == 5433)
    }

    @Test("collect parses port as String")
    func testCollect_parsesPortAsString() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", port: "5433")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].port == 5433)
    }

    @Test("collect uses default port when missing")
    func testCollect_defaultPortWhenMissing() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let portMap = Dictionary(
            uniqueKeysWithValues: result.connections.map { ($0.type, $0.port) }
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

    @Test("collect parses SSH tunnel with PUBLIC_KEY auth")
    func testCollect_parsesSSHTunnel_publicKey() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh != nil)
        #expect(ssh?.enabled == true)
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Private Key")
        #expect(ssh?.privateKeyPath == "~/.ssh/id_rsa")
    }

    @Test("collect parses SSH tunnel with AGENT auth")
    func testCollect_parsesSSHTunnel_agent() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh?.authMethod == "SSH Agent")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("collect parses SSH tunnel with PASSWORD auth")
    func testCollect_parsesSSHTunnel_password() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let ssh = result.connections[0].sshConfig

        #expect(ssh?.authMethod == "Password")
        #expect(ssh?.privateKeyPath == "")
    }

    @Test("collect no SSH when handler missing")
    func testCollect_noSSHWhenHandlerMissing() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "No SSH PG", sshEnabled: false)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].sshConfig == nil)
    }

    @Test("collect preserves folders")
    func testCollect_preservesFolders() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let pathsByName = Dictionary(uniqueKeysWithValues: result.connections.indices.map {
            (result.connections[$0].name, result.groupPath(at: $0))
        })

        #expect(pathsByName["Prod PG"] == ["Production Servers"])
        #expect(pathsByName["Dev PG"] == ["Development Servers"])
        #expect(pathsByName["Local PG"] == [])
        #expect(result.bundle.groups.count == 2)
    }

    @Test("collect keeps the folder path and names a folder without description by its path component")
    func testCollect_folderWithoutDescription() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", folder: "team/backend")
        ]
        let folders: [String: [String: Any]] = [
            "team/backend": ["description": ""]
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections, folders: folders))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.groupPath(at: 0) == ["team", "backend"])
    }

    @Test("collect decrypts credentials")
    func testCollect_decryptsCredentials() throws {
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

        let result = try importer.collect(.withPasswords)
        #expect(result.bundle.credentials["pg-1"]?.password == "s3cr3t_p4ss")
    }

    @Test("collect without passwords skips decryption")
    func testCollect_withoutPasswords_skipsDecryption() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        try writeCredentials(["pg-1": ["#connection": ["password": "secret"]]])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.bundle.credentials.isEmpty)
    }

    // MARK: - Data source files

    @Test("collect reads every data-sources file with its own credentials file and one folder tree")
    func testCollect_readsEveryDataSourcesFile() throws {
        try writeDataSources(makeDataSourcesJSON(
            connections: ["main-1": makeConnection(name: "Main", user: nil)],
            folders: ["shared": ["description": "Shared Servers"]]
        ))
        try writeCredentials(["main-1": ["#connection": ["user": "main-user", "password": "main-pass"]]])
        try writeDataSources(
            makeDataSourcesJSON(connections: ["sub-1": makeConnection(name: "Second", user: nil, folder: "shared")]),
            named: "data-sources-2.json"
        )
        try writeCredentials(
            ["sub-1": ["#connection": ["user": "reporter", "password": "sub-pass"]]],
            named: "credentials-config-2.json"
        )
        try Data("not json".utf8).write(to: projectDir.appendingPathComponent("data-sources-broken.json"))

        #expect(importer.inventory().connections == 2)
        let result = try importer.collect(.withPasswords)
        #expect(result.connections.map { $0.name } == ["Main", "Second"])
        #expect(result.connections.map { $0.username } == ["main-user", "reporter"])
        #expect(result.bundle.credentials["main-1"]?.password == "main-pass")
        #expect(result.bundle.credentials["sub-1"]?.password == "sub-pass")
        #expect(result.groupPath(at: 1) == ["Shared Servers"])
    }

    @Test("A project with only an extra data-sources file is found")
    func testCollect_projectWithOnlyAnExtraFile() throws {
        try writeDataSources(
            makeDataSourcesJSON(connections: ["team-1": makeConnection(name: "Team")]),
            named: "data-sources-team.json"
        )

        #expect(importer.isAvailable())
        #expect(try importer.collect(.connectionsOnly).connections.map { $0.name } == ["Team"])
    }

    @Test("The first project by name is read, whatever order the folder lists them in")
    func testCollect_readsProjectsInNameOrder() throws {
        let workspace = projectDir.deletingLastPathComponent().deletingLastPathComponent()
        for project in ["Beta", "Alpha"] {
            let json = makeDataSourcesJSON(connections: ["\(project)-1": makeConnection(name: "\(project) PG")])
            let data = try JSONSerialization.data(withJSONObject: json)
            let metadata = workspace.appendingPathComponent("\(project)/.dbeaver", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try data.write(to: metadata.appendingPathComponent("data-sources.json"))
        }

        #expect(try importer.collect(.connectionsOnly).connections.map { $0.name } == ["Alpha PG"])
    }

    // MARK: - Tunnel credentials

    @Test("A tunnel's user and password come from the credentials file's network node")
    func testCollect_tunnelSecretsFromNetworkNode() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "ssh-1": makeConnection(name: "Tunnel", sshEnabled: true, sshHost: "bastion.example.com")
        ]))
        try writeCredentials(["ssh-1": ["network/ssh_tunnel": ["user": "tunnel-user", "password": "tunnel-secret"]]])

        #expect(try importer.collect(.connectionsOnly).connections[0].sshConfig?.username == "tunnel-user")
        let result = try importer.collect(.withPasswords)
        #expect(result.connections[0].sshConfig?.username == "tunnel-user")
        #expect(result.bundle.credentials["ssh-1"]?.sshPassword == "tunnel-secret")
        #expect(result.bundle.credentials["ssh-1"]?.password == nil)
    }

    @Test("A key tunnel's saved secret imports as the key passphrase, not the SSH password")
    func testCollect_keyTunnelSecretIsThePassphrase() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "key-1": makeConnection(
                name: "Key tunnel",
                sshEnabled: true,
                sshHost: "bastion.example.com",
                sshUsername: "deploy",
                sshAuthType: "PUBLIC_KEY",
                sshKeyPath: "~/.ssh/id_ed25519"
            )
        ]))
        try writeCredentials(["key-1": ["network/ssh_tunnel": ["password": "phrase"]]])

        let credentials = try importer.collect(.withPasswords).bundle.credentials["key-1"]
        #expect(credentials?.keyPassphrase == "phrase")
        #expect(credentials?.sshPassword == nil)
    }

    // MARK: - Username (credentials-config.json)

    @Test("Username imports from credentials-config.json")
    func testCollect_usernameFromCredentials() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", user: nil)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        try writeCredentials(["pg-1": ["#connection": ["user": "sameer", "password": "p"]]])

        let result = try importer.collect(.withPasswords)
        #expect(result.connections[0].username == "sameer")
    }

    @Test("Username imports even when passwords are excluded")
    func testCollect_usernameImportsWithoutPasswords() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", user: nil)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        try writeCredentials(["pg-1": ["#connection": ["user": "sameer", "password": "p"]]])

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].username == "sameer")
        #expect(result.bundle.credentials.isEmpty)
    }

    @Test("Username falls back to data-sources configuration.user")
    func testCollect_usernameFallsBackToConfig() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", user: "configuser")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.withPasswords)
        #expect(result.connections[0].username == "configuser")
    }

    @Test("Credentials username takes precedence over configuration.user")
    func testCollect_credentialsUsernameWins() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", user: "configuser")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        try writeCredentials(["pg-1": ["#connection": ["user": "creduser"]]])

        let result = try importer.collect(.withPasswords)
        #expect(result.connections[0].username == "creduser")
    }

    @Test("Empty credentials username falls back to configuration.user")
    func testCollect_emptyCredentialsUsernameFallsBack() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "PG", user: "configuser")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))
        try writeCredentials(["pg-1": ["#connection": ["user": ""]]])

        let result = try importer.collect(.withPasswords)
        #expect(result.connections[0].username == "configuser")
    }

    @Test("collect invalid JSON throws parse error")
    func testCollect_invalidJSON_throwsParseError() throws {
        let invalidData = Data("not valid json {{{".utf8)
        try invalidData.write(to: projectDir.appendingPathComponent("data-sources.json"))

        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect empty connections throws noConnectionsFound")
    func testCollect_emptyConnections_throws() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [:]))

        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect color mapping from RGB")
    func testCollect_colorMapping() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let colorMap = Dictionary(uniqueKeysWithValues: result.connections.map { ($0.name, $0.color) })

        #expect(colorMap["Red"] == "Red")
        #expect(colorMap["Orange"] == "Orange")
        #expect(colorMap["Yellow"] == "Yellow")
        #expect(colorMap["Green"] == "Green")
        #expect(colorMap["Blue"] == "Blue")
        #expect(colorMap["Purple"] == "Purple")
        #expect(colorMap["No Color"] == Optional<String>.none)
    }

    @Test("collect file not found throws error")
    func testCollect_fileNotFound_throwsError() throws {
        try FileManager.default.removeItem(at: tempDir)

        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.connectionsOnly)
        }
    }

    @Test("collect stamps the bundle and keys each connection by its data source id, sorted by name")
    func testCollect_bundleMetadata() throws {
        let connections: [String: [String: Any]] = [
            "pg-2": makeConnection(name: "Zeta"),
            "pg-1": makeConnection(name: "Alpha")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.bundle.appVersion == "DBeaver Import")
        #expect(result.bundle.tags.isEmpty)
        #expect(result.bundle.connections.map { $0.ref } == ["pg-1", "pg-2"])
    }

    @Test("collect SSH port as string")
    func testCollect_sshPortAsString() throws {
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

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].sshConfig?.port == 2222)
    }

    @Test("collect unknown provider passes through")
    func testCollect_unknownProvider() throws {
        let connections: [String: [String: Any]] = [
            "x-1": makeConnection(name: "Unknown DB", provider: "exoticdb")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].type == "exoticdb")
    }

    // MARK: - SSL Parsing

    @Test("collect parses SSL with require mode")
    func testCollect_parsesSSLRequireMode() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Require", sslEnabled: true, sslMode: "require")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Required")
    }

    @Test("collect parses SSL with verify-ca mode")
    func testCollect_parsesSSLVerifyCaMode() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Verify CA", sslEnabled: true, sslMode: "verify-ca")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Verify CA")
    }

    @Test("collect parses SSL with verify-full mode")
    func testCollect_parsesSSLVerifyFullMode() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Verify Full", sslEnabled: true, sslMode: "verify-full")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.mode == "Verify Identity")
    }

    @Test("A plain ssl handler with no mode keeps TLS on, with a mode the review warns about")
    func testCollect_sslEnabledEmptyModeIsUnread() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "SSL Default", sslEnabled: true, sslMode: "")
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig

        #expect(ssl?.mode == "ssl")
        #expect(ssl?.portableMode == nil)
    }

    @Test("Each engine's TLS handler is read by its own name, with DBeaver's certificate keys")
    func testCollect_engineTLSHandlers() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "pg-require": tlsConnection("PG require", handler: "postgre_ssl", properties: ["sslMode": "require"]),
            "pg-default": tlsConnection("PG default", handler: "postgre_ssl", properties: [
                "sslMode": "", "ssl.ca.cert": "", "rootCert": "/root.crt", "clientCert": "/old.crt"
            ]),
            "pg-certs": tlsConnection("PG certs", handler: "postgre_ssl", properties: [
                "sslMode": "verify-ca",
                "ssl.ca.cert": "/ca.pem",
                "ssl.client.cert": "/cert.pem",
                "ssl.client.key": "/key.pem"
            ]),
            "pg-off": tlsConnection("PG off", handler: "postgre_ssl", properties: ["sslMode": "disable"]),
            "mysql-required": tlsConnection("MySQL required", provider: "mysql", handler: "mysql_ssl", properties: [
                "ssl.require": "true", "ssl.verify.server": "false"
            ]),
            "mysql-verified": tlsConnection("MySQL verified", provider: "mysql", handler: "mysql_ssl", properties: [
                "ssl.verify.server": true, "ssl.ca.cert": "/certs/mysql-ca.pem"
            ]),
            "clickhouse": tlsConnection("ClickHouse", provider: "clickhouse", handler: "clickhouse-ssl", properties: [
                "ssl.mode": "NONE"
            ])
        ]))

        let byName = try collectByName()
        #expect(byName["PG require"]?.sslConfig?.mode == "Required")
        let pgDefault = byName["PG default"]?.sslConfig
        #expect(pgDefault?.mode == "Verify Identity")
        #expect(pgDefault?.caCertificatePath == "/root.crt")
        #expect(pgDefault?.clientCertificatePath == "/old.crt")
        let certs = byName["PG certs"]?.sslConfig
        #expect(certs?.mode == "Verify CA")
        #expect(certs?.caCertificatePath == "/ca.pem")
        #expect(certs?.clientCertificatePath == "/cert.pem")
        #expect(certs?.clientKeyPath == "/key.pem")
        #expect(byName["PG off"]?.sslConfig == nil)
        #expect(byName["MySQL required"]?.sslConfig?.mode == "Required")
        #expect(byName["MySQL verified"]?.sslConfig?.mode == "Verify CA")
        #expect(byName["MySQL verified"]?.sslConfig?.caCertificatePath == "/certs/mysql-ca.pem")
        #expect(byName["ClickHouse"]?.sslConfig?.mode == "Required")
    }

    @Test("A TLS handler whose mode is not read keeps TLS on, with a mode the review warns about")
    func testCollect_unreadTLSHandler() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "mssql": tlsConnection("SQL Server", provider: "sqlserver", handler: "mssql_ssl", properties: [
                "ssl.method": "KEYSTORE", "ssl.keystore": "/certs/store.jks"
            ]),
            "pg-unknown": tlsConnection("PG unknown", handler: "postgre_ssl", properties: ["sslMode": "sometimes"]),
            "ch-lax": tlsConnection("ClickHouse lax", provider: "clickhouse", handler: "clickhouse-ssl", properties: [
                "ssl.mode": "LAX"
            ])
        ]))

        let byName = try collectByName()
        #expect(byName["SQL Server"]?.sslConfig?.mode == "mssql_ssl")
        #expect(byName["PG unknown"]?.sslConfig?.mode == "sometimes")
        #expect(byName["ClickHouse lax"]?.sslConfig?.mode == "LAX")
        #expect(byName.values.allSatisfy { $0.sslConfig != nil && $0.sslConfig?.portableMode == nil })
    }

    @Test("A pgjdbc connection with no TLS handler takes the driver's default, preferred")
    func testCollect_pgjdbcWithoutHandlerPrefersTLS() throws {
        func pgjdbc(_ name: String, driver: String = "postgres-jdbc", _ configuration: [String: Any]) -> [String: Any] {
            ["provider": "postgresql", "driver": driver, "name": name, "configuration": configuration]
        }
        try writeDataSources(makeDataSourcesJSON(connections: [
            "plain": pgjdbc("Plain", ["host": "db.example.com"]),
            "url-off": pgjdbc("URL off", [
                "host": "db.example.com", "url": "jdbc:postgresql://db.example.com/app?sslmode=disable"
            ]),
            "property": pgjdbc("Property", ["host": "db.example.com", "properties": ["sslmode": "require"]]),
            "handler-off": pgjdbc("Handler off", [
                "host": "db.example.com",
                "handlers": ["postgre_ssl": ["enabled": true, "properties": ["sslMode": "disable"]]]
            ]),
            "other-driver": pgjdbc("Other driver", driver: "postgres-other", ["host": "db.example.com"]),
            "mysql": ["provider": "mysql", "driver": "mysql8", "name": "MySQL", "configuration": ["host": "db.example.com"]]
        ]))

        let byName = try collectByName()
        #expect(byName["Plain"]?.sslConfig == ExportableSSLConfig(mode: "Preferred"))
        #expect(byName["URL off"]?.sslConfig == nil)
        #expect(byName["Property"]?.sslConfig?.mode == "sslmode")
        #expect(byName["Property"]?.sslConfig?.portableMode == nil)
        #expect(byName["Handler off"]?.sslConfig == nil)
        #expect(byName["Other driver"]?.sslConfig == nil)
        #expect(byName["MySQL"]?.sslConfig == nil)

        let collected = try importer.collect(.connectionsOnly)
        #expect(collected.notes(named: "Plain") == ["SSL Preferred is on because DBeaver encrypts this connection by default"])
        let unnoted = ["URL off", "Property", "Handler off", "Other driver", "MySQL"]
        #expect(unnoted.allSatisfy { collected.notes(named: $0).isEmpty })
    }

    // MARK: - URLs

    @Test("A URL-only connection keeps what its URL names, never the URL or its password")
    func testCollect_urlOnlyConnectionNeverKeepsTheURL() throws {
        let url = "jdbc:postgresql://admin:hunter2@db.cloud.example:6543/app?password=hunter2&sslmode=require"
        try writeDataSources(makeDataSourcesJSON(connections: [
            "cloud": urlConnection("Cloud", configuration: ["url": url])
        ]))

        let connection = try #require(try importer.collect(.connectionsOnly).connections.first)
        #expect(connection.host == "db.cloud.example")
        #expect(connection.port == 6543)
        #expect(connection.database == "app")
        #expect(connection.username == "admin")
        #expect(connection.sslConfig?.mode == "Required")
        let encoded = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        #expect(!encoded.contains("hunter2"))
    }

    @Test("In URL mode the URL names the server over leftover manual fields")
    func testCollect_urlModeURLWins() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "url": urlConnection("URL mode", configuration: [
                "host": "old.example.com", "port": "6000", "database": "old",
                "url": "jdbc:postgresql://new.example.com/current", "configurationType": "URL"
            ]),
            "manual": urlConnection("Manual mode", configuration: [
                "host": "manual.example.com", "port": "5433", "database": "manual",
                "url": "jdbc:postgresql://url.example.com:6543/fromurl", "configurationType": "MANUAL"
            ]),
            "unparsed": urlConnection("Unparsed URL", configuration: [
                "host": "db", "port": "6000", "url": "not a url", "configurationType": "URL"
            ])
        ]))

        let byName = try collectByName()
        let urlMode = try #require(byName["URL mode"])
        #expect(urlMode.host == "new.example.com")
        #expect(urlMode.port == 5432)
        #expect(urlMode.database == "current")
        let manual = try #require(byName["Manual mode"])
        #expect(manual.host == "manual.example.com")
        #expect(manual.port == 5433)
        #expect(manual.database == "manual")
        let unparsed = try #require(byName["Unparsed URL"])
        #expect(unparsed.host == "db")
        #expect(unparsed.port == 6000)
    }

    @Test("A connection keeps the TLS its URL asks for and marks any other TLS switch unread")
    func testCollect_urlTLS() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "verified": urlConnection("Verified", configuration: [
                "url": "jdbc:postgresql://db.example.com/app?sslmode=verify-full"
            ]),
            "switch": urlConnection("Switch", configuration: ["url": "jdbc:postgresql://db.example.com/app?ssl=true"]),
            "https": urlConnection("HTTPS", provider: "clickhouse", configuration: [
                "url": "jdbc:clickhouse:https://ch.example.com:8443/default"
            ]),
            "plain": urlConnection("Plain", configuration: ["url": "jdbc:postgresql://db.example.com/app"])
        ]))

        let byName = try collectByName()
        #expect(byName["Verified"]?.sslConfig?.mode == "Verify Identity")
        #expect(byName["Switch"]?.sslConfig != nil)
        #expect(byName["Switch"]?.sslConfig?.portableMode == nil)
        #expect(byName["HTTPS"]?.sslConfig?.mode == "Verify Identity")
        #expect(byName["HTTPS"]?.host == "ch.example.com")
        #expect(byName["HTTPS"]?.port == 8443)
        #expect(byName["Plain"]?.sslConfig == nil)
    }

    @Test("A MongoDB URL keeps its seed list and auth database as MongoDB fields")
    func testCollect_mongoURLFields() throws {
        try writeDataSources(makeDataSourcesJSON(connections: [
            "atlas": urlConnection("Atlas", provider: "mongodb", configuration: [
                "url": "mongodb+srv://cluster0.example.net/app"
            ]),
            "mongo": urlConnection("Mongo", provider: "mongodb", configuration: [
                "host": "mongo.example.com", "port": "27017", "database": "shop",
                "url": "mongodb://mongo.example.com:27017/shop?authSource=admin"
            ])
        ]))

        let byName = try collectByName()
        let atlas = try #require(byName["Atlas"])
        #expect(atlas.host == "cluster0.example.net")
        #expect(atlas.database == "app")
        #expect(atlas.additionalFields?["mongoUseSrv"] == "true")
        #expect(atlas.sslConfig?.mode == "Verify Identity")
        let mongo = try #require(byName["Mongo"])
        #expect(mongo.host == "mongo.example.com")
        #expect(mongo.additionalFields?["mongoAuthSource"] == "admin")
    }

    @Test("collect parses SSL certificate paths")
    func testCollect_parsesSSLCertPaths() throws {
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

        let result = try importer.collect(.connectionsOnly)
        let ssl = result.connections[0].sslConfig

        #expect(ssl != nil)
        #expect(ssl?.caCertificatePath == "/path/to/ca.pem")
        #expect(ssl?.clientCertificatePath == "/path/to/cert.pem")
        #expect(ssl?.clientKeyPath == "/path/to/key.pem")
    }

    @Test("collect no SSL when handler missing")
    func testCollect_noSSLWhenHandlerMissing() throws {
        let connections: [String: [String: Any]] = [
            "pg-1": makeConnection(name: "No SSL", sslEnabled: false)
        ]
        try writeDataSources(makeDataSourcesJSON(connections: connections))

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].sslConfig == nil)
    }

    @Test("collect no SSL when handler disabled")
    func testCollect_noSSLWhenHandlerDisabled() throws {
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

        let result = try importer.collect(.connectionsOnly)
        #expect(result.connections[0].sslConfig == nil)
    }

    // MARK: - Scripts

    private var scriptsDir: URL {
        projectDir.deletingLastPathComponent().appendingPathComponent("Scripts", isDirectory: true)
    }

    private func writeScriptFixture() throws {
        try writeDataSources(makeDataSourcesJSON(connections: ["pg-1": makeConnection(name: "Orders")]))
        try ForeignFixture.write("select 1;", to: scriptsDir.appendingPathComponent("Script.sql"))
        try ForeignFixture.write("select 3;", to: scriptsDir.appendingPathComponent("Script-3.sql"))
        try ForeignFixture.write("select ${days};", to: scriptsDir.appendingPathComponent("Reports/Daily users.sql"))
        try ForeignFixture.write("select 'free';", to: scriptsDir.appendingPathComponent("Unbound.sql"))
        try ForeignFixture.write("select 'other';", to: scriptsDir.appendingPathComponent("Elsewhere.sql"))
        try ForeignFixture.write("", to: scriptsDir.appendingPathComponent("Empty.sql"))
        try ForeignFixture.write("  \n", to: scriptsDir.appendingPathComponent("Blank.sql"))
        try ForeignFixture.write("not a script", to: scriptsDir.appendingPathComponent("notes.txt"))
        let metadata: [String: Any] = [
            "resources": [
                "Scripts/Script.sql": ["default-datasource": "pg-1"],
                "Scripts/Reports/Daily users.sql": ["default-datasource": "pg-1", "default-schema": "public"],
                "Scripts/Elsewhere.sql": ["default-datasource": "postgres-in-another-project"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: projectDir.appendingPathComponent("project-metadata.json"))
    }

    @Test("collect binds a script to the data source DBeaver opens it on")
    func testCollect_boundScriptKeepsItsConnection() throws {
        try writeScriptFixture()

        let result = try importer.collect(.withSavedQueries)

        let daily = try #require(result.savedQuery(named: "Daily users"))
        #expect(daily.sql == "select ${days};")
        #expect(daily.connectionRef == "pg-1")
        #expect(result.folderPath(of: daily) == ["Reports"])
        #expect(result.bundle.folderChain(daily.folderRef).allSatisfy { $0.connectionRef == "pg-1" })
        #expect(result.isSuggested(daily))
    }

    @Test("collect files an unbound script as a global query under the DBeaver folder")
    func testCollect_unboundScriptIsGlobal() throws {
        try writeScriptFixture()

        let result = try importer.collect(.withSavedQueries)

        let unbound = try #require(result.savedQuery(named: "Unbound"))
        #expect(unbound.connectionRef == nil)
        #expect(result.folderPath(of: unbound) == ["DBeaver"])
        #expect(result.isSuggested(unbound))
    }

    @Test("collect lists a script bound to an unknown data source as global and unchecked")
    func testCollect_scriptBoundElsewhereIsUnsuggested() throws {
        try writeScriptFixture()

        let result = try importer.collect(.withSavedQueries)

        let elsewhere = try #require(result.savedQuery(named: "Elsewhere"))
        #expect(elsewhere.connectionRef == nil)
        #expect(result.folderPath(of: elsewhere) == ["DBeaver"])
        #expect(!result.isSuggested(elsewhere))
    }

    @Test("collect lists default-named scripts unchecked and skips empty files")
    func testCollect_autoNamedUncheckedEmptySkipped() throws {
        try writeScriptFixture()

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQueryNames == ["Script", "Script-3", "Daily users", "Unbound", "Elsewhere"])
        let script = try #require(result.savedQuery(named: "Script"))
        #expect(script.connectionRef == "pg-1")
        #expect(!result.isSuggested(script))
        let numbered = try #require(result.savedQuery(named: "Script-3"))
        #expect(!result.isSuggested(numbered))
    }

    @Test("A script over the sync limit is listed as oversized without being read")
    func testCollect_oversizedScript() throws {
        try writeScriptFixture()
        let big = String(repeating: "-", count: 1_048_576)
        try ForeignFixture.write(big, to: scriptsDir.appendingPathComponent("Big.sql"))

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQuery(named: "Big") == nil)
        let oversized = try #require(result.oversizedQueries.first { $0.name == "Big" })
        #expect(oversized.byteCount == 1_048_576)
        #expect(oversized.connection == nil)
        #expect(oversized.folderPath == ["DBeaver"])
    }

    @Test("collect reads no scripts unless saved queries are requested")
    func testCollect_withoutSavedQueries_readsNoScripts() throws {
        try writeScriptFixture()

        let result = try importer.collect(.connectionsOnly)

        #expect(result.bundle.savedQueries.isEmpty)
        #expect(result.oversizedQueries.isEmpty)
    }

    @Test("Script names DBeaver generates are recognized")
    func testAutoNamedScripts() {
        #expect(DBeaverScriptReader.isAutoNamed("Script"))
        #expect(DBeaverScriptReader.isAutoNamed("Script-12"))
        #expect(DBeaverScriptReader.isAutoNamed("script-2"))
        #expect(!DBeaverScriptReader.isAutoNamed("Script-"))
        #expect(!DBeaverScriptReader.isAutoNamed("Script-2b"))
        #expect(!DBeaverScriptReader.isAutoNamed("Scripts"))
        #expect(!DBeaverScriptReader.isAutoNamed("Monthly report"))
    }

    @Test("inventory counts scripts that have text")
    func testInventory_countsScripts() throws {
        try writeScriptFixture()

        #expect(importer.inventory() == ForeignAppInventory(connections: 1, savedQueries: 5))
    }
}
