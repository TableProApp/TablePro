//
//  DeeplinkHandlerTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Deeplink Handler")
@MainActor
struct DeeplinkHandlerTests {

    // MARK: - Connect Actions

    @Test("Connect action with simple name")
    func testConnectSimpleName() {
        let url = URL(string: "tablepro://connect/Production")!
        let action = DeeplinkHandler.parse(url)
        if case .connect(let name) = action {
            #expect(name == "Production")
        } else {
            Issue.record("Expected .connect, got \(String(describing: action))")
        }
    }

    @Test("Connect action with percent-encoded name")
    func testConnectPercentEncodedName() {
        let url = URL(string: "tablepro://connect/My%20DB")!
        let action = DeeplinkHandler.parse(url)
        if case .connect(let name) = action {
            #expect(name == "My DB")
        } else {
            Issue.record("Expected .connect, got \(String(describing: action))")
        }
    }

    @Test("Open table without database")
    func testOpenTableWithoutDatabase() {
        let url = URL(string: "tablepro://connect/Prod/table/users")!
        let action = DeeplinkHandler.parse(url)
        if case .openTable(let connectionName, let tableName, let databaseName) = action {
            #expect(connectionName == "Prod")
            #expect(tableName == "users")
            #expect(databaseName == nil)
        } else {
            Issue.record("Expected .openTable, got \(String(describing: action))")
        }
    }

    @Test("Open table with database")
    func testOpenTableWithDatabase() {
        let url = URL(string: "tablepro://connect/Prod/database/analytics/table/events")!
        let action = DeeplinkHandler.parse(url)
        if case .openTable(let connectionName, let tableName, let databaseName) = action {
            #expect(connectionName == "Prod")
            #expect(tableName == "events")
            #expect(databaseName == "analytics")
        } else {
            Issue.record("Expected .openTable, got \(String(describing: action))")
        }
    }

    @Test("Open query with decoded SQL")
    func testOpenQueryDecodedSQL() {
        let url = URL(string: "tablepro://connect/Prod/query?sql=SELECT%20*%20FROM%20users")!
        let action = DeeplinkHandler.parse(url)
        if case .openQuery(let connectionName, let sql) = action {
            #expect(connectionName == "Prod")
            #expect(sql == "SELECT * FROM users")
        } else {
            Issue.record("Expected .openQuery, got \(String(describing: action))")
        }
    }

    @Test("Open query with empty SQL returns nil")
    func testOpenQueryEmptySQLReturnsNil() {
        let url = URL(string: "tablepro://connect/Prod/query?sql=")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    @Test("Unrecognized path returns nil")
    func testUnrecognizedPathReturnsNil() {
        let url = URL(string: "tablepro://connect/Prod/unknown/path")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    @Test("Unknown host returns nil")
    func testUnknownHostReturnsNil() {
        let url = URL(string: "tablepro://unknown-host")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    @Test("Wrong scheme returns nil")
    func testWrongSchemeReturnsNil() {
        let url = URL(string: "https://example.com")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    // MARK: - Import — Basic Fields

    @Test("Import with all basic params")
    func testImportBasicParams() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&port=3306&username=root&database=mydb")!
        let action = DeeplinkHandler.parse(url)
        guard case .importConnection(let conn) = action else {
            Issue.record("Expected .importConnection, got \(String(describing: action))")
            return
        }
        #expect(conn.name == "Dev")
        #expect(conn.host == "localhost")
        #expect(conn.port == 3306)
        #expect(conn.type == "MySQL")
        #expect(conn.username == "root")
        #expect(conn.database == "mydb")
    }

    @Test("Import with minimal required params")
    func testImportMinimalParams() {
        let url = URL(string: "tablepro://import?name=Test&host=db.example.com&type=postgresql")!
        let action = DeeplinkHandler.parse(url)
        guard case .importConnection(let conn) = action else {
            Issue.record("Expected .importConnection, got \(String(describing: action))")
            return
        }
        #expect(conn.name == "Test")
        #expect(conn.host == "db.example.com")
        #expect(conn.type == "PostgreSQL")
        #expect(conn.username == "")
        #expect(conn.database == "")
        #expect(conn.sshConfig == nil)
        #expect(conn.sslConfig == nil)
        #expect(conn.color == nil)
        #expect(conn.tagName == nil)
        #expect(conn.groupName == nil)
        #expect(conn.additionalFields == nil)
    }

    @Test("Import uses default port when not specified")
    func testImportDefaultPort() {
        let url = URL(string: "tablepro://import?name=PG&host=localhost&type=postgresql")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.port == 5432)
    }

    @Test("Import with case-insensitive type")
    func testImportCaseInsensitiveType() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=PostgreSQL")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.type == "PostgreSQL")
    }

    @Test("Import missing name returns nil")
    func testImportMissingNameReturnsNil() {
        let url = URL(string: "tablepro://import?host=localhost&type=mysql")!
        #expect(DeeplinkHandler.parse(url) == nil)
    }

    @Test("Import missing host returns nil")
    func testImportMissingHostReturnsNil() {
        let url = URL(string: "tablepro://import?name=Dev&type=mysql")!
        #expect(DeeplinkHandler.parse(url) == nil)
    }

    @Test("Import missing type returns nil")
    func testImportMissingTypeReturnsNil() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost")!
        #expect(DeeplinkHandler.parse(url) == nil)
    }

