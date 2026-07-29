//
//  SOCKSProxyPaneViewModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("SOCKS proxy pane view model")
struct SOCKSProxyPaneViewModelTests {
    @Test("disabled reports no issues")
    func disabledNoIssues() {
        let viewModel = SOCKSProxyPaneViewModel()
        viewModel.state.enabled = false
        #expect(viewModel.validationIssues.isEmpty)
    }

    @Test("enabled requires a host")
    func requiresHost() {
        let viewModel = SOCKSProxyPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.host = "   "
        #expect(viewModel.validationIssues.contains { $0.localizedCaseInsensitiveContains("host") })

        viewModel.state.host = "proxy.example.com"
        #expect(viewModel.validationIssues.isEmpty)
    }

    @Test("port must be in range")
    func portRange() {
        let viewModel = SOCKSProxyPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.host = "proxy.example.com"

        viewModel.state.port = "70000"
        #expect(viewModel.validationIssues.contains { $0.localizedCaseInsensitiveContains("port") })

        viewModel.state.port = "not-a-port"
        #expect(viewModel.validationIssues.contains { $0.localizedCaseInsensitiveContains("port") })

        viewModel.state.port = "1080"
        #expect(viewModel.validationIssues.isEmpty)
    }

    @Test("credentials are optional")
    func credentialsOptional() {
        let viewModel = SOCKSProxyPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.host = "proxy.example.com"
        viewModel.state.username = ""
        viewModel.state.password = ""
        #expect(viewModel.validationIssues.isEmpty)
    }
}
