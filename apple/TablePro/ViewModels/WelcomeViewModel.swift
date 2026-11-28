//
//  WelcomeViewModel.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProConnectionLibrary
import TableProImport
import TableProPluginKit

internal struct WelcomeNewGroupRequest: Hashable {
    internal let parentId: UUID?
    internal let movingConnectionIds: [UUID]
}

internal struct WelcomeTagFilter: Equatable {
    // In the order they were turned on; a tag missing from storage still filters but has nothing to show.
    internal var tags: [ConnectionTag] = []
    internal var tagCount = 0
    internal var match: LibraryTagMatch = .any

    internal var isActive: Bool { tagCount > 0 }
    internal var offersMatch: Bool { tagCount > 1 }
}

enum WelcomeActiveSheet: Identifiable {
    case newGroup(WelcomeNewGroupRequest)
    /// Carries the group as it was when the sheet opened, so a sync that deletes it meanwhile
    /// leaves the sheet open with an error on Save rather than empty.
    case editGroup(ConnectionGroup)
    case importFile(URL)
    case exportConnections([DatabaseConnection])
    case importFromApp
    case importFromAWS
    case projectFolderScan(URL)
    case deeplinkImport(ConnectionBundle)
    case teamLibraryConflicts
    case newProject
    case manageProjects

    var id: String {
        switch self {
        case .newGroup(let request):
            "newGroup-\(request.parentId?.uuidString ?? "root")-"
                + request.movingConnectionIds.map(\.uuidString).joined(separator: ",")
        case .editGroup(let group): "editGroup-\(group.id.uuidString)"
        case .importFile(let u): "importFile-\(u.absoluteString)"
        case .exportConnections: "exportConnections"
        case .importFromApp: "importFromApp"
        case .importFromAWS: "importFromAWS"
        case .projectFolderScan(let u): "projectFolderScan-\(u.absoluteString)"
        case .deeplinkImport(let bundle):
            "deeplinkImport-" + bundle.connections
                .map { "\($0.settings.type)-\($0.settings.name)-\($0.settings.host)-\($0.settings.port)" }
                .joined(separator: ",")
        case .teamLibraryConflicts: "teamLibraryConflicts"
        case .newProject: "newProject"
        case .manageProjects: "manageProjects"
        }
    }
}

@MainActor
internal protocol WelcomeOutlineControlling: AnyObject {
    var outlineUndoManager: UndoManager? { get }
    func beginRename(_ row: LibraryRowID)
    func focusList(selectFirstRow: Bool)
}

