//
//  TrustedDevelopersView.swift
//  TablePro
//

import SwiftUI

struct TrustedDevelopersView: View {
    @State private var developers: [TrustedPluginDeveloper] = []
    @State private var pendingRevoke: TrustedPluginDeveloper?

    private let store: any PluginDeveloperTrustChecking

    init(store: any PluginDeveloperTrustChecking = PluginDeveloperTrustStore.shared) {
        self.store = store
    }

    var body: some View {
        Section {
            if developers.isEmpty {
                Text("No plugin developers trusted yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(developers) { developer in
                    row(for: developer)
                }
            }
        } header: {
            Text("Trusted Plugin Developers")
        } footer: {
            Text(
                "Plugins signed by these developers install and load without asking. "
                    + "Removing one stops every plugin they signed from loading."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            revokeTitle,
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop Trusting", role: .destructive) {
                if let developer = pendingRevoke {
                    store.revoke(teamID: developer.identity.teamID)
                    reload()
                }
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: {
            Text("Plugins signed by this developer stop loading the next time TablePro starts.")
        }
    }

    private func row(for developer: TrustedPluginDeveloper) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(developer.identity.name)
                Text(developer.identity.teamID)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            Button("Stop Trusting") { pendingRevoke = developer }
                .buttonStyle(.borderless)
        }
    }

    private var revokeTitle: String {
        guard let developer = pendingRevoke else { return String(localized: "Stop trusting this developer?") }
        return String(format: String(localized: "Stop trusting %@?"), developer.identity.name)
    }

    private func reload() {
        developers = store.trustedDevelopers()
    }
}
