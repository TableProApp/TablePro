//
//  ConnectionEditorStorePortTLSTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStorePortTLSTests {
    private func newConnection(_ type: DatabaseType, in fixture: ConnectionEditorStoreFixture) -> ConnectionEditorStore {
        fixture.makeStore(.new(type: type, parsedURL: nil))
    }

    private func imported(_ url: String, in fixture: ConnectionEditorStoreFixture) throws -> ConnectionEditorStore {
        fixture.makeStore(.new(type: nil, parsedURL: try ConnectionURLParser.parse(url).get()))
    }

    @Test("Typing port 443 on a new Trino connection turns on Verify Identity, and typing past it turns it off")
    func typedPortFollowsTheTLSPort() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.trino, in: fixture)
        #expect(store.draft.ssl.mode == .disabled)

        store.setPort("443")
        #expect(store.draft.ssl.mode == .verifyIdentity)

        store.setPort("4430")
        #expect(store.draft.ssl.mode == .disabled)
    }

    @Test("A mode the user picked is never changed by the port")
    func chosenModeSurvivesThePort() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.trino, in: fixture)
        store.selectSSLMode(.required)

        store.setPort("443")
        #expect(store.draft.ssl.mode == .required)

        store.selectSSLMode(.disabled)
        store.setPort("4430")
        store.setPort("443")
        #expect(store.draft.ssl.mode == .disabled)
    }

    @Test("The port note names the mode the port implies, and offers it while SSL is Disabled")
    func portNoticeFollowsThePort() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.trino, in: fixture)
        #expect(store.portTLSNotice == nil)

        store.setPort("443")
        let implied = try #require(store.portTLSNotice)
        #expect(implied.impliedMode == .verifyIdentity)
        #expect(!implied.sslModeIsDisabled)
        #expect(implied.actionTitle == nil)
        #expect(store.layout.contains(.builtIn(.portTLSNotice)))

        store.selectSSLMode(.disabled)
        let offered = try #require(store.portTLSNotice)
        #expect(offered.sslModeIsDisabled)
        #expect(offered.actionTitle != nil)

        store.setPort("4430")
        #expect(store.portTLSNotice == nil)
        #expect(!store.layout.contains(.builtIn(.portTLSNotice)))
    }

    @Test("A Trino connection on port 443 with Verify Identity saves without a CA certificate")
    func verifyIdentityNeedsNoCAForTrino() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.trino, in: fixture)
        store.setPort("443")

        #expect(store.draft.ssl.caCertPath.isEmpty)
        #expect(store.issues(for: .sslTLS).isEmpty)
    }

    @Test("Verify CA on Trino still asks for a CA certificate, since it checks no hostname")
    func verifyCANeedsACAForTrino() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.trino, in: fixture)
        store.selectSSLMode(.verifyCa)
        #expect(!store.issues(for: .sslTLS).isEmpty)
    }

    @Test("Importing trino://host:443 opens the form on Verify Identity, and editing the port away reverts it")
    func importedTLSPortIsImplied() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try imported("trino://analyst@trino.example.com:443/hive", in: fixture)
        #expect(store.draft.ssl.mode == .verifyIdentity)

        store.setPort("8080")
        #expect(store.draft.ssl.mode == .disabled)
    }

    @Test("Importing trino://host:443 with SSL=false keeps SSL off through later port edits")
    func importedSSLFalseIsAChoice() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try imported("trino://trino.example.com:443/hive?SSL=false", in: fixture)
        #expect(store.draft.ssl.mode == .disabled)

        store.setPort("4430")
        store.setPort("443")
        #expect(store.draft.ssl.mode == .disabled)
    }

    @Test("An imported JDBC URL with SSLVerification=CA opens on Verify CA, asks for the CA file, and keeps it through port edits")
    func importedVerificationIsAChoice() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try imported(
            "jdbc:trino://analyst@trino.example.com:8443/hive?SSL=true&SSLVerification=CA",
            in: fixture
        )
        #expect(store.draft.ssl.mode == .verifyCa)
        #expect(!store.issues(for: .sslTLS).isEmpty)

        store.setPort("443")
        store.setPort("8080")
        #expect(store.draft.ssl.mode == .verifyCa)
    }

    @Test("Typing port 8443 on a new ClickHouse connection turns on Verify Identity")
    func clickHouseTLSPort() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.clickhouse, in: fixture)
        store.setPort("8443")
        #expect(store.draft.ssl.mode == .verifyIdentity)

        store.setPort("8123")
        #expect(store.draft.ssl.mode == .disabled)
    }

    @Test("SQL Server verify modes save, since the form has no CA field for them")
    func mssqlVerifyModesSave() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.mssql, in: fixture)
        store.selectSSLMode(.verifyIdentity)
        #expect(store.issues(for: .sslTLS).isEmpty)
        #expect(!store.layout.contains(.builtIn(.sslCACertificate)))

        store.selectSSLMode(.verifyCa)
        #expect(store.issues(for: .sslTLS).isEmpty)
    }

    @Test("PostgreSQL Verify Identity saves without a CA certificate, and Verify CA still asks for one")
    func postgresNeedsACAOnlyForVerifyCA() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = newConnection(.postgresql, in: fixture)
        store.selectSSLMode(.verifyIdentity)
        #expect(store.issues(for: .sslTLS).isEmpty)

        store.selectSSLMode(.verifyCa)
        #expect(!store.issues(for: .sslTLS).isEmpty)
    }
}
