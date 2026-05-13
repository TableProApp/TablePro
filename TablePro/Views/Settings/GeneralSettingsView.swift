//
//  GeneralSettingsView.swift
//  TablePro
//

import Sparkle
import SwiftUI

struct GeneralSettingsView: View {
    @Binding var settings: GeneralSettings
    @Binding var tabSettings: TabSettings
    @Binding var historySettings: HistorySettings
    var updaterBridge: UpdaterBridge
    var onResetAll: () -> Void

    @State private var initialLanguage: AppLanguage?
    @State private var showResetConfirmation = false

    private static let standardTimeouts = [10, 20, 30, 40, 50, 60, 90, 120, 180, 300, 600]

    private var queryTimeoutOptions: [Int] {
        let current = settings.queryTimeoutSeconds
        if current > 0, !Self.standardTimeouts.contains(current) {
            return (Self.standardTimeouts + [current]).sorted()
        }
        return Self.standardTimeouts
    }

    var body: some View {
        Form {
            Picker("Language:", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            if let initial = initialLanguage, settings.language != initial {
                Text("Restart TablePro for the language change to take full effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("When TablePro starts:", selection: $settings.startupBehavior) {
                ForEach(StartupBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }

            Section("Tabs") {
                Toggle("Enable preview tabs", isOn: $tabSettings.enablePreviewTabs)
                    .help("Single-clicking a table opens a temporary tab that gets replaced on next click.")

                Toggle("Group all connections in one window", isOn: $tabSettings.groupAllConnectionTabs)
                    .help("When enabled, tabs from different connections share the same window instead of opening separate windows.")
            }

            Section("Query Execution") {
                Picker("Query timeout:", selection: $settings.queryTimeoutSeconds) {
                    Text("No limit").tag(0)
                    ForEach(queryTimeoutOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .help(String(localized: "Maximum time to wait for a query to complete. Set to 0 for no limit. Applied to new connections."))
            }

            HistorySection(settings: $historySettings)

            Section("Software Update") {
                Toggle("Automatically check for updates", isOn: $settings.automaticallyCheckForUpdates)
                    .onChange(of: settings.automaticallyCheckForUpdates) { _, newValue in
                        updaterBridge.updater.automaticallyChecksForUpdates = newValue
                    }

                Button("Check for Updates...") {
                    updaterBridge.checkForUpdates()
                }
                .disabled(!updaterBridge.canCheckForUpdates)
            }

            Section {
                Toggle("Share anonymous usage data", isOn: $settings.shareAnalytics)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Help improve TablePro by sharing anonymous usage statistics (no personal data or queries).")
            }

            Section {
                Button(String(localized: "Reset All Settings to Defaults"), role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert(String(localized: "Reset All Settings"), isPresented: $showResetConfirmation) {
            Button(String(localized: "Reset"), role: .destructive) { onResetAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This will reset all settings across every section to their default values.")
        }
        .onAppear {
            if initialLanguage == nil { initialLanguage = settings.language }
            updaterBridge.updater.automaticallyChecksForUpdates = settings.automaticallyCheckForUpdates
        }
    }
}

#Preview {
    GeneralSettingsView(
        settings: .constant(.default),
        tabSettings: .constant(.default),
        historySettings: .constant(.default),
        updaterBridge: UpdaterBridge.shared,
        onResetAll: {}
    )
    .frame(width: 450, height: 500)
}
