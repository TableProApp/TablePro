//
//  ConnectionSharingTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Connection Sharing")
@MainActor
struct ConnectionSharingTests {

    // MARK: - buildImportDeeplink

    @Suite("Build Import Deeplink")
    struct BuildDeeplinkTests {

        @Test("Emits required fields")
        @MainActor
        func testRequiredFields() {
            let conn = DatabaseConnection(
                name: "Dev", host: "localhost", port: 3306,
                database: "mydb", username: "root", type: .mysql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(link.contains("name=Dev"))
            #expect(link.contains("host=localhost"))
            #expect(link.contains("port=3306"))
            #expect(link.contains("type=MySQL"))
            #expect(link.contains("username=root"))
            #expect(link.contains("database=mydb"))
        }

        @Test("Omits empty username and database")
        @MainActor
        func testOmitsEmptyFields() {
            let conn = DatabaseConnection(
                name: "Minimal", host: "db.com", port: 5432,
                database: "", username: "", type: .postgresql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(!link.contains("username="))
            #expect(!link.contains("database="))
        }

        @Test("Includes SSH config when enabled")
        @MainActor
        func testIncludesSSH() {
            var ssh = SSHConfiguration()
            ssh.enabled = true
            ssh.host = "bastion.com"
            ssh.port = 2222
            ssh.username = "deploy"
            ssh.authMethod = .privateKey
            ssh.privateKeyPath = "~/.ssh/id_ed25519"
            let conn = DatabaseConnection(
                name: "SSH", host: "db.internal", port: 5432,
                database: "main", username: "app", type: .postgresql,
                sshConfig: ssh
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(link.contains("ssh=1"))
            #expect(link.contains("sshHost=bastion.com"))
            #expect(link.contains("sshPort=2222"))
            #expect(link.contains("sshUsername=deploy"))
            #expect(link.contains("sshAuthMethod=privateKey"))
        }

        @Test("Omits SSH when disabled")
        @MainActor
        func testOmitsSSHWhenDisabled() {
            let conn = DatabaseConnection(
                name: "NoSSH", host: "localhost", port: 3306,
                database: "", username: "", type: .mysql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(!link.contains("ssh="))
            #expect(!link.contains("sshHost="))
        }

        @Test("Omits default SSH port 22")
        @MainActor
        func testOmitsDefaultSSHPort() {
            var ssh = SSHConfiguration()
            ssh.enabled = true
            ssh.host = "bastion.com"
            ssh.port = 22
            let conn = DatabaseConnection(
                name: "SSH", host: "db.com", port: 5432,
                database: "", username: "", type: .postgresql,
                sshConfig: ssh
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(!link.contains("sshPort="))
        }

        @Test("Includes SSL config")
        @MainActor
        func testIncludesSSL() {
            let ssl = SSLConfiguration(
                mode: .required,
                caCertificatePath: "~/certs/ca.pem",
                clientCertificatePath: "",
                clientKeyPath: ""
            )
            let conn = DatabaseConnection(
                name: "SSL", host: "db.com", port: 5432,
                database: "", username: "", type: .postgresql,
                sslConfig: ssl
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(link.contains("sslMode=required"))
            #expect(link.contains("sslCaCertPath="))
        }

        @Test("Omits SSL when disabled")
        @MainActor
        func testOmitsSSLWhenDisabled() {
            let conn = DatabaseConnection(
                name: "NoSSL", host: "localhost", port: 3306,
                database: "", username: "", type: .mysql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(!link.contains("sslMode="))
        }

        @Test("Includes metadata fields")
        @MainActor
        func testIncludesMetadata() {
            let conn = DatabaseConnection(
                name: "Prod", host: "db.com", port: 5432,
                database: "", username: "", type: .postgresql,
                color: .red,
                safeModeLevel: .readOnly,
                aiPolicy: .never
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(link.contains("color=red"))
            #expect(link.contains("safeModeLevel=readOnly"))
            #expect(link.contains("aiPolicy=never"))
        }

        @Test("Omits default metadata values")
        @MainActor
        func testOmitsDefaultMetadata() {
            let conn = DatabaseConnection(
                name: "Default", host: "localhost", port: 3306,
                database: "", username: "", type: .mysql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(!link.contains("color="))
            #expect(!link.contains("safeModeLevel="))
            #expect(!link.contains("aiPolicy="))
        }

        @Test("Includes additional fields with af_ prefix")
        @MainActor
        func testIncludesAdditionalFields() {
            let conn = DatabaseConnection(
                name: "Redis", host: "localhost", port: 6379,
                database: "", username: "", type: .redis,
                redisDatabase: 3,
                additionalFields: ["customField": "customValue"]
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(link.contains("redisDatabase=3"))
            #expect(link.contains("af_customField=customValue"))
        }

        @Test("Includes startup commands")
        @MainActor
        func testIncludesStartupCommands() {
            let conn = DatabaseConnection(
                name: "Dev", host: "localhost", port: 5432,
                database: "", username: "", type: .postgresql,
                startupCommands: "SET search_path TO myschema;"
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(link.contains("startupCommands="))
        }

        @Test("Includes localOnly flag")
        @MainActor
        func testIncludesLocalOnly() {
            let conn = DatabaseConnection(
                name: "Local", host: "localhost", port: 5432,
                database: "", username: "", type: .postgresql,
                localOnly: true
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            #expect(link.contains("localOnly=1"))
        }

        @Test("Percent-encodes special characters")
        @MainActor
        func testPercentEncodesSpecialChars() {
            let conn = DatabaseConnection(
                name: "Dev & Staging", host: "db.example.com", port: 5432,
                database: "my db", username: "user@domain", type: .postgresql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            let url = URL(string: link)
            #expect(url != nil)
            let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
            let nameValue = components?.queryItems?.first(where: { $0.name == "name" })?.value
            #expect(nameValue == "Dev & Staging")
        }

        @Test("Produces valid URL")
        @MainActor
        func testProducesValidURL() {
            var ssh = SSHConfiguration()
            ssh.enabled = true
            ssh.host = "bastion.com"
            ssh.port = 2222
            let conn = DatabaseConnection(
                name: "Complex Connection", host: "db.prod.internal", port: 5433,
                database: "main", username: "app_user", type: .postgresql,
                sshConfig: ssh,
                sslConfig: SSLConfiguration(mode: .required),
                color: .red,
                safeModeLevel: .readOnly,
                startupCommands: "SET timeout=30;"
            )
            let link = ConnectionExportService.buildImportDeeplink(for: conn)!
            let url = URL(string: link)
            #expect(url != nil)
            #expect(url?.scheme == "tablepro")
            #expect(url?.host() == "import")
        }
    }

    // MARK: - buildCompactJSON

    @Suite("Build Compact JSON")
    struct BuildCompactJSONTests {

        @Test("Returns valid JSON")
        @MainActor
        func testReturnsValidJSON() {
            let conn = DatabaseConnection(
                name: "Dev", host: "localhost", port: 3306,
                database: "mydb", username: "root", type: .mysql
            )
            let json = ConnectionExportService.buildCompactJSON(for: conn)
            let data = json.data(using: .utf8)!
            let decoded = try? JSONDecoder().decode(ExportableConnection.self, from: data)
            #expect(decoded != nil)
            #expect(decoded?.name == "Dev")
            #expect(decoded?.host == "localhost")
            #expect(decoded?.type == "MySQL")
        }

        @Test("Excludes SSH profile ID")
        @MainActor
        func testExcludesSSHProfileId() {
            let conn = DatabaseConnection(
                name: "Dev", host: "localhost", port: 3306,
                database: "", username: "", type: .mysql
            )
            let json = ConnectionExportService.buildCompactJSON(for: conn)
            let data = json.data(using: .utf8)!
            let decoded = try! JSONDecoder().decode(ExportableConnection.self, from: data)
            #expect(decoded.sshProfileId == nil)
        }

        @Test("Is compact (not pretty printed)")
        @MainActor
        func testIsCompact() {
            let conn = DatabaseConnection(
                name: "Dev", host: "localhost", port: 3306,
                database: "", username: "", type: .mysql
            )
            let json = ConnectionExportService.buildCompactJSON(for: conn)
            #expect(!json.contains("\n  "))
        }

        @Test("Includes SSH config when enabled")
        @MainActor
        func testIncludesSSHInJSON() {
            var ssh = SSHConfiguration()
            ssh.enabled = true
            ssh.host = "bastion.com"
            ssh.port = 22
            ssh.username = "admin"
            let conn = DatabaseConnection(
                name: "SSH", host: "db.com", port: 5432,
                database: "", username: "", type: .postgresql,
                sshConfig: ssh
            )
            let json = ConnectionExportService.buildCompactJSON(for: conn)
            let data = json.data(using: .utf8)!
            let decoded = try! JSONDecoder().decode(ExportableConnection.self, from: data)
            #expect(decoded.sshConfig != nil)
            #expect(decoded.sshConfig?.host == "bastion.com")
        }
    }

    // MARK: - Round-Trip

    @Suite("Round-Trip: buildImportDeeplink → parseImport")
    struct RoundTripTests {

        @Test("Basic connection survives round-trip")
        @MainActor
        func testBasicRoundTrip() {
            let original = DatabaseConnection(
                name: "Dev MySQL", host: "db.example.com", port: 3307,
                database: "app_db", username: "dev_user", type: .mysql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }
            #expect(parsed.name == original.name)
            #expect(parsed.host == original.host)
            #expect(parsed.port == original.port)
            #expect(parsed.database == original.database)
            #expect(parsed.username == original.username)
            #expect(parsed.type == original.type.rawValue)
        }

        @Test("SSH config survives round-trip")
        @MainActor
        func testSSHRoundTrip() {
            var ssh = SSHConfiguration()
            ssh.enabled = true
            ssh.host = "bastion.prod.com"
            ssh.port = 2222
            ssh.username = "deploy"
            ssh.authMethod = .privateKey
            ssh.privateKeyPath = "~/.ssh/prod_key"
            ssh.useSSHConfig = true
            ssh.agentSocketPath = "/tmp/agent.sock"
            let original = DatabaseConnection(
                name: "SSH Prod", host: "db.internal", port: 5432,
                database: "main", username: "app", type: .postgresql,
                sshConfig: ssh
            )
            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }
            #expect(parsed.sshConfig != nil)
            #expect(parsed.sshConfig?.enabled == true)
            #expect(parsed.sshConfig?.host == "bastion.prod.com")
            #expect(parsed.sshConfig?.port == 2222)
            #expect(parsed.sshConfig?.username == "deploy")
            #expect(parsed.sshConfig?.authMethod == "privateKey")
            #expect(parsed.sshConfig?.privateKeyPath == "~/.ssh/prod_key")
            #expect(parsed.sshConfig?.useSSHConfig == true)
            #expect(parsed.sshConfig?.agentSocketPath == "/tmp/agent.sock")
        }

        @Test("SSL config survives round-trip")
        @MainActor
        func testSSLRoundTrip() {
            let ssl = SSLConfiguration(
                mode: .verifyCa,
                caCertificatePath: "~/certs/ca.pem",
                clientCertificatePath: "~/certs/client.pem",
                clientKeyPath: "~/certs/client.key"
            )
            let original = DatabaseConnection(
                name: "SSL DB", host: "db.com", port: 5432,
                database: "secure", username: "admin", type: .postgresql,
                sslConfig: ssl
            )
            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }
            #expect(parsed.sslConfig != nil)
            #expect(parsed.sslConfig?.mode == "verifyCa")
            #expect(parsed.sslConfig?.caCertificatePath == "~/certs/ca.pem")
            #expect(parsed.sslConfig?.clientCertificatePath == "~/certs/client.pem")
            #expect(parsed.sslConfig?.clientKeyPath == "~/certs/client.key")
        }

        @Test("Metadata survives round-trip")
        @MainActor
        func testMetadataRoundTrip() {
            let original = DatabaseConnection(
                name: "Prod", host: "db.prod.com", port: 5432,
                database: "main", username: "app", type: .postgresql,
                color: .red,
                safeModeLevel: .readOnly,
                aiPolicy: .never,
                startupCommands: "SET statement_timeout = 30000;",
                localOnly: true
            )
            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }
            #expect(parsed.color == "red")
            #expect(parsed.safeModeLevel == "readOnly")
            #expect(parsed.aiPolicy == "never")
            #expect(parsed.startupCommands == "SET statement_timeout = 30000;")
            #expect(parsed.localOnly == true)
        }

        @Test("Redis database survives round-trip")
        @MainActor
        func testRedisRoundTrip() {
            let original = DatabaseConnection(
                name: "Cache", host: "redis.local", port: 6379,
                database: "", username: "", type: .redis,
                redisDatabase: 5
            )
            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }
            #expect(parsed.redisDatabase == 5)
        }

        @Test("Special characters in name survive round-trip")
        @MainActor
        func testSpecialCharsRoundTrip() {
            let original = DatabaseConnection(
                name: "Dev & Staging (v2)", host: "db.example.com", port: 5432,
                database: "my database", username: "user@company.com", type: .postgresql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }
            #expect(parsed.name == "Dev & Staging (v2)")
            #expect(parsed.database == "my database")
            #expect(parsed.username == "user@company.com")
        }

        @Test("Minimal connection round-trip produces correct defaults")
        @MainActor
        func testMinimalRoundTrip() {
            let original = DatabaseConnection(
                name: "Bare", host: "localhost", port: 5432,
                database: "", username: "", type: .postgresql
            )
            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }
            #expect(parsed.sshConfig == nil)
            #expect(parsed.sslConfig == nil)
            #expect(parsed.color == nil)
            #expect(parsed.tagName == nil)
            #expect(parsed.groupName == nil)
            #expect(parsed.safeModeLevel == nil)
            #expect(parsed.aiPolicy == nil)
            #expect(parsed.additionalFields == nil)
            #expect(parsed.redisDatabase == nil)
            #expect(parsed.startupCommands == nil)
            #expect(parsed.localOnly == nil)
        }

        @Test("Full config round-trip")
        @MainActor
        func testFullConfigRoundTrip() {
            var ssh = SSHConfiguration()
            ssh.enabled = true
            ssh.host = "bastion.prod.com"
            ssh.port = 2222
            ssh.username = "deploy"
            ssh.authMethod = .privateKey
            ssh.privateKeyPath = "~/.ssh/prod_key"
            ssh.jumpHosts = [
                SSHJumpHost(
                    host: "jump1.com", port: 22, username: "admin",
                    authMethod: .password, privateKeyPath: ""
                )
            ]

            let ssl = SSLConfiguration(
                mode: .verifyCa,
                caCertificatePath: "~/certs/ca.pem",
                clientCertificatePath: "",
                clientKeyPath: ""
            )

            let original = DatabaseConnection(
                name: "Full Config", host: "db.prod.internal", port: 5433,
                database: "main", username: "app_user", type: .postgresql,
                sshConfig: ssh,
                sslConfig: ssl,
                color: .red,
                safeModeLevel: .readOnly,
                aiPolicy: .never,
                redisDatabase: nil,
                startupCommands: "SET statement_timeout = 30000;",
                localOnly: true,
                additionalFields: ["schema": "public"]
            )

            let link = ConnectionExportService.buildImportDeeplink(for: original)
            let url = URL(string: link)!
            guard case .importConnection(let parsed) = DeeplinkHandler.parse(url) else {
                Issue.record("Failed to parse round-trip link")
                return
            }

            #expect(parsed.name == "Full Config")
            #expect(parsed.host == "db.prod.internal")
            #expect(parsed.port == 5433)
            #expect(parsed.type == "PostgreSQL")
            #expect(parsed.username == "app_user")
            #expect(parsed.database == "main")

            #expect(parsed.sshConfig?.host == "bastion.prod.com")
            #expect(parsed.sshConfig?.port == 2222)
            #expect(parsed.sshConfig?.username == "deploy")
            #expect(parsed.sshConfig?.authMethod == "privateKey")
            #expect(parsed.sshConfig?.jumpHosts?.count == 1)
            #expect(parsed.sshConfig?.jumpHosts?.first?.host == "jump1.com")

            #expect(parsed.sslConfig?.mode == "verifyCa")
            #expect(parsed.sslConfig?.caCertificatePath == "~/certs/ca.pem")

            #expect(parsed.color == "red")
            #expect(parsed.safeModeLevel == "readOnly")
            #expect(parsed.aiPolicy == "never")
            #expect(parsed.startupCommands == "SET statement_timeout = 30000;")
            #expect(parsed.localOnly == true)
            #expect(parsed.additionalFields?["schema"] == "public")
        }
    }
}
