import AppKit
import SwiftUI

struct MCPTokenListView: View {
    let tokens: [MCPAuthToken]
    let onGenerate: () -> Void
    let onRevoke: (UUID) -> Void
    let onDelete: (UUID) -> Void

    @State private var selection: Set<UUID> = []
    @State private var deleteCandidate: MCPAuthToken?

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
                .accessibilityLabel(String(localized: "Generate token"))

                Spacer()
            }
        }
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding, presenting: deleteCandidate) { token in
            Button(String(localized: "Cancel"), role: .cancel) {
                deleteCandidate = nil
            }
            Button(String(localized: "Delete"), role: .destructive) {
                onDelete(token.id)
                selection.remove(token.id)
                deleteCandidate = nil
            }
        } message: { token in
            Text(String(format: String(localized: "“%@” will be permanently deleted. External clients using this token will lose access immediately."), token.name))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(String(localized: "No tokens created"))
                .foregroundStyle(.secondary)
            Text(String(localized: "Generate a token so external clients can connect with their own credentials."))
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
            deleteCandidate = token
        } label: {
            Label(String(localized: "Delete…"), systemImage: "trash")
        }
    }

    private func deleteSelectionFromKeyboard() {
        guard let id = selection.first, let token = tokens.first(where: { $0.id == id }) else { return }
        deleteCandidate = token
    }

    private func copyTokenId(_ id: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id.uuidString, forType: .string)
    }

    private var deleteAlertTitle: String {
        String(localized: "Delete token?")
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    deleteCandidate = nil
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
                HStack(spacing: 6) {
                    Text(token.name)

                    Text(token.permissions.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(permissionColor.opacity(0.15))
                        .foregroundStyle(permissionColor)
                        .clipShape(Capsule())
                }

                HStack(spacing: 8) {
                    Text(token.prefix + "...")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(lastUsedText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

    private var permissionColor: Color {
        switch token.permissions {
        case .readOnly: Color(nsColor: .systemBlue)
        case .readWrite: Color(nsColor: .systemOrange)
        case .fullAccess: Color(nsColor: .systemRed)
        }
    }
}
