import AppKit
import SwiftUI
import TableProMCP

struct MCPTokenListView: View {
    let tokens: [MCPAuthToken]
    let isStoreAvailable: Bool
    let onGenerate: () -> Void
    let onRevoke: (UUID) -> Void
    let onDelete: (Set<UUID>) -> Void

    @State private var selection: Set<UUID> = []
    @State private var deleteCandidates: [MCPAuthToken] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tokens.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(tokens) { token in
                        MCPTokenRow(token: token)
                            .tag(token.id)
                            .contextMenu {
                                contextMenu(for: token)
                            }
                    }
                }
                .frame(minHeight: 160)
                .onDeleteCommand(perform: deleteSelectionFromKeyboard)
            }

            HStack(spacing: 8) {
                Button {
                    onGenerate()
                } label: {
                    Label(String(localized: "Generate Token"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isStoreAvailable)
                .accessibilityLabel(String(localized: "Generate token"))

                Spacer()
            }
        }
        .alert(
            deleteAlertTitle,
            isPresented: deleteAlertBinding,
            presenting: deleteCandidates.isEmpty ? nil : deleteCandidates
        ) { candidates in
            Button(String(localized: "Cancel"), role: .cancel) {
                deleteCandidates = []
            }
            Button(String(localized: "Delete"), role: .destructive) {
                let ids = Set(candidates.map(\.id))
                onDelete(ids)
                selection.subtract(ids)
                deleteCandidates = []
            }
        } message: { candidates in
            Text(verbatim: Self.deleteAlertMessage(for: candidates))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(isStoreAvailable ? String(localized: "No tokens created") : String(localized: "Tokens are not available"))
                .foregroundStyle(.secondary)
            Text(isStoreAvailable
                ? String(localized: "Generate a token so external clients can connect with their own credentials.")
                : String(localized: "Tokens load while the MCP server is running."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func contextMenu(for token: MCPAuthToken) -> some View {
        if token.isActive {
            Button(role: .destructive) {
                onRevoke(token.id)
            } label: {
                Label(String(localized: "Revoke"), systemImage: "xmark.circle")
            }
        }
        Button {
            copyTokenId(token.id)
        } label: {
            Label(String(localized: "Copy ID"), systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            // A right-click inside a multiple selection acts on all of it, as in Finder.
            deleteCandidates = selection.contains(token.id) ? selectedTokens : [token]
        } label: {
            Label(String(localized: "Delete…"), systemImage: "trash")
        }
    }

    private var selectedTokens: [MCPAuthToken] {
        tokens.filter { selection.contains($0.id) }
    }

    private func deleteSelectionFromKeyboard() {
        deleteCandidates = selectedTokens
    }

    private func copyTokenId(_ id: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id.uuidString, forType: .string)
    }

    private var deleteAlertTitle: String {
        deleteCandidates.count > 1
            ? String(format: String(localized: "Delete %d tokens?"), deleteCandidates.count)
            : String(localized: "Delete token?")
    }

    private static func deleteAlertMessage(for candidates: [MCPAuthToken]) -> String {
        guard candidates.count > 1 else {
            return String(
                format: String(localized: "“%@” will be permanently deleted. External clients using this token will lose access immediately."),
                candidates.first?.name ?? ""
            )
        }
        return String(localized: "These tokens will be permanently deleted. External clients using them will lose access immediately.")
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { !deleteCandidates.isEmpty },
            set: { isPresented in
                if !isPresented {
                    deleteCandidates = []
                }
            }
        )
    }
}

private struct MCPTokenRow: View {
    let token: MCPAuthToken

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(token.name)

                HStack(spacing: 8) {
                    Text(token.permissions.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(token.prefix + "…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(lastUsedText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if token.extraScopes.contains(.connectionsDisplay) {
                    Text(String(localized: "Lists connections hidden from AI"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            IntegrationStatusIndicator(status: tokenStatus)
                .help(tokenStatus == .active
                    ? String(localized: "Active")
                    : tokenStatus == .expired
                        ? String(localized: "Expired")
                        : String(localized: "Revoked"))
        }
        .padding(.vertical, 2)
    }

    private var tokenStatus: IntegrationStatus {
        if token.isExpired { return .expired }
        return token.isActive ? .active : .revoked
    }

    private var lastUsedText: String {
        guard let lastUsed = token.lastUsedAt else {
            return String(localized: "Never used")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastUsed, relativeTo: .now)
    }
}
