//
//  MCPGrantListView.swift
//  TablePro
//

import SwiftUI
import TableProMCP

/// The approvals the user has already given, so a remembered answer stays visible and revocable.
struct MCPGrantListView: View {
    @ObservedObject private var mcpServerManager = MCPServerManager.shared
    @State private var grants: [MCPConnectionGrant] = []
    @State private var connectionNames: [UUID: String] = [:]
    @State private var tokenNames: [UUID: String] = [:]

    var body: some View {
        Group {
            if grants.isEmpty {
                Text("No connections are approved yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(grants) { grant in
                    LabeledContent {
                        Button(String(localized: "Forget")) {
                            forget(grant)
                        }
                    } label: {
                        Text(name(for: grant))
                        if let client = Self.clientName(forSubject: grant.subject, tokenNames: tokenNames) {
                            Text(client)
                        }
                    }
                }

                Button(String(localized: "Forget All"), role: .destructive) {
                    forgetAll()
                }
            }
        }
        .task { await refresh() }
    }

    private func name(for grant: MCPConnectionGrant) -> String {
        connectionNames[grant.connectionId] ?? String(localized: "Deleted connection")
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

    private func forget(_ grant: MCPConnectionGrant) {
        Task {
            await MCPServerManager.shared.forgetGrant(subject: grant.subject, connectionId: grant.connectionId)
            await refresh()
        }
    }

    private func forgetAll() {
        Task {
            await MCPServerManager.shared.forgetEveryGrant()
            await refresh()
        }
    }

    private func refresh() async {
        grants = await mcpServerManager.connectionGrants()
            .sorted { $0.grantedAt > $1.grantedAt }
        connectionNames = Dictionary(
            ConnectionStorage.shared.loadConnections().map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let tokens = await mcpServerManager.tokenStore?.list() ?? []
        tokenNames = Dictionary(tokens.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
