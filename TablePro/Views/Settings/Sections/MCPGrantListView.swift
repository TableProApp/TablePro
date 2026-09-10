//
//  MCPGrantListView.swift
//  TablePro
//

import SwiftUI

/// The approvals the user has already given, so a remembered answer stays visible and revocable.
struct MCPGrantListView: View {
    @State private var grants: [MCPConnectionGrant] = []
    @State private var connectionNames: [UUID: String] = [:]

    var body: some View {
        Group {
            if grants.isEmpty {
                Text("No connections are approved yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(grants) { grant in
                    LabeledContent(name(for: grant)) {
                        Button(String(localized: "Forget")) {
                            forget(grant)
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
        grants = await MCPServerManager.shared.connectionGrants()
            .sorted { $0.grantedAt > $1.grantedAt }
        connectionNames = Dictionary(
            ConnectionStorage.shared.loadConnections().map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
