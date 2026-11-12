//
//  SyncSection.swift
//  TablePro
//

import SwiftUI
import TableProSyncTransport

struct SyncSection: View {
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared

    private var isProAvailable: Bool {
        featureAccess.isAvailable(.iCloudSync)
    }

    var body: some View {
        Section {
            Toggle("Sync this Mac with iCloud", isOn: $settingsManager.sync.enabled)
                .help("Syncs connections, table favorites, settings, and SSH profiles across your Macs via iCloud.")
                .disabled(!isProAvailable)

            if !isProAvailable {
                LicenseGateRow(feature: .iCloudSync)
            }
        } header: {
            Text("iCloud Sync")
        }

        if settingsManager.sync.enabled && isProAvailable {
            statusSection
            categoriesSection
        }
    }

    // MARK: - Status

    // A blocker is explained by the notice at the top of the pane, so the Status row only names it.
    private var statusSection: some View {
        let presentation = SyncStatusPresentation(status: syncCoordinator.syncStatus)
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
                    Text(presentation.title)
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
                    }
                }

            if settingsManager.sync.syncConnections {
                Toggle("Passwords", isOn: $settingsManager.sync.syncPasswords)
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
}
