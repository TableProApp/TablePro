import AppKit
import SwiftUI

struct MCPSection: View {
    @Binding var settings: MCPSettings
    @State private var manager = MCPServerManager.shared
    @State private var tokenList: [MCPAuthToken] = []
    @State private var showSetupSheet = false
    @State private var showCreateSheet = false
    @State private var showRevealSheet = false
    @State private var revealedToken: MCPAuthToken?
    @State private var revealedPlaintext: String = ""

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
            helpSection

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

    private var helpSection: some View {
        Section {
            Button(String(localized: "Connect a Client…")) {
                showSetupSheet = true
            }
            Button(String(localized: "View Activity…")) {
                IntegrationsActivityWindowFactory.openOrFront()
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            IntegrationsSetupSheet(port: settings.port)
        }
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
