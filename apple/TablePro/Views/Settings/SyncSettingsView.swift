import AppKit
import os
import SwiftUI
import TableProFFI
import TableProSyncTransport

// One pane for every provider: iCloud runs on the Apple Account, TablePro Sync on the TablePro account.
struct SyncSettingsView: View {
    @Binding var settings: SyncSettings

    @ObservedObject private var coordinator = SyncProviderCoordinator.shared
    @ObservedObject private var moves = ProviderMoves.shared
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @ObservedObject private var policy = ManagedPolicyCenter.shared

    @State private var sheet: SyncProviderSheet?
    @State private var asksICloudDeletion = false
    @State private var isDeletingICloudData = false
    @State private var iCloudDataProblem: String?
    @State private var serviceSyncProblem: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncSettingsView")

    private var isSyncing: Bool {
        coordinator.syncStatus.isSyncing
    }

    private var layout: SyncPaneLayout {
        SyncPaneLayout(SyncPaneInputs(
            provider: settings.provider,
            choices: SyncProviderPolicy.choices(policy.snapshot),
            iCloudAccess: featureAccess.check(.iCloudSync),
            serviceAccess: featureAccess.check(.serviceSync),
            iCloudStatus: coordinator.syncStatus,
            engine: moves.engineStatus,
            serverLicense: featureAccess.state.serverLicense,
            // A Mac that never synced with iCloud has nothing of its own to delete there.
            offersICloudDataDeletion: coordinator.lastSyncDate != nil
                && ProviderMoves.offersICloudDataDeletion(settings.provider, under: policy.snapshot),
            scopes: moves.scopes
        ))
    }

    var body: some View {
        let layout = self.layout
        let presentation = SyncStatusPresentation(status: coordinator.syncStatus)

        Form {
            if layout.asksNewIdentity {
                Section {
                    SyncNewIdentityNotice(moves: moves)
                }
            }

            if let notice = layout.iCloudNotice {
                Section {
                    noticeRow(notice)
                }
            }

            if let notice = layout.serviceNotice {
                Section {
                    SyncServiceNoticeRow(notice: notice) {
                        sheet = notice == .awaitsMoveBack ? moveToICloud : moveToService
                    }
                }
            }

            Section {
                providerPicker(layout)

                if let gate = layout.licenseGate {
                    LicenseGateRow(feature: gate)
                }

                if layout.showsICloudStatus {
                    statusRow(presentation)
                }

                if let status = layout.serviceStatus {
                    serviceStatusRow(status)
                }

                ForEach(layout.serverPolicies, id: \.self) { serverPolicy in
                    NoticeLabel(serverPolicy.message, severity: serverPolicy == .personalSyncOff ? .warning : .info)
                        .accessibilityIdentifier("settings-sync-server-policy")
                }

                if layout.showsLastSynced {
                    lastSyncedRow(offersSyncNow: layout.offersSyncNow)
                }

                if layout.offersICloudDataDeletion {
                    iCloudDataRow
                }
            }

            if layout.showsCategories {
                categoriesSection
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-sync")
        .task {
            // The engine's status names the provider it is on, which the TablePro Sync rows read.
            if settings.provider == .tableproSync, moves.engineStatus == nil {
                await moves.openEngine()
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .moveToService(let fromICloud, let session):
                SyncMoveSheet(moves: moves, fromICloud: fromICloud, session: session)
            case .moveToICloud(let session):
                SyncMoveBackSheet(moves: moves, session: session)
            }
        }
        .alert(String(localized: "Delete TablePro's Data from iCloud?"), isPresented: $asksICloudDeletion) {
            Button(String(localized: "Delete"), role: .destructive) {
                Task { await deleteICloudData() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                "Devices still syncing with iCloud stop syncing until one of them uploads again. What this Mac and TablePro Sync hold stays."
            )
        }
    }

    // MARK: - Provider

    private func providerPicker(_ layout: SyncPaneLayout) -> some View {
        Picker(selection: providerSelection) {
            ForEach(layout.options, id: \.self) { option in
                Text(option.title).tag(option)
            }
        } label: {
            Text("Sync this Mac with")
            if layout.managedNote != nil {
                Text("Managed by your organization")
                    .accessibilityIdentifier("settings-sync-managed")
            } else {
                Text(settings.provider.summary)
            }
        }
        .pickerStyle(.menu)
        .disabled(layout.isPickerLocked || sheet != nil)
        .accessibilityIdentifier("settings-sync-provider")
    }

    // Read when the sheet opens, since the move itself changes the stored provider.
    private var movesFromICloud: Bool {
        settings.provider == .iCloud
    }

    // The picker shows the stored provider; a move changes it only once the sheet confirms.
    private var providerSelection: Binding<SyncProviderSetting> {
        Binding(
            get: { settings.provider },
            set: { choose($0) }
        )
    }

    private func choose(_ next: SyncProviderSetting) {
        let current = settings.provider
        guard next != current else { return }
        switch next {
        case .off:
            Task { await moves.turnOff() }
        case .iCloud:
            guard featureAccess.isAvailable(.iCloudSync) else {
                LicenseGateAlert.present(for: .iCloudSync, in: NSApp.keyWindow)
                return
            }
            if current == .tableproSync {
                sheet = moveToICloud
            } else {
                settings.provider = .iCloud
            }
        case .tableproSync:
            guard featureAccess.isAvailable(.serviceSync) else {
                LicenseGateAlert.present(for: .serviceSync, in: NSApp.keyWindow)
                return
            }
            sheet = moveToService
        }
    }

    // Each move is bound to the sign-in it opens under: the plan the person confirms is that account's.
    private var moveToService: SyncProviderSheet {
        .moveToService(fromICloud: movesFromICloud, session: featureAccess.state.sessionID)
    }

    private var moveToICloud: SyncProviderSheet {
        .moveToICloud(session: featureAccess.state.sessionID)
    }

    // MARK: - Rows

    private func noticeRow(_ notice: SyncNotice) -> some View {
        SyncNoticeRow(symbolName: notice.symbolName, title: notice.title, message: notice.message) {
            ForEach(notice.actions) { action in
                control(for: action)
            }
        }
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
                settings.provider = .off
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

    private func serviceStatusRow(_ status: SyncServiceStatus) -> some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if status == .syncing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: status.symbolName)
                        .foregroundStyle(status.isWarning ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                }

                Text(status.title)
                    .accessibilityIdentifier("settings-sync-status")
            }
        } label: {
            Text("Status")
            if let serviceSyncProblem {
                Text(serviceSyncProblem)
            }
        }
    }

