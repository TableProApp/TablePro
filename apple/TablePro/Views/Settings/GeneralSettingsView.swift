import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsSlice<GeneralSettings>
    let onResetAll: () -> Void
    @ObservedObject private var policy = ManagedPolicyCenter.shared

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $settings.value.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .accessibilityIdentifier("general-language-picker")

                if settings.value.language != LanguageLaunchState.language {
                    LabeledContent {
                        Button(String(localized: "Relaunch")) {
                            UpdateCenter.shared.relaunch()
                        }
                        .accessibilityIdentifier("language-relaunch-button")
                    } label: {
                        Text("Relaunch TablePro to finish switching languages.")
                    }
                }

                Picker("When TablePro starts", selection: $settings.value.startupBehavior) {
                    ForEach(StartupBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .accessibilityIdentifier("general-startup-picker")
            }

            Section {
                SoftwareUpdateDrillRow()
                SettingsDrillRow(route: SettingsRoute.page(.commandLineTool), title: SettingsPage.commandLineTool.title)
            }

            Section {
                Toggle(isOn: shareUsageData) {
                    Text("Share usage data")
                    if policy.snapshot.allowsUsageData {
                        Text(
                            """
                            Sent to PostHog: app and macOS versions, Mac model, screen size, architecture, language, \
                            time zone, database types, connection count, first connection and query, plan prompts, \
                            sign-in and sign-out, and your account ID once you sign in. Never hostnames, credentials, \
                            queries, or rows.
                            """
                        )
                    } else {
                        Text("Managed by your organization")
                            .accessibilityIdentifier("general-share-usage-managed")
                    }
                }
                .disabled(!policy.snapshot.allowsUsageData)
                .accessibilityIdentifier("general-share-usage-toggle")
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent {
                    Button(String(localized: "Reset…"), role: .destructive) {
                        showResetConfirmation = true
                    }
                    .accessibilityLabel(String(localized: "Reset All Settings…"))
                    .accessibilityIdentifier("general-reset-all-button")
                } label: {
                    Text("Reset all settings")
                    Text("Returns every section to its defaults.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-general")
        .alert(String(localized: "Reset all settings?"), isPresented: $showResetConfirmation) {
            Button(String(localized: "Reset"), role: .destructive) { onResetAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                """
                Every section returns to its default values. AI providers and their API keys, Enable AI features, \
                Share usage data, linked folders, trusted links, connections and history are kept.
                """
            )
        }
    }
}

extension GeneralSettingsView {
    // UsageDataAllowed=false shows the switch off and leaves the person's own choice as it was.
    private var shareUsageData: Binding<Bool> {
        guard policy.snapshot.allowsUsageData else { return .constant(false) }
        return $settings.value.shareAnalytics
    }
}

// Only this row re-renders when the update status changes.
private struct SoftwareUpdateDrillRow: View {
    @ObservedObject private var updates = UpdateCenter.shared

    var body: some View {
        SettingsDrillRow(
            route: SettingsRoute.page(.softwareUpdate),
            title: SettingsPage.softwareUpdate.title,
            value: updates.status.indicatorTitle
        )
    }
}
