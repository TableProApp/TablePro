//
//  MCPOutsideServersSection.swift
//  TablePro
//

import SwiftUI

/// The MCP servers somebody else runs that a session may call.
///
/// Its own section rather than a line in **Integrations**, because it is the opposite direction:
/// everything above it is what an outside client may ask of TablePro, and this is what TablePro may
/// ask of an outside server. It sits below them for that reason, and it works whether or not the
/// built-in server is switched on.
internal struct MCPOutsideServersSection: View {
    @ObservedObject private var store = MCPServerStore.shared

    @State private var editing: MCPServerConfiguration?
    @State private var isAdding = false
    @State private var deleteCandidate: MCPServerConfiguration?

    var body: some View {
        Section {
            if store.servers.isEmpty {
                emptyState
            } else {
                ForEach(store.servers) { server in
                    row(server)
                }
            }

            Button {
                isAdding = true
            } label: {
                Label(String(localized: "Add Server…"), systemImage: "plus")
            }
        } header: {
            Text("Outside MCP Servers")
        } footer: {
            Text("A session can call tools on a server you add here once you allow it on a connection. Every call waits for you to approve it, and the arguments leave this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isAdding) {
            MCPOutsideServerSheet(server: nil)
        }
        .sheet(item: $editing) { server in
            MCPOutsideServerSheet(server: server)
        }
        .alert(
            String(localized: "Remove server?"),
            isPresented: deleteAlertBinding,
            presenting: deleteCandidate
        ) { server in
            Button(String(localized: "Cancel"), role: .cancel) { deleteCandidate = nil }
            Button(String(localized: "Remove"), role: .destructive) {
                store.remove(id: server.id)
                deleteCandidate = nil
            }
        } message: { server in
            Text(String(
                format: String(localized: "“%@” and its token are removed from this Mac. Sessions lose its tools."),
                server.name
            ))
        }
    }

    private func row(_ server: MCPServerConfiguration) -> some View {
        Button {
            editing = server
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name)
                    Text(server.endpoint.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(reachText(server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(server.name)
        .accessibilityValue(reachText(server))
        .contextMenu {
            Button(String(localized: "Edit…")) { editing = server }
            Divider()
            Button(role: .destructive) {
                deleteCandidate = server
            } label: {
                Text(String(localized: "Remove…"))
            }
        }
    }

    /// How far the server reaches, which is the one thing about it worth reading at a glance. A
    /// server allowed nowhere is inert, and saying so is more use than a status dot that would have
    /// to connect to mean anything.
    private func reachText(_ server: MCPServerConfiguration) -> String {
        let count = server.allowedConnectionIds.count
        if count == 0 { return String(localized: "No connections") }
        if count == 1 { return String(localized: "1 connection") }
        return String(format: String(localized: "%d connections"), count)
    }

    private var emptyState: some View {
        Text("No servers yet.")
            .foregroundStyle(.secondary)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )
    }
}
