//
//  SyncSettingsView.swift
//  TablePro
//
//  Settings for iCloud sync configuration
//

import SwiftUI

struct SyncSettingsView: View {
    @Bindable private var syncCoordinator = SyncCoordinator.shared
    @State private var syncSettings: SyncSettings = AppSettingsStorage.shared.loadSync()

    private let licenseManager = LicenseManager.shared

    var body: some View {
        Form {
            Section("iCloud Sync") {
                Toggle("iCloud Sync:", isOn: $syncSettings.enabled)
                    .onChange(of: syncSettings.enabled) { _, newValue in
                        persistSettings()
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

            if syncSettings.enabled {
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
            Toggle("Connections:", isOn: $syncSettings.syncConnections)
                .onChange(of: syncSettings.syncConnections) { _, newValue in
                    persistSettings()
                    if !newValue, syncSettings.syncPasswords {
                        syncSettings.syncPasswords = false
                        persistSettings()
                        onPasswordSyncChanged(false)
                    }
                }

            if syncSettings.syncConnections {
                Toggle("Passwords:", isOn: $syncSettings.syncPasswords)
                    .onChange(of: syncSettings.syncPasswords) { _, newValue in
                        persistSettings()
                        onPasswordSyncChanged(newValue)
                    }
                    .padding(.leading, 20)

                Text("Syncs passwords via iCloud Keychain (end-to-end encrypted).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            Toggle("Groups & Tags:", isOn: $syncSettings.syncGroupsAndTags)
                .onChange(of: syncSettings.syncGroupsAndTags) { _, _ in persistSettings() }

            Toggle("SSH Profiles:", isOn: $syncSettings.syncSSHProfiles)
                .onChange(of: syncSettings.syncSSHProfiles) { _, _ in persistSettings() }

            Toggle("Settings:", isOn: $syncSettings.syncSettings)
                .onChange(of: syncSettings.syncSettings) { _, _ in persistSettings() }
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

    private func persistSettings() {
        AppSettingsStorage.shared.saveSync(syncSettings)
    }

    private func onPasswordSyncChanged(_ enabled: Bool) {
        let effective = syncSettings.enabled && syncSettings.syncConnections && enabled
        Task.detached {
            KeychainHelper.shared.migratePasswordSyncState(synchronizable: effective)
            UserDefaults.standard.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
        }
    }

    private func updatePasswordSyncFlag() {
        let effective = syncSettings.enabled && syncSettings.syncConnections && syncSettings.syncPasswords
        let current = UserDefaults.standard.bool(forKey: KeychainHelper.passwordSyncEnabledKey)
        guard effective != current else { return }
        Task.detached {
            KeychainHelper.shared.migratePasswordSyncState(synchronizable: effective)
            UserDefaults.standard.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
        }
    }

    private func openLicenseSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            UserDefaults.standard.set(SettingsTab.license.rawValue, forKey: "selectedSettingsTab")
        }
    }
}

#Preview {
    SyncSettingsView()
        .frame(width: 450, height: 400)
}
