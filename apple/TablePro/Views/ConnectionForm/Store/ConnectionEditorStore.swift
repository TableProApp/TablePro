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

    // Written only through update(_:), the edit methods and the binding helpers, which keep everything below in step.
    @Published var draft: ConnectionDraft
    @Published var traits: ConnectionTypeTraits
    @Published var context: EditorContext
    @Published var layout: EditorLayout
    @Published var issues: [FieldIssue] = []
    @Published var hasUnsavedChanges = false
    @Published var selectedFacet: ConnectionFacet = .general
    @Published var focusRequest: FocusRequest?

    @Published var isRecordMissing = false
    @Published var isLibraryUnreadable = false

    @Published var testState: ConnectionTestState = .idle
    @Published var pluginInstallConnection: DatabaseConnection?
    @Published var pluginDiagnostic: PluginDiagnosticItem?

    @Published var isChoosingType = false
    @Published var pendingRetype: RetypeProposal?
    @Published var sshProfileSheet: SSHProfileSheet?
    @Published var isSavingCredentialsAsProfile = false
    @Published var saveError: ConnectionEditorSaveError?
    @Published var deleteError: ConnectionEditorDeleteError?

    @Published var cloudflaredDetection: BinaryDetection = .notChecked
    @Published var cloudSQLProxyDetection: BinaryDetection = .notChecked
    @Published var cloudSQLProxyDownloadPhase: CloudSQLProxyDownload.Phase = .idle
    @Published var cloudflareSignInError: String?
    @Published var isCloudflareSignInRunning = false
    @Published var pgpassStatus: PgpassStatus = .notChecked
    @Published var pastedURLNotice: PastedURLNotice?

    // Fixed at load: the merge's base. A connectionUpdated event never moves it.
    var baseline: ConnectionDraft
    var baselineEdits: ConnectionFormEdits?
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
    var cancellables: Set<AnyCancellable> = []

    weak var window: NSWindow?
    weak var undoManager: UndoManager?
    var dismissAction: (() -> Void)?

    var storage: ConnectionStorage { services.connectionStorage }

    init(
        request: Request,
        services: AppServices = .live,
        recentConnections: RecentConnectionsStore = .shared,
        listPreferences: ConnectionListPreferences = .shared,
        cloudSQLProxyDownload: CloudSQLProxyDownload = .shared,
        managedPolicy: any ManagedPolicyReading = ManagedPolicyReader.shared
    ) {
        self.services = services
        self.recentConnections = recentConnections
        self.listPreferences = listPreferences
        self.cloudSQLProxyDownload = cloudSQLProxyDownload
        self.managedPolicy = managedPolicy

        let initialType: DatabaseType
        switch request {
        case .edit(let id):
            connectionId = id
            isNew = false
            initialType = services.connectionStorage.loadConnection(id: id)?.type ?? .mysql
        case .new(let type, let parsedURL):
            connectionId = UUID()
            isNew = true
            initialType = parsedURL?.type ?? type ?? .mysql
        }
        let traits = ConnectionTypeTraits.live(for: initialType, pluginManager: services.pluginManager)
        let draft = ConnectionDraft.new(type: initialType, traits: traits)
        self.traits = traits
        self.draft = draft
        self.baseline = draft
        self.context = EditorContext()
        self.layout = EditorLayout(facets: [])

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

    func refreshDerivedState() {
        layout = ConnectionEditorEngine.layout(draft, traits, context)
        issues = ConnectionEditorEngine.issues(draft, traits, context, layout: layout)
        if let dirtyBaseline {
            hasUnsavedChanges = dirtyFingerprint() != dirtyBaseline
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

    func facetHasErrors(_ facet: ConnectionFacet) -> Bool {
        issues.contains { $0.facet == facet && $0.blocksSave }
    }

    var firstBlockingIssue: FieldIssue? {
        issues.first(where: \.blocksSave)
    }

    var canSave: Bool { !isRecordMissing && firstBlockingIssue == nil }

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

    // MARK: - Window

    var windowTitle: String {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return draft.name }
        if !isNew, !baseline.name.isEmpty { return baseline.name }
        return String(localized: "New Connection")
    }

    var windowSubtitle: String { traits.displayName }

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