@MainActor
final class WelcomeViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WelcomeViewModel")
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000

    let services: AppServices
    let recentConnections: RecentConnectionsStore
    let listPreferences: ConnectionListPreferences
    let scope: ConnectionScope
    var projectStorage: ProjectStorage { services.projectStorage }
    weak var outlineController: WelcomeOutlineControlling?
    var storage: ConnectionStorage { services.connectionStorage }
    var groupStorage: GroupStorage { services.groupStorage }

    // MARK: - Library

    @Published private(set) var connections: [DatabaseConnection] = []
    @Published private(set) var groups: [ConnectionGroup] = []
    @Published private(set) var tags: [ConnectionTag] = []
    private(set) var connectionsById: [UUID: DatabaseConnection] = [:]
    private(set) var groupsById: [UUID: ConnectionGroup] = [:]
    private(set) var tagsById: [UUID: ConnectionTag] = [:]
    private(set) var groupGraph = LibraryGroupGraph(groups: [ConnectionGroup]())
    private(set) var groupConnectionCounts: [UUID: Int] = [:]
    // The lists above hold the whole library, so an edit, a lookup by id and the device state never lose
    // another project's records. Only what is listed reads this.
    private(set) var scopedLibrary = LibraryScopedLibrary<DatabaseConnection, ConnectionGroup>(
        projectId: nil,
        connections: [],
        groups: []
    )
    @Published private(set) var projects: [ConnectionProject] = []
    @Published private(set) var activeProjectId: UUID?
    @Published var linkedConnections: [LinkedConnection] = [] {
        didSet { rebuildOutline() }
    }
    @Published var teamLibraryConnections: [DatabaseConnection] = [] {
        didSet { rebuildOutline() }
    }

    // MARK: - Query

    @Published var searchText = "" { didSet { scheduleRebuild(previous: oldValue) } }
    @Published var tagFilterIds: [UUID] = [] {
        didSet { if tagFilterIds != oldValue { rebuildOutline() } }
    }
    @Published var tagMatch: LibraryTagMatch = .any {
        didSet { if tagMatch != oldValue { rebuildOutline() } }
    }
    @Published private(set) var tagFilter = WelcomeTagFilter()

    // MARK: - Outline

    @Published private(set) var outline: LibraryOutline = .empty
    @Published private(set) var outlineRevision = 0
    @Published private(set) var sortMode: LibrarySortMode
    private(set) var showsRecent: Bool
    @Published var expandedGroupIds: Set<UUID> = [] {
        didSet { groupExpansionStore.save(expandedGroupIds) }
    }
    @Published var selection: [LibraryRowID] = []

    // MARK: - Presentation

    @Published private(set) var hasImportableApp = false
    @Published var connectionsToDelete: [DatabaseConnection] = []
    @Published var showDeleteConfirmation = false
    @Published var connectionsToExcludeFromSync: [DatabaseConnection] = []
    @Published var showExcludeFromSyncConfirmation = false
    // The provider the Exclude question names, read when it is asked.
    @Published var excludeFromSyncProvider: SyncProviderSetting = .iCloud
    @Published var pendingDeleteHasFavorites = false
    private var deleteRequestToken = UUID()
    @Published var showDeleteGroupConfirmation = false
    @Published var groupToDelete: ConnectionGroup?
    @Published var activeSheet: WelcomeActiveSheet?
    @Published var pluginInstallConnection: DatabaseConnection?

    @Published var databaseTypeChooser: DatabaseTypeChooserPayload?
    @Published var urlImportPresented = false
    @Published var pendingInstallType: DatabaseType?
    var pendingInstallPayload: DatabaseTypeChooserPayload?

    @Published var libraryErrorMessage: String?

    @Published var connectionError: String?
    @Published var connectionErrorRecovery: PendingConnectionRecovery?
    @Published var showConnectionError = false
    @Published var pluginDiagnostic: PluginDiagnosticItem?

    @Published var showImportFilePanel = false
    @Published var importOutcome: ImportOutcome?
    // Handed off from the sheet's `onDismiss`, so an alert or a new window waits for the sheet to finish closing.
    @Published var finishedImport: FinishedImport?

    // MARK: - Observers

    private var connectionUpdatedCancellable: AnyCancellable?
    private var listStateCancellable: AnyCancellable?
    private var scopeCancellable: AnyCancellable?
    private var showsRecentCancellable: AnyCancellable?
    private var linkedFoldersCancellable: AnyCancellable?
    private var teamLibraryCancellable: AnyCancellable?
    private var licenseCancellable: AnyCancellable?
    private var connectionStatusCancellable: AnyCancellable?
    private var welcomeRouterTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var importableAppRefresh: Task<Void, Never>?
    private let importableAppDetector: @MainActor () async -> Bool
    private let groupExpansionStore: WelcomeGroupExpansionStore
    private let hasStoredGroupExpansion: Bool

    // MARK: - Initialization

    convenience init() {
        self.init(services: .live)
    }

    init(
        services: AppServices,
        importableAppDetector: @escaping @MainActor () async -> Bool = { await !ForeignSourceScanner.probe().isEmpty },
        groupExpansionStore: WelcomeGroupExpansionStore = WelcomeGroupExpansionStore(),
        recentConnections: RecentConnectionsStore = .shared,
        listPreferences: ConnectionListPreferences = .shared,
        scope: ConnectionScope = .shared
    ) {
        self.services = services
        self.importableAppDetector = importableAppDetector
        self.groupExpansionStore = groupExpansionStore
        self.recentConnections = recentConnections
        self.listPreferences = listPreferences
        self.scope = scope
        self.sortMode = listPreferences.sortMode
        self.showsRecent = listPreferences.showsRecent
        let storedExpansion = groupExpansionStore.load()
        self.hasStoredGroupExpansion = storedExpansion != nil
        self.expandedGroupIds = storedExpansion ?? []
    }

    deinit {
        welcomeRouterTask?.cancel()
        searchDebounceTask?.cancel()
        importableAppRefresh?.cancel()
    }

    // MARK: - Derived State

    var availableTags: [ConnectionTag] {
        let usedIds = Set(scopedLibrary.connections.flatMap(\.tagIds))
        return tags.filter { usedIds.contains($0.id) }
    }

    var scopedGroups: [ConnectionGroup] {
        scopedLibrary.groups
    }

    var activeProject: ConnectionProject? {
        activeProjectId.flatMap { id in projects.first { $0.id == id } }
    }

    func tagSuggestions(matching text: String) -> [ConnectionTag] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let active = Set(tagFilterIds)
        return availableTags.filter { !active.contains($0.id) && $0.name.localizedCaseInsensitiveContains(term) }
    }

    func setTagFilter(_ tagId: UUID, isOn: Bool) {
        if isOn {
            guard !tagFilterIds.contains(tagId) else { return }
            tagFilterIds.append(tagId)
        } else {
            tagFilterIds.removeAll { $0 == tagId }
        }
    }

    // The typed text only led to the tag, so it goes once the tag filters instead.
    func applyTagSuggestion(_ tagId: UUID) {
        searchText = ""
        setTagFilter(tagId, isOn: true)
    }

    func clearTagFilters() {
        tagFilterIds.removeAll()
    }

    var query: LibraryQuery {
        LibraryQuery(text: searchText, tagIds: Set(tagFilterIds), tagMatch: tagMatch)
    }

    var isFiltering: Bool {
        query.isActive
    }

    var presentableLinkedConnections: [LinkedConnection] {
        guard services.featureAccess.isAvailable(.linkedFolders) else { return [] }
        return linkedConnections
    }

    var presentableTeamLibraryConnections: [DatabaseConnection] {
        guard services.featureAccess.isAvailable(.teamLibrary) else { return [] }
        return teamLibraryConnections
    }

    var sharedConnectionsById: [UUID: WelcomeSharedConnection] {
        Dictionary(
            presentableLinkedConnections.map { ($0.id, WelcomeSharedConnection.linked($0)) }
                + presentableTeamLibraryConnections.map { ($0.id, WelcomeSharedConnection.team($0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var hasAnyConnection: Bool {
        !connections.isEmpty || !presentableLinkedConnections.isEmpty || !presentableTeamLibraryConnections.isEmpty
    }

    var isSearchAvailable: Bool {
        hasAnyConnection
    }

    var showsSectionHeaders: Bool {
        !(outline.sections.count == 1 && outline.sections.first?.kind == .connections)
    }

    var listState: WelcomeListState {
        WelcomeListState.resolve(WelcomeListState.Input(
            hasAnyConnection: hasAnyConnection,
            hasVisibleContent: !outline.isEmpty,
            searchText: query.trimmedText,
            isTagFiltered: !tagFilterIds.isEmpty,
            activeProjectName: activeProject?.name
        ))
    }

    func isGroupExpanded(_ groupId: UUID) -> Bool {
        isFiltering ? outline.groupIdsExpandedByQuery.contains(groupId) : expandedGroupIds.contains(groupId)
    }

    func setGroupExpanded(_ groupId: UUID, _ expanded: Bool) {
        guard !isFiltering else { return }
        if expanded {
            expandedGroupIds.insert(groupId)
        } else {
            expandedGroupIds.remove(groupId)
        }
    }

    // MARK: - Outline

    func rebuildOutline() {
        refreshScope()
        guard filtersStillApply() else { return }
        connectionsById = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tagsById = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupGraph = LibraryGroupGraph(groups: groups)
        outline = LibraryOutlineBuilder.build(outlineRequest(query: query))
        groupConnectionCounts = Self.groupCounts(in: outline)
        let visible = visibleRowIds()
        selection = selection.filter { visible.contains($0) }
        let filter = WelcomeTagFilter(
            tags: tagFilterIds.compactMap { tagsById[$0] },
            tagCount: tagFilterIds.count,
            match: tagMatch
        )
        if filter != tagFilter {
            tagFilter = filter
        }
        outlineRevision += 1
    }

    func outlineRequest(query: LibraryQuery) -> LibraryOutlineRequest<DatabaseConnection, ConnectionGroup, ConnectionTag> {
        LibraryOutlineRequest(
            connections: scopedLibrary.connections,
            groups: scopedLibrary.groups,
            tags: tags,
            sortMode: sortMode,
            query: query,
            favoritesOrder: listPreferences.favoritesOrder,
            lastConnected: recentConnections.lastConnected,
            includesRecent: showsRecent,
            externalSections: [
                LibraryExternalSection(kind: .linkedFolders, entries: presentableLinkedConnections.map(\.libraryEntry)),
                LibraryExternalSection(kind: .teamLibrary, entries: presentableTeamLibraryConnections.map(\.libraryExternalEntry)),
            ]
        )
    }

    func visibleRowIds() -> Set<LibraryRowID> {
        var rows: Set<LibraryRowID> = []
        let headers = showsSectionHeaders
        for section in outline.sections {
            if headers {
                rows.insert(.section(section.kind))
            }
            collectVisibleRows(section.nodes, in: section.kind, into: &rows)
        }
        return rows
    }

    private func collectVisibleRows(
        _ nodes: [LibraryNode],
        in section: LibrarySectionKind,
        into rows: inout Set<LibraryRowID>
    ) {
        for node in nodes {
            rows.insert(node.rowID(in: section))
            if case .group(let id, let children, _) = node, isGroupExpanded(id) {
                collectVisibleRows(children, in: section, into: &rows)
            }
        }
    }

    private static func groupCounts(in outline: LibraryOutline) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        func visit(_ nodes: [LibraryNode]) {
            for node in nodes {
                guard case .group(let id, let children, let count) = node else { continue }
                counts[id] = count
                visit(children)
            }
        }
        visit(outline.section(.connections)?.nodes ?? [])
        return counts
    }

    private func filtersStillApply() -> Bool {
        if !hasAnyConnection, !searchText.isEmpty {
            searchText = ""
            return false
        }
        let usedTagIds = Set(scopedLibrary.connections.flatMap(\.tagIds))
        let keptTagIds = tagFilterIds.filter { usedTagIds.contains($0) }
        guard keptTagIds.count == tagFilterIds.count else {
            tagFilterIds = keptTagIds
            return false
        }
        return true
    }

    private func scheduleRebuild(previous: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        if searchText.isEmpty || previous.isEmpty {
            rebuildOutline()
            return
        }
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            searchDebounceTask = nil
            rebuildOutline()
        }
    }

    // Return can arrive inside the debounce; picking the first row then picked it from the list for
    // fewer typed characters, and the late rebuild dropped that row and the selection with it.
    func submitSearch() {
        if let pending = searchDebounceTask {
            pending.cancel()
            searchDebounceTask = nil
            rebuildOutline()
        }
        focusList(selectFirstRow: true)
    }

    // Read on every rebuild: the active project and the project list change outside this window.
    private func refreshScope() {
        scopedLibrary = scope.scoped(connections: connections, groups: groups)
        let stored = projectStorage.loadProjects()
        if projects != stored {
            projects = stored
        }
        if activeProjectId != scopedLibrary.projectId {
            activeProjectId = scopedLibrary.projectId
        }
    }

    func setSortMode(_ mode: LibrarySortMode) {
        listPreferences.setSortMode(mode)
        guard sortMode != mode else { return }
        sortMode = mode
        rebuildOutline()
    }

    func focusList(selectFirstRow: Bool = false) {
        outlineController?.focusList(selectFirstRow: selectFirstRow)
    }

    private func listStateDidChange() {
        sortMode = listPreferences.sortMode
        rebuildOutline()
    }

    private func showsRecentDidChange(_ showsRecent: Bool) {
        guard showsRecent != self.showsRecent else { return }
        self.showsRecent = showsRecent
        rebuildOutline()
    }

    // MARK: - Setup

    // The probe runs off the main actor; an answer a newer refresh replaced is dropped.
    @discardableResult
    func refreshImportableApp() -> Task<Void, Never> {
        importableAppRefresh?.cancel()
        let detector = importableAppDetector
        let refresh = Task { @MainActor [weak self] in
            let found = await detector()
            guard !Task.isCancelled, let self else { return }
            hasImportableApp = found
        }
        importableAppRefresh = refresh
        return refresh
    }

    func setUp() {
        refreshImportableApp()
        guard connectionUpdatedCancellable == nil else { return }

        if !hasStoredGroupExpansion {
            let allGroupIds = Set(groupStorage.loadGroups().map(\.id))
            if !allGroupIds.isEmpty {
                expandedGroupIds = allGroupIds
            }
        }

        connectionUpdatedCancellable = services.appEvents.connectionUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loadConnections()
            }

        listStateCancellable = services.appEvents.connectionListStateChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.listStateDidChange()
            }

        // Sent on the main actor. The outline view holds the reload back while a drag or a rename runs.
        scopeCancellable = scope.scopedSetChanged
            .sink { [weak self] _ in
                self?.loadConnections()
            }

        showsRecentCancellable = listPreferences.$showsRecent
            .dropFirst()
            .sink { [weak self] showsRecent in
                self?.showsRecentDidChange(showsRecent)
            }

        linkedFoldersCancellable = services.appEvents.linkedFoldersDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.linkedConnections = self.services.linkedFolderWatcher.linkedConnections
            }

        teamLibraryCancellable = services.appEvents.teamLibraryDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.teamLibraryConnections = Self.buildTeamLibraryConnections()
            }

        licenseCancellable = services.appEvents.licenseStatusDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.teamLibraryConnections = Self.buildTeamLibraryConnections()
            }

        // The row's mark reads the session and the window phase, neither observable, so the revision moves on both.
        connectionStatusCancellable = Publishers.Merge(
            services.appEvents.connectionStatusChanged.map { $0.connectionId },
            services.appEvents.connectionPhaseChanged
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.outlineRevision += 1
        }

        loadConnections()
        linkedConnections = services.linkedFolderWatcher.linkedConnections
        teamLibraryConnections = Self.buildTeamLibraryConnections()

        consumePendingRouterActions()
        startWelcomeRouterObservation()
    }

    private func consumePendingRouterActions() {
        let router = services.welcomeRouter
        if let request = router.consumePendingRequest() {
            handle(request)
            return
        }
        if let pendingURL = router.consumePendingShare() {
            activeSheet = .importFile(pendingURL)
            return
        }
        if let pendingImport = router.consumePendingImport() {
            activeSheet = .deeplinkImport(pendingImport)
            return
        }
        if let pendingInstall = router.consumePendingPluginInstall() {
            pluginInstallConnection = pendingInstall
            return
        }
        if let pendingError = router.consumePendingError() {
            presentConnectionFailure(pendingError.error, connection: pendingError.connection)
        }
    }

    private func startWelcomeRouterObservation() {
        welcomeRouterTask?.cancel()
        let router = services.welcomeRouter
        welcomeRouterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.consumePendingRouterActions()
                guard await Self.awaitWelcomeRouterChange(router: router) else { return }
            }
        }
    }

    private static func awaitWelcomeRouterChange(router: WelcomeRouter) async -> Bool {
        let box = ContinuationBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.set(continuation)
                /// One-shot: the continuation resumes on the first change, and the sink is
                /// released with the box, so nothing needs re-arming.
                box.hold(router.onMainActorChange {
                    box.resume(with: true)
                })
            }
        } onCancel: {
            box.resume(with: false)
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        private var observation: AnyCancellable?

        /// Keeps the subscription alive until the continuation resumes.
        func hold(_ cancellable: AnyCancellable) {
            lock.lock()
            defer { lock.unlock() }
            observation = cancellable
        }

        private var continuation: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()

        func set(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func resume(with value: Bool) {
            lock.lock()
            observation = nil
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    // MARK: - Data Loading

    func loadConnections() {
        connections = storage.loadConnections()
        tags = services.tagStorage.loadTags()
        groups = groupStorage.loadGroups()
        pruneDeviceState()
        rebuildOutline()
    }

    // A library that did not load, or a record this build cannot read, keeps its place.
    private func pruneDeviceState() {
        guard !storage.lastLoadFailed else { return }
        let unreadableIds = storage.unreadableConnectionIds
        let favoriteIds = Set(connections.filter(\.isFavorite).map(\.id)).union(unreadableIds)
        listPreferences.setFavoritesOrder(
            LibraryOrdering.favoritesOrder(listPreferences.favoritesOrder, keeping: favoriteIds)
        )
        guard !connections.isEmpty else { return }
        recentConnections.retain(only: Set(connections.map(\.id)).union(unreadableIds))
    }

    // The list shows one project and the saved order holds every project's, so a change made here is merged in.
    func saveFavoritesOrder(_ updated: [UUID], replacing displayed: [UUID]) {
        listPreferences.setFavoritesOrder(
            LibraryOrdering.favoritesOrder(listPreferences.favoritesOrder, scoped: displayed, reorderedTo: updated)
        )
    }

    // MARK: - Connecting

    func connectToDatabase(_ connection: DatabaseConnection) {
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    func connectAfterInstall(_ connection: DatabaseConnection) {
        connectToDatabase(connection)
    }

    func connectToSharedConnection(_ shared: WelcomeSharedConnection) {
        let connection = shared.databaseConnection()
        Task {
            do {
                try await TabRouter.shared.openTransientConnection(connection)
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    private static func buildTeamLibraryConnections() -> [DatabaseConnection] {
        guard FeatureAccess.shared.isAvailable(.teamLibrary) else { return [] }
        return TeamLibrary.shared.content.connections.map(\.connection)
    }

    // MARK: - Import / Export

    func exportConnections(_ connectionsToExport: [DatabaseConnection]) {
        guard !connectionsToExport.isEmpty else { return }
        activeSheet = .exportConnections(connectionsToExport)
    }

    func importConnectionsFromApp() {
        activeSheet = .importFromApp
    }

    func importConnectionsFromAWS() {
        activeSheet = .importFromAWS
    }

    func importConnectionsFromFile() {
        showImportFilePanel = true
    }

    func finishImport(_ outcome: ImportOutcome, from origin: ImportOrigin) {
        finishedImport = FinishedImport(outcome: outcome, origin: origin)
        activeSheet = nil
    }

    internal struct FinishedImport: Equatable {
        let outcome: ImportOutcome
        let origin: ImportOrigin
    }

    internal enum ImportEnding: Equatable {
        case open(UUID)
        case select([UUID])
        case report(ImportOutcome, selecting: [UUID])
    }

    // A clean import hands off like the setup guide; anything failed or not kept is reported, and nothing opens.
    internal static func importEnding(for outcome: ImportOutcome, from origin: ImportOrigin) -> ImportEnding {
        let notKept = outcome.failure != nil || outcome.passwordsNotKept > 0 || outcome.savedQueriesNotImported > 0
        switch outcome.handoff(from: origin) {
        case .open(let id) where !notKept:
            return .open(id)
        case .select(let ids) where !notKept:
            return .select(ids)
        default:
            return .report(outcome, selecting: outcome.connectionIds)
        }
    }

    // A presentation a routed request or a failed connect opened; the setup guide stays out of its way.
    var hasRoutedPresentation: Bool {
        activeSheet != nil
            || databaseTypeChooser != nil
            || urlImportPresented
            || pendingInstallType != nil
            || pluginInstallConnection != nil
            || pluginDiagnostic != nil
            || showConnectionError
            || showImportFilePanel
    }

    // The setup guide's ending, run here so a failed connect reports on Welcome as a list open does.
    func handOff(_ handoff: ImportHandoff) {
        switch handoff {
        case .open(let id):
            loadConnections()
            guard let connection = connectionsById[id] else { return }
            connectToDatabase(connection)
        case .select(let ids):
            revealConnections(ids)
        case .stay:
            return
        }
    }

    func importSheetDidDismiss() {
        guard let finished = finishedImport else { return }
        finishedImport = nil
        let outcome = finished.outcome
        switch Self.importEnding(for: outcome, from: finished.origin) {
        case .open(let id):
            loadConnections()
            guard let connection = connectionsById[id] else {
                importOutcome = outcome
                return
            }
            connectToDatabase(connection)
        case .select(let ids):
            revealConnections(ids)
        case .report(let reported, let ids):
            revealConnections(ids)
            importOutcome = reported
        }
    }

    // A search, a tag filter or a collapsed group would hide the rows, and the outline drops a hidden row's selection.
    private func revealConnections(_ ids: [UUID]) {
        loadConnections()
        let present = ids.filter { connectionsById[$0] != nil }
        guard !present.isEmpty else { return }
        if !searchText.isEmpty {
            searchText = ""
        }
        if !tagFilterIds.isEmpty {
            tagFilterIds = []
        }
        for id in present {
            if let groupId = connectionsById[id]?.groupId {
                expandedGroupIds.formUnion(groupGraph.pathIds(to: groupId))
            }
        }
        rebuildOutline()
        selection = present.map { .connection($0, section: .connections) }
        focusList()
    }

    func connectionString(for connection: DatabaseConnection) -> String {
        let password = storage.loadPassword(for: connection.id)
        guard let profileId = connection.sshProfileId else {
            return ConnectionURLFormatter.format(
                connection,
                password: password,
                sshPassword: storage.loadSSHPassword(for: connection.id),
                sshProfile: nil
            )
        }
        let profiles = services.sshProfileStorage
        return ConnectionURLFormatter.format(
            connection,
            password: password,
            sshPassword: profiles.loadSSHPassword(for: profileId),
            sshProfile: profiles.profile(for: profileId)
        )
    }

    // MARK: - Connection Errors

    internal enum ConnectErrorRoute: Equatable {
        case ignore
        case window
        case pluginInstall
        case alert
    }

    // A connect that reached a window reports there, inline in its pane. Only an error raised
    // before any window could take the connection, such as a record that is gone, is shown here.
    internal static func route(for error: Error, isShownInWindow: Bool) -> ConnectErrorRoute {
        if error.isUserCancellation { return .ignore }
        if isShownInWindow { return .window }
        if case PluginError.pluginNotInstalled = error { return .pluginInstall }
        return .alert
    }

    func handleConnectError(_ error: Error, connection: DatabaseConnection) {
        switch Self.route(for: error, isShownInWindow: WindowManager.shared.hasOpenWindow(for: connection.id)) {
        case .ignore:
            Self.logger.info("Connection attempt cancelled for \(connection.name, privacy: .private(mask: .hash))")
        case .window:
            Self.logger.info("Connect failed in its window: \(error.publicLogShape, privacy: .public)")
        case .pluginInstall:
            Self.logger.info("Plugin not installed for \(connection.type.rawValue, privacy: .public)")
            pluginInstallConnection = connection
        case .alert:
            Self.logger.error("Failed to open the connection: \(error.publicLogShape, privacy: .public)")
            presentConnectionFailure(error, connection: connection)
        }
    }

    private func presentConnectionFailure(_ error: Error, connection: DatabaseConnection) {
        if let item = PluginDiagnosticItem.classify(
            error: error, connection: connection, username: connection.username
        ) {
            pluginDiagnostic = item
            return
        }
        guard let action = ConnectionFailureClassifier.recoveryAction(
            for: error,
            canEditConnection: ConnectionRecoveryPerformer.canEdit(connection)
        ) else {
            connectionErrorRecovery = nil
            connectionError = SSLHandshakeError.formatted(error)
            showConnectionError = true
            return
        }
        let info = ConnectionFailureClassifier.info(for: error)
        connectionErrorRecovery = PendingConnectionRecovery(action: action, connection: connection)
        connectionError = [info.message, info.failureReason, info.recoverySuggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        showConnectionError = true
    }

    func performConnectionErrorRecovery() {
        guard let recovery = connectionErrorRecovery else { return }
        dismissConnectionError()
        ConnectionRecoveryPerformer.perform(recovery.action, for: recovery.connection)
    }

    func dismissConnectionError() {
        connectionError = nil
        connectionErrorRecovery = nil
    }

    // MARK: - Delete

    func requestDeleteConnections(_ ids: [UUID]) {
        let targets = ids.compactMap { connectionsById[$0] }
        guard !targets.isEmpty else { return }
        let token = UUID()
        deleteRequestToken = token
        connectionsToDelete = targets
        pendingDeleteHasFavorites = false
        Task {
            let hasFavorites = await services.sqlFavoriteManager.hasFavorites(for: targets.map(\.id))
            guard deleteRequestToken == token else { return }
            pendingDeleteHasFavorites = hasFavorites
            showDeleteConfirmation = true
        }
    }

    func deleteSelectedConnections() {
        let ids = Set(connectionsToDelete.map(\.id))
        connectionsToDelete = []
        let stored = storage.loadConnections().filter { ids.contains($0.id) }
        guard !stored.isEmpty else { return }
        guard storage.deleteConnections(stored) else {
            reportLibraryWriteFailure()
            loadConnections()
            return
        }
        recentConnections.remove(ids)
        listPreferences.setFavoritesOrder(LibraryOrdering.favoritesOrder(listPreferences.favoritesOrder, removing: ids))
        selection.removeAll { row in
            guard case .connection(let id, _) = row else { return false }
            return ids.contains(id)
        }
        services.appEvents.connectionUpdated.send(nil)
        loadConnections()
    }

    func reportLibraryWriteFailure() {
        libraryErrorMessage = String(
            localized: "The change could not be saved. Check disk space and permissions, then try again."
        )
    }

    // MARK: - Groups

    func requestNewGroup(parentId: UUID?, movingConnectionIds: [UUID]) {
        activeSheet = .newGroup(WelcomeNewGroupRequest(parentId: parentId, movingConnectionIds: movingConnectionIds))
    }

    func createGroup(
        name: String,
        color: ConnectionColor,
        iconName: String?,
        parentId: UUID?,
        moving connectionIds: [UUID]
    ) throws {
        let group = scope.placingInActiveProject(
            ConnectionGroup(name: name, color: color, iconName: iconName, parentId: parentId)
        )
        try groupStorage.addGroup(group)
        expandedGroupIds.insert(group.id)
        if let parentId {
            expandedGroupIds.insert(parentId)
        }
        groups = groupStorage.loadGroups()
        if !connectionIds.isEmpty,
           !storage.moveConnections(connectionIds, toGroup: group.id, before: nil, groups: groups) {
            reportLibraryWriteFailure()
        }
        loadConnections()
    }

    func requestEditGroup(_ groupId: UUID) {
        guard let group = groupsById[groupId] else { return }
        activeSheet = .editGroup(group)
    }

    func saveGroup(id: UUID, from opening: ConnectionGroupFields, to edited: ConnectionGroupFields) throws {
        try groupStorage.editGroup(id: id, from: opening, to: edited)
        if let parentId = edited.parentId {
            expandedGroupIds.formUnion(groupGraph.pathIds(to: parentId))
        }
        loadConnections()
    }

    func requestDeleteGroup(_ groupId: UUID) {
        guard let group = groupsById[groupId] else { return }
        groupToDelete = group
        showDeleteGroupConfirmation = true
    }

    func confirmDeleteGroup() {
        guard let group = groupToDelete else { return }
        groupToDelete = nil
        if !groupStorage.deleteGroup(group) {
            libraryErrorMessage = GroupStorageError.storeUnreadable.localizedDescription
        }
        loadConnections()
    }
}
