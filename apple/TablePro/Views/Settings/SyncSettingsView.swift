import AppKit
import os
import SwiftUI
import TableProSyncTransport

struct SyncPaneLayout: Equatable {
    let notice: SyncNotice?
    let isToggleDisabled: Bool
    let showsManagedNote: Bool
    let showsLicenseGate: Bool
    let showsStatus: Bool
    let showsLastSynced: Bool
    let offersSyncNow: Bool
    let showsCategories: Bool

    // `isManaged` when a configuration profile leaves one choice or none, `allowsICloud` while iCloud is one of them.
    init(
        enabled: Bool,
        isLicensed: Bool,
        presentation: SyncStatusPresentation,
        isManaged: Bool = false,
        allowsICloud: Bool = true
    ) {
        let showsLive = enabled && isLicensed && allowsICloud
        notice = presentation.notice
        // A lapsed license can still turn sync off; the organization's choice cannot be changed here.
        isToggleDisabled = isManaged || (!isLicensed && !enabled)
        showsManagedNote = isManaged
        showsLicenseGate = !isLicensed && allowsICloud
        showsStatus = showsLive && presentation.notice == nil
        showsLastSynced = showsLive
        offersSyncNow = presentation.offersSyncNow
        // The categories apply before the first upload, so they show while sync is off too.
        showsCategories = isLicensed && allowsICloud
    }
}

// Its own pane: sync runs on the Apple Account, a different identity from the email on a license.
struct SyncSettingsView: View {
    @Binding var settings: SyncSettings

    @ObservedObject private var coordinator = SyncCoordinator.shared
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @ObservedObject private var policy = ManagedPolicyCenter.shared

    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncSettingsView")

    private var isSyncing: Bool {
        coordinator.syncStatus.isSyncing
    }

