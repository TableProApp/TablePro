//
//  ConnectionFormPortTLSTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionFormPortTLSTests {
    private func newConnection(_ type: DatabaseType) -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil, initialType: type)
        coordinator.start()
        return coordinator
    }

    private func imported(_ url: String) throws -> ConnectionFormCoordinator {
        guard case .success(let parsed) = ConnectionURLParser.parse(url) else {
            throw ConnectionURLParseError.invalidURL
        }
        let coordinator = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: parsed)
        coordinator.start()
        return coordinator
    }

    @Test("Typing port 443 on a new Trino connection turns on Verify Identity, and typing past it turns it off")
    func typedPortFollowsTheTLSPort() {
        let coordinator = newConnection(.trino)
        #expect(coordinator.ssl.mode == .disabled)

        coordinator.network.setPort("443")
        #expect(coordinator.ssl.mode == .verifyIdentity)

        coordinator.network.setPort("4430")
        #expect(coordinator.ssl.mode == .disabled)
    }

    @Test("A mode the user picked is never changed by the port")
    func chosenModeSurvivesThePort() {
        let coordinator = newConnection(.trino)
        coordinator.ssl.select(.required)

        coordinator.network.setPort("443")
        #expect(coordinator.ssl.mode == .required)

        coordinator.ssl.select(.disabled)
        coordinator.network.setPort("4430")
        coordinator.network.setPort("443")
        #expect(coordinator.ssl.mode == .disabled)
    }

    @Test("A Trino connection on port 443 with Verify Identity saves without a CA certificate")
    func verifyIdentityNeedsNoCAForTrino() {
        let coordinator = newConnection(.trino)
        coordinator.network.setPort("443")

        #expect(coordinator.ssl.caCertPath.isEmpty)
        #expect(coordinator.ssl.validationIssues.isEmpty)
    }

    @Test("Verify CA on Trino still asks for a CA certificate, since it checks no hostname")
    func verifyCANeedsACAForTrino() {
        let coordinator = newConnection(.trino)
        coordinator.ssl.select(.verifyCa)
        #expect(!coordinator.ssl.validationIssues.isEmpty)
    }

    @Test("Importing trino://host:443 opens the form on Verify Identity, and editing the port away reverts it")
    func importedTLSPortIsImplied() throws {
        let coordinator = try imported("trino://analyst@trino.example.com:443/hive")
        #expect(coordinator.ssl.mode == .verifyIdentity)

        coordinator.network.setPort("8080")
        #expect(coordinator.ssl.mode == .disabled)
    }

    @Test("Importing trino://host:443 with SSL=false keeps SSL off through later port edits")
    func importedSSLFalseIsAChoice() throws {
        let coordinator = try imported("trino://trino.example.com:443/hive?SSL=false")
        #expect(coordinator.ssl.mode == .disabled)

        coordinator.network.setPort("4430")
        coordinator.network.setPort("443")
        #expect(coordinator.ssl.mode == .disabled)
    }

    @Test("An imported JDBC URL with SSLVerification=CA opens on Verify CA, asks for the CA file, and keeps it through port edits")
    func importedVerificationIsAChoice() throws {
        let coordinator = try imported("jdbc:trino://analyst@trino.example.com:8443/hive?SSL=true&SSLVerification=CA")
        #expect(coordinator.ssl.mode == .verifyCa)
        #expect(!coordinator.ssl.validationIssues.isEmpty)

        coordinator.network.setPort("443")
        coordinator.network.setPort("8080")
        #expect(coordinator.ssl.mode == .verifyCa)
    }

    @Test("Typing port 8443 on a new ClickHouse connection turns on Verify Identity")
    func clickHouseTLSPort() {
        let coordinator = newConnection(.clickhouse)
        coordinator.network.setPort("8443")
        #expect(coordinator.ssl.mode == .verifyIdentity)

        coordinator.network.setPort("8123")
        #expect(coordinator.ssl.mode == .disabled)
    }

    @Test("SQL Server verify modes save, since the form has no CA field for them")
    func mssqlVerifyModesSave() {
        let coordinator = newConnection(.mssql)
        coordinator.ssl.select(.verifyIdentity)
        #expect(coordinator.ssl.validationIssues.isEmpty)

        coordinator.ssl.select(.verifyCa)
        #expect(coordinator.ssl.validationIssues.isEmpty)
    }

    @Test("PostgreSQL Verify Identity still asks for a CA certificate")
    func postgresStillRequiresCA() {
        let coordinator = newConnection(.postgresql)
        coordinator.ssl.select(.verifyIdentity)
        #expect(!coordinator.ssl.validationIssues.isEmpty)
    }
}
