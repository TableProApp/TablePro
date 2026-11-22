import SwiftUI
import TableProMCP

// The Approved Connections page: a remembered answer stays visible here and can be forgotten.
struct MCPGrantListView: View {
    @ObservedObject var model: MCPSettingsModel
    let approval: MCPConnectionApproval

    @State private var isConfirmingForgetAll = false

    var body: some View {
        Form {
            if approval != .oncePerConnection {
                Section {
                    SettingsHelpRow(String(
                        format: String(localized: "Approval is set to “%@”, so these approvals are not used now. They apply again if you choose Ask Once for Each Connection."),
                        approval.displayName
                    ))
                }
            }

            Section {
                if model.grants.isEmpty {
                    if model.hasLoadedGrants {
                        Text("No approved connections. A connection a client may reach without asking again appears here.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.grants) { grant in
                        row(grant)
                    }
                }
            } footer: {
                if !model.grants.isEmpty {
                    SettingsSectionActions {
                        Button(String(localized: "Forget All…"), role: .destructive) {
                            isConfirmingForgetAll = true
                        }
                        .accessibilityIdentifier("mcp-grants-forget-all")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.mcpApprovals.pageIdentifier)
        .alert(String(localized: "Forget All Approvals?"), isPresented: $isConfirmingForgetAll) {
            Button(String(localized: "Forget All"), role: .destructive) {
                Task { await model.forgetEveryGrant() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Clients ask again the next time they reach a connection.")
        }
    }

    private func row(_ grant: MCPConnectionGrant) -> some View {
        let connection = model.connectionNames[grant.connectionId] ?? String(localized: "Deleted connection")
        let client = Self.clientName(forSubject: grant.subject, tokenNames: model.tokenNames)
        let forgetLabel = client.map {
            String(format: String(localized: "Forget %1$@ for %2$@"), connection, $0)
        } ?? String(format: String(localized: "Forget %@"), connection)
        return LabeledContent {
            Button(String(localized: "Forget")) {
                forget(grant)
            }
            .accessibilityLabel(forgetLabel)
        } label: {
            Text(verbatim: connection)
            Text(verbatim: Self.detail(client: client, grantedAt: grant.grantedAt))
        }
        .contextMenu {
            Button(String(localized: "Forget")) {
                forget(grant)
            }
        }
    }

    private func forget(_ grant: MCPConnectionGrant) {
        Task { await model.forgetGrant(grant) }
    }

    private static func detail(client: String?, grantedAt: Date) -> String {
        let date = grantedAt.formatted(date: .abbreviated, time: .omitted)
        guard let client else {
            return String(format: String(localized: "Approved %@"), date)
        }
        return String(format: String(localized: "%1$@, approved %2$@"), client, date)
    }

    // Two clients approved for one connection would otherwise show as two identical rows.
    nonisolated static func clientName(forSubject subject: String, tokenNames: [UUID: String]) -> String? {
        switch subject {
        case MCPGrantSubject.bridge.storageKey:
            return IntegrationsFormatting.displayTokenName(MCPTokenStore.stdioBridgeTokenName)
        case MCPGrantSubject.claudeAgent.storageKey:
            return AIProviderType.claudeAgent.displayName
        default:
            return UUID(uuidString: subject).flatMap { tokenNames[$0] }.map(IntegrationsFormatting.displayTokenName)
        }
    }
}
