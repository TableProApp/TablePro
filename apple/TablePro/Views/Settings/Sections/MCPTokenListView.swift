import SwiftUI
import TableProMCP

enum MCPTokenAlert: Equatable {
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

// The Tokens page: a full-page list, so a long list of clients scrolls on its own.
struct MCPTokenListView: View {
    private struct Confirmation: Identifiable {
        enum Kind {
            case revoke
            case delete
        }

        let kind: Kind
        let tokens: [MCPAuthToken]

        var id: [UUID] { tokens.map(\.id) }
    }

    @ObservedObject var model: MCPSettingsModel
    let configuredPort: () -> Int

    @State private var selection: Set<UUID> = []
    @State private var confirmation: Confirmation?
    @State private var tokenAlert: MCPTokenAlert?
    @State private var showsCreateSheet = false

    var body: some View {
        SettingsFullPageList {
            List(selection: $selection) {
                ForEach(rows) { token in
                    MCPTokenRow(
                        token: token,
                        onRevoke: token.isActive ? { requestRevoke([token]) } : nil,
                        onDelete: { requestDelete([token]) }
                    )
                    .tag(token.id)
                }
            }
            .accessibilityIdentifier("mcp-tokens-list")
            .contextMenu(forSelectionType: UUID.self) { ids in
                menu(for: ids)
            }
            .onDeleteCommand {
                requestDelete(tokens(in: selection))
            }
            .alert(
                confirmationTitle,
                isPresented: confirmationBinding,
                presenting: confirmation
            ) { confirmation in
                switch confirmation.kind {
                case .revoke:
                    Button(String(localized: "Revoke"), role: .destructive) {
                        revoke(confirmation.tokens)
                    }
                case .delete:
                    Button(String(localized: "Delete"), role: .destructive) {
                        delete(confirmation.tokens)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: { confirmation in
                Text(verbatim: Self.confirmationMessage(confirmation))
            }
        } emptyState: {
            emptyState
        } bar: {
            SettingsListBar(
                addLabel: String(localized: "Generate Token"),
                removeLabel: String(localized: "Delete"),
                canAdd: model.tokenStore != nil,
                canRemove: !tokens(in: selection).isEmpty,
                addHelp: String(localized: "Generate Token…"),
                removeHelp: String(localized: "Delete…"),
                addIdentifier: "mcp-token-add",
                removeIdentifier: "mcp-token-remove",
                onAdd: { showsCreateSheet = true },
                onRemove: { requestDelete(tokens(in: selection)) }
            )
        }
        .sheet(isPresented: $showsCreateSheet) {
            MCPTokenCreateSheet { request in
                await model.generate(request, configuredPort: configuredPort())
            }
        }
        .alert(tokenAlert?.title ?? "", isPresented: tokenAlertBinding, presenting: tokenAlert) { _ in
            Button(String(localized: "OK")) {}
        } message: { alert in
            Text(verbatim: alert.message)
        }
        .onChange(of: model.tokens.map(\.id)) { ids in
            selection.formIntersection(ids)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.mcpTokens.pageIdentifier)
    }

    // Tokens from a stopped server stay loaded but are not shown, since nothing can change them.
    private var rows: [MCPAuthToken] {
        model.tokenStore == nil ? [] : model.tokens
    }

    private func tokens(in ids: Set<UUID>) -> [MCPAuthToken] {
        rows.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.tokenStore == nil {
            UnavailableStateView(
                String(localized: "Tokens Unavailable"),
                systemImage: "key",
                description: Text("Tokens load while the MCP server is running.")
            )
        } else if model.hasLoadedTokens && model.tokens.isEmpty {
            UnavailableStateView {
                Label("No Tokens", systemImage: "key")
            } description: {
                Text("Generate a token so external clients can connect with their own credentials.")
            } actions: {
                Button(String(localized: "Generate Token…")) {
                    showsCreateSheet = true
                }
                .accessibilityIdentifier("mcp-token-generate-empty")
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        let targets = tokens(in: ids)
        if !targets.isEmpty {
            if targets.contains(where: { $0.isActive }) {
                Button(String(localized: "Revoke…")) {
                    requestRevoke(targets)
                }
            }
            if targets.count == 1, let token = targets.first {
                Button(String(localized: "Copy ID")) {
                    ClipboardService.shared.writeText(token.id.uuidString)
                }
            }
            Divider()
            Button(String(localized: "Delete…"), role: .destructive) {
                requestDelete(targets)
            }
        }
    }

    private func requestRevoke(_ targets: [MCPAuthToken]) {
        let active = targets.filter { $0.isActive }
        guard !active.isEmpty else { return }
        confirmation = Confirmation(kind: .revoke, tokens: active)
    }

    private func requestDelete(_ targets: [MCPAuthToken]) {
        guard !targets.isEmpty else { return }
        confirmation = Confirmation(kind: .delete, tokens: targets)
    }

    private func revoke(_ targets: [MCPAuthToken]) {
        let ids = Set(targets.map(\.id))
        Task {
            tokenAlert = await model.revoke(ids)
        }
    }

    private func delete(_ targets: [MCPAuthToken]) {
        let ids = Set(targets.map(\.id))
        selection.subtract(ids)
        Task {
            tokenAlert = await model.delete(ids)
        }
    }

    private var confirmationTitle: String {
        guard let confirmation else { return "" }
        let count = confirmation.tokens.count
        let name = confirmation.tokens.first?.name ?? ""
        switch confirmation.kind {
        case .revoke:
            return count > 1
                ? String(format: String(localized: "Revoke %d Tokens?"), count)
                : String(format: String(localized: "Revoke “%@”?"), name)
        case .delete:
            return count > 1
                ? String(format: String(localized: "Delete %d Tokens?"), count)
                : String(format: String(localized: "Delete “%@”?"), name)
        }
    }

    private static func confirmationMessage(_ confirmation: Confirmation) -> String {
        let isSingle = confirmation.tokens.count == 1
        switch confirmation.kind {
        case .revoke:
            return isSingle
                ? String(localized: "Apps using it lose access now. This can't be undone.")
                : String(localized: "Apps using them lose access now. This can't be undone.")
        case .delete:
            return isSingle
                ? String(localized: "Apps using it lose access now, and the token leaves this list.")
                : String(localized: "Apps using them lose access now, and the tokens leave this list.")
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { isPresented in
                if !isPresented {
                    confirmation = nil
                }
            }
        )
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
}

private struct MCPTokenRow: View {
    let token: MCPAuthToken
    let onRevoke: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: token.name)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(token.permissions.displayName)
                    Text(verbatim: "·")
                    connectionsText
                    Text(verbatim: "·")
                    Text(verbatim: token.prefix + "…")
                        .font(.subheadline.monospaced())
                    Text(verbatim: "·")
                    Text(lastUsedText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if token.extraScopes.contains(.connectionsDisplay) {
                    Text("Lists connections hidden from AI")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            status
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let onRevoke {
                Button(String(localized: "Revoke"), action: onRevoke)
            }
            Button(String(localized: "Delete"), action: onDelete)
        }
    }

    @ViewBuilder
    private var connectionsText: some View {
        switch token.connectionAccess {
        case .all:
            Text("All connections")
        case .limited(let ids):
            Text("^[\(ids.count) connection](inflect: true)")
        }
    }

    @ViewBuilder
    private var status: some View {
        if !token.isActive {
            IntegrationStatusIndicator(status: .revoked, label: String(localized: "Revoked"))
        } else if token.isExpired {
            IntegrationStatusIndicator(status: .expired, label: String(localized: "Expired"))
        } else if let expiresAt = token.expiresAt {
            Text(String(format: String(localized: "Expires %@"), expiresAt.formatted(date: .abbreviated, time: .omitted)))
                .foregroundStyle(.secondary)
        } else {
            Text("Active")
                .foregroundStyle(.secondary)
        }
    }

    private var lastUsedText: String {
        guard let lastUsed = token.lastUsedAt else {
            return String(localized: "Never used")
        }
        return String(format: String(localized: "Last used %@"), lastUsed.formatted(.relative(presentation: .named)))
    }
}
