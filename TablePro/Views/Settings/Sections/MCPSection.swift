import AppKit
import SwiftUI

struct MCPSection: View {
    @Binding var settings: MCPSettings
    @State private var manager = MCPServerManager.shared
    @State private var selectedTool: IntegrationClient = .claudeDesktop
    @State private var tokenList: [MCPAuthToken] = []
    @State private var showCreateSheet = false
    @State private var showRevealSheet = false
    @State private var revealedToken: MCPAuthToken?
    @State private var revealedPlaintext: String = ""
    @State private var disconnectCandidate: MCPServer.SessionSnapshot?

    var body: some View {
        Section(String(localized: "Integrations")) {
            Toggle(String(localized: "Enable MCP Server"), isOn: $settings.enabled)

            if settings.enabled {
                LabeledContent(String(localized: "Status")) {
                    MCPStatusIndicator()
                }
            }
        }

        if settings.enabled {
            configurationSection
            authenticationSection
            networkSection
            connectedClientsSection
            setupSection

            Section {
                Text(String(localized: "AI access policies are configured per-connection in each connection's settings."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private var configurationSection: some View {
        Section(String(localized: "Server Configuration")) {
            LabeledContent(String(localized: "Port")) {
                TextField("", value: $settings.port, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent(String(localized: "Default row limit")) {
                TextField("", value: $settings.defaultRowLimit, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent(String(localized: "Maximum row limit")) {
                TextField("", value: $settings.maxRowLimit, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent(String(localized: "Query timeout")) {
                HStack(spacing: 4) {
                    TextField("", value: $settings.queryTimeoutSeconds, format: .number.grouping(.never))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(String(localized: "seconds"))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(String(localized: "Log MCP queries in history"), isOn: $settings.logQueriesInHistory)
        }
    }

    private var authenticationSection: some View {
        Section(String(localized: "Authentication")) {
            Toggle(String(localized: "Require authentication"), isOn: $settings.requireAuthentication)

            if settings.requireAuthentication {
                MCPTokenListView(
                    tokens: tokenList,
                    onGenerate: { showCreateSheet = true },
                    onRevoke: { id in Task { await manager.tokenStore?.revoke(tokenId: id); await refreshTokens() } },
                    onDelete: { id in Task { await manager.tokenStore?.delete(tokenId: id); await refreshTokens() } }
                )
            }
        }
        .task { await refreshTokens() }
        .sheet(isPresented: $showCreateSheet) {
            MCPTokenCreateSheet(onGenerate: handleGenerate)
        }
        .sheet(isPresented: $showRevealSheet) {
            if let revealedToken {
                MCPTokenRevealSheet(
                    token: revealedToken,
                    plaintext: revealedPlaintext,
                    port: settings.port,
                    allowRemoteConnections: settings.allowRemoteConnections
                )
            }
        }
    }

    private var networkSection: some View {
        Section(String(localized: "Network")) {
            Toggle(String(localized: "Allow remote connections"), isOn: $settings.allowRemoteConnections)

            if settings.allowRemoteConnections {
                Label {
                    Text(String(localized: "The server will be accessible from other devices on your network. Authentication and TLS are enabled automatically."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
                .font(.callout)
            }
        }
    }

    private var setupSection: some View {
        Section(String(localized: "Connect a Client")) {
            DisclosureGroup(String(localized: "Setup Instructions")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(String(localized: "Client"), selection: $selectedTool) {
                        ForEach(IntegrationClient.allCases) { tool in
                            Text(tool.displayName).tag(tool)
                        }
                    }

                    MCPSetupInstructions(tool: selectedTool, port: settings.port)
                }
                .padding(.top, 4)
            }
        }
    }

    private var connectedClientsSection: some View {
        Section(String(localized: "Connected Clients")) {
            if manager.connectedClients.isEmpty {
                Text(String(localized: "No clients connected"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.connectedClients) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(client.clientName)
                                if let version = client.clientVersion {
                                    Text(version)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(client.connectedSince, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            disconnectCandidate = client
                        } label: {
                            Text(String(localized: "Disconnect"))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .alert(
            String(localized: "Disconnect client?"),
            isPresented: disconnectAlertBinding,
            presenting: disconnectCandidate
        ) { client in
            Button(String(localized: "Cancel"), role: .cancel) {
                disconnectCandidate = nil
            }
            Button(String(localized: "Disconnect"), role: .destructive) {
                Task { await manager.disconnectClient(client.id) }
                disconnectCandidate = nil
            }
        } message: { client in
            Text(String(format: String(localized: "“%@” will be disconnected and any in-flight requests will be cancelled."), client.clientName))
        }
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

    private func handleGenerate(name: String, permissions: TokenPermissions, connectionIds: Set<UUID>?, expiresAt: Date?) {
        Task {
            guard let store = manager.tokenStore else { return }
            let access: ConnectionAccess = connectionIds.map { .limited($0) } ?? .all
            let result = await store.generate(
                name: name,
                permissions: permissions,
                connectionAccess: access,
                expiresAt: expiresAt
            )
            revealedToken = result.token
            revealedPlaintext = result.plaintext
            showCreateSheet = false
            showRevealSheet = true
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        guard let store = MCPServerManager.shared.tokenStore else { return }
        tokenList = await store.list().filter { $0.name != MCPTokenStore.stdioBridgeTokenName }
    }
}

private struct MCPSetupInstructions: View {
    let tool: IntegrationClient
    let port: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 20, alignment: .trailing)
                    Text(step)
                        .textSelection(.enabled)
                }
            }

            if let snippet = configSnippet {
                CopyableCodeBlock(text: snippet)
            }
            if let command {
                CopyableCodeBlock(text: command)
            }
        }
        .font(.callout)
    }

    private var url: String { "http://127.0.0.1:\(port)/mcp" }

    private var steps: [String] {
        switch tool {
        case .claudeDesktop:
            return [
                String(localized: "Open Claude Desktop, go to Settings > Developer"),
                String(localized: "Click \"Edit Config\" to open claude_desktop_config.json"),
                String(localized: "Add the JSON below inside the file and save"),
                String(localized: "Restart Claude Desktop")
            ]
        case .claudeCode:
            return [String(localized: "Run the command below in your terminal")]
        case .cursor:
            return [
                String(localized: "Open Cursor, go to Settings > MCP"),
                String(localized: "Click \"+ Add new global MCP server\""),
                String(localized: "Paste the JSON below and save")
            ]
        }
    }

    private var configSnippet: String? {
        switch tool {
        case .claudeDesktop, .cursor:
            return """
            {
              "mcpServers": {
                "tablepro": {
                  "url": "\(url)"
                }
              }
            }
            """
        case .claudeCode:
            return nil
        }
    }

    private var command: String? {
        switch tool {
        case .claudeCode: "claude mcp add tablepro --transport http \(url)"
        default: nil
        }
    }
}

private struct MCPStatusIndicator: View {
    @State private var manager = MCPServerManager.shared

    var body: some View {
        IntegrationStatusIndicator(status: status, label: statusText)
    }

    private var status: IntegrationStatus {
        switch manager.state {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .failed: .failed
        }
    }

    private var statusText: String {
        switch manager.state {
        case .stopped:
            String(localized: "Stopped")
        case .starting:
            String(localized: "Starting...")
        case .running(let port):
            String(format: String(localized: "Running on port %d"), port)
        case .failed(let message):
            if message.contains("48") || message.lowercased().contains("address already in use") {
                String(localized: "Port is already in use. Try a different port or close the other process.")
            } else {
                String(format: String(localized: "Failed: %@"), message)
            }
        }
    }
}
