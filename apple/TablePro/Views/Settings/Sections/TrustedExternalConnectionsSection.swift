import Combine
import SwiftUI

internal struct TrustedLinkEntry: Identifiable, Equatable, Sendable {
    internal let key: ExternalConnectionTrustKey
    internal let title: String
    // Two saved connections can share type, host, database and user, so the name tells their entries apart.
    internal let savedConnectionName: String?

    internal var id: ExternalConnectionTrustKey { key }
}

@MainActor
internal final class TrustedLinksModel: ObservableObject {
    @Published internal private(set) var entries: [TrustedLinkEntry] = []

    private let store: ExternalConnectionTrustStore
    private let savedConnectionNames: @MainActor () -> [UUID: String]
    private var changes: AnyCancellable?

    internal init(
        store: ExternalConnectionTrustStore = .shared,
        savedConnectionNames: @escaping @MainActor () -> [UUID: String] = TrustedLinksModel.savedConnectionNames
    ) {
        self.store = store
        self.savedConnectionNames = savedConnectionNames
        refresh()
        changes = store.changes.sink { [weak self] _ in
            self?.refresh()
        }
    }

    internal func refresh() {
        let trusted = store.entries().sorted { $0.trustedAt > $1.trustedAt }
        let names = trusted.contains { $0.key.savedConnectionId != nil } ? savedConnectionNames() : [:]
        let updated = trusted.map { entry in
            TrustedLinkEntry(
                key: entry.key,
                title: entry.key.displayDescription,
                savedConnectionName: entry.key.savedConnectionId.flatMap { names[$0] }
            )
        }
        guard updated != entries else { return }
        entries = updated
    }

    internal func forget(_ key: ExternalConnectionTrustKey) {
        store.revoke(key)
    }

    internal func forgetAll() {
        store.revokeAll()
    }

    static func savedConnectionNames() -> [UUID: String] {
        Dictionary(
            ConnectionStorage.shared.loadConnections().map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

internal struct TrustedLinksPage: View {
    @EnvironmentObject private var model: TrustedLinksModel
    @State private var isConfirmingForgetAll = false

    internal var body: some View {
        Form {
            Section {
                if model.entries.isEmpty {
                    Text("No trusted links")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.entries) { entry in
                        TrustedLinkRow(entry: entry) {
                            model.forget(entry.key)
                        }
                    }
                }

                SettingsHelpRow(
                    "A link you chose Always Allow for connects without asking again. Only connections on this Mac can be trusted."
                )
            } footer: {
                SettingsSectionActions {
                    Button(String(localized: "Forget All…")) {
                        isConfirmingForgetAll = true
                    }
                    .disabled(model.entries.isEmpty)
                    .accessibilityIdentifier("trusted-links-forget-all-button")
                }
            }
        }
        .formStyle(.grouped)
        .alert(String(localized: "Forget All Trusted Links?"), isPresented: $isConfirmingForgetAll) {
            Button(String(localized: "Forget All"), role: .destructive) {
                model.forgetAll()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Each link asks again before it connects. This applies only to this Mac.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.trustedLinks.pageIdentifier)
    }
}

private struct TrustedLinkRow: View {
    let entry: TrustedLinkEntry
    let onForget: () -> Void

    var body: some View {
        SettingsRecordRow(title: entry.title, subtitle: subtitle) {
            Button(String(localized: "Forget"), action: onForget)
                .accessibilityLabel(String(format: String(localized: "Forget %@"), entry.title))
        }
        .help(entry.title)
        .contextMenu {
            Button(String(localized: "Forget"), action: onForget)
        }
    }

    private var subtitle: String? {
        entry.savedConnectionName.map { String(format: String(localized: "Saved connection “%@”"), $0) }
    }
}
