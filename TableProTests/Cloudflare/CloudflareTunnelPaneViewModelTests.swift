//
//  CloudflareTunnelPaneViewModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Cloudflare tunnel pane validation")
@MainActor
struct CloudflareTunnelPaneViewModelTests {
    @Test("disabled tunnel reports no validation issues")
    func disabledNoIssues() {
        let viewModel = CloudflareTunnelPaneViewModel()
        viewModel.state.enabled = false
        #expect(viewModel.validationIssues.isEmpty)
    }

    @Test("enabled tunnel requires a hostname")
    func requiresHostname() {
        let viewModel = CloudflareTunnelPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.accessHostname = "   "
        #expect(viewModel.validationIssues.contains { $0.localizedCaseInsensitiveContains("hostname") })
    }

    @Test("manual port must be within range")
    func portRange() {
        let viewModel = CloudflareTunnelPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.accessHostname = "db.example.com"
        viewModel.state.automaticPort = false
        viewModel.state.localPort = "70000"
        #expect(viewModel.validationIssues.contains { $0.localizedCaseInsensitiveContains("port") })
    }

    @Test("service token mode requires id and secret")
    func serviceTokenRequired() {
        let viewModel = CloudflareTunnelPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.accessHostname = "db.example.com"
        viewModel.state.authMethod = .serviceToken
        #expect(!viewModel.validationIssues.isEmpty)
    }

    @Test("valid browser sign-in config has no issues")
    func validBrowserConfig() {
        let viewModel = CloudflareTunnelPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.accessHostname = "db.example.com"
        viewModel.state.authMethod = .browserSSO
        #expect(viewModel.validationIssues.isEmpty)
    }
}
