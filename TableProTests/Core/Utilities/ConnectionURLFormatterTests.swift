//
//  ConnectionURLFormatterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection URL Formatter")
struct ConnectionURLFormatterTests {
    // MARK: - Basic URLs

    @Test("Basic MySQL URL")
    func testBasicMySQLURL() {
        let conn = DatabaseConnection(
            name: "", host: "localhost", port: 3_306, database: "testdb",
            username: "root", type: .mysql
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url == "mysql://root:pass@localhost/testdb")
    }

    @Test("Basic PostgreSQL URL")
    func testBasicPostgreSQLURL() {
        let conn = DatabaseConnection(
            name: "", host: "db.example.com", port: 5_432, database: "mydb",
            username: "admin", type: .postgresql
        )
        let url = ConnectionURLFormatter.format(conn, password: "secret", sshPassword: nil)
        #expect(url == "postgresql://admin:secret@db.example.com/mydb")
    }

    // MARK: - Port Handling

    @Test("Default port omitted for MySQL")
    func testDefaultPortOmittedMySQL() {
        let conn = DatabaseConnection(
            name: "", host: "localhost", port: 3_306, database: "db",
            username: "root", type: .mysql
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(!url.contains(":3306"))
        #expect(url == "mysql://root:pass@localhost/db")
    }

    @Test("Non-default port included for MySQL")
    func testNonDefaultPortIncludedMySQL() {
        let conn = DatabaseConnection(
            name: "", host: "localhost", port: 3_307, database: "db",
            username: "root", type: .mysql
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains(":3307"))
        #expect(url == "mysql://root:pass@localhost:3307/db")
    }

    @Test("Default port omitted for PostgreSQL")
    func testDefaultPortOmittedPostgreSQL() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 5_432, database: "db",
            username: "user", type: .postgresql
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(!url.contains(":5432"))
    }

