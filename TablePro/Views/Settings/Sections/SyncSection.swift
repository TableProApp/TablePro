//
//  SyncSection.swift
//  TablePro
//

import SwiftUI

struct SyncSection: View {
    @Bindable private var settingsManager = AppSettingsManager.shared
    @Bindable private var syncCoordinator = SyncCoordinator.shared

    private var isProAvailable: Bool {
        LicenseManager.shared.isFeatureAvailable(.iCloudSync)
    }

    var body: some View {
        Section {
            Toggle("iCloud Sync:", isOn: $settingsManager.sync.enabled)
                .onChange(of: settingsManager.sync.enabled) { _, newValue in
                    updatePasswordSyncFlag()
                    if newValue {
                        syncCoordinator.enableSync()
                    } else {
                        syncCoordinator.disableSync()
                    }
                }
                .help("Syncs connections, settings, and SSH profiles across your Macs via iCloud.")
                .disabled(!isProAvailable)
        } header: {
            HStack(spacing: 6) {
                Text("iCloud Sync")
                if !isProAvailable {
                    ProBadge()
                }
            }
        }

        if settingsManager.sync.enabled && isProAvailable {
            statusSection
            categoriesSection
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Sync Status") {
            if syncCoordinator.iCloudAccountAvailable {
                LabeledContent(String(localized: "Account:")) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
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
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }

            if let lastSync = syncCoordinator.lastSyncDate {
                LabeledContent(String(localized: "Last Synced:")) {
                    Text(lastSync, style: .relative)
                }
            }

            HStack(spacing: 8) {
                Button(String(localized: "Sync Now")) {
                    Task { await syncCoordinator.syncNow() }
                }
                .disabled(syncCoordinator.syncStatus.isSyncing || !syncCoordinator.iCloudAccountAvailable)

                if syncCoordinator.syncStatus.isSyncing {
                    ProgressView().controlSize(.small)
                }
            }

            if case .error(let error) = syncCoordinator.syncStatus {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
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
                    .help("Syncs passwords via iCloud Keychain (end-to-end encrypted).")
                    .padding(.leading, 20)

                Text("Only affects new saves. Re-save a password to update its sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Toggle("Groups & Tags:", isOn: $settingsManager.sync.syncGroupsAndTags)
            Toggle("SSH Profiles:", isOn: $settingsManager.sync.syncSSHProfiles)
            Toggle("Settings:", isOn: $settingsManager.sync.syncSettings)
        }
    }

    // MARK: - Helpers

    private func onPasswordSyncChanged(_ enabled: Bool) {
        let effective = settingsManager.sync.enabled && settingsManager.sync.syncConnections && enabled
        UserDefaults.standard.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
    }

    private func updatePasswordSyncFlag() {
        let sync = settingsManager.sync
        let effective = sync.enabled && sync.syncConnections && sync.syncPasswords
        UserDefaults.standard.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
    }
}
