import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Binding var settings: GeneralSettings
    var onResetAll: () -> Void

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Picker("Language:", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            if settings.language != LanguageLaunchState.language {
                LabeledContent {
                    Button(String(localized: "Relaunch")) {
                        UpdateCenter.shared.relaunch()
                    }
                    .accessibilityIdentifier("language-relaunch-button")
                } label: {
                    Text("Relaunch TablePro to finish switching languages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("When TablePro starts:", selection: $settings.startupBehavior) {
                ForEach(StartupBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }

            Section {
                NavigationLink(value: SettingsSubpage.commandLine) {
                    Label("Command Line Tool", systemImage: "terminal")
                }
                NavigationLink(value: SettingsSubpage.softwareUpdate) {
                    Label("Software Update", systemImage: "arrow.down.circle")
                }
            }

            LinkedFoldersSection()

            TrustedExternalConnectionsSection()

            Section {
                Toggle("Share usage data", isOn: $settings.shareAnalytics)
            } header: {
                Text("Privacy")
            } footer: {
                Text(
                    """
                    Sent to PostHog: app and macOS versions, Mac model, screen size, architecture, language, time zone, \
                    database types, connection count, first connection and query, plan prompts, sign-in and sign-out, \
                    and your account ID once you sign in. Never hostnames, credentials, queries, or rows.
                    """
                )
            }

            Section {
                Button(String(localized: "Reset All Settings to Defaults"), role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .alert(String(localized: "Reset All Settings"), isPresented: $showResetConfirmation) {
            Button(String(localized: "Reset"), role: .destructive) { onResetAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This will reset all settings across every section to their default values. AI providers, their API keys and Enable AI Features are kept.")
        }
    }
}

#Preview {
    GeneralSettingsView(
        settings: .constant(.default),
        onResetAll: {}
    )
    .frame(width: 450, height: 500)
}
