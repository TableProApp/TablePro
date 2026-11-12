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
    @State private var revealedPlaintext: String = ""
    @State private var tokenAlert: MCPTokenAlert?
    @State private var rejectedPort: Int?

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
        Section {
            LabeledContent(String(localized: "Port")) {
                TextField("", value: portBinding, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("mcp-port-field")
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
        } header: {
            Text(String(localized: "Server Configuration"))
        } footer: {
            if let rejectedPort {
                NoticeLabel(
                    String(
                        format: String(localized: "Port %d cannot be used. Choose a port from %d to %d."),
                        rejectedPort,
                        MCPSettings.portRange.lowerBound,
                        MCPSettings.portRange.upperBound
                    ),
                    severity: .error
                )
                .font(.caption)
            }
        }
    }

    // An out-of-range port is kept out of the settings, so the server never binds a port the field did not show.
    private var portBinding: Binding<Int> {
        Binding(
            get: { settings.port },
            set: { newValue in
                if MCPSettings.portRange.contains(newValue) {
                    rejectedPort = nil
                    settings.port = newValue
                } else {
                    rejectedPort = newValue
                }
            }
        )
    }

    private var authenticationSection: some View {
        Section(String(localized: "Authentication")) {
            MCPTokenListView(
                tokens: tokenList,
                isStoreAvailable: manager.tokenStore != nil,
                onGenerate: { showCreateSheet = true },
                onRevoke: { id in revoke(id) },
                onDelete: { ids in delete(ids) }
            )
        }
        .task(id: manager.tokenStore.map { ObjectIdentifier($0) }) { await refreshTokens() }
        .sheet(isPresented: $showCreateSheet) {
            MCPTokenCreateSheet { name, permissions, connectionIds, expiresAt in
                await generate(name: name, permissions: permissions, connectionIds: connectionIds, expiresAt: expiresAt)
            }
        }
        .sheet(isPresented: $showRevealSheet) {
            if !revealedPlaintext.isEmpty {
                MCPTokenRevealSheet(
                    plaintext: revealedPlaintext,
                    port: manager.listeningPort ?? settings.port,
                    configuredPort: settings.port
                )
            }
        }
        .alert(tokenAlert?.title ?? "", isPresented: tokenAlertBinding, presenting: tokenAlert) { _ in
            Button(String(localized: "OK")) {}
        } message: { alert in
            Text(verbatim: alert.message)
        }
    }

    private var tokenAlertBinding: Binding<Bool> {
        Binding(
            get: { tokenAlert != nil },
            set: { isPresented in
                if !isPresented {
                    tokenAlert = nil
                }
            }
        )
    }

    private var helpSection: some View {
        Section {
            Button(String(localized: "Connect a Client…")) {
                showSetupSheet = true
            }
            .accessibilityIdentifier("mcp-connect-client")
            Button(String(localized: "View Activity…")) {
                WindowOpener.shared.openIntegrationsActivity()
            }
            .accessibilityIdentifier("mcp-view-activity")
        }
        .sheet(isPresented: $showSetupSheet) {
            MCPClientSetupSheet()
        }
    }

    private func generate(
        name: String,
        permissions: TokenPermissions,
        connectionIds: Set<UUID>?,
        expiresAt: Date?
    ) async -> MCPTokenCreateFailure? {
        guard let store = manager.tokenStore else {
            return MCPTokenCreateFailure(
                message: String(localized: "The MCP server is not running, so TablePro cannot save a token now. Start the server, then try again."),
                endsSheet: true
            )
        }
        let access: ConnectionAccess = connectionIds.map { .limited($0) } ?? .all
        do {
            let result = try await store.generate(
                name: name,
                permissions: permissions,
                connectionAccess: access,
                expiresAt: expiresAt,
                isBridgeCredential: false,
                isClaudeAgentCredential: false,
                extraScopes: []
            )
            revealedPlaintext = result.plaintext
            showCreateSheet = false
            showRevealSheet = true
            await refreshTokens()
            return nil
        } catch {
            return MCPTokenCreateFailure(message: Self.generateFailureMessage(error), endsSheet: false)
        }
    }

    private static func generateFailureMessage(_ error: Error) -> String {
        switch error as? MCPTokenStoreError {
        case .storedTokensUnreadable?:
            String(localized: "TablePro could not read the tokens saved in the Keychain, so it will not save a new one over them. Restart TablePro and try again.")
        case .randomGenerationFailed?:
            String(localized: "macOS could not generate a secure token. Try again.")
        case .keychainUnavailable?, .notSaved?, nil:
            String(localized: "TablePro could not save the token to the Keychain, so it was not created. Try again.")
        }
    }

    private func revoke(_ id: UUID) {
        Task {
            guard manager.tokenStore != nil else {
                tokenAlert = .serverNotRunning
                return
            }
            if !(await manager.revokeToken(id: id)) {
                tokenAlert = .revocationNotSaved
            }
            await refreshTokens()
        }
    }

    private func delete(_ ids: Set<UUID>) {
        Task {
            guard let store = manager.tokenStore else {
                tokenAlert = .serverNotRunning
                return
            }
            var allSaved = true
            for id in ids {
                let saved = await store.delete(tokenId: id)
                allSaved = allSaved && saved
            }
            if !allSaved {
                tokenAlert = .deletionNotSaved
            }
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        guard let store = manager.tokenStore else { return }
        tokenList = await store.list().filter { !$0.isBridgeCredential }
    }
}

private enum MCPTokenAlert: Equatable {
    case serverNotRunning
    case revocationNotSaved
    case deletionNotSaved

    var title: String {
        switch self {
        case .serverNotRunning: String(localized: "MCP Server Not Running")
        case .revocationNotSaved: String(localized: "Couldn't Save the Revocation")
        case .deletionNotSaved: String(localized: "Couldn't Save the Deletion")
        }
    }

    var message: String {
        switch self {
        case .serverNotRunning:
            String(localized: "The MCP server is not running, so TablePro cannot change its tokens now. Start the server, then try again.")
        case .revocationNotSaved, .deletionNotSaved:
            String(localized: "TablePro could not save the change to the Keychain. The token works again after TablePro restarts.")
        }
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
