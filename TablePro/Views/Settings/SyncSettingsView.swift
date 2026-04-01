//
//  SyncSettingsView.swift
//  TablePro
//
//  Settings for iCloud sync configuration
//

import SwiftUI

struct SyncSettingsView: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Bindable private var syncCoordinator = SyncCoordinator.shared

    private let licenseManager = LicenseManager.shared

    var body: some View {
        Form {
            Section("iCloud Sync") {
                Toggle("iCloud Sync:", isOn: $settingsManager.sync.enabled)
                    .onChange(of: settingsManager.sync.enabled) { _, newValue in
                        updatePasswordSyncFlag()
                        if newValue {
                            syncCoordinator.enableSync()
                        } else {
                            syncCoordinator.disableSync()
                        }
                    }

                Text("Syncs connections, settings, and SSH profiles across your Macs via iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settingsManager.sync.enabled {
                statusSection

                syncCategoriesSection
            }

            LinkedFoldersSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if case .disabled(.licenseExpired) = syncCoordinator.syncStatus {
                licensePausedBanner
            }
        }
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            if syncCoordinator.iCloudAccountAvailable {
                LabeledContent(String(localized: "Account:")) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(String(localized: "iCloud Connected"))
                    }
                }
            } else {
                LabeledContent(String(localized: "Account:")) {
                    Text(String(localized: "Not Available"))
                        .foregroundStyle(.secondary)
                }

                Text("Sign in to iCloud in System Settings to enable sync.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let lastSync = syncCoordinator.lastSyncDate {
                LabeledContent(String(localized: "Last Synced:")) {
                    Text(lastSync, style: .relative)
                }
            }

            HStack(spacing: 8) {
                Button(String(localized: "Sync Now")) {
                    Task {
                        await syncCoordinator.syncNow()
                    }
                }
                .disabled(syncCoordinator.syncStatus.isSyncing || !syncCoordinator.iCloudAccountAvailable)

                if syncCoordinator.syncStatus.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if case .error(let error) = syncCoordinator.syncStatus {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Sync Categories Section

    private var syncCategoriesSection: some View {
        Section("Sync Categories") {
            Toggle("Connections:", isOn: $settingsManager.sync.syncConnections)
                .onChange(of: settingsManager.sync.syncConnections) { _, newValue in
                    if !newValue, settingsManager.sync.syncPasswords {
                        settingsManager.sync.syncPasswords = false
                        onPasswordSyncChanged(false)
                    }
                }

            if settingsManager.sync.syncConnections {
                Toggle("Passwords:", isOn: $settingsManager.sync.syncPasswords)
                    .onChange(of: settingsManager.sync.syncPasswords) { _, newValue in
                        onPasswordSyncChanged(newValue)
                    }
                    .padding(.leading, 20)

                Text("Syncs passwords via iCloud Keychain (end-to-end encrypted).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            Toggle("Groups & Tags:", isOn: $settingsManager.sync.syncGroupsAndTags)

            Toggle("SSH Profiles:", isOn: $settingsManager.sync.syncSSHProfiles)

            Toggle("Settings:", isOn: $settingsManager.sync.syncSettings)
        }
    }

    // MARK: - License Paused Banner

    private var licensePausedBanner: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(String(localized: "Sync paused — Pro license expired"))
                    .font(.callout)
                Spacer()
                Button(String(localized: "Renew License...")) {
                    openLicenseSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()

            Spacer()
        }
    }

    // MARK: - Helpers

    private func onPasswordSyncChanged(_ enabled: Bool) {
        let effective = settingsManager.sync.enabled && settingsManager.sync.syncConnections && enabled
        Task.detached {
            KeychainHelper.shared.migratePasswordSyncState(synchronizable: effective)
            UserDefaults.standard.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
        }
    }

    private func updatePasswordSyncFlag() {
        let sync = settingsManager.sync
        let effective = sync.enabled && sync.syncConnections && sync.syncPasswords
        let current = UserDefaults.standard.bool(forKey: KeychainHelper.passwordSyncEnabledKey)
        guard effective != current else { return }
        Task.detached {
            KeychainHelper.shared.migratePasswordSyncState(synchronizable: effective)
            UserDefaults.standard.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
        }
    }

    private func openLicenseSettings() {
        UserDefaults.standard.set(SettingsTab.license.rawValue, forKey: "selectedSettingsTab")
    }
}

#Preview {
    SyncSettingsView()
        .frame(width: 450, height: 400)
}
