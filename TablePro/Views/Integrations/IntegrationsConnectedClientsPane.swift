//
//  IntegrationsConnectedClientsPane.swift
//  TablePro
//

import SwiftUI

struct IntegrationsConnectedClientsPane: View {
    @State private var manager = MCPServerManager.shared
    @State private var selection: MCPServerManager.SessionSnapshot.ID?
    @State private var disconnectCandidate: MCPServerManager.SessionSnapshot?

    var body: some View {
        Group {
            if manager.connectedClients.isEmpty {
                ContentUnavailableView(
                    String(localized: "No clients connected"),
                    systemImage: "person.2.slash",
                    description: Text(String(localized: "Clients will appear here while they have an active MCP session."))
                )
            } else {
                clientList
            }
        }
        .navigationTitle(IntegrationsActivitySection.connectedClients.title)
        .navigationSubtitle(subtitle)
        .toolbar(content: toolbar)
        .alert(
            String(localized: "Disconnect client?"),
            isPresented: disconnectAlertBinding,
            presenting: disconnectCandidate,
            actions: alertActions,
            message: alertMessage
        )
    }

    private var clientList: some View {
        List(manager.connectedClients, selection: $selection) { client in
            ConnectedClientRow(client: client, tokenLabel: displayTokenName(client.tokenName))
                .contextMenu {
                    Button(role: .destructive) {
                        disconnectCandidate = client
                    } label: {
                        Label(String(localized: "Disconnect"), systemImage: "xmark.circle")
                    }
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItem {
            Button(role: .destructive) {
                if let id = selection,
                   let client = manager.connectedClients.first(where: { $0.id == id }) {
                    disconnectCandidate = client
                }
            } label: {
                Label(String(localized: "Disconnect"), systemImage: "xmark.circle")
            }
            .help(String(localized: "Disconnect the selected client"))
            .disabled(selection == nil)
        }
    }

    @ViewBuilder
    private func alertActions(client: MCPServerManager.SessionSnapshot) -> some View {
        Button(String(localized: "Cancel"), role: .cancel) {
            disconnectCandidate = nil
        }
        Button(String(localized: "Disconnect"), role: .destructive) {
            Task { await manager.disconnectClient(client.id) }
            disconnectCandidate = nil
        }
    }

    private func alertMessage(client: MCPServerManager.SessionSnapshot) -> some View {
        Text(String(format: String(localized: "“%@” will be disconnected and any in-flight requests will be cancelled."), client.clientName))
    }

    private var subtitle: String {
        let count = manager.connectedClients.count
        return String(format: String(localized: "%d connected"), count)
    }

    private func displayTokenName(_ name: String?) -> String? {
        guard let name else { return nil }
        return name == MCPTokenStore.stdioBridgeTokenName ? String(localized: "Built-in CLI") : name
    }

    private var disconnectAlertBinding: Binding<Bool> {
        Binding(
            get: { disconnectCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    disconnectCandidate = nil
                }
            }
        )
    }
}

private struct ConnectedClientRow: View {
    let client: MCPServerManager.SessionSnapshot
    let tokenLabel: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IntegrationStatusIndicator(status: .running)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                primaryLine
                metadataLine
            }
            Spacer(minLength: 12)
            timestamp
        }
        .padding(.vertical, 4)
    }

    private var primaryLine: some View {
        HStack(spacing: 6) {
            Text(client.clientName)
                .font(.callout.weight(.medium))
            if let version = client.clientVersion {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        let parts: [String] = [
            tokenLabel,
            client.remoteAddress
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timestamp: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(client.connectedSince, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "Active %@"),
                        client.lastActivityAt.formatted(.relative(presentation: .named))))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .help(client.connectedSince.formatted(date: .complete, time: .standard))
    }
}
