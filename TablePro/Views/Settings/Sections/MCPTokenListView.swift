//
//  MCPTokenListView.swift
//  TablePro
//

import SwiftUI

struct MCPTokenListView: View {
    let tokens: [MCPAuthToken]
    let onGenerate: () -> Void
    let onRevoke: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        if tokens.isEmpty {
            Text("No tokens created")
                .foregroundStyle(.secondary)
        } else {
            ForEach(tokens) { token in
                MCPTokenRow(
                    token: token,
                    onRevoke: { onRevoke(token.id) },
                    onDelete: { onDelete(token.id) }
                )
            }
        }

        Button("Generate New Token", action: onGenerate)
    }
}

// MARK: - Token Row

private struct MCPTokenRow: View {
    let token: MCPAuthToken
    let onRevoke: () -> Void
    let onDelete: () -> Void

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

                    lastUsedText
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            statusIndicator

            contextMenuButton
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(token.isEffectivelyActive ? .green : .red)
            .frame(width: 8, height: 8)
            .help(statusHelpText)
    }

    private var statusHelpText: String {
        if token.isExpired {
            return String(localized: "Expired")
        }
        return token.isActive ? String(localized: "Active") : String(localized: "Revoked")
    }

    private var lastUsedText: some View {
        Group {
            if let lastUsed = token.lastUsedAt {
                Text(lastUsed, style: .relative) + Text(" ago")
            } else {
                Text("Never used")
            }
        }
    }

    private var permissionColor: Color {
        switch token.permissions {
        case .readOnly: .blue
        case .readWrite: .orange
        case .fullAccess: .red
        }
    }

    private var contextMenuButton: some View {
        Menu {
            if token.isActive {
                Button(role: .destructive) {
                    onRevoke()
                } label: {
                    Label("Deactivate", systemImage: "xmark.circle")
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }
}
