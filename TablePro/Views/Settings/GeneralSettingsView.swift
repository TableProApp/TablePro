//
//  GeneralSettingsView.swift
//  TablePro
//
//  Settings for startup behavior and confirmations
//

import Sparkle
import SwiftUI

struct GeneralSettingsView: View {
    @Binding var settings: GeneralSettings
    var updaterBridge: UpdaterBridge
    @Bindable private var settingsManager = AppSettingsManager.shared
    @State private var initialLanguage: AppLanguage?

    private static let standardTimeouts = [10, 20, 30, 40, 50, 60, 90, 120, 180, 300, 600]

    /// Timeout options including the current value if it's non-standard
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

            Section("Query Execution") {
                Picker("Query timeout:", selection: $settings.queryTimeoutSeconds) {
                    Text("No limit").tag(0)
                    ForEach(queryTimeoutOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .help("Maximum time to wait for a query to complete. Set to 0 for no limit. Applied to new connections.")
            }

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

            Section("Privacy") {
                Toggle("Share anonymous usage data", isOn: $settings.shareAnalytics)

                Text("Help improve TablePro by sharing anonymous usage statistics (no personal data or queries).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tabs") {
                Toggle("Enable preview tabs", isOn: $settingsManager.tabs.enablePreviewTabs)

                Text("Single-clicking a table opens a temporary tab that gets replaced on next click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            if initialLanguage == nil {
                initialLanguage = settings.language
            }
            updaterBridge.updater.automaticallyChecksForUpdates = settings.automaticallyCheckForUpdates
        }
    }
}

#Preview {
    GeneralSettingsView(
        settings: .constant(.default),
        updaterBridge: UpdaterBridge()
    )
    .frame(width: 450, height: 300)
}
