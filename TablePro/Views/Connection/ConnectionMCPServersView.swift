//
//  ConnectionMCPServersView.swift
//  TablePro
//

import SwiftUI

/// Which outside MCP servers a session on this connection may reach.
///
/// Per connection rather than app-wide on purpose: a server added for a side project must not be
/// reachable from a production connection just because both are open in the same app.
///
/// Only shown for a connection that has been saved. The allowlist is keyed by connection id, and a
/// form that has not saved one yet has no id to key by; inventing one here would write an allowlist
/// entry for a connection that may never exist.
internal struct ConnectionMCPServersView: View {
    internal let connectionId: UUID

    private let store = MCPServerStore.shared

    internal var body: some View {
        if !store.servers.isEmpty {
            Section {
                ForEach(store.servers) { server in
                    Toggle(isOn: binding(for: server)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(verbatim: server.endpoint.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Outside MCP Servers"))
            } footer: {
                /// No font or colour of its own. A `Section` footer is already secondary and already
                /// sized for the platform, and restating both here overrides whatever the pane's
                /// form style would have chosen.
                Text(String(localized: """
                    A session on this connection may call the servers ticked here. Every call waits \
                    for your approval and is recorded in the audit log. Add servers in \
                    Settings > Integrations.
                    """))
            }
        }
    }

    private func binding(for server: MCPServerConfiguration) -> Binding<Bool> {
        Binding(
            get: { server.allowedConnectionIds.contains(connectionId) },
            set: { store.setAllowed($0, serverId: server.id, connectionId: connectionId) }
        )
    }
}
