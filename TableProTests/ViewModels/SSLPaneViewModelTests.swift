//
//  SSLPaneViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SSLPaneViewModel")
@MainActor
struct SSLPaneViewModelTests {
    @Test("resetForType applies engine's native default for PostgreSQL")
    func testResetForPostgreSQL() {
        let viewModel = SSLPaneViewModel()
        viewModel.mode = .disabled
        viewModel.resetForType(.postgresql)
        #expect(viewModel.mode == .preferred)
    }

    @Test("resetForType applies engine's native default for SQL Server")
    func testResetForMSSQL() {
        let viewModel = SSLPaneViewModel()
        viewModel.mode = .disabled
        viewModel.resetForType(.mssql)
        #expect(viewModel.mode == .preferred)
    }

    @Test("resetForType keeps disabled for binary-TLS engines")
    func testResetForRedis() {
        let viewModel = SSLPaneViewModel()
        viewModel.mode = .required
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
        viewModel.mode = .required
        viewModel.resetForType(DatabaseType(rawValue: "FutureDB"))
        #expect(viewModel.mode == .disabled)
    }
}
