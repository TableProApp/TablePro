//
//  DataGripImporterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("DataGripImporter", .serialized)
struct DataGripImporterTests {
    private let root: URL
    private let optionsDir: URL
    private var importer: DataGripImporter

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataGripImporterTests-\(UUID().uuidString)")
        optionsDir = root.appendingPathComponent("DataGrip2025.1/options")
        try FileManager.default.createDirectory(at: optionsDir, withIntermediateDirectories: true)

        var imp = DataGripImporter()
        imp.jetBrainsRoot = root
        importer = imp
    }

    // MARK: - Fixtures

    private func writeDataSources(_ elements: [String]) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="DataSourceManagerImpl" format="xml" multifile-model="true">
          \(elements.joined(separator: "\n"))
          </component>
        </application>
        """
        try xml.write(to: optionsDir.appendingPathComponent("dataSources.xml"), atomically: true, encoding: .utf8)
    }

    private func writeSSHConfig(_ configs: [String]) throws {
        let xml = """
        <application>
          <component name="SshConfigs">
            <configs>
            \(configs.joined(separator: "\n"))
            </configs>
          </component>
        </application>
        """
        try xml.write(to: optionsDir.appendingPathComponent("ssh-config.xml"), atomically: true, encoding: .utf8)
    }

    private func source(
        uuid: String,
        name: String,
        driverRef: String,
        jdbcURL: String,
        userName: String = "",
        group: String? = nil,
        extra: String = ""
    ) -> String {
        let groupAttr = group.map { " group-name=\"\($0)\"" } ?? ""
        let userElement = userName.isEmpty ? "" : "<user-name>\(userName)</user-name>"
        return """
        <data-source source="LOCAL" name="\(name)" uuid="\(uuid)"\(groupAttr)>
          <driver-ref>\(driverRef)</driver-ref>
          <jdbc-url>\(jdbcURL)</jdbc-url>
          \(userElement)
          \(extra)
        </data-source>
        """
    }

    // MARK: - Discovery

    @Test("connectionCount counts unique data sources")
    func connectionCount() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a"),
            source(uuid: "2", name: "B", driverRef: "postgresql", jdbcURL: "jdbc:postgresql://h:5432/b")
        ])
        #expect(importer.connectionCount() == 2)
    }

    @Test("import throws when no DataGrip data found")
    func noData() {
        #expect(throws: ForeignAppImportError.self) {
            try importer.importConnections(includePasswords: false)
        }
    }

    // MARK: - Mapping

    @Test("maps driver-ref to database types")
    func driverMapping() throws {
        try writeDataSources([
            source(uuid: "1", name: "my", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a"),
            source(uuid: "2", name: "pg", driverRef: "postgresql", jdbcURL: "jdbc:postgresql://h:5432/b"),
            source(uuid: "3", name: "ms", driverRef: "sqlserver.ms", jdbcURL: "jdbc:sqlserver://h:1433;databaseName=c"),
            source(uuid: "4", name: "or", driverRef: "oracle", jdbcURL: "jdbc:oracle:thin:@h:1521:ORCL"),
            source(uuid: "5", name: "lt", driverRef: "sqlite.xerial", jdbcURL: "jdbc:sqlite:/tmp/x.db")
        ])

        let result = try importer.importConnections(includePasswords: false)
        let types = Dictionary(uniqueKeysWithValues: result.envelope.connections.map { ($0.name, $0.type) })

        #expect(types["my"] == "MySQL")
        #expect(types["pg"] == "PostgreSQL")
        #expect(types["ms"] == "SQL Server")
        #expect(types["or"] == "Oracle")
        #expect(types["lt"] == "SQLite")
    }

    @Test("parses host, port and database from jdbc url")
    func endpointParsing() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://db.example.com:3307/shop", userName: "root")
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        #expect(connection.host == "db.example.com")
        #expect(connection.port == 3_307)
        #expect(connection.database == "shop")
        #expect(connection.username == "root")
    }

    @Test("uses default port when jdbc url omits it")
    func defaultPort() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "postgresql", jdbcURL: "jdbc:postgresql://localhost/app")
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        #expect(connection.port == 5_432)
    }

    @Test("SQLite stores file path as database")
    func sqlitePath() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "sqlite.xerial", jdbcURL: "jdbc:sqlite:/Users/me/app.db")
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        #expect(connection.type == "SQLite")
        #expect(connection.database == "/Users/me/app.db")
    }

    // MARK: - SSH

    @Test("joins SSH config by ssh-config-id")
    func sshJoin() throws {
        try writeDataSources([
            source(
                uuid: "1",
                name: "A",
                driverRef: "mysql.8",
                jdbcURL: "jdbc:mysql://h:3306/a",
                extra: "<ssh-properties><enabled>true</enabled><ssh-config-id>SSH1</ssh-config-id></ssh-properties>"
            )
        ])
        try writeSSHConfig([
            "<sshConfig host=\"bastion.example.com\" id=\"SSH1\" keyPath=\"/Users/me/.ssh/id_rsa\" port=\"2222\" username=\"deploy\" authType=\"KEY_PAIR\"/>"
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        let ssh = try #require(connection.sshConfig)
        #expect(ssh.host == "bastion.example.com")
        #expect(ssh.port == 2_222)
        #expect(ssh.username == "deploy")
        #expect(ssh.authMethod == "Private Key")
        #expect(ssh.privateKeyPath == "/Users/me/.ssh/id_rsa")
    }

    @Test("no SSH when properties disabled")
    func sshDisabled() throws {
        try writeDataSources([
            source(
                uuid: "1",
                name: "A",
                driverRef: "mysql.8",
                jdbcURL: "jdbc:mysql://h:3306/a",
                extra: "<ssh-properties><enabled>false</enabled></ssh-properties>"
            )
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        #expect(connection.sshConfig == nil)
    }

    // MARK: - SSL

    @Test("parses SSL mode and certificate paths")
    func sslParsing() throws {
        try writeDataSources([
            source(
                uuid: "1",
                name: "A",
                driverRef: "postgresql",
                jdbcURL: "jdbc:postgresql://h:5432/a",
                extra: """
                <ssl-properties>
                  <enabled>true</enabled>
                  <ssl-mode>verify-full</ssl-mode>
                  <ca-file>/certs/ca.pem</ca-file>
                </ssl-properties>
                """
            )
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        let ssl = try #require(connection.sslConfig)
        #expect(ssl.mode == "Verify Identity")
        #expect(ssl.caCertificatePath == "/certs/ca.pem")
    }

    // MARK: - Groups & Dedup

    @Test("group-name attribute becomes a group")
    func groups() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a", group: "Production")
        ])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections.first?.groupName == "Production")
        #expect(result.envelope.groups?.contains { $0.name == "Production" } == true)
    }

    @Test("deduplicates data sources by uuid")
    func dedup() throws {
        try writeDataSources([
            source(uuid: "dup", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a"),
            source(uuid: "dup", name: "A copy", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a")
        ])

        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.connections.count == 1)
    }
}