    private func lastSyncedRow(offersSyncNow: Bool) -> some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SyncLastSyncedText(date: lastSyncDate)

                if offersSyncNow {
                    Button("Sync Now") {
                        Task { await syncNow() }
                    }
                    .disabled(isSyncing)
                    .accessibilityIdentifier("settings-sync-now")
                }
            }
        } label: {
            Text("Last synced")
        }
    }

    private var lastSyncDate: Date? {
        guard settings.provider == .tableproSync else { return coordinator.lastSyncDate }
        return moves.engineStatus?.lastPassMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    private var iCloudDataRow: some View {
        LabeledContent {
            Button(String(localized: "Delete iCloud Data…"), role: .destructive) {
                iCloudDataProblem = nil
                asksICloudDeletion = true
            }
            .disabled(isDeletingICloudData)
            .accessibilityIdentifier("settings-sync-delete-icloud-data")
        } label: {
            Text("iCloud data")
            if let iCloudDataProblem {
                Text(iCloudDataProblem)
            } else {
                Text("TablePro's data stays in iCloud after this Mac stops syncing with it.")
            }
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
                Text(passwordsDetail)
            }
            .disabled(!settings.syncConnections || passwordsOffOnServer)
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

    private var passwordsOffOnServer: Bool {
        layout.passwordsOffOnServer
    }

    private var passwordsDetail: String {
        if passwordsOffOnServer {
            return String(localized: "Your server does not sync passwords. Each one stays on this Mac.")
        }
        if settings.provider == .tableproSync {
            return String(
                localized: "End-to-end encrypted with your account's keys. This Mac also keeps its own copy of each password."
            )
        }
        return String(
            localized: "Stored in iCloud Keychain, end-to-end encrypted. Applies to each password the next time you save it."
        )
    }

    private var syncConnections: Binding<Bool> {
        let settings = $settings
        return Binding(
            get: { settings.wrappedValue.syncConnections },
            set: { settings.wrappedValue = settings.wrappedValue.settingConnections($0) }
        )
    }

    // MARK: - Actions

    private func syncNow() async {
        guard settings.provider == .tableproSync else {
            await coordinator.syncNow()
            return
        }
        serviceSyncProblem = nil
        do {
            try await moves.syncNow()
        } catch {
            Self.logger.error("Sync Now failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            serviceSyncProblem = ProviderMoves.message(for: error)
        }
    }

    private func deleteICloudData() async {
        isDeletingICloudData = true
        defer { isDeletingICloudData = false }
        do {
            try await moves.deleteICloudData()
        } catch {
            Self.logger.error("Deleting the iCloud data failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            iCloudDataProblem = String(localized: "TablePro's data could not be deleted from iCloud. Try again later.")
        }
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

enum SyncProviderSheet: Hashable, Identifiable {
    case moveToService(fromICloud: Bool, session: String?)
    case moveToICloud(session: String?)

    var id: Self { self }
}

extension SyncProviderSetting {
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .iCloud: "iCloud"
        case .tableproSync: "TablePro Sync"
        }
    }

    var summary: String {
        switch self {
        case .off:
            String(localized: "Connections and settings stay on this Mac.")
        case .iCloud:
            String(localized: "Keep your connections and the items you choose the same on devices signed in to your Apple Account.")
        case .tableproSync:
            String(localized: "Sync through your TablePro account with every device signed in to it. Passwords, other secrets and query history are end-to-end encrypted.")
        }
    }
}

extension SyncServerPolicy {
    var message: String {
        switch self {
        case .personalSyncOff:
            String(localized: "Your server does not keep personal data, so this Mac keeps its own. Team Library goes on syncing.")
        case .passwordsOff:
            String(localized: "Your server does not sync passwords. Each one stays on this Mac.")
        case .historyOff:
            String(localized: "Your server does not sync query history. It stays on this Mac.")
        }
    }
}

extension SyncServiceStatus {
    var title: String {
        switch self {
        case .upToDate: String(localized: "Up to Date")
        case .syncing: String(localized: "Syncing…")
        case .waiting: String(localized: "Waiting to Retry")
        case .downloadOnly: String(localized: "Downloading Only")
        case .off: String(localized: "Sync Off")
        case .unavailable: String(localized: "Sync Is Unavailable")
        }
    }

    // Every symbol here ships with macOS 13.
    var symbolName: String {
        switch self {
        case .upToDate: "checkmark.circle"
        case .syncing: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .downloadOnly: "arrow.down.circle"
        case .off: "slash.circle"
        case .unavailable: "exclamationmark.circle"
        }
    }

    var isWarning: Bool {
        switch self {
        case .waiting, .downloadOnly, .unavailable: true
        case .upToDate, .syncing, .off: false
        }
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
