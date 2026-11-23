//
//  ConnectionEditorEngineSSLTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineSSLTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func sslIssues(for type: DatabaseType, mode: SSLMode, caCertPath: String = "") -> [FieldIssue] {
        let traits = traits(type)
        var draft = ConnectionDraft.new(type: type, traits: traits)
        draft.selectSSLMode(mode)
        draft.ssl.caCertPath = caCertPath
        return ConnectionEditorEngine.issues(draft, traits, EditorContext()).filter { $0.facet == .sslTLS }
    }

    // MARK: - Defaults

    @Test("A new connection starts on its engine's native SSL default, and an unknown engine on Disabled")
    func newConnectionTakesTheNativeDefault() {
        let expected: [(DatabaseType, SSLMode)] = [
            (.postgresql, .preferred),
            (.mssql, .preferred),
            (.redis, .disabled),
            (DatabaseType(rawValue: "FutureDB"), .disabled)
        ]
        for (type, mode) in expected {
            let draft = ConnectionDraft.new(type: type, traits: traits(type))
            #expect(draft.ssl.mode == mode, "\(type.rawValue)")
            #expect(draft.ssl.origin == .typeDefault, "\(type.rawValue)")
        }
    }

    @Test("A mode nobody picked takes the new engine's default on a retype")
    func unchosenModeFollowsTheNewType() {
        let postgres = traits(.postgresql)
        let redis = traits(.redis)
        let fromPostgres = ConnectionDraft.new(type: .postgresql, traits: postgres)
        #expect(fromPostgres.retyped(to: redis, from: postgres).result.ssl.mode == .disabled)

        let fromRedis = ConnectionDraft.new(type: .redis, traits: redis)
        #expect(fromRedis.retyped(to: postgres, from: redis).result.ssl.mode == .preferred)
        #expect(fromRedis.retyped(to: traits(.mssql), from: redis).result.ssl.mode == .preferred)
        let future = traits(DatabaseType(rawValue: "FutureDB"))
        #expect(fromRedis.retyped(to: future, from: redis).result.ssl.mode == .disabled)
    }

    // MARK: - CA certificate

    @Test("Verify Identity without a CA file saves for SAP HANA and Kafka, which trust the system roots")
    func systemTrustStoreEnginesNeedNoCAFile() {
        for type in [DatabaseType.sapHana, .kafka] {
            #expect(type.verifiesServerWithSystemTrust)
            #expect(sslIssues(for: type, mode: .verifyIdentity).isEmpty, "\(type.rawValue)")
        }
    }

    @Test("Verify Identity without a CA file is refused for engines that need one")
    func fileTrustEnginesStillRequireACAFile() {
        #expect(!DatabaseType.mysql.verifiesServerWithSystemTrust)
        let issues = sslIssues(for: .mysql, mode: .verifyIdentity)
        #expect(issues.count == 1)
        #expect(issues.first?.row == .builtIn(.sslCACertificate))
        #expect(sslIssues(for: .mysql, mode: .verifyIdentity, caCertPath: "/tmp/ca.pem").isEmpty)
    }

    @Test(
        "The libpq engines save Verify Identity without a CA file and still need one for Verify CA",
        arguments: [DatabaseType.postgresql, .redshift, .cockroachdb, .kingbasees]
    )
    func libpqEnginesNeedACAFileOnlyForVerifyCA(type: DatabaseType) {
        #expect(type.verifiesServerWithSystemTrust)
        #expect(sslIssues(for: type, mode: .verifyIdentity).isEmpty)
        #expect(sslIssues(for: type, mode: .verifyCa).count == 1)
        #expect(sslIssues(for: type, mode: .verifyCa, caCertPath: "/tmp/ca.pem").isEmpty)
    }

    // MARK: - Port

    @Test("A Trino port of 443 escalates the type default to Verify Identity, and another port reverts it")
    func portFollowsTheTLSPort() {
        let trino = traits(.trino)
        var draft = ConnectionDraft.new(type: .trino, traits: trino)

        draft.setPort("443", traits: trino)
        #expect(draft.ssl.mode == .verifyIdentity)
        #expect(draft.ssl.origin == .impliedByPort)

        draft.setPort("4430", traits: trino)
        #expect(draft.ssl.mode == .disabled)
        #expect(draft.ssl.origin == .typeDefault)
    }

    @Test("A selected mode is never changed by the port")
    func selectedModeIgnoresThePort() {
        let trino = traits(.trino)
        var draft = ConnectionDraft.new(type: .trino, traits: trino)
        draft.selectSSLMode(.disabled)

        draft.setPort("443", traits: trino)
        #expect(draft.ssl.mode == .disabled)
        #expect(draft.ssl.origin == .chosen)
    }

    @Test("A stored Disabled on port 443 is still the type default, so editing the port escalates it")
    func loadedDefaultModeCanStillEscalate() {
        let trino = traits(.trino)
        let connection = DatabaseConnection(
            name: "Trino", port: 443, type: .trino, sslConfig: SSLConfiguration(mode: .disabled)
        )
        var draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: trino)
        #expect(draft.ssl.origin == .typeDefault)

        draft.setPort("443", traits: trino)
        #expect(draft.ssl.mode == .verifyIdentity)
    }

    @Test("A stored Verify Identity is a choice, so moving off port 443 keeps it")
    func loadedNonDefaultModeIsAChoice() {
        let trino = traits(.trino)
        let connection = DatabaseConnection(
            name: "Trino", port: 443, type: .trino, sslConfig: SSLConfiguration(mode: .verifyIdentity)
        )
        var draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: trino)
        #expect(draft.ssl.origin == .chosen)

        draft.setPort("8080", traits: trino)
        #expect(draft.ssl.mode == .verifyIdentity)
    }

    @Test("A type with no TLS ports ignores the port")
    func typeWithoutTLSPortsIgnoresThePort() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)

        draft.setPort("443", traits: postgres)
        #expect(draft.ssl.mode == .preferred)
        #expect(draft.ssl.origin == .typeDefault)
    }

    // MARK: - Import

    @Test("An imported explicit mode is a choice, and an import with no mode follows the port")
    func importedModes() {
        let trino = traits(.trino)
        var draft = ConnectionDraft.new(type: .trino, traits: trino)

        draft.applyImportedSSL(SSLModeResolution(mode: .required, origin: .chosen))
        #expect(draft.ssl.mode == .required)
        #expect(draft.ssl.origin == .chosen)

        draft.applyImportedSSL(DatabaseType.trino.sslModeResolution(forPort: 443))
        #expect(draft.ssl.mode == .verifyIdentity)
        #expect(draft.ssl.origin == .impliedByPort)

        draft.setPort("8080", traits: trino)
        #expect(draft.ssl.mode == .disabled)
        #expect(draft.ssl.origin == .typeDefault)
    }

    @Test("An imported ssl=false turns SSL off even where the driver defaults to Preferred")
    func importedSSLFalseIsDisabled() throws {
        let parsed = try ConnectionURLParser.parse("mysql://root@db.example.com/shop?ssl=false").get()
        var draft = ConnectionDraft.new(type: .mysql, traits: traits(.mysql))
        draft.applyImportedSSL(parsed.sslModeResolution)
        #expect(draft.ssl.mode == .disabled)
        #expect(draft.ssl.origin == .chosen)
    }
}
