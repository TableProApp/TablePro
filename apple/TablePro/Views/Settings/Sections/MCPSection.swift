import SwiftUI
import TableProMCP

struct MCPSection: View {
    @Binding var settings: MCPSettings
    @ObservedObject var model: MCPSettingsModel
    let onChangeAIPolicy: () -> Void

    @State private var showsClientSetup = false

    var body: some View {
        Section {
            Toggle(isOn: $settings.enabled) {
                Text("MCP server")
                Text("Lets AI apps such as Claude and Cursor work with your connections through TablePro.")
            }
            .accessibilityIdentifier("mcp-enable-server-toggle")

            if settings.enabled {
                MCPStatusRow(configuredPort: settings.port)

                LabeledContent {
                    Button(String(localized: "Connect a Client…")) {
                        showsClientSetup = true
                    }
                    .accessibilityIdentifier("mcp-connect-client")
                } label: {
                    Text("Clients")
                    Text("Add TablePro to Claude, Cursor and other apps on this Mac.")
                }

                LabeledContent {
                    Button(String(localized: "View Activity…")) {
                        WindowOpener.shared.openIntegrationsActivity()
                    }
                    .accessibilityIdentifier("mcp-view-activity")
                } label: {
                    Text("Activity")
                    Text("Requests, approvals and connected clients.")
                }
            }
        }
        .sheet(isPresented: $showsClientSetup) {
            MCPClientSetupSheet()
        }

        if settings.enabled {
            accessSection
            serverSection
        }
    }

    private var accessSection: some View {
        Section {
            Picker(selection: $settings.connectionApproval) {
                ForEach(MCPConnectionApproval.allCases) { approval in
                    Text(approval.displayName).tag(approval)
                }
            } label: {
                Text("Approval")
                Text(settings.connectionApproval.explanation)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("mcp-approval-picker")

            SettingsDrillRow(
                route: SettingsRoute.page(.mcpApprovals),
                title: "Approved connections",
                value: approvalsValue,
                subtitle: settings.connectionApproval != .oncePerConnection
                    ? "Used only with Ask Once for Each Connection."
                    : nil
            )

            SettingsDrillRow(route: SettingsRoute.page(.mcpTokens), title: "Tokens", value: tokensValue)

            MCPDefaultAIPolicyRow(onChange: onChangeAIPolicy)

            Toggle(isOn: $settings.allowsHiddenConnectionListing) {
                Text("Allow apps to list connections hidden from AI")
                // swiftlint:disable:next line_length
                Text("A paired app, such as a launcher, can ask when it pairs to show connections whose AI Policy is Never, with their user names. It still cannot query them. Turning this off stops every app at once.")
            }
            .accessibilityIdentifier("mcp-hidden-connection-listing-toggle")

            // swiftlint:disable:next line_length
            SettingsHelpRow("Approval is separate from what a client may reach. A connection blocked for external clients stays blocked, a read-only one stays read only, and Safe Mode still confirms destructive statements.")
        } header: {
            Text("Access")
        }
    }

    private var serverSection: some View {
        Section {
            SettingsNumberField(
                "Port",
                value: $settings.port,
                range: MCPSettings.portRange,
                width: 64,
                invalid: .reject(String(
                    format: String(localized: "Choose a port from %d to %d."),
                    MCPSettings.portRange.lowerBound,
                    MCPSettings.portRange.upperBound
                )),
                identifier: "mcp-port-field"
            )

            SettingsNumberField(
                "Default row limit",
                subtitle: "Rows a query returns when the client sets no limit.",
                value: $settings.defaultRowLimit,
                range: settings.requestableRowLimitRange,
                step: 100,
                unit: "rows",
                width: 72,
                identifier: "mcp-default-row-limit-field"
            )

            SettingsNumberField(
                "Maximum row limit",
                subtitle: "The most rows a client can ask for.",
                value: maxRowLimit,
                range: SettingsValidationRules.mcpRowLimitRange,
                step: 1_000,
                unit: "rows",
                width: 72,
                identifier: "mcp-max-row-limit-field"
            )

            SettingsNumberField(
                "Query timeout",
                value: $settings.queryTimeoutSeconds,
                range: SettingsValidationRules.mcpQueryTimeoutRange,
                step: 5,
                unit: "seconds",
                width: 56,
                identifier: "mcp-query-timeout-field"
            )

            Toggle("Log MCP queries in history", isOn: $settings.logQueriesInHistory)
                .accessibilityIdentifier("mcp-log-queries-toggle")
        } header: {
            Text("Server")
        }
    }

    // A lower maximum pulls the default down with it in the same write.
    private var maxRowLimit: Binding<Int> {
        Binding(
            get: { settings.maxRowLimit },
            set: { settings = settings.withMaxRowLimit($0) }
        )
    }

    private var approvalsValue: String? {
        guard model.hasLoadedGrants else { return nil }
        return model.grants.isEmpty ? String(localized: "None") : SettingsFormat.count(model.grants.count)
    }

    private var tokensValue: String? {
        guard model.tokenStore != nil else { return String(localized: "Unavailable") }
        guard model.hasLoadedTokens else { return nil }
        if model.tokens.isEmpty { return String(localized: "None") }
        return String(format: String(localized: "%lld active"), model.activeTokenCount)
    }
}

private struct MCPStatusRow: View {
    @ObservedObject private var manager = MCPServerManager.shared
    let configuredPort: Int

    var body: some View {
        let presentation = MCPServerStatusPresentation(state: manager.state, configuredPort: configuredPort)
        LabeledContent {
            HStack(spacing: 8) {
                IntegrationStatusIndicator(status: presentation.status, label: presentation.title)
                if presentation.offersRetry {
                    Button(String(localized: "Try Again")) {
                        manager.retry()
                    }
                    .accessibilityIdentifier("mcp-status-try-again")
                }
            }
        } label: {
            Text("Status")
            if let detail = presentation.detail {
                Text(verbatim: detail)
                    .textSelection(.enabled)
            }
        }
    }
}

// Read only: the policy belongs to AI, and MCP enforces it for connections without their own.
private struct MCPDefaultAIPolicyRow: View {
    @ObservedObject private var ai = AppSettingsManager.shared.aiSlice
    let onChange: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(ai.value.defaultConnectionPolicy.displayName)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Change…"), action: onChange)
                    .accessibilityIdentifier("mcp-default-ai-policy-change")
            }
        } label: {
            Text("Default AI policy")
            Text("Connections without their own AI Policy use it. Clients cannot query a connection set to Never.")
        }
    }
}
