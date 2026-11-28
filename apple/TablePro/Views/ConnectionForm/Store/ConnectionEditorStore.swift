//
//  ConnectionEditorStore.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit
import TableProSSHConfig

// The only state container of the connection editor. Views read and write the draft through it, never through each other.
@MainActor
final class ConnectionEditorStore: ObservableObject {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionEditorStore")

    enum Request {
        case edit(connectionId: UUID)
        case new(type: DatabaseType?, parsedURL: ParsedConnectionURL?)
        // Nil when the copy was not staged, which reads as a record that is gone.
        case editTeamCopy(TeamCopyTarget?)
    }

    enum BinaryDetection: Equatable {
        case notChecked
        case checking
        case found(String)
        case notFound
    }

    enum SSHProfileSheet: Identifiable, Equatable {
        case create
        case edit(SSHProfile)
        case saveCurrent(SSHProfile)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let profile): return "edit-\(profile.id.uuidString)"
            case .saveCurrent: return "saveCurrent"
            }
        }
    }

    // The id a new connection is saved under, fixed for the window so a retried Save never mints another.
    let connectionId: UUID
    let isNew: Bool
    let services: AppServices
    let recentConnections: RecentConnectionsStore
    let listPreferences: ConnectionListPreferences
    let cloudSQLProxyDownload: CloudSQLProxyDownload
    let managedPolicy: any ManagedPolicyReading
    let scope: ConnectionScope
    let approvalStores: [ConnectionApprovalStore]
    let teamLibrary: TeamLibrary
    // Set for a Team Library connection, whose Save publishes to its team.
    let teamCopy: TeamCopyTarget?

    // Written only through update(_:), the edit methods and the binding helpers, which keep everything below in step.
    @Published var draft: ConnectionDraft
    @Published var traits: ConnectionTypeTraits
    @Published var context: EditorContext
    @Published var layout: EditorLayout
    @Published var issues: [FieldIssue] = []
    @Published var hasUnsavedChanges = false
    @Published var selectedFacet: ConnectionFacet = .general
    @Published var focusRequest: FocusRequest?
    @Published private(set) var revealedRows: Set<EditorRow> = []
    @Published private(set) var revealsAllIssues = false

    @Published var isRecordMissing = false
    @Published var isLibraryUnreadable = false

    @Published var testState: ConnectionTestState = .idle
    @Published var pluginInstallConnection: DatabaseConnection?
    @Published var pluginDiagnostic: PluginDiagnosticItem?

    @Published var isChoosingType = false
    @Published var pendingRetype: RetypeProposal?
    @Published var sshProfileSheet: SSHProfileSheet?
    // Made once per presentation: the sheet saves, retries and leases Test Source's user under this id.
    @Published var credentialProfileToSave: CredentialProfile?
    @Published var saveError: ConnectionEditorSaveError?
    @Published var isPublishingTeamCopy = false
    @Published var deleteError: ConnectionEditorDeleteError?

    @Published var cloudflaredDetection: BinaryDetection = .notChecked
    @Published var cloudSQLProxyDetection: BinaryDetection = .notChecked
    @Published var cloudSQLProxyDownloadPhase: CloudSQLProxyDownload.Phase = .idle
    @Published var cloudflareSignInError: String?
    @Published var isCloudflareSignInRunning = false
    @Published var pgpassStatus: PgpassStatus = .notChecked
    @Published var pastedURLNotice: PastedURLNotice?

    // Fixed at load: the merge's base. A connectionUpdated event never moves it; only the sign-in a deleted credential
    // profile hands over reaches loadedRecord, as it reaches the draft.
    var baseline: ConnectionDraft
    var baselineEdits: ConnectionFormEdits?
    var loadedRecord: DatabaseConnection?
    var originalTraits: ConnectionTypeTraits?
    var dirtyBaseline: ConnectionEditorEngine.TestFingerprint?

    // Keys a load could not read are never deleted; values it read are not written back unchanged.
    var unreadableSecretKeys: Set<String> = []
    var loadedSecrets: [String: String] = [:]

    var testRun: TestRun?
    var lastTestedFingerprint: ConnectionEditorEngine.TestFingerprint?
    var pendingTestReceipts: [UUID: TestSecretReceipt] = [:]
    var pendingPastedURL: (parsed: ParsedConnectionURL, snapshot: ConnectionDraft)?
    var pastedURLSnapshot: ConnectionDraft?
    var isApplyingPaste = false
    var pgpassLookup: PgpassLookup?
    var cloudflareLogin: CloudflareAccessLogin?
    var wasDownloadingCloudSQLProxy = false
    var isClosing = false
    var hasPlacedInitialFocus = false
    var cancellables: Set<AnyCancellable> = []

    weak var window: NSWindow?
    weak var undoManager: UndoManager?
    var dismissAction: (() -> Void)?
    var connectAction: (DatabaseConnection) -> Void = { ConnectionEditorStore.connectToDatabase($0) }

    var storage: ConnectionStorage { services.connectionStorage }

    init(
        request: Request,
        services: AppServices = .live,
        recentConnections: RecentConnectionsStore = .shared,
        listPreferences: ConnectionListPreferences = .shared,
        cloudSQLProxyDownload: CloudSQLProxyDownload = .shared,
        managedPolicy: any ManagedPolicyReading = ManagedPolicyReader.shared,
        approvalStores: [ConnectionApprovalStore] = ConnectionApprovalStore.all,
        scope: ConnectionScope = .shared,
        teamLibrary: TeamLibrary = .shared
    ) {
        self.services = services
        self.scope = scope
        self.teamLibrary = teamLibrary
        self.recentConnections = recentConnections
        self.listPreferences = listPreferences
        self.cloudSQLProxyDownload = cloudSQLProxyDownload
        self.managedPolicy = managedPolicy
        self.approvalStores = approvalStores

        let initialType: DatabaseType
        switch request {
        case .edit(let id):
            connectionId = id
            isNew = false
            teamCopy = nil
            initialType = services.connectionStorage.loadConnection(id: id)?.type ?? .mysql
        case .new(let type, let parsedURL):
            connectionId = UUID()
            isNew = true
            teamCopy = nil
            initialType = parsedURL?.type ?? type ?? .mysql
        case .editTeamCopy(let target):
            connectionId = target?.original.connection.id ?? UUID()
            isNew = false
            teamCopy = target
            initialType = target?.original.connection.type ?? .mysql
        }
        let traits = ConnectionTypeTraits.live(for: initialType, pluginManager: services.pluginManager)
        let draft = ConnectionDraft.new(type: initialType, traits: traits)
        self.traits = traits
        self.draft = draft
        self.baseline = draft
        self.context = EditorContext()
        self.layout = EditorLayout(facets: [])
        revealsAllIssues = !isNew

        load(request)
        subscribe()
    }

    // MARK: - Writes

    // Every edit goes through here, so layout, issues, dirty state and the test result follow in one place.
    func update(_ mutate: (inout ConnectionDraft) -> Void) {
        var next = draft
        mutate(&next)
        commit(next)
    }

    func commit(_ next: ConnectionDraft) {
        let normalized = ConnectionEditorEngine.normalized(next, traits)
        if normalized != draft {
            draft = normalized
            if pastedURLSnapshot != nil, !isApplyingPaste {
                dismissPastedURLNotice()
            }
        }
        refreshDerivedState()
    }

    // Each assignment is published only when it changed: every publish re-renders each view that observes the store.
    func refreshDerivedState() {
        let nextLayout = ConnectionEditorEngine.layout(draft, traits, context)
        if nextLayout != layout {
            layout = nextLayout
        }
        let nextIssues = ConnectionEditorEngine.issues(draft, traits, context, layout: nextLayout)
        if nextIssues != issues {
            issues = nextIssues
        }
        if let dirtyBaseline {
            let dirty = dirtyFingerprint() != dirtyBaseline
            if dirty != hasUnsavedChanges {
                hasUnsavedChanges = dirty
            }
        }
        if !layout.facetIDs.contains(selectedFacet) {
            selectedFacet = .general
        }
        invalidateStaleTestResult()
        startBinaryDetectionIfNeeded()
        refreshPgpassStatus()
    }

    func dirtyFingerprint() -> ConnectionEditorEngine.TestFingerprint {
        let edits = ConnectionEditorEngine.edits(draft, traits, originalTraits: originalTraits, context)
        let secrets = ConnectionEditorEngine.testFingerprint(draft, traits, originalTraits: originalTraits, context).secrets
        return ConnectionEditorEngine.TestFingerprint(edits: edits, secrets: secrets)
    }

    // MARK: - Issues

    func issues(for facet: ConnectionFacet) -> [FieldIssue] {
        issues.filter { $0.facet == facet }
    }

    func issues(for row: EditorRow) -> [FieldIssue] {
        issues.filter { $0.row == row }
    }

    func issue(for row: EditorRow) -> FieldIssue? {
        issues.first { $0.row == row }
    }

    var firstBlockingIssue: FieldIssue? {
        issues.first(where: \.blocksSave)
    }

    // One rule for the row, the sidebar mark and the commit bar: a pristine new form is never painted red.
    func isRevealed(_ issue: FieldIssue) -> Bool {
        revealsAllIssues || revealedRows.contains(issue.row)
    }

    func revealedIssue(for row: EditorRow) -> FieldIssue? {
        guard let issue = issue(for: row), isRevealed(issue) else { return nil }
        return issue
    }

    func facetHasRevealedErrors(_ facet: ConnectionFacet) -> Bool {
        issues.contains { $0.facet == facet && $0.blocksSave && isRevealed($0) }
    }

    func noteEdited(_ row: EditorRow) {
        guard !revealsAllIssues, !revealedRows.contains(row) else { return }
        revealedRows.insert(row)
    }

    func revealAllIssues() {
        guard !revealsAllIssues else { return }
        revealsAllIssues = true
    }

    // Asking why Save is off is asking to see the issue.
    func reveal(_ issue: FieldIssue) {
        noteEdited(issue.row)
        focus(on: issue)
    }

    // A control's changes count as edits of its row; a write from code, or a field handing back what it showed, does not.
    func tracking<Value: Equatable>(_ binding: Binding<Value>, row: EditorRow) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue, transaction in
                if newValue != binding.wrappedValue {
                    self.noteEdited(row)
                }
                binding.transaction(transaction).wrappedValue = newValue
            }
        )
    }

    var canSave: Bool { !isRecordMissing && !isPublishingTeamCopy && firstBlockingIssue == nil }

    var canTest: Bool { !isTesting && !isRecordMissing && !issues.contains(where: \.blocksTest) }

    func focus(on issue: FieldIssue) {
        focus(facet: issue.facet, row: issue.row)
    }

    func focus(facet: ConnectionFacet, row: EditorRow) {
        selectedFacet = facet
        focusRequest = FocusRequest(facet: facet, row: row, token: UUID())
    }

    func focusFirstIssue() {
        guard let issue = firstBlockingIssue ?? issues.first else { return }
        focus(on: issue)
    }

    // Spent once a row takes it, so a row that appears later never pulls the cursor back.
    func didApplyFocus(_ request: FocusRequest) {
        if focusRequest == request {
            focusRequest = nil
        }
    }

    // Once per window: a new connection starts where its address goes, a saved one at its name.
    func placeInitialFocusIfNeeded() {
        guard !hasPlacedInitialFocus else { return }
        hasPlacedInitialFocus = true
        guard focusRequest == nil, selectedFacet == .general else { return }
        let target = isNew
            ? [EditorRow.builtIn(.host), .builtIn(.databaseFile)].first { layout.isEnabled($0) } ?? .builtIn(.name)
            : .builtIn(.name)
        focus(facet: .general, row: target)
    }

    // MARK: - Window

    var windowTitle: String {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return draft.name }
        if !isNew, !baseline.name.isEmpty { return baseline.name }
        return String(localized: "New Connection")
    }

    // A team's copy names who last changed it, so the person sees whose version they edit.
    var windowSubtitle: String {
        guard let original = teamCopy?.original,
              let lastChange = WelcomeRowPresentation.lastChangeLine(by: original.lastWriter, at: original.lastChangedAt)
        else { return traits.displayName }
        return lastChange
    }

    var namePrompt: String {
        ConnectionEditorEngine.fallbackName(draft, traits, context)
    }

    var effectiveName: String {
        ConnectionEditorEngine.effectiveName(draft, traits, context)
    }

    func cancel() {
        dismissAction?()
    }

    // Closing the window reaps a running test's staged secrets, which only its own completion deletes otherwise.
    func teardown() {
        isClosing = true
        cancelTest()
        for receipt in Array(pendingTestReceipts.values) {
            cleanupTestSecrets(receipt)
        }
        cloudflareLogin = nil
        cancellables.removeAll()
    }
}
