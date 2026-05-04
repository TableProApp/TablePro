//
//  IntegrationsConnectedClientsPane.swift
//  TablePro
//

import SwiftUI

struct IntegrationsConnectedClientsPane: View {
    @State private var manager = MCPServerManager.shared
    @State private var selection: MCPServerManager.SessionSnapshot.ID?
    @State private var disconnectCandidate: MCPServerManager.SessionSnapshot?
    @State private var sortOrder: [KeyPathComparator<MCPServerManager.SessionSnapshot>] = [
        KeyPathComparator(\MCPServerManager.SessionSnapshot.connectedSince, order: .reverse)
    ]

    var body: some View {
        Group {
            if manager.connectedClients.isEmpty {
                ContentUnavailableView(
                    String(localized: "No clients connected"),
                    systemImage: "person.2.slash",
                    description: Text(String(localized: "Clients will appear here while they have an active MCP session."))
                )
            } else {
                ConnectedClientsTable(
                    clients: sortedClients,
                    selection: $selection,
                    sortOrder: $sortOrder,
                    onDisconnect: { client in disconnectCandidate = client }
                )
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

    private var sortedClients: [MCPServerManager.SessionSnapshot] {
        manager.connectedClients.sorted(using: sortOrder)
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

private struct ConnectedClientsTable: View {
    let clients: [MCPServerManager.SessionSnapshot]
    @Binding var selection: MCPServerManager.SessionSnapshot.ID?
    @Binding var sortOrder: [KeyPathComparator<MCPServerManager.SessionSnapshot>]
    let onDisconnect: (MCPServerManager.SessionSnapshot) -> Void

    var body: some View {
        Table(of: MCPServerManager.SessionSnapshot.self,
              selection: $selection,
              sortOrder: $sortOrder) {
            TableColumn(String(localized: "Client"), value: \.clientName) { client in
                clientCell(for: client)
            }
            .width(min: 160, ideal: 200)

            TableColumn(String(localized: "Version")) { client in
                versionCell(for: client)
            }
            .width(min: 70, ideal: 90)

            TableColumn(String(localized: "Token")) { client in
                tokenCell(for: client)
            }
            .width(min: 110, ideal: 140)

            TableColumn(String(localized: "Address")) { client in
                addressCell(for: client)
            }
            .width(min: 120, ideal: 160)

            TableColumn(String(localized: "Connected"), value: \.connectedSince) { client in
                connectedCell(for: client)
            }
            .width(min: 110, ideal: 130)

            TableColumn(String(localized: "Last Activity"), value: \.lastActivityAt) { client in
                lastActivityCell(for: client)
            }
            .width(min: 110, ideal: 130)
        } rows: {
            ForEach(clients) { client in
                SwiftUI.TableRow(client)
                    .contextMenu { contextMenu(for: client) }
            }
        }
    }

    @ViewBuilder
    private func clientCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        Label {
            Text(client.clientName)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        }
    }

    @ViewBuilder
    private func versionCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        if let version = client.clientVersion {
            Text(version).foregroundStyle(.secondary)
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func tokenCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        if let name = client.tokenName {
            Text(IntegrationsFormatting.displayTokenName(name))
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func addressCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        if let address = client.remoteAddress {
            Text(address).font(.system(.body, design: .monospaced))
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func connectedCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        Text(client.connectedSince, format: .relative(presentation: .named))
            .help(client.connectedSince.formatted(date: .complete, time: .standard))
    }

    @ViewBuilder
    private func lastActivityCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        Text(client.lastActivityAt, format: .relative(presentation: .named))
            .help(client.lastActivityAt.formatted(date: .complete, time: .standard))
    }

    @ViewBuilder
    private func contextMenu(for client: MCPServerManager.SessionSnapshot) -> some View {
        Button(role: .destructive) {
            onDisconnect(client)
        } label: {
            Label(String(localized: "Disconnect"), systemImage: "xmark.circle")
        }
    }
}
