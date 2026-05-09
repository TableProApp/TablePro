import SwiftUI
import TableProModels

struct SettingsView: View {
    @AppStorage("com.TablePro.settings.shareAnalytics") private var shareAnalytics = true
    @AppStorage(AppLockState.lockEnabledKey) private var lockEnabled = false
    @AppStorage(AppLockState.lockTimeoutKey) private var lockTimeoutSeconds = AppLockState.AutoLockTimeout.fiveMinutes.rawValue
    @AppStorage(AppPreferences.cloudSyncEnabledKey) private var cloudSyncEnabled = true
    @AppStorage(AppPreferences.defaultPageSizeKey) private var defaultPageSize = 100
    @AppStorage(AppPreferences.defaultSafeModeKey) private var defaultSafeModeRaw = SafeModeLevel.off.rawValue

    private let auth = BiometricAuthService()

    var body: some View {
        Form {
            biometricSection
            syncSection
            defaultsSection

            Section("Privacy") {
                Toggle(String(localized: "Share anonymous usage data"), isOn: $shareAnalytics)

                Text("Help improve TablePro by sharing anonymous usage statistics (no personal data or queries).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent(String(localized: "Version")) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                }
                LabeledContent(String(localized: "Build")) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-")
                }
            }
        }
        .navigationTitle(String(localized: "Settings"))
    }

    @ViewBuilder
    private var biometricSection: some View {
        let availability = auth.availability
        if availability != .unavailable {
            Section {
                Toggle(toggleLabel(for: availability), isOn: $lockEnabled)

                if lockEnabled {
                    Picker(String(localized: "Auto-Lock"), selection: $lockTimeoutSeconds) {
                        ForEach(AppLockState.AutoLockTimeout.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Locks TablePro when reopened after the selected idle time. Cold launches always require authentication.")
            }
        }
    }

    private var syncSection: some View {
        Section {
            Toggle(String(localized: "iCloud Sync"), isOn: $cloudSyncEnabled)
        } header: {
            Text("Sync")
        } footer: {
            Text("When off, connections, groups, and tags stay on this device only. Existing iCloud data is not deleted.")
        }
    }

    private var defaultsSection: some View {
        Section {
            Picker(String(localized: "Rows per Page"), selection: $defaultPageSize) {
                ForEach(AppPreferences.pageSizeOptions, id: \.self) { size in
                    Text("\(size) rows").tag(size)
                }
            }

            Picker(String(localized: "Default Safe Mode"), selection: $defaultSafeModeRaw) {
                ForEach(SafeModeLevel.allCases) { level in
                    Text(level.displayName).tag(level.rawValue)
                }
            }
        } header: {
            Text("New Connections")
        } footer: {
            Text("Defaults applied when adding a new connection and when opening a table for the first time.")
        }
    }

    private func toggleLabel(for availability: BiometricAuthService.Availability) -> String {
        switch availability {
        case .faceID: String(localized: "Require Face ID")
        case .touchID: String(localized: "Require Touch ID")
        case .opticID: String(localized: "Require Optic ID")
        case .unavailable: ""
        }
    }
}