    @Test("Import with empty name returns nil")
    func testImportEmptyNameReturnsNil() {
        let url = URL(string: "tablepro://import?name=&host=localhost&type=mysql")!
        #expect(DeeplinkHandler.parse(url) == nil)
    }

    @Test("Import with empty host returns nil")
    func testImportEmptyHostReturnsNil() {
        let url = URL(string: "tablepro://import?name=Dev&host=&type=mysql")!
        #expect(DeeplinkHandler.parse(url) == nil)
    }

    // MARK: - Import — SSH Config

    @Test("Import with SSH config")
    func testImportWithSSH() {
        let url = URL(string: "tablepro://import?name=Prod&host=db.internal&type=postgresql&ssh=1&sshHost=bastion.example.com&sshPort=2222&sshUsername=deploy&sshAuthMethod=privateKey&sshPrivateKeyPath=~/.ssh/id_ed25519")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig != nil)
        #expect(conn.sshConfig?.enabled == true)
        #expect(conn.sshConfig?.host == "bastion.example.com")
        #expect(conn.sshConfig?.port == 2222)
        #expect(conn.sshConfig?.username == "deploy")
        #expect(conn.sshConfig?.authMethod == "privateKey")
        #expect(conn.sshConfig?.privateKeyPath == "~/.ssh/id_ed25519")
    }

    @Test("Import without ssh=1 has no SSH config")
    func testImportNoSSHFlag() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&sshHost=bastion.com")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig == nil)
    }

    @Test("Import with SSH defaults")
    func testImportSSHDefaults() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&ssh=1&sshHost=bastion.com")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig?.port == 22)
        #expect(conn.sshConfig?.username == "")
        #expect(conn.sshConfig?.authMethod == "password")
        #expect(conn.sshConfig?.privateKeyPath == "")
        #expect(conn.sshConfig?.useSSHConfig == false)
        #expect(conn.sshConfig?.agentSocketPath == "")
    }

    @Test("Import with SSH agent")
    func testImportSSHAgent() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&ssh=1&sshHost=bastion.com&sshAuthMethod=sshAgent&sshAgentSocketPath=/tmp/agent.sock")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig?.authMethod == "sshAgent")
        #expect(conn.sshConfig?.agentSocketPath == "/tmp/agent.sock")
    }

    @Test("Import with SSH use config flag")
    func testImportSSHUseConfig() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&ssh=1&sshHost=bastion.com&sshUseSSHConfig=1")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig?.useSSHConfig == true)
    }

    @Test("Import with SSH TOTP config")
    func testImportSSHTOTP() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&ssh=1&sshHost=bastion.com&sshTotpMode=autoGenerate&sshTotpAlgorithm=sha256&sshTotpDigits=8&sshTotpPeriod=60")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig?.totpMode == "autoGenerate")
        #expect(conn.sshConfig?.totpAlgorithm == "sha256")
        #expect(conn.sshConfig?.totpDigits == 8)
        #expect(conn.sshConfig?.totpPeriod == 60)
    }

    @Test("Import with SSH jump hosts")
    func testImportSSHJumpHosts() {
        let jumpJson = #"[{"host":"jump1.com","port":22,"username":"admin","authMethod":"password","privateKeyPath":""}]"#
        let encoded = jumpJson.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&ssh=1&sshHost=bastion.com&sshJumpHosts=\(encoded)")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig?.jumpHosts?.count == 1)
        #expect(conn.sshConfig?.jumpHosts?.first?.host == "jump1.com")
        #expect(conn.sshConfig?.jumpHosts?.first?.username == "admin")
    }

    @Test("Import with invalid jump hosts JSON ignores gracefully")
    func testImportInvalidJumpHostsJSON() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&ssh=1&sshHost=bastion.com&sshJumpHosts=not-json")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshConfig?.jumpHosts == nil)
    }

    // MARK: - Import — SSL Config

    @Test("Import with SSL config")
    func testImportWithSSL() {
        let url = URL(string: "tablepro://import?name=Prod&host=db.com&type=postgresql&sslMode=require&sslCaCertPath=~/certs/ca.pem&sslClientCertPath=~/certs/client.pem&sslClientKeyPath=~/certs/client.key")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sslConfig != nil)
        #expect(conn.sslConfig?.mode == "require")
        #expect(conn.sslConfig?.caCertificatePath == "~/certs/ca.pem")
        #expect(conn.sslConfig?.clientCertificatePath == "~/certs/client.pem")
        #expect(conn.sslConfig?.clientKeyPath == "~/certs/client.key")
    }

    @Test("Import without sslMode has no SSL config")
    func testImportNoSSLMode() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&sslCaCertPath=~/ca.pem")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sslConfig == nil)
    }

    @Test("Import with SSL mode only, no cert paths")
    func testImportSSLModeOnly() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&sslMode=preferred")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sslConfig?.mode == "preferred")
        #expect(conn.sslConfig?.caCertificatePath == nil)
    }

    // MARK: - Import — Metadata

    @Test("Import with color")
    func testImportWithColor() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&color=red")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.color == "red")
    }

    @Test("Import with tag and group names")
    func testImportWithTagAndGroup() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&tagName=production&groupName=Backend%20Services")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.tagName == "production")
        #expect(conn.groupName == "Backend Services")
    }

    @Test("Import with safe mode level")
    func testImportWithSafeModeLevel() {
        let url = URL(string: "tablepro://import?name=Prod&host=db.com&type=postgresql&safeModeLevel=readOnly")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.safeModeLevel == "readOnly")
    }

    @Test("Import with AI policy")
    func testImportWithAIPolicy() {
        let url = URL(string: "tablepro://import?name=Prod&host=db.com&type=postgresql&aiPolicy=never")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.aiPolicy == "never")
    }

    // MARK: - Import — Other Fields

    @Test("Import with Redis database")
    func testImportWithRedisDatabase() {
        let url = URL(string: "tablepro://import?name=Cache&host=localhost&type=redis&redisDatabase=3")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.redisDatabase == 3)
    }

    @Test("Import with startup commands")
    func testImportWithStartupCommands() {
        let commands = "SET search_path TO myschema;"
        let encoded = commands.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=postgresql&startupCommands=\(encoded)")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.startupCommands == commands)
    }

    @Test("Import with localOnly flag")
    func testImportWithLocalOnly() {
        let url = URL(string: "tablepro://import?name=Local&host=localhost&type=sqlite&localOnly=1")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.localOnly == true)
    }

    @Test("Import without localOnly defaults to nil")
    func testImportLocalOnlyDefault() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.localOnly == nil)
    }

    // MARK: - Import — Additional Fields (Plugin)

    @Test("Import with additional fields using af_ prefix")
    func testImportAdditionalFields() {
        let url = URL(string: "tablepro://import?name=Mongo&host=cluster.mongodb.net&type=mongodb&af_authSource=admin&af_replicaSet=rs0&af_useSrv=true")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.additionalFields?["authSource"] == "admin")
        #expect(conn.additionalFields?["replicaSet"] == "rs0")
        #expect(conn.additionalFields?["useSrv"] == "true")
    }

    @Test("Import with af_ prefix but no value is ignored")
    func testImportAdditionalFieldsNoValue() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&af_emptyField=")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.additionalFields == nil)
    }

    @Test("Import with af_ prefix but empty key is ignored")
    func testImportAdditionalFieldsEmptyKey() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&af_=someValue")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.additionalFields == nil)
    }

    // MARK: - Import — Combined Full Config

    @Test("Import with all fields combined")
    func testImportFullConfig() {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(name: "name", value: "Production DB"),
            URLQueryItem(name: "host", value: "db.prod.internal"),
            URLQueryItem(name: "port", value: "5433"),
            URLQueryItem(name: "type", value: "postgresql"),
            URLQueryItem(name: "username", value: "app_user"),
            URLQueryItem(name: "database", value: "main"),
            URLQueryItem(name: "ssh", value: "1"),
            URLQueryItem(name: "sshHost", value: "bastion.prod.com"),
            URLQueryItem(name: "sshPort", value: "2222"),
            URLQueryItem(name: "sshUsername", value: "deploy"),
            URLQueryItem(name: "sshAuthMethod", value: "privateKey"),
            URLQueryItem(name: "sshPrivateKeyPath", value: "~/.ssh/prod_key"),
            URLQueryItem(name: "sslMode", value: "verify-ca"),
            URLQueryItem(name: "sslCaCertPath", value: "~/certs/ca.pem"),
            URLQueryItem(name: "color", value: "red"),
            URLQueryItem(name: "tagName", value: "production"),
            URLQueryItem(name: "groupName", value: "Backend"),
            URLQueryItem(name: "safeModeLevel", value: "readOnly"),
            URLQueryItem(name: "aiPolicy", value: "never"),
            URLQueryItem(name: "startupCommands", value: "SET statement_timeout = 30000;"),
            URLQueryItem(name: "af_schema", value: "public"),
        ]
        let url = components.url!

        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }

        #expect(conn.name == "Production DB")
        #expect(conn.host == "db.prod.internal")
        #expect(conn.port == 5433)
        #expect(conn.type == "PostgreSQL")
        #expect(conn.username == "app_user")
        #expect(conn.database == "main")

        #expect(conn.sshConfig?.enabled == true)
        #expect(conn.sshConfig?.host == "bastion.prod.com")
        #expect(conn.sshConfig?.port == 2222)
        #expect(conn.sshConfig?.username == "deploy")
        #expect(conn.sshConfig?.authMethod == "privateKey")
        #expect(conn.sshConfig?.privateKeyPath == "~/.ssh/prod_key")

        #expect(conn.sslConfig?.mode == "verify-ca")
        #expect(conn.sslConfig?.caCertificatePath == "~/certs/ca.pem")

        #expect(conn.color == "red")
        #expect(conn.tagName == "production")
        #expect(conn.groupName == "Backend")
        #expect(conn.safeModeLevel == "readOnly")
        #expect(conn.aiPolicy == "never")
        #expect(conn.startupCommands == "SET statement_timeout = 30000;")
        #expect(conn.additionalFields?["schema"] == "public")
    }

    // MARK: - Import — Security

    @Test("Import link never contains password field")
    func testImportNoPasswordField() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&password=secret123")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.name == "Dev")
    }

    // MARK: - Import — Edge Cases

    @Test("Import with percent-encoded special characters in name")
    func testImportSpecialCharsInName() {
        let url = URL(string: "tablepro://import?name=Dev%20%26%20Staging&host=localhost&type=mysql")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.name == "Dev & Staging")
    }

    @Test("Import with IPv6 host")
    func testImportIPv6Host() {
        let url = URL(string: "tablepro://import?name=IPv6&host=::1&type=postgresql")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.host == "::1")
    }

    @Test("Import with no query params returns nil")
    func testImportNoQueryParams() {
        let url = URL(string: "tablepro://import")!
        #expect(DeeplinkHandler.parse(url) == nil)
    }

    @Test("Import with unknown type returns nil")
    func testImportUnknownType() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=nonexistent_db")!
        #expect(DeeplinkHandler.parse(url) == nil)
    }

    @Test("sshProfileId is always nil in deep links")
    func testImportSSHProfileIdAlwaysNil() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&ssh=1&sshHost=bastion.com")!
        guard case .importConnection(let conn) = DeeplinkHandler.parse(url) else {
            Issue.record("Expected .importConnection")
            return
        }
        #expect(conn.sshProfileId == nil)
    }
}
