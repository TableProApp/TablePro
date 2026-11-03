//
//  CloudSQLProxyPaneViewModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro
import TableProTestSupport

@MainActor
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

    @Test("The pane shows the shared download, and its Cancel stops it")
    func paneFollowsSharedDownload() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = DownloadRecord()
        let download = CloudSQLProxyDownload(binaryManager: CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(Data("pinned build".utf8)),
            download: { _, progress in
                record.started()
                await progress(0.5)
                await suspendUntilCancelled()
                record.sawCancel()
                throw URLError(.cancelled)
            }
        ))
        let viewModel = CloudSQLProxyPaneViewModel(download: download)

        viewModel.downloadBinary()
        try await waitUntil { viewModel.downloadPhase == .downloading(fraction: 0.5) }
        #expect(viewModel.isDownloading)

        viewModel.cancelDownload()
        #expect(viewModel.downloadPhase == .idle)
        try await waitUntil { record.wasCancelled }
    }

    @Test(
        "Only a managed binary that passes its checksum shows as detected",
        .enabled(if: CLIExecutableFinder.findExecutable("cloud-sql-proxy") == nil, "a system cloud-sql-proxy wins over the managed one")
    )
    func detectedNeedsACurrentManagedBinary() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("pinned build".utf8)
        let binary = dir.appendingPathComponent("cloud-sql-proxy")
        try Data("altered".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try CloudSQLProxyBinaryManager.pinnedVersion
            .write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        let viewModel = CloudSQLProxyPaneViewModel(download: CloudSQLProxyDownload(binaryManager: CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(bytes),
            download: TestProxyDownload.serving(bytes, into: dir)
        )))

        viewModel.resolveBinary()
        try await waitUntil { viewModel.didResolveBinary }
        #expect(viewModel.resolvedBinaryPath == nil)

        try bytes.write(to: binary)
        viewModel.didResolveBinary = false
        viewModel.resolveBinary()
        try await waitUntil { viewModel.didResolveBinary }
        #expect(viewModel.resolvedBinaryPath == binary.path)
    }

    @Test("The not-found caption is plain text that names the install command")
    func binaryNotFoundMessageIsPlainText() {
        let message = CloudSQLProxyPaneViewModel().binaryNotFoundMessage

        #expect(!message.contains("`"))
        #expect(message.contains("brew install cloud-sql-proxy"))
    }
}
