//
//  ConnectionEditorStoreURLImportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreURLImportTests {
    private func importing(_ url: String, into fixture: ConnectionEditorStoreFixture) throws -> ConnectionEditorStore {
        fixture.makeStore(.new(type: nil, parsedURL: try ConnectionURLParser.parse(url).get()))
    }

    private func recordEdits(_ store: ConnectionEditorStore) -> ConnectionFormEdits {
        ConnectionEditorEngine.edits(store.draft, store.traits, originalTraits: store.originalTraits, store.context)
    }

    @Test("Secrets a MongoDB connection string carries reach Keychain-backed fields, never plain options")
    func mongoURISecretsStayOutOfPlainOptions() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try importing(
            "mongodb://app:s3cret@db.example.com:27017/orders?tls=true"
                + "&tlsCertificateKeyFile=%2FUsers%2Falice%2Fclient.pem&tlsCertificateKeyFilePassword=hunter2"
                + "&authMechanism=MONGODB-AWS&authMechanismProperties=AWS_SESSION_TOKEN%3AFQoGZXIvYXdz"
                + "&proxyPassword=proxy-secret&retryWrites=true",
            into: fixture
        )
        let token = "mongoAWSSessionToken"
        let formValues = store.draft.fieldValues.filter { $0.key != token }
        let recordValues = recordEdits(store).additionalFields

        #expect(store.draft.ssl.clientCertPath == "/Users/alice/client.pem")
        #expect(store.draft.ssl.clientKeyPassphrase == "hunter2")
        #expect(store.draft.ssl.clientKeyPath == "/Users/alice/client.pem")
        #expect(store.draft.fieldValues[token] == "FQoGZXIvYXdz")
        #expect(ConnectionEditorEngine.secureFieldsOwnedByForm(store.traits, originalTraits: store.originalTraits)
            .contains { $0.id == token })
        let plan = ConnectionEditorEngine.secretPlan(store.draft, store.traits, originalTraits: store.originalTraits, store.context)
        #expect(plan.writes(of: .pluginField(token)) == "FQoGZXIvYXdz")
        #expect(plan.writes(of: .sslClientKeyPassphrase) == "hunter2")
        #expect(recordValues[token] == nil)
        for plain in [formValues, recordValues] {
            #expect(!plain.values.contains("hunter2"))
            #expect(!plain.values.contains { $0.contains("FQoGZXIvYXdz") })
            #expect(!plain.values.contains("proxy-secret"))
            #expect(plain["mongoParam_retryWrites"] == "true")
        }
    }

    @Test("sslmode=verify-full opens the form on Verify Identity")
    func verifyFullKeepsIdentityVerification() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try importing("postgresql://u@db.example.com/app?sslmode=verify-full", into: fixture)
        #expect(store.draft.ssl.mode == .verifyIdentity)
    }

    @Test("sslmode=verify-ca opens the form on Verify CA")
    func verifyCaKeepsCertificateVerification() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try importing("postgresql://u@db.example.com/app?sslmode=verify-ca", into: fixture)
        #expect(store.draft.ssl.mode == .verifyCa)
    }

    @Test(
        "ssl=1 and ssl=require turn TLS on as ssl=true does",
        arguments: [
            "postgresql://u@db.example.com/app",
            "mysql://root@db.example.com/app",
            "redis://cache.example.com"
        ],
        ["1", "require"]
    )
    func sslFlagSpellingsTurnTLSOn(_ base: String, _ value: String) throws {
        let fixture = try ConnectionEditorStoreFixture()
        let spelled = try importing("\(base)?ssl=\(value)", into: fixture)
        let canonical = try importing("\(base)?ssl=true", into: fixture)
        #expect(spelled.draft.ssl.mode == canonical.draft.ssl.mode)
        #expect(spelled.draft.ssl.mode == .required)
    }

    @Test("A bracketed IPv6 host reaches the form bare, as a driver dials it")
    func ipv6HostReachesTheFormBare() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try importing("postgres://alice@[2001:db8::5]:6000/sales", into: fixture)
        #expect(store.draft.host == "2001:db8::5")
        #expect(store.draft.portText == "6000")
    }

    @Test("A libSQL URL with an IPv6 host rebuilds a database URL that keeps its brackets")
    func libSQLIPv6KeepsBrackets() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try importing("libsql://[::1]:8443", into: fixture)
        #expect(store.draft.fieldValues["databaseUrl"] == "https://[::1]:8443")
    }

    @Test("Host, credentials and database from the URL reach the form")
    func connectionFieldsReachTheForm() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try importing("postgres://alice:p%40ss@db.example.com:6000/sales", into: fixture)
        #expect(store.draft.type == .postgresql)
        #expect(store.traits.type == .postgresql)
        #expect(store.draft.host == "db.example.com")
        #expect(store.draft.portText == "6000")
        #expect(store.draft.database == "sales")
        #expect(store.draft.credentials.username == "alice")
        #expect(store.draft.credentials.password == "p@ss")
    }

    @Test(
        "A socket URL opens the form on Socket with its path",
        arguments: [
            "mysql://root@localhost/local?socket=%2Ftmp%2Fmysql.sock",
            "mariadb://root@/local?unix_socket=/tmp/mysql.sock"
        ]
    )
    func socketURLSelectsSocket(_ url: String) throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try importing(url, into: fixture)
        #expect(store.draft.endpoint == .localSocket)
        #expect(store.draft.localSocketPath == "/tmp/mysql.sock")
        #expect(store.draft.transport == nil)
        #expect(store.draft.fieldValues[MySQLLocalSocket.fieldKey] == nil)

        let edits = recordEdits(store)
        #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
        #expect(edits.applied(to: DatabaseConnection(name: "")).localSocketPath == "/tmp/mysql.sock")
    }
}
