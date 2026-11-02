//
//  CloudflareTunnelPaneViewModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

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

    @Test("Browser sign-in refuses a hostname cloudflared would read as an option or split", arguments: [
        "-h", "--help", "db.example.com --url x", "db\texample.com", "db.example.com\u{202E}",
    ])
    func signInRefusesFlagLikeHostname(hostname: String) {
        let viewModel = CloudflareTunnelPaneViewModel()
        viewModel.state.binaryPath = "/usr/bin/true"
        viewModel.state.accessHostname = hostname

        viewModel.signInWithBrowser()

        #expect(viewModel.signInError != nil)
    }

    @Test("Browser sign-in starts for a plain hostname")
    func signInStartsForPlainHostname() {
        let viewModel = CloudflareTunnelPaneViewModel()
        viewModel.state.binaryPath = "/usr/bin/true"
        viewModel.state.accessHostname = "db.example.com"

        viewModel.signInWithBrowser()

        #expect(viewModel.signInError == nil)
    }

    @Test("The not-found caption is plain text that names the install command")
    func binaryNotFoundMessageIsPlainText() {
        let message = CloudflareTunnelPaneViewModel().binaryNotFoundMessage

        #expect(!message.contains("`"))
        #expect(message.contains("brew install cloudflared"))
    }
}
