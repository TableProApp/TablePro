//
//  RemoteFilePaneViewModel.swift
//  TablePro
//

import Foundation

/// Validation for the Remote File pane.
///
/// The pane edits the same `SSHTunnelFormState` the SSH Tunnel pane does, because a file-backed
/// connection reaches its server with the same credentials a tunnel would. Only two fields are its
/// own, and only one of them can be wrong: a connection that names a server and no file has nothing
/// to open.
@Observable
@MainActor
final class RemoteFilePaneViewModel {
    var coordinator: WeakCoordinatorRef?

    /// Nothing to say unless this pane is the one on screen.
    ///
    /// `ConnectionFormCoordinator.isFormValid` reads every pane's issues, visible or not, so a view
    /// model that answers for a type it does not belong to disables Save and Test on that type's
    /// form. This pane shares `SSHTunnelFormState` with the SSH Tunnel pane, so without the
    /// capability check every MySQL or PostgreSQL connection with a tunnel would be told it needs a
    /// remote database file path.
    var validationIssues: [String] {
        guard let coordinator = coordinator?.value,
              coordinator.services.pluginManager.supportsRemoteDatabaseFile(for: coordinator.network.type)
        else { return [] }

        let ssh = coordinator.ssh.state
        guard ssh.enabled else { return [] }

        var issues: [String] = []
        if resolvedHost(for: coordinator).isEmpty {
            issues.append(String(localized: "SSH host is required"))
        }
        if ssh.remoteFilePath.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "Remote database file path is required"))
        }
        return issues
    }

    /// A profile supplies the host, so the inline field being empty says nothing on its own.
    private func resolvedHost(for coordinator: ConnectionFormCoordinator) -> String {
        coordinator.ssh.state.buildSSHConfig().host.trimmingCharacters(in: .whitespaces)
    }
}
