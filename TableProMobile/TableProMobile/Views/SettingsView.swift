//
//  SettingsView.swift
//  TableProMobile
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("com.TablePro.settings.shareAnalytics") private var shareAnalytics = true
    @AppStorage(AppLockState.lockEnabledKey) private var lockEnabled = false
    @AppStorage(AppLockState.lockTimeoutKey) private var lockTimeoutSeconds = AppLockState.AutoLockTimeout.fiveMinutes.rawValue

    private let auth = BiometricAuthService()

    var body: some View {
        Form {
            biometricSection

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

    private func toggleLabel(for availability: BiometricAuthService.Availability) -> String {
        switch availability {
        case .faceID: String(localized: "Require Face ID")
        case .touchID: String(localized: "Require Touch ID")
        case .opticID: String(localized: "Require Optic ID")
        case .unavailable: ""
        }
    }
}