    var body: some View {
        let presentation = SyncStatusPresentation(status: coordinator.syncStatus)
        let iCloud = SyncProviderPolicy.iCloud(policy.snapshot)
        let layout = SyncPaneLayout(
            enabled: settings.enabled,
            isLicensed: featureAccess.isAvailable(.iCloudSync),
            presentation: presentation,
            isManaged: iCloud.isLocked,
            allowsICloud: iCloud.isAllowed
        )

        Form {
            if let notice = layout.notice {
                Section {
                    noticeRow(notice)
                }
            }

            Section {
                Toggle(isOn: $settings.enabled) {
                    Text("Sync this Mac with iCloud")
                    if layout.showsManagedNote {
                        Text("Managed by your organization")
                            .accessibilityIdentifier("settings-sync-managed")
                    } else {
                        Text(
                            "Keep your connections and the items you choose the same on devices signed in to your Apple Account."
                        )
                    }
                }
                .disabled(layout.isToggleDisabled)
                .accessibilityIdentifier("settings-sync-toggle")

                if layout.showsLicenseGate {
                    LicenseGateRow(feature: .iCloudSync)
                }

                if layout.showsStatus {
                    statusRow(presentation)
                }

                if layout.showsLastSynced {
                    lastSyncedRow(offersSyncNow: layout.offersSyncNow)
                }
            }

            if layout.showsCategories {
                categoriesSection
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-sync")
    }

    private func noticeRow(_ notice: SyncNotice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    Text(notice.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: notice.symbolName)
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }

            if !notice.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(notice.actions) { action in
                        control(for: action)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-sync-notice")
    }

    @ViewBuilder
    private func control(for action: SyncStatusAction) -> some View {
        switch action {
        case .tryAgain:
            Button(action.title) {
                Task { await coordinator.syncNow() }
            }
            .disabled(isSyncing)
        case .manageStorage:
            Button(action.title) {
                Self.openSystemSettings("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings*AppleIDSettings?iCloud")
            }
        case .openAccountSettings:
            Button(action.title) {
                Self.openSystemSettings("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")
            }
        case .checkForUpdates:
            SyncUpdateActionButton()
        case .uploadAgain:
            Button(action.title) {
                Task { await coordinator.uploadAgain() }
            }
        case .turnOffSync:
            // The setting's commit also turns password sync off and stops the coordinator.
            Button(action.title) {
                settings.enabled = false
            }
        }
    }

    private func statusRow(_ presentation: SyncStatusPresentation) -> some View {
        LabeledContent {
            // First baseline keeps the value on the label's baseline while the spinner shows.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: presentation.symbolName)
                        .foregroundStyle(presentation.isWarning ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                }

                Text(presentation.title)
                    .accessibilityIdentifier("settings-sync-status")
            }
        } label: {
            Text("Status")
            if let detail = presentation.statusDetail {
                Text(detail)
            }
        }
    }

    private func lastSyncedRow(offersSyncNow: Bool) -> some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SyncLastSyncedText(date: coordinator.lastSyncDate)

                if offersSyncNow {
                    Button("Sync Now") {
                        Task { await coordinator.syncNow() }
                    }
                    .disabled(isSyncing)
                    .accessibilityIdentifier("settings-sync-now")
                }
            }
        } label: {
            Text("Last synced")
        }
    }

    private var categoriesSection: some View {
        Section("What Syncs") {
            Toggle(isOn: syncConnections) {
                Text("Connections")
                Text("Connections set to Local only are left out.")
            }
            .accessibilityIdentifier("settings-sync-category-connections")

            Toggle(isOn: $settings.syncPasswords) {
                Text("Passwords")
                Text(
                    "Stored in iCloud Keychain, end-to-end encrypted. Applies to each password the next time you save it."
                )
            }
            .disabled(!settings.syncConnections)
            .accessibilityIdentifier("settings-sync-category-passwords")

            Toggle("Groups & Tags", isOn: $settings.syncGroupsAndTags)
                .accessibilityIdentifier("settings-sync-category-groups-and-tags")

            Toggle("SSH Profiles", isOn: $settings.syncSSHProfiles)
                .accessibilityIdentifier("settings-sync-category-ssh-profiles")

            Toggle("Credential Profiles", isOn: $settings.syncCredentialProfiles)
                .accessibilityIdentifier("settings-sync-category-credential-profiles")

            Toggle("Saved Queries", isOn: $settings.syncSQLFavorites)
                .accessibilityIdentifier("settings-sync-category-saved-queries")

            Toggle("Table Favorites", isOn: $settings.syncTableFavorites)
                .accessibilityIdentifier("settings-sync-category-table-favorites")

            Toggle("Table Folders", isOn: $settings.syncTableFolders)
                .accessibilityIdentifier("settings-sync-category-table-folders")

            Toggle("Database Favorites", isOn: $settings.syncDatabaseFavorites)
                .accessibilityIdentifier("settings-sync-category-database-favorites")

            // Generic on purpose: the list of settings that stay on this Mac keeps growing.
            Toggle(isOn: $settings.syncSettings) {
                Text("Settings")
                Text(
                    "Preferences and custom themes. Some settings, such as fonts and the appearance mode, stay on this Mac."
                )
            }
            .accessibilityIdentifier("settings-sync-category-settings")
        }
    }

    private var syncConnections: Binding<Bool> {
        let settings = $settings
        return Binding(
            get: { settings.wrappedValue.syncConnections },
            set: { settings.wrappedValue = settings.wrappedValue.settingConnections($0) }
        )
    }

    // Notes and Freeform open these Apple Account panes, but the addresses are not documented.
    private static func openSystemSettings(_ address: String) {
        if let url = URL(string: address), NSWorkspace.shared.open(url) {
            return
        }
        logger.notice("System Settings did not open the Apple Account pane; opening System Settings instead")
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            logger.error("System Settings is not installed")
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

// Only this button observes UpdateCenter, so an update check redraws it and not the pane.
private struct SyncUpdateActionButton: View {
    @ObservedObject private var updates = UpdateCenter.shared

    var body: some View {
        Button(updates.status.appUpdateTitle) {
            updates.performAppUpdateAction()
        }
        .disabled(!updates.isAppUpdateActionEnabled)
    }
}

// Reads like Time Machine's latest backup ("Today at 14:50") and moves to "Yesterday" without a reopen.
private struct SyncLastSyncedText: View {
    let date: Date?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        if let date {
            TimelineView(.everyMinute) { context in
                Text(verbatim: Self.formatter.string(from: min(date, context.date)))
                    .accessibilityIdentifier("settings-sync-last-synced")
            }
        } else {
            Text("Never")
                .accessibilityIdentifier("settings-sync-last-synced")
        }
    }
}

#Preview {
    SyncSettingsView(settings: .constant(.default))
        .frame(width: 520, height: 500)
}
