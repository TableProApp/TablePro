//
//  CloudSQLProxyPaneViewModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("Cloud SQL Auth Proxy pane view model")
struct CloudSQLProxyPaneViewModelTests {
    @Test("disabled reports no issues")
    func disabledNoIssues() {
        let viewModel = CloudSQLProxyPaneViewModel()
        viewModel.state.enabled = false
        #expect(viewModel.validationIssues.isEmpty)
    }

    @Test("enabled requires a well-formed instance connection name")
    func requiresInstanceName() {
        let viewModel = CloudSQLProxyPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.instanceConnectionName = "bad"
        #expect(!viewModel.validationIssues.isEmpty)

        viewModel.state.instanceConnectionName = "p:r:i"
        #expect(viewModel.validationIssues.isEmpty)
    }

    @Test("manual port must be in range")
    func manualPortRange() {
        let viewModel = CloudSQLProxyPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.instanceConnectionName = "p:r:i"
        viewModel.state.automaticPort = false

        viewModel.state.localPort = "70000"
        #expect(!viewModel.validationIssues.isEmpty)

        viewModel.state.localPort = "5432"
        #expect(viewModel.validationIssues.isEmpty)
    }

    @Test("service account key mode requires a key")
    func serviceAccountKeyRequired() {
        let viewModel = CloudSQLProxyPaneViewModel()
        viewModel.state.enabled = true
        viewModel.state.instanceConnectionName = "p:r:i"
        viewModel.state.authMode = .serviceAccountKey

        viewModel.state.serviceAccountKeyJSON = ""
        #expect(!viewModel.validationIssues.isEmpty)

        viewModel.state.serviceAccountKeyJSON = "{\"type\":\"service_account\"}"
        #expect(viewModel.validationIssues.isEmpty)
    }
}
