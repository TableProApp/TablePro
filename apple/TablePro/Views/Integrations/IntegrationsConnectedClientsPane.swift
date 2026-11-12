import SwiftUI
import TableProMCPClients

struct IntegrationsConnectedClientsPane: View {
    @ObservedObject private var manager = MCPServerManager.shared
    @State private var selection: MCPServerManager.SessionSnapshot.ID?
    @State private var disconnectCandidate: MCPServerManager.SessionSnapshot?
    @State private var revocationNotSaved = false
    @State private var showSetupSheet = false
    @State private var detectedClientIDs: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<ConnectedClientRow>] = [
        KeyPathComparator(\ConnectedClientRow.connectedSince, order: .reverse)
    ]

    var body: some View {
        Group {
            if manager.connectedClients.isEmpty {
                emptyState
            } else {
                ConnectedClientsTable(
                    rows: sortedRows,
                    selection: $selection,
                    sortOrder: $sortOrder,
                    onDisconnect: { client in disconnectCandidate = client }
                )
                .onDeleteCommand(perform: disconnectSelection)
            }
        }
        .task(id: ambiguousClientIDs) { await detectAmbiguousClients() }
        .navigationTitle(IntegrationsActivitySection.connectedClients.title)
        .navigationSubtitle(subtitle)
        .task { await manager.refreshClientsWhileShown() }
        .toolbar(content: toolbar)
        .alert(
            String(localized: "Disconnect client?"),
            isPresented: disconnectAlertBinding,
            presenting: disconnectCandidate,
            actions: alertActions,
            message: alertMessage
        )
        .alert(String(localized: "Couldn't Save the Revocation"), isPresented: $revocationNotSaved) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(String(localized: "TablePro could not save the change to the Keychain. The token works again after TablePro restarts."))
        }
        .sheet(isPresented: $showSetupSheet) {
            MCPClientSetupSheet()
        }
    }

    private var emptyState: some View {
        UnavailableStateView {
            Label(emptyStateTitle, systemImage: emptyStateSymbol)
        } description: {
            Text(emptyStateDescription)
        } actions: {
            Button(String(localized: "Connect a Client…")) {
                showSetupSheet = true
            }
            .accessibilityIdentifier("connected-clients-connect")
        }
    }

    private var emptyStateTitle: String {
        switch manager.state {
        case .running: String(localized: "No clients connected")
        case .starting: String(localized: "MCP Server Starting")
        case .stopped: String(localized: "MCP Server Off")
        case .failed: String(localized: "MCP Server Couldn't Start")
        }
    }

    private var emptyStateSymbol: String {
        switch manager.state {
        case .running: "person.2.slash"
        case .starting: "hourglass"
        case .stopped: "power"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var emptyStateDescription: String {
        switch manager.state {
        case .running:
            String(localized: "Clients will appear here while they have an active MCP session.")
        case .starting:
            String(localized: "Clients can connect once the MCP server is running.")
        case .stopped:
            String(localized: "Clients can connect while the MCP server is on. Turn it on in Settings > MCP.")
        case .failed:
            String(localized: "Clients cannot connect until it runs. Open Settings > MCP to see why and try again.")
        }
    }

    private func disconnectSelection() {
        guard let id = selection, let client = manager.connectedClients.first(where: { $0.id == id }) else { return }
        disconnectCandidate = client
    }

    private var sortedRows: [ConnectedClientRow] {
        manager.connectedClients.map { session in
            ConnectedClientRow(
                session: session,
                name: session.clientDisplayName(detected: detectedClientIDs),
                iconSlug: session.catalogIconSlug(detected: detectedClientIDs)
            )
        }
        .sorted(using: sortOrder)
    }

    private var ambiguousClientIDs: Set<String> {
        let sessions = manager.connectedClients.map { (clientInfoName: $0.sessionInfoName, tokenName: $0.tokenName) }
        return MCPClientCatalogBundle.shared?.ambiguousClientIDs(forSessionsNamed: sessions) ?? []
    }

    private func detectAmbiguousClients() async {
        let ids = ambiguousClientIDs
        guard !ids.isEmpty, let catalog = MCPClientCatalogBundle.shared else { return }
        detectedClientIDs = await Self.detect(ids, scanner: MCPClientScanner(catalog: catalog, context: .live()))
    }

    @concurrent
    nonisolated private static func detect(_ ids: Set<String>, scanner: MCPClientScanner) async -> Set<String> {
        scanner.detectedIDs(among: ids)
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItem {
            Button {
                showSetupSheet = true
            } label: {
                Label(String(localized: "Connect a Client…"), systemImage: "plus")
            }
            .help(String(localized: "Set up an app to use TablePro's MCP server"))
            .accessibilityIdentifier("connected-clients-toolbar-connect")
        }
        ToolbarItem {
            Button(role: .destructive) {
                disconnectSelection()
            } label: {
                Label(String(localized: "Disconnect"), systemImage: ToolbarSymbols.disconnect())
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
            Task {
                if !(await manager.disconnectClient(client.id)) {
                    revocationNotSaved = true
                }
            }
            disconnectCandidate = nil
        }
    }

    private func alertMessage(client: MCPServerManager.SessionSnapshot) -> some View {
        switch client.transport {
        case .http:
            Text(String(
                format: String(localized: "“%@” will be disconnected and its token revoked. Any in-flight requests will be cancelled."),
                client.clientDisplayName(detected: detectedClientIDs)
            ))
        case .stdioBridge:
            Text(String(
                // swiftlint:disable:next line_length
                format: String(localized: "“%@”'s running requests will be cancelled, but it can send new ones right away. To stop it, remove TablePro from it in Connect a Client, or turn off the MCP server."),
                client.clientDisplayName(detected: detectedClientIDs)
            ))
        }
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

private struct ConnectedClientRow: Identifiable {
    let session: MCPServerManager.SessionSnapshot
    let name: String
    let iconSlug: String?

    var id: MCPServerManager.SessionSnapshot.ID { session.id }
    var connectedSince: Date { session.connectedSince }
    var lastActivityAt: Date { session.lastActivityAt }
}

private struct ConnectedClientsTable: View {
    let rows: [ConnectedClientRow]
    @Binding var selection: MCPServerManager.SessionSnapshot.ID?
    @Binding var sortOrder: [KeyPathComparator<ConnectedClientRow>]
    let onDisconnect: (MCPServerManager.SessionSnapshot) -> Void

    var body: some View {
        Table(of: ConnectedClientRow.self,
              selection: $selection,
              sortOrder: $sortOrder) {
            TableColumn(String(localized: "Client"), value: \.name) { row in
                clientCell(for: row)
            }
            .width(min: 160, ideal: 200)

            TableColumn(String(localized: "Version")) { row in
                versionCell(for: row.session)
            }
            .width(min: 70, ideal: 90)

            TableColumn(String(localized: "Token")) { row in
                tokenCell(for: row.session)
            }
            .width(min: 110, ideal: 140)

            TableColumn(String(localized: "Address")) { row in
                addressCell(for: row.session)
            }
            .width(min: 120, ideal: 160)

            TableColumn(String(localized: "Connected"), value: \.connectedSince) { row in
                connectedCell(for: row.session)
            }
            .width(min: 110, ideal: 130)

            TableColumn(String(localized: "Last Activity"), value: \.lastActivityAt) { row in
                lastActivityCell(for: row.session)
            }
            .width(min: 110, ideal: 130)
        } rows: {
            ForEach(rows) { row in
                SwiftUI.TableRow(row)
                    .contextMenu { contextMenu(for: row.session) }
            }
        }
    }

    @ViewBuilder
    private func clientCell(for row: ConnectedClientRow) -> some View {
        Label {
            Text(verbatim: row.name)
        } icon: {
            BrandIconView(icon: BrandIcon(slug: row.iconSlug, fallbackSystemImage: "app"))
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private func versionCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        if let version = client.clientVersion {
            Text(version).foregroundStyle(.secondary)
        } else {
            Text(verbatim: "-").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func tokenCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        if let name = client.tokenName {
            Text(IntegrationsFormatting.displayTokenName(name))
        } else {
            Text(verbatim: "-").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func addressCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        if let address = client.remoteAddress {
            Text(address).font(.system(.body, design: .monospaced))
        } else {
            Text(verbatim: "-").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func connectedCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        relativeText(client.connectedSince)
    }

    @ViewBuilder
    private func lastActivityCell(for client: MCPServerManager.SessionSnapshot) -> some View {
        relativeText(client.lastActivityAt)
    }

    // The list publishes only when it changes, so the elapsed time redraws on its own schedule.
    private func relativeText(_ date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            Text(date.formatted(.relative(presentation: .named)))
        }
        .help(date.formatted(date: .complete, time: .standard))
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

extension MCPServerManager.SessionSnapshot {
    fileprivate var sessionInfoName: String {
        clientInfoName ?? clientName
    }

    // A session two catalog rows share keeps its own clientInfo title unless one of them alone is on this Mac.
    func clientDisplayName(detected: Set<String>) -> String {
        MCPClientCatalogBundle.shared?.client(forSessionNamed: sessionInfoName, tokenName: tokenName, detected: detected)?.name
            ?? IntegrationsFormatting.displayClientName(self)
    }

    func catalogIconSlug(detected: Set<String>) -> String? {
        MCPClientCatalogBundle.shared?.iconSlug(forSessionNamed: sessionInfoName, tokenName: tokenName, detected: detected)
    }
}