    @Test("Default port omitted for MongoDB")
    func testDefaultPortOmittedMongoDB() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 27_017, database: "db",
            username: "user", type: .mongodb
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(!url.contains(":27017"))
        #expect(url == "mongodb://user:pass@host/db")
    }

    // MARK: - Credentials

    @Test("No credentials when username is empty")
    func testNoCredentialsWhenUsernameEmpty() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 3_306, database: "db",
            username: "", type: .mysql
        )
        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)
        #expect(url == "mysql://host/db")
    }

    @Test("Username without password")
    func testUsernameWithoutPassword() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 3_306, database: "db",
            username: "user", type: .mysql
        )
        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)
        #expect(url == "mysql://user@host/db")
    }

    @Test("Username with empty password")
    func testUsernameWithEmptyPassword() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 3_306, database: "db",
            username: "user", type: .mysql
        )
        let url = ConnectionURLFormatter.format(conn, password: "", sshPassword: nil)
        #expect(url == "mysql://user@host/db")
    }

    // MARK: - Special Characters

    @Test("Special characters in password are percent-encoded")
    func testSpecialCharsInPasswordEncoded() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 5_432, database: "db",
            username: "user", type: .postgresql
        )
        let url = ConnectionURLFormatter.format(conn, password: "p@ss#word", sshPassword: nil)
        #expect(url.contains("p%40ss%23word"))
        #expect(url == "postgresql://user:p%40ss%23word@host/db")
    }

    @Test("Special characters in username are percent-encoded")
    func testSpecialCharsInUsernameEncoded() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 5_432, database: "db",
            username: "user@domain", type: .postgresql
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains("user%40domain"))
    }

    // MARK: - SQLite

    @Test("SQLite with absolute path")
    func testSQLiteAbsolutePath() {
        let conn = DatabaseConnection(
            name: "", host: "", port: 0, database: "/Users/me/data.db",
            username: "", type: .sqlite
        )
        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)
        #expect(url == "sqlite:///Users/me/data.db")
    }

    @Test("SQLite with relative path")
    func testSQLiteRelativePath() {
        let conn = DatabaseConnection(
            name: "", host: "", port: 0, database: "data.db",
            username: "", type: .sqlite
        )
        let url = ConnectionURLFormatter.format(conn, password: nil, sshPassword: nil)
        #expect(url == "sqlite://data.db")
    }

    // MARK: - SSH Tunnel

    @Test("SSH tunnel URL")
    func testSSHTunnelURL() {
        var sshConfig = SSHConfiguration()
        sshConfig.enabled = true
        sshConfig.host = "sshhost"
        sshConfig.port = 1_234
        sshConfig.username = "sshuser"

        let conn = DatabaseConnection(
            name: "", host: "127.0.0.1", port: 3_306, database: "db",
            username: "dbuser", type: .mysql, sshConfig: sshConfig
        )
        let url = ConnectionURLFormatter.format(conn, password: "dbpass", sshPassword: nil)
        #expect(url == "mysql+ssh://sshuser@sshhost:1234/dbuser:dbpass@127.0.0.1/db")
    }

    @Test("SSH with default port omitted")
    func testSSHDefaultPortOmitted() {
        var sshConfig = SSHConfiguration()
        sshConfig.enabled = true
        sshConfig.host = "sshhost"
        sshConfig.port = 22
        sshConfig.username = "sshuser"

        let conn = DatabaseConnection(
            name: "", host: "127.0.0.1", port: 3_306, database: "db",
            username: "dbuser", type: .mysql, sshConfig: sshConfig
        )
        let url = ConnectionURLFormatter.format(conn, password: "dbpass", sshPassword: nil)
        #expect(url == "mysql+ssh://sshuser@sshhost/dbuser:dbpass@127.0.0.1/db")
        #expect(!url.contains(":22"))
    }

    @Test("SSH with private key adds query param")
    func testSSHPrivateKey() {
        var sshConfig = SSHConfiguration()
        sshConfig.enabled = true
        sshConfig.host = "sshhost"
        sshConfig.port = 22
        sshConfig.username = "root"
        sshConfig.authMethod = .privateKey

        let conn = DatabaseConnection(
            name: "", host: "localhost", port: 3_306, database: "db",
            username: "user", type: .mysql, sshConfig: sshConfig
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains("usePrivateKey=true"))
    }

    // MARK: - SSL Mode

    @Test("SSL mode included in query string")
    func testSSLModeIncluded() {
        var sslConfig = SSLConfiguration()
        sslConfig.mode = .required

        let conn = DatabaseConnection(
            name: "", host: "host", port: 5_432, database: "db",
            username: "user", type: .postgresql, sslConfig: sslConfig
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains("sslmode=require"))
    }

    @Test("SSL disabled produces no sslmode param")
    func testSSLDisabledNoParam() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 5_432, database: "db",
            username: "user", type: .postgresql
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(!url.contains("sslmode"))
    }

    // MARK: - Connection Name

    @Test("Connection name in query string")
    func testConnectionNameInQuery() {
        let conn = DatabaseConnection(
            name: "My Connection", host: "host", port: 3_306, database: "db",
            username: "user", type: .mysql
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains("name=My+Connection"))
    }

    // MARK: - Round-trip

    @Test("Round-trip: format then parse preserves fields")
    func testRoundTrip() {
        var sshConfig = SSHConfiguration()
        sshConfig.enabled = true
        sshConfig.host = "jumpbox.example.com"
        sshConfig.port = 2_222
        sshConfig.username = "deploy"
        sshConfig.authMethod = .privateKey

        var sslConfig = SSLConfiguration()
        sslConfig.mode = .required

        let original = DatabaseConnection(
            name: "Production DB", host: "10.0.0.5", port: 5_433, database: "appdb",
            username: "admin", type: .postgresql, sshConfig: sshConfig, sslConfig: sslConfig
        )
        let password = "s3cret"

        let url = ConnectionURLFormatter.format(original, password: password, sshPassword: nil)
        let parseResult = ConnectionURLParser.parse(url)

        guard case .success(let parsed) = parseResult else {
            Issue.record("Expected successful parse of formatted URL: \(url)")
            return
        }

        #expect(parsed.type == .postgresql)
        #expect(parsed.host == "10.0.0.5")
        #expect(parsed.port == 5_433)
        #expect(parsed.database == "appdb")
        #expect(parsed.username == "admin")
        #expect(parsed.password == password)
        #expect(parsed.sshHost == "jumpbox.example.com")
        #expect(parsed.sshPort == 2_222)
        #expect(parsed.sshUsername == "deploy")
        #expect(parsed.usePrivateKey == true)
        #expect(parsed.sslMode == .required)
        #expect(parsed.connectionName == "Production DB")
    }

    // MARK: - MariaDB

    @Test("MariaDB uses mariadb scheme")
    func testMariaDBScheme() {
        let conn = DatabaseConnection(
            name: "", host: "host", port: 3_306, database: "db",
            username: "root", type: .mariadb
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.hasPrefix("mariadb://"))
    }

    @Test("SSH Agent connection formats useSSHAgent=true")
    func testSSHAgentConnectionFormat() {
        let sshConfig = SSHConfiguration(
            enabled: true, host: "jump.example.com", port: 22,
            username: "admin", authMethod: .sshAgent
        )
        let conn = DatabaseConnection(
            name: "Test", host: "127.0.0.1", port: 3_306, database: "mydb",
            username: "root", type: .mysql, sshConfig: sshConfig
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains("useSSHAgent=true"))
        #expect(!url.contains("usePrivateKey"))
        #expect(!url.contains("agentSocket"))
    }

    @Test("SSH Agent with custom socket formats agentSocket")
    func testSSHAgentWithCustomSocket() {
        let sshConfig = SSHConfiguration(
            enabled: true, host: "jump.example.com", port: 22,
            username: "admin", authMethod: .sshAgent,
            agentSocketPath: SSHAgentSocketOption.onePasswordSocketPath
        )
        let conn = DatabaseConnection(
            name: "Test", host: "127.0.0.1", port: 3_306, database: "mydb",
            username: "root", type: .mysql, sshConfig: sshConfig
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains("useSSHAgent=true"))
        #expect(url.contains("agentSocket="))
        #expect(url.contains("Group%20Containers"))
        #expect(!url.contains("Group Containers"))
    }

    @Test("SSH Agent without custom socket omits agentSocket param")
    func testSSHAgentNoSocketOmitsParam() {
        let sshConfig = SSHConfiguration(
            enabled: true, host: "jump.example.com", port: 22,
            username: "admin", authMethod: .sshAgent
        )
        let conn = DatabaseConnection(
            name: "", host: "127.0.0.1", port: 3_306, database: "mydb",
            username: "root", type: .mysql, sshConfig: sshConfig
        )
        let url = ConnectionURLFormatter.format(conn, password: "pass", sshPassword: nil)
        #expect(url.contains("useSSHAgent=true"))
        #expect(!url.contains("agentSocket"))
    }
}
