//
//  DataGripImporterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
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

    private func writeLocalDataSources(_ elements: [String]) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <project version="4">
          <component name="dataSourceStorageLocal">
          \(elements.joined(separator: "\n"))
          </component>
        </project>
        """
        try xml.write(to: optionsDir.appendingPathComponent("dataSources.local.xml"), atomically: true, encoding: .utf8)
    }

    private func writeSSHConfigs(_ configs: [String]) throws {
        let xml = """
        <application>
          <component name="SshConfigs">
            <configs>
            \(configs.joined(separator: "\n"))
            </configs>
          </component>
        </application>
        """
        try xml.write(to: optionsDir.appendingPathComponent("sshConfigs.xml"), atomically: true, encoding: .utf8)
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

    private func localSource(uuid: String, name: String = "", userName: String = "", extra: String = "") -> String {
        let nameAttr = name.isEmpty ? "" : " name=\"\(name)\""
        let userElement = userName.isEmpty ? "" : "<user-name>\(userName)</user-name>"
        return """
        <data-source\(nameAttr) uuid="\(uuid)">
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

    @Test("joins SSH config from local file, infers key auth, expands $USER_HOME$")
    func sshJoin() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a")
        ])
        try writeLocalDataSources([
            localSource(
                uuid: "1",
                userName: "appuser",
                extra: "<ssh-properties><enabled>true</enabled><ssh-config-id>SSH1</ssh-config-id></ssh-properties>"
            )
        ])
        try writeSSHConfigs([
            """
            <sshConfig host="bastion.example.com" id="SSH1" keyPath="$USER_HOME$/.ssh/id_ed25519" \
            port="2222" username="deploy" useOpenSSHConfig="true"/>
            """
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        #expect(connection.username == "appuser")
        let ssh = try #require(connection.sshConfig)
        #expect(ssh.host == "bastion.example.com")
        #expect(ssh.port == 2_222)
        #expect(ssh.username == "deploy")
        #expect(ssh.authMethod == "Private Key")
        #expect(ssh.privateKeyPath == "\(NSHomeDirectory())/.ssh/id_ed25519")
    }

    @Test("respects explicit password auth even with a key path")
    func sshPasswordAuth() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a")
        ])
        try writeLocalDataSources([
            localSource(
                uuid: "1",
                extra: "<ssh-properties><enabled>true</enabled><ssh-config-id>SSH1</ssh-config-id></ssh-properties>"
            )
        ])
        try writeSSHConfigs([
            "<sshConfig host=\"h\" id=\"SSH1\" port=\"22\" username=\"u\" authType=\"PASSWORD\"/>"
        ])

        let ssh = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first?.sshConfig)
        #expect(ssh.authMethod == "Password")
        #expect(ssh.privateKeyPath == "")
    }

    @Test("no SSH when properties disabled in local file")
    func sshDisabled() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a")
        ])
        try writeLocalDataSources([
            localSource(uuid: "1", extra: "<ssh-properties><enabled>false</enabled></ssh-properties>")
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        #expect(connection.sshConfig == nil)
    }

    @Test("imports SSH password from c.kdbx end to end")
    func sshPasswordImported() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "mysql.8", jdbcURL: "jdbc:mysql://h:3306/a")
        ])
        try writeLocalDataSources([
            localSource(
                uuid: "1",
                extra: "<ssh-properties><enabled>true</enabled><ssh-config-id>SSH1</ssh-config-id></ssh-properties>"
            )
        ])
        try writeSSHConfigs([
            "<sshConfig authType=\"PASSWORD\" host=\"localhost\" id=\"SSH1\" port=\"22\" username=\"u\" useOpenSSHConfig=\"false\"/>"
        ])

        let configDir = optionsDir.deletingLastPathComponent()
        let mainKey = KdbxTestFixture.randomBytes(64)
        let service = JetBrainsCredentialStore.sshPasswordServiceName(host: "localhost", port: 22, configId: "SSH1")
        try KdbxTestFixture.makeKdbx(mainKey: mainKey, title: service, userName: "", password: "ssh-pw")
            .write(to: configDir.appendingPathComponent("c.kdbx"))
        try KdbxTestFixture.makeMainKeyFile(mainKey: mainKey)
            .write(to: configDir.appendingPathComponent("c.pwd"), atomically: true, encoding: .utf8)

        let result = try importer.importConnections(includePasswords: true)
        let credentials = try #require(result.envelope.credentials?["0"])
        #expect(credentials.sshPassword == "ssh-pw")
    }

    @Test("merges user-name from local file when shared file omits it")
    func usernameFromLocalFile() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "postgresql", jdbcURL: "jdbc:postgresql://h:5432/db")
        ])
        try writeLocalDataSources([
            localSource(uuid: "1", userName: "postgres")
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        #expect(connection.username == "postgres")
    }

    // MARK: - SSL

    @Test("parses SSL config from local file and expands $USER_HOME$")
    func sslParsing() throws {
        try writeDataSources([
            source(uuid: "1", name: "A", driverRef: "postgresql", jdbcURL: "jdbc:postgresql://h:5432/a")
        ])
        try writeLocalDataSources([
            localSource(uuid: "1", extra: """
            <ssl-config use-ide-store="true">
              <ca-cert>$USER_HOME$/certs/ca.pem</ca-cert>
              <client-cert>$USER_HOME$/certs/client.crt</client-cert>
              <client-key>$USER_HOME$/certs/client.key</client-key>
              <enabled>true</enabled>
              <mode>VERIFY_FULL</mode>
            </ssl-config>
            """)
        ])

        let connection = try #require(try importer.importConnections(includePasswords: false).envelope.connections.first)
        let ssl = try #require(connection.sslConfig)
        #expect(ssl.mode == "Verify Identity")
        #expect(ssl.caCertificatePath == "\(NSHomeDirectory())/certs/ca.pem")
        #expect(ssl.clientCertificatePath == "\(NSHomeDirectory())/certs/client.crt")
        #expect(ssl.clientKeyPath == "\(NSHomeDirectory())/certs/client.key")
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
