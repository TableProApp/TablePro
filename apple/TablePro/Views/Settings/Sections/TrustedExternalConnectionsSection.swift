//
//  TrustedExternalConnectionsSection.swift
//  TablePro
//

import SwiftUI

struct TrustedExternalConnectionsSection: View {
    private let store: ExternalConnectionTrustStore

    @State private var entries: [TrustedExternalConnection] = []

    init(store: ExternalConnectionTrustStore = .shared) {
        self.store = store
    }

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("No links are trusted yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    LabeledContent {
                        Button("Forget") {
                            store.revoke(entry.key)
                            refresh()
                        }
                    } label: {
                        Text(entry.key.displayDescription)
                        if let name = savedConnectionName(of: entry) {
                            Text(String(format: String(localized: "Saved connection “%@”"), name))
                        }
                    }
                }

                Button(String(localized: "Forget All"), role: .destructive) {
                    store.revokeAll()
                    refresh()
                }
            }
        } header: {
            Text("Trusted Links")
        } footer: {
            Text("Links you chose to always allow. TablePro connects without asking. Only connections on this machine can be trusted.")
        }
        .onAppear(perform: refresh)
    }

    // Two saved connections can share type, host, database and user, so the name tells their entries apart.
    private func savedConnectionName(of entry: TrustedExternalConnection) -> String? {
        entry.key.savedConnectionId.flatMap { ConnectionStorage.shared.loadConnection(id: $0)?.name }
    }

    private func refresh() {
        entries = store.entries().sorted { $0.trustedAt > $1.trustedAt }
    }
}
