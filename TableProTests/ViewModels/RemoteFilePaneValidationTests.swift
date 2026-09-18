//
//  RemoteFilePaneValidationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// `isFormValid` reads every pane's issues, visible or not.
///
/// The Remote File pane edits the same `SSHTunnelFormState` the SSH Tunnel pane does, so a version
/// of it that answered whenever SSH was enabled told every MySQL and PostgreSQL connection with a
/// tunnel that it needed a remote database file path, and disabled Save and Test on all of them.
@MainActor
@Suite("Remote file pane validation")
struct RemoteFilePaneValidationTests {
    private func coordinator(type: DatabaseType) -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.type = type
        return coordinator
    }

    @Test("An SSH-tunnelled network connection is never asked for a remote file path")
    func networkConnectionWithTunnelStaysValid() {
        for type in [DatabaseType.mysql, .postgresql] {
            let coordinator = coordinator(type: type)
            coordinator.ssh.state.enabled = true
            coordinator.ssh.state.host = "bastion.example.com"
            coordinator.ssh.state.username = "deploy"

            #expect(coordinator.remoteFile.validationIssues.isEmpty)
        }
    }

    @Test("A file-backed connection with SSH on but no path is told what is missing")
    func fileBackedConnectionRequiresAPath() {
        let coordinator = coordinator(type: .sqlite)
        coordinator.ssh.state.enabled = true
        coordinator.ssh.state.host = "prod-1"
        coordinator.ssh.state.username = "deploy"
        coordinator.ssh.state.remoteFilePath = ""

        #expect(coordinator.remoteFile.validationIssues.count == 1)
    }

    @Test("A file-backed connection naming both a server and a path has nothing to report")
    func completeRemoteFileIsValid() {
        let coordinator = coordinator(type: .sqlite)
        coordinator.ssh.state.enabled = true
        coordinator.ssh.state.host = "prod-1"
        coordinator.ssh.state.username = "deploy"
        coordinator.ssh.state.remoteFilePath = "/srv/app.db"

        #expect(coordinator.remoteFile.validationIssues.isEmpty)
    }

    @Test("SSH switched off leaves nothing to validate")
    func disabledSSHReportsNothing() {
        let coordinator = coordinator(type: .sqlite)
        coordinator.ssh.state.enabled = false

        #expect(coordinator.remoteFile.validationIssues.isEmpty)
    }
}
