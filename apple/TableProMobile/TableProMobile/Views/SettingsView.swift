import SwiftUI
import TableProFFI
import TableProModels

struct SettingsView: View {
    private static let privacyPolicyURL = URL(string: "https://tablepro.app/privacy")

    @Environment(AppState.self) private var appState

    @AppStorage(AppLockState.lockEnabledKey) private var lockEnabled = false
    @AppStorage(AppLockState.lockTimeoutKey) private var lockTimeoutSeconds = AppLockState.AutoLockTimeout.fiveMinutes.rawValue
    @AppStorage(AppPreferences.defaultPageSizeKey) private var defaultPageSize = 100
    @AppStorage(AppPreferences.defaultSafeModeKey) private var defaultSafeModeRaw = SafeModeLevel.off.rawValue
    @AppStorage(AppPreferences.hideQueryPreviewInActivityKey) private var hideQueryPreviewInActivity = false

    private let auth = BiometricAuthService()

    var body: some View {
        Form {
            AccountSection(account: appState.account, managed: appState.onboarding.managed)
            biometricSection
            syncSection
            defaultsSection
            usageDataSection
            liveActivitySection
            aboutSection
        }
        .navigationTitle(String(localized: "Settings"))
    }

    @ViewBuilder
    private var biometricSection: some View {
        let availability = auth.availability
        if availability != .unavailable {
            Section {
                Toggle(toggleLabel(for: availability), isOn: lockBinding)

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
                if lockEnabled {
                    Text("Locks TablePro when reopened after the selected idle time. Cold launches always require authentication.")
                }
            }
        }
    }

    // The provider and its state on one row; the page behind it holds the picker, the moves and what syncs.
    private var syncSection: some View {
        Section {
            NavigationLink {
                SyncSettingsPage()
            } label: {
                LabeledContent(String(localized: "Sync"), value: appState.onboarding.syncProvider.title)
            }
            .accessibilityIdentifier("settings-sync-row")
        } footer: {
            if appState.onboarding.managed.locksSyncProvider {
                Text("Your organization manages how TablePro syncs on this device.")
            }
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

    private var usageDataSection: some View {
        Section {
            Toggle(String(localized: "Share Usage Data"), isOn: usageDataBinding)
                .disabled(!appState.onboarding.managed.allowsUsageData)
        } header: {
            Text("Privacy")
        } footer: {
            if !appState.onboarding.managed.allowsUsageData {
                Text("Your organization turned off usage data for TablePro.")
            } else {
                usageDataExplanation
            }
        }
    }

    private var usageDataExplanation: some View {
        Text("Off until you turn it on. Sent to PostHog with a random ID: app and iOS versions, device model, screen size, language, time zone, network type, database types, connection count, and first connection and query. PostHog derives an approximate location from your IP address. Never hostnames, credentials, queries, or rows.")
    }

    private var liveActivitySection: some View {
        Section {
            Toggle(String(localized: "Hide Query"), isOn: $hideQueryPreviewInActivity)
        } header: {
            Text("Live Activities")
        } footer: {
            Text("When on, the lock screen and Dynamic Island show \"Running query\" instead of the SQL preview.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent(String(localized: "Version"), value: versionText)
            if FeatureHighlights.release(appState.currentAppVersion) != nil {
                NavigationLink(String(localized: "What's New")) {
                    WhatsNewSettingsPage(version: appState.currentAppVersion)
                }
            }
            if let privacyPolicyURL = Self.privacyPolicyURL {
                Link(String(localized: "Privacy Policy"), destination: privacyPolicyURL)
            }
            NavigationLink(String(localized: "Acknowledgements")) {
                AcknowledgementsView()
            }
        }
    }

    private var versionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !build.isEmpty else { return appState.currentAppVersion }
        return String(format: String(localized: "%1$@ (%2$@)"), appState.currentAppVersion, build)
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { lockEnabled },
            set: { enabled in
                guard !enabled else {
                    lockEnabled = true
                    return
                }
                Task { await turnOffLock() }
            }
        )
    }

    private func turnOffLock() async {
        let reason = String(localized: "Authenticate to stop locking TablePro.")
        guard await auth.authenticate(reason: reason) else { return }
        lockEnabled = false
    }

    private var usageDataBinding: Binding<Bool> {
        Binding(
            get: { appState.onboarding.isUsageDataEnabled },
            set: { appState.setUsageDataEnabled($0) }
        )
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
