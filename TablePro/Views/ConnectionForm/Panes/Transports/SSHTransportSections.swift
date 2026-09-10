//
//  SSHTransportSections.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The SSH server half of a connection, as sections of the Network tab's form.
///
/// Nothing here switches the transport on: reaching this view at all means the picker already
/// selected it, which is why the old `Toggle("Enable SSH Tunnel")` that made up an entire pane on
/// its own is gone.
struct SSHTransportSections: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        SSHServerSections(sshState: $coordinator.ssh.state)
        forwardTargetSection
    }

    /// A tunnel normally forwards to Host and Port; a database that only listens on a unix socket
    /// needs the path instead, and then Host and Port go unused. The field belongs beside the
    /// tunnel that carries it rather than beside the host it replaces.
    private var forwardTargetSection: some View {
        Section {
            TextField(
                String(localized: "Socket Path"),
                text: $coordinator.network.sshForwardUnixSocketPath,
                prompt: Text(verbatim: coordinator.network.socketPathPrompt)
            )
            if coordinator.network.hasHostListField, replicaSetHostsAreListed {
                Label(
                    String(localized: "TablePro connects to the first host over a tunnel. Replica set failover is not available."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Forward To"))
        } footer: {
            forwardTargetFooter
        }
    }

    @ViewBuilder
    private var forwardTargetFooter: some View {
        switch coordinator.network.socketPathIssue {
        case .notAbsolute:
            caption(
                String(localized: "Enter an absolute path, as it appears on the SSH server."),
                systemImage: "exclamationmark.triangle",
                tint: .orange
            )
        case .looksLikeDirectory:
            caption(
                String(localized: "Point at the socket file itself, not the directory holding it."),
                systemImage: "exclamationmark.triangle",
                tint: .orange
            )
        case .none:
            if coordinator.network.forwardsToUnixSocket {
                caption(
                    String(localized: """
                    The SSH server connects to this socket instead of Host and Port. \
                    A database on a socket cannot negotiate TLS, so TablePro turns it off; \
                    the SSH tunnel still encrypts the whole path.
                    """),
                    systemImage: "info.circle",
                    tint: .secondary
                )
            } else {
                caption(
                    String(localized: "Optional. Set this to reach a database that only listens on a Unix socket."),
                    systemImage: "info.circle",
                    tint: .secondary
                )
            }
        }
    }

    private func caption(_ message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
    }

    private var replicaSetHostsAreListed: Bool {
        coordinator.network.firstHostListValue.contains(",")
    }
}

/// Points a file-backed connection at a database file on an SSH server.
///
/// The server half is the same problem whether what comes back is a socket or a file, so it is the
/// same view. What this adds is the path.
struct RemoteFileTransportSections: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Section {
            TextField(String(localized: "Path"), text: $coordinator.ssh.state.remoteFilePath)
                .autocorrectionDisabled()
                .accessibilityIdentifier("connection-form-remote-file-path")
        } header: {
            Text(String(localized: "Remote File"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Absolute, or relative to the SSH account's home directory. `~` works.")
                Text("The file is copied to this Mac and opened read-only. The original on the server is never written to.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        SSHServerSections(sshState: $coordinator.ssh.state)
    }
}
