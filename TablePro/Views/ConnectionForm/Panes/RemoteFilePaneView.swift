//
//  RemoteFilePaneView.swift
//  TablePro
//

import SwiftUI

/// Points a file-backed connection at a database file on an SSH server.
///
/// The server half is `ConnectionSSHTunnelView`, unchanged, because reaching the machine is the
/// same problem whether what comes back is a socket or a file. What this pane adds is the path, and
/// the decision the path forces: whether edits may be sent back over a file another process may be
/// writing.
struct RemoteFilePaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    private var isEnabled: Bool { coordinator.ssh.state.enabled }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $coordinator.ssh.state.enabled) {
                    Text("Open a database file on an SSH server")
                }
                Text(
                    "The file is copied to this Mac and opened read-only. The original on the server is never written to."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if isEnabled {
                Section("Remote File") {
                    TextField("Path", text: $coordinator.ssh.state.remoteFilePath)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Text("Absolute, or relative to the SSH account's home directory. `~` works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ConnectionSSHTunnelView(
                sshState: $coordinator.ssh.state,
                databaseType: coordinator.network.type,
                coordinator: coordinator
            )
        }
        .formStyle(.grouped)
    }
}
