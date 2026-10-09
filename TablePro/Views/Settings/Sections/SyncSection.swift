//
//  SyncSection.swift
//  TablePro
//

import SwiftUI
import TableProSyncTransport

struct SyncSection: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared

    private var isProAvailable: Bool {
        licenseManager.isFeatureAvailable(.iCloudSync)
    }

    var body: some View {
        Section {
            Toggle("Sync this Mac with iCloud", isOn: $settingsManager.sync.enabled)
                .onChange(of: settingsManager.sync.enabled) { newValue in
                    updatePasswordSyncFlag()
                    if newValue {
                        syncCoordinator.enableSync()
                    } else {
                        syncCoordinator.disableSync()
                    }
                }
                .help("Syncs connections, table favorites, settings, and SSH profiles across your Macs via iCloud.")
                .disabled(!isProAvailable)
        } header: {
            HStack(spacing: 6) {
                Text("iCloud Sync")
                if !isProAvailable {
                    ProBadge(feature: .iCloudSync)
                }
            }
        }

        if settingsManager.sync.enabled && isProAvailable {
            statusSection
            categoriesSection
        }
    }

    // MARK: - Status

    /// A blocked state is explained by the notice at the top of the pane, so this section names it
    /// in the Status row and leaves the long message there.
    private var statusSection: some View {
        let presentation = SyncStatusPresentation(
            status: syncCoordinator.syncStatus,
            lastSyncDate: syncCoordinator.lastSyncDate
        )
        return Section("Sync Status") {
            LabeledContent(String(localized: "Status")) {
                HStack(spacing: 4) {
                    if syncCoordinator.syncStatus.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: presentation.symbolName)
                            .foregroundStyle(presentation.isWarning ? Color.orange : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(presentation.statusTitle)
                }
            }

            if let lastSync = syncCoordinator.lastSyncDate {
                LabeledContent(String(localized: "Last Synced")) {
                    Text(lastSync, style: .relative)
                }
            }

            if presentation.offersSyncNow {
                Button(String(localized: "Sync Now")) {
                    Task { await syncCoordinator.syncNow() }
                }
                .disabled(syncCoordinator.syncStatus.isSyncing)
            }

            if let detail = presentation.statusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        Section("Sync Categories") {
            Toggle("Connections", isOn: $settingsManager.sync.syncConnections)
                .onChange(of: settingsManager.sync.syncConnections) { newValue in
                    if !newValue, settingsManager.sync.syncPasswords {
                        settingsManager.sync.syncPasswords = false
                        onPasswordSyncChanged(false)
                    }
                }

            if settingsManager.sync.syncConnections {
                Toggle("Passwords", isOn: $settingsManager.sync.syncPasswords)
                    .onChange(of: settingsManager.sync.syncPasswords) { newValue in
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

            Toggle("Groups & Tags", isOn: $settingsManager.sync.syncGroupsAndTags)
            Toggle("SSH Profiles", isOn: $settingsManager.sync.syncSSHProfiles)
            Toggle("Credential Profiles", isOn: $settingsManager.sync.syncCredentialProfiles)
            Toggle("Settings", isOn: $settingsManager.sync.syncSettings)
            Toggle("Table Favorites", isOn: $settingsManager.sync.syncTableFavorites)
            Toggle("Table Folders", isOn: $settingsManager.sync.syncTableFolders)
            Toggle("Database Favorites", isOn: $settingsManager.sync.syncDatabaseFavorites)
            Toggle("Saved Queries", isOn: $settingsManager.sync.syncSQLFavorites)
        }
    }

    // MARK: - Helpers

    private func onPasswordSyncChanged(_ enabled: Bool) {
        let effective = settingsManager.sync.enabled && settingsManager.sync.syncConnections && enabled
        AppStorageEnvironment.shared.defaults.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
    }

    private func updatePasswordSyncFlag() {
        let sync = settingsManager.sync
        let effective = sync.enabled && sync.syncConnections && sync.syncPasswords
        AppStorageEnvironment.shared.defaults.set(effective, forKey: KeychainHelper.passwordSyncEnabledKey)
    }
}
