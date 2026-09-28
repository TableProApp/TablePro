//
//  SSLPaneViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct SSLPaneViewModelTests {
    @Test("resetForType applies engine's native default for PostgreSQL")
    func testResetForPostgreSQL() {
        let viewModel = SSLPaneViewModel()
        viewModel.select(.disabled)
        viewModel.resetForType(.postgresql)
        #expect(viewModel.mode == .preferred)
    }

    @Test("resetForType applies engine's native default for SQL Server")
    func testResetForMSSQL() {
        let viewModel = SSLPaneViewModel()
        viewModel.select(.disabled)
        viewModel.resetForType(.mssql)
        #expect(viewModel.mode == .preferred)
    }

    @Test("resetForType keeps disabled for binary-TLS engines")
    func testResetForRedis() {
        let viewModel = SSLPaneViewModel()
        viewModel.select(.required)
        viewModel.resetForType(.redis)
        #expect(viewModel.mode == .disabled)
    }

    @Test("resetForType clears certificate paths")
    func testResetClearsPaths() {
        let viewModel = SSLPaneViewModel()
        viewModel.caCertPath = "/tmp/ca.pem"
        viewModel.clientCertPath = "/tmp/client.crt"
        viewModel.clientKeyPath = "/tmp/client.key"
        viewModel.resetForType(.postgresql)
        #expect(viewModel.caCertPath.isEmpty)
        #expect(viewModel.clientCertPath.isEmpty)
        #expect(viewModel.clientKeyPath.isEmpty)
    }

    @Test("resetForType for unknown future engine falls back to disabled")
    func testResetForUnknownType() {
        let viewModel = SSLPaneViewModel()
        viewModel.select(.required)
        viewModel.resetForType(DatabaseType(rawValue: "FutureDB"))
        #expect(viewModel.mode == .disabled)
    }

    @Test("A Trino port of 443 escalates the type default to Verify Identity, and another port reverts it")
    func testReconcileFollowsTheTLSPort() {
        let viewModel = SSLPaneViewModel()
        viewModel.resetForType(.trino)

        viewModel.reconcile(port: 443, type: .trino)
        #expect(viewModel.mode == .verifyIdentity)
        #expect(viewModel.origin == .impliedByPort)

        viewModel.reconcile(port: 4_430, type: .trino)
        #expect(viewModel.mode == .disabled)
        #expect(viewModel.origin == .typeDefault)
    }

    @Test("A selected mode is never changed by the port")
    func testReconcileKeepsASelectedMode() {
        let viewModel = SSLPaneViewModel()
        viewModel.resetForType(.trino)
        viewModel.select(.disabled)

        viewModel.reconcile(port: 443, type: .trino)
        #expect(viewModel.mode == .disabled)
        #expect(viewModel.origin == .chosen)
    }

    @Test("A stored Disabled on port 443 is still the type default, so editing the port escalates it")
    func testLoadedDefaultModeCanStillEscalate() {
        let connection = DatabaseConnection(
            name: "Trino", port: 443, type: .trino, sslConfig: SSLConfiguration(mode: .disabled)
        )
        let viewModel = SSLPaneViewModel()
        viewModel.load(from: connection)
        #expect(viewModel.origin == .typeDefault)

        viewModel.reconcile(port: 443, type: .trino)
        #expect(viewModel.mode == .verifyIdentity)
    }

    @Test("A stored Verify Identity is a choice, so moving off port 443 keeps it")
    func testLoadedNonDefaultModeIsAChoice() {
        let connection = DatabaseConnection(
            name: "Trino", port: 443, type: .trino, sslConfig: SSLConfiguration(mode: .verifyIdentity)
        )
        let viewModel = SSLPaneViewModel()
        viewModel.load(from: connection)
        #expect(viewModel.origin == .chosen)

        viewModel.reconcile(port: 8_080, type: .trino)
        #expect(viewModel.mode == .verifyIdentity)
    }

    @Test("An imported explicit mode is a choice, and an import with no mode follows the port")
    func testApplyImported() {
        let viewModel = SSLPaneViewModel()

        viewModel.applyImported(SSLModeResolution(mode: .required, origin: .chosen))
        #expect(viewModel.mode == .required)
        #expect(viewModel.origin == .chosen)

        viewModel.applyImported(DatabaseType.trino.sslModeResolution(forPort: 443))
        #expect(viewModel.mode == .verifyIdentity)
        #expect(viewModel.origin == .impliedByPort)

        viewModel.reconcile(port: 8_080, type: .trino)
        #expect(viewModel.mode == .disabled)
        #expect(viewModel.origin == .typeDefault)
    }

    @Test("An imported ssl=false turns SSL off even where the driver defaults to Preferred")
    func testImportedSSLFalseIsDisabled() throws {
        guard case .success(let parsed) = ConnectionURLParser.parse("mysql://root@db.example.com/shop?ssl=false") else {
            Issue.record("Expected the URL to parse")
            return
        }
        let viewModel = SSLPaneViewModel()
        viewModel.applyImported(parsed.sslModeResolution)
        #expect(viewModel.mode == .disabled)
        #expect(viewModel.origin == .chosen)
    }

    @Test("A type with no TLS ports ignores the port")
    func testReconcileIgnoresTypesWithoutTLSPorts() {
        let viewModel = SSLPaneViewModel()
        viewModel.resetForType(.postgresql)

        viewModel.reconcile(port: 443, type: .postgresql)
        #expect(viewModel.mode == .preferred)
        #expect(viewModel.origin == .typeDefault)
    }
}
