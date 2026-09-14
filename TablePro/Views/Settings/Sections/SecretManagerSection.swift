//
//  SecretManagerSection.swift
//  TablePro
//

import SwiftUI

/// The one command every connection set to "Shared secret manager command" runs.
///
/// Connections backed by the same vault differ only in the path their own fields spell out, so the
/// command lives here once and each connection fills it in. Editing it drops every cached password
/// it produced, which is what makes a vault move take effect on the next connect.
struct SecretManagerSection: View {
    @State private var settings = AppSettingsManager.shared
    @State private var didClearCache = false

    var body: some View {
        Section {
            TextField(
                String(localized: "Command"),
                text: $settings.secretManager.defaultCommand,
                axis: .vertical
            )
            .lineLimit(1 ... 4)
            .font(.system(.body, design: .monospaced))
            .accessibilityIdentifier("secret-manager-command")

            LabeledContent(String(localized: "Placeholders:")) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PasswordCommandTemplate.placeholders) { placeholder in
                        Text("\(placeholder.token)  \(placeholder.summary)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Picker(String(localized: "Keep fetched passwords:"), selection: $settings.secretManager.cacheLifetime) {
                ForEach(SecretCacheLifetime.allCases) { lifetime in
                    Text(lifetime.displayName).tag(lifetime)
                }
            }
            .accessibilityIdentifier("secret-manager-cache-lifetime")

            HStack(spacing: 8) {
                Button(String(localized: "Forget Fetched Passwords")) {
                    Task {
                        await ResolvedPasswordCache.shared.invalidateAll()
                        didClearCache = true
                    }
                }
                .accessibilityIdentifier("secret-manager-clear-cache")

                if didClearCache {
                    Text("Cleared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Secret Manager")
        } footer: {
            Text("""
                Runs on every connect for connections set to the shared command, and prints the \
                password on stdout. Fetched passwords are kept in memory only, never written to \
                disk, and never synced.
                """)
        }
        .onChange(of: settings.secretManager) { _, _ in didClearCache = false }
    }
}
