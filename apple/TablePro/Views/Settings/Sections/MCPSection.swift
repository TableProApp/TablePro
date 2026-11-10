import AppKit
import SwiftUI
import TableProMCP

struct MCPSection: View {
    @Binding var settings: MCPSettings
    @ObservedObject private var manager = MCPServerManager.shared
    @State private var tokenList: [MCPAuthToken] = []
    @State private var showSetupSheet = false
    @State private var showCreateSheet = false
    @State private var showRevealSheet = false
    @State private var revealedToken: MCPAuthToken?
    @State private var revealedPlaintext: String = ""
    @State private var revocationNotSaved = false

    var body: some View {
        Section {
            Toggle(String(localized: "Enable MCP Server"), isOn: $settings.enabled)
                .accessibilityIdentifier("mcp-enable-server-toggle")

            if settings.enabled {
                MCPStatusRow(configuredPort: settings.port)
            }
        }

        if settings.enabled {
            configurationSection
            connectionAccessSection
            authenticationSection
            helpSection
        }
    }

    private var connectionAccessSection: some View {
        Section {
            Picker(String(localized: "Approval"), selection: $settings.connectionApproval) {
                ForEach(MCPConnectionApproval.allCases) { approval in
                    Text(approval.displayName).tag(approval)
                }
            }
            .pickerStyle(.menu)

            Text(settings.connectionApproval.explanation)
                .foregroundStyle(.secondary)
                .font(.callout)

            MCPGrantListView()

            Toggle(
                String(localized: "Allow apps to list connections hidden from AI"),
                isOn: $settings.allowsHiddenConnectionListing
            )
            .accessibilityIdentifier("mcp-hidden-connection-listing-toggle")

            // swiftlint:disable:next line_length
            Text(String(localized: "A paired app, such as a launcher, can ask when it pairs to show connections whose AI Policy is Never, with their user names. It still cannot query them. Turning this off stops every app at once."))
                .foregroundStyle(.secondary)
                .font(.callout)
        } header: {
            Text("Connection Access")
        } footer: {
            // swiftlint:disable:next line_length
            Text("Approval is separate from what a client may reach. A connection blocked for external clients stays blocked, a read-only one stays read only, and Safe Mode still confirms destructive statements.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            MCPTokenListView(
                tokens: tokenList,
                onGenerate: { showCreateSheet = true },
                onRevoke: { id in
                    Task {
                        if !(await manager.revokeToken(id: id)) {
                            revocationNotSaved = true
                        }
                        await refreshTokens()
                    }
                },
                onDelete: { id in Task { await manager.tokenStore?.delete(tokenId: id); await refreshTokens() } }
            )
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
                    port: manager.listeningPort ?? settings.port
                )
            }
        }
        .alert(String(localized: "Couldn't Save the Revocation"), isPresented: $revocationNotSaved) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(String(localized: "TablePro could not save the change to the Keychain. The token works again after TablePro restarts."))
        }
    }

    private var helpSection: some View {
        Section {
            Button(String(localized: "Connect a Client…")) {
                showSetupSheet = true
            }
            Button(String(localized: "View Activity…")) {
                WindowOpener.shared.openIntegrationsActivity()
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            IntegrationsSetupSheet(port: manager.listeningPort ?? settings.port)
        }
    }

    private func handleGenerate(name: String, permissions: TokenPermissions, connectionIds: Set<UUID>?, expiresAt: Date?) {
        Task {
            guard let store = manager.tokenStore else { return }
            let access: ConnectionAccess = connectionIds.map { .limited($0) } ?? .all
            guard let result = try? await store.generate(
                name: name,
                permissions: permissions,
                connectionAccess: access,
                expiresAt: expiresAt,
                isBridgeCredential: false,
                extraScopes: []
            ) else { return }
            revealedToken = result.token
            revealedPlaintext = result.plaintext
            showCreateSheet = false
            showRevealSheet = true
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        guard let store = MCPServerManager.shared.tokenStore else { return }
        tokenList = await store.list().filter { !$0.isBridgeCredential }
    }
}

private struct MCPStatusRow: View {
    @ObservedObject private var manager = MCPServerManager.shared
    let configuredPort: Int

    var body: some View {
        let presentation = MCPServerStatusPresentation(state: manager.state, configuredPort: configuredPort)
        LabeledContent(String(localized: "Status")) {
            HStack(spacing: 8) {
                IntegrationStatusIndicator(status: presentation.status, label: presentation.title)
                if presentation.offersRetry {
                    Button(String(localized: "Try Again")) {
                        manager.retry()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("mcp-status-try-again")
                }
            }
        }
        if let detail = presentation.detail {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
