import SwiftUI
import TableProFFI
import TableProSyncTransport

// Settings > Sync: one page for every provider. iCloud runs on the Apple Account, TablePro Sync on the TablePro
// account, as the Mac's Sync pane has it.
struct SyncSettingsPage: View {
    @Environment(AppState.self) private var appState

    @State private var sheet: SyncProviderSheet?
    @State private var categories = SyncCategories()
    @State private var asksICloudDeletion = false
    @State private var isDeletingICloudData = false
    @State private var iCloudDataProblem: String?
    @State private var serviceProblem: String?
    @State private var needsSignIn = false

    private var moves: IOSProviderMoves {
        appState.providerMoves
    }

    private var provider: SyncProviderTag {
        appState.onboarding.syncProvider
    }

    private var layout: MobileSyncLayout {
        MobileSyncLayout(MobileSyncInputs(
            provider: provider,
            choices: appState.onboarding.managed.syncChoices,
            iCloudStatus: appState.syncCoordinator.status,
            engine: moves.engineStatus,
            scopes: moves.scopes,
            serverLicense: appState.account.license,
            isSignedIn: appState.account.isSignedIn,
            hasICloudData: appState.hasICloudSyncData
        ))
    }

    var body: some View {
        let layout = self.layout
        Form {
            if layout.asksNewIdentity {
                Section {
                    SyncNewIdentityNotice(moves: moves)
                }
            }

            if let notice = layout.serviceNotice {
                Section {
                    SyncServiceNoticeRow(notice: notice) {
                        sheet = notice == .awaitsMoveBack ? moveToICloud : moveToService
                    }
                }
            }

            providerSection(layout)

            if layout.showsICloudStatus || layout.serviceStatus != nil {
                statusSection(layout)
            }

            if layout.showsCategories {
                categoriesSection(layout)
            }

            if layout.offersICloudDataDeletion {
                iCloudDataSection
            }
        }
        .navigationTitle(String(localized: "Sync"))
        .accessibilityIdentifier("settings-sync-page")
        .onAppear {
            categories = appState.syncCategories
        }
        .task {
            // The engine's status names the provider it is on, which the TablePro Sync rows read.
            if provider == .tableproSync, moves.engineStatus == nil {
                await moves.openEngine()
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .moveToService(let fromICloud, let session):
                SyncMoveSheet(moves: moves, fromICloud: fromICloud, session: session) { state, finished in
                    AnyView(SyncKeysStep(state: state, finished: finished))
                }
            case .moveToICloud(let session):
                SyncMoveBackSheet(moves: moves, session: session)
            }
        }
        .onChange(of: appState.account.snapshot.sessionID) {
            // A move sheet is bound to the sign-in it opened under.
            sheet = nil
        }
        .alert(String(localized: "Sign In to TablePro"), isPresented: $needsSignIn) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text("TablePro Sync runs on your TablePro account. Sign in under Account in Settings, then choose TablePro Sync again.")
        }
        .alert(String(localized: "Delete TablePro's Data from iCloud?"), isPresented: $asksICloudDeletion) {
            Button(String(localized: "Delete"), role: .destructive) {
                Task { await deleteICloudData() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Devices still syncing with iCloud stop syncing until one of them uploads again. What this device and TablePro Sync hold stays.")
        }
    }

    // MARK: - Provider

    private func providerSection(_ layout: MobileSyncLayout) -> some View {
        Section {
            Picker(String(localized: "Sync With"), selection: providerSelection) {
                ForEach(layout.options, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(layout.isPickerLocked || moves.isMoving)
            .accessibilityIdentifier("settings-sync-provider")
        } header: {
            Text("Sync With")
        } footer: {
            if layout.isPickerLocked {
                Text("Your organization manages how TablePro syncs on this device.")
            } else {
                Text(provider.summary)
            }
        }
    }

    // The picker shows the provider in use; a move changes it only once its sheet confirms.
    private var providerSelection: Binding<SyncProviderTag> {
        Binding(
            get: { provider },
            set: { choose($0) }
        )
    }

    private func choose(_ next: SyncProviderTag) {
        let current = provider
        guard next != current else { return }
        switch next {
        case .off:
            appState.chooseSyncProvider(.off)
        case .icloud:
            if current == .tableproSync {
                sheet = moveToICloud
            } else {
                appState.chooseSyncProvider(.icloud)
            }
        case .tableproSync:
            guard appState.account.isSignedIn else {
                needsSignIn = true
                return
            }
            sheet = moveToService
        }
    }

    // Each move is bound to the sign-in it opens under: the plan the person confirms is that account's.
    private var moveToService: SyncProviderSheet {
        .moveToService(fromICloud: provider == .icloud, session: appState.account.snapshot.sessionID)
    }

    private var moveToICloud: SyncProviderSheet {
        .moveToICloud(session: appState.account.snapshot.sessionID)
    }

    // MARK: - Status

    private func statusSection(_ layout: MobileSyncLayout) -> some View {
        Section {
            if layout.showsICloudStatus {
                iCloudStatusRows
            }
            if let status = layout.serviceStatus {
                serviceStatusRow(status)
            }
            ForEach(layout.serverPolicies, id: \.self) { policy in
                Label(policy.message, systemImage: policy == .personalSyncOff ? "exclamationmark.triangle" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-sync-server-policy")
            }
            if layout.showsLastSynced {
                LabeledContent(String(localized: "Last Sync")) {
                    lastSyncLabel
                }
            }
            if layout.offersSyncNow {
                Button(String(localized: "Sync Now")) {
                    Task { await syncNow() }
                }
                .accessibilityIdentifier("settings-sync-now")
            }
        } header: {
            Text("Status")
        }
    }

    @ViewBuilder
    private var iCloudStatusRows: some View {
        let status = appState.syncCoordinator.status
        let presentation = SyncStatusPresentation(status: status)
        LabeledContent(String(localized: "Status")) {
            HStack(spacing: 6) {
                if status.isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: presentation.symbolName)
                        .foregroundStyle(presentation.isWarning ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                }
                Text(presentation.title)
                    .accessibilityIdentifier("settings-sync-status")
            }
        }
        if status.error != nil {
            Text(presentation.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let guidance = presentation.guidance {
                Text(guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // The provider picker above is already the way to turn sync off.
            ForEach(presentation.mobileActions.filter { $0 != .turnOffSync }) { action in
                Button(action.title) {
                    appState.performSyncAction(action)
                }
            }
        }
    }

    @ViewBuilder
    private func serviceStatusRow(_ status: MobileSyncServiceStatus) -> some View {
        LabeledContent(String(localized: "Status")) {
            HStack(spacing: 6) {
                if status == .syncing {
                    ProgressView()
                } else {
                    Image(systemName: status.symbolName)
                        .foregroundStyle(status.isWarning ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                }
                Text(status.title)
                    .accessibilityIdentifier("settings-sync-status")
            }
        }
        if let detail = serviceProblem ?? serviceDetail(status) {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if status == .needsApproval {
            NavigationLink(String(localized: "End-to-End Encryption")) {
                SyncEncryptionDestination()
            }
        }
    }

    // What the engine's standing problem means, when the status alone does not say it.
    private func serviceDetail(_ status: MobileSyncServiceStatus) -> String? {
        guard status.isWarning, let problem = moves.engineStatus?.problem else { return nil }
        return MobileSyncText.message(forCode: problem)
    }

    // Last Sync keeps the last pass that finished, even while a problem stands: the date is how long this device has
    // gone without syncing.
    @ViewBuilder
    private var lastSyncLabel: some View {
        if let date = lastSyncDate {
            Text(date, style: .relative)
                .foregroundStyle(.secondary)
        } else {
            Text("Never")
                .foregroundStyle(.secondary)
        }
    }

    private var lastSyncDate: Date? {
        guard provider == .tableproSync else { return appState.syncCoordinator.lastSyncDate }
        return moves.engineStatus?.lastPassMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    // MARK: - What syncs

    private func categoriesSection(_ layout: MobileSyncLayout) -> some View {
        Section {
            Toggle(isOn: categoryBinding(\.connections)) {
                Text("Connections")
                Text("Connections set to Local only are left out.")
            }
            .accessibilityIdentifier("settings-sync-category-connections")

            Toggle(isOn: categoryBinding(\.passwords)) {
                Text("Passwords")
                Text(passwordsDetail(layout))
            }
            .disabled(!categories.connections || layout.passwordsOffOnServer)
            .accessibilityIdentifier("settings-sync-category-passwords")

            Toggle(String(localized: "Groups & Tags"), isOn: categoryBinding(\.groupsAndTags))
                .accessibilityIdentifier("settings-sync-category-groups-and-tags")

            Toggle(String(localized: "SSH Profiles"), isOn: categoryBinding(\.sshProfiles))
                .accessibilityIdentifier("settings-sync-category-ssh-profiles")

            Toggle(String(localized: "Saved Queries"), isOn: categoryBinding(\.savedQueries))
                .accessibilityIdentifier("settings-sync-category-saved-queries")
        } header: {
            Text("What Syncs")
        }
    }

    private func categoryBinding(_ keyPath: WritableKeyPath<SyncCategories, Bool>) -> Binding<Bool> {
        Binding(
            get: { categories[keyPath: keyPath] },
            set: { value in
                categories[keyPath: keyPath] = value
                appState.setSyncCategories(categories)
            }
        )
    }

    private func passwordsDetail(_ layout: MobileSyncLayout) -> String {
        if layout.passwordsOffOnServer {
            return String(localized: "Your server does not sync passwords. Each one stays on this device.")
        }
        if provider == .tableproSync {
            return String(localized: "End-to-end encrypted with your account's keys. This device also keeps its own copy of each password.")
        }
        return String(localized: "Stored in iCloud Keychain, end-to-end encrypted. Applies to each password the next time you save it.")
    }

    // MARK: - iCloud data

    private var iCloudDataSection: some View {
        Section {
            Button(String(localized: "Delete iCloud Data"), role: .destructive) {
                iCloudDataProblem = nil
                asksICloudDeletion = true
            }
            .disabled(isDeletingICloudData)
            .accessibilityIdentifier("settings-sync-delete-icloud-data")
        } footer: {
            if let iCloudDataProblem {
                Text(iCloudDataProblem)
            } else {
                Text("TablePro's data stays in iCloud after this device stops syncing with it.")
            }
        }
    }

    // MARK: - Actions

    private func syncNow() async {
        guard provider == .tableproSync else {
            await appState.syncCoordinator.sync(.userRequest)
            return
        }
        serviceProblem = nil
        do {
            try await moves.syncNow()
        } catch {
            MobileSyncText.log("Sync Now failed", error)
            serviceProblem = MobileSyncText.message(for: error)
        }
    }

    private func deleteICloudData() async {
        isDeletingICloudData = true
        defer { isDeletingICloudData = false }
        do {
            try await moves.deleteICloudData()
        } catch {
            MobileSyncText.log("Deleting the iCloud data failed", error)
            iCloudDataProblem = String(localized: "TablePro's data could not be deleted from iCloud. Try again later.")
        }
    }
}

enum SyncProviderSheet: Hashable, Identifiable {
    case moveToService(fromICloud: Bool, session: String?)
    case moveToICloud(session: String?)

    var id: Self { self }
}
