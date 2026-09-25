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

internal struct WelcomeTagToken: Identifiable, Hashable {
    internal let id: UUID
    internal let name: String
    internal let color: ConnectionColor
}

enum WelcomeActiveSheet: Identifiable {
    case newGroup(WelcomeNewGroupRequest)
    case activation
    case importFile(URL)
    case exportConnections([DatabaseConnection])
    case importFromApp
    case importFromAWS
    case projectFolderScan(URL)
    case deeplinkImport(ExportableConnection)

    var id: String {
        switch self {
        case .newGroup(let request):
            "newGroup-\(request.parentId?.uuidString ?? "root")-"
                + request.movingConnectionIds.map(\.uuidString).joined(separator: ",")
        case .activation: "activation"
        case .importFile(let u): "importFile-\(u.absoluteString)"
        case .exportConnections: "exportConnections"
        case .importFromApp: "importFromApp"
        case .importFromAWS: "importFromAWS"
        case .projectFolderScan(let u): "projectFolderScan-\(u.absoluteString)"
        case .deeplinkImport(let c): "deeplinkImport-\(c.type)-\(c.name)-\(c.host)-\(c.port)"
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
    private static let teamLibraryNamespace = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000

    let services: AppServices
    let recentConnections: RecentConnectionsStore
    let listPreferences: ConnectionListPreferences
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
    @Published var linkedConnections: [LinkedConnection] = [] {
        didSet { rebuildOutline() }
    }
    @Published var teamLibraryConnections: [LinkedConnection] = [] {
        didSet { rebuildOutline() }
    }

    // MARK: - Query

    @Published var searchText = "" { didSet { scheduleRebuild(previous: oldValue) } }
    @Published var searchTokens: [WelcomeTagToken] = [] {
        didSet { if searchTokens != oldValue { rebuildOutline() } }
    }
    @Published var tagMatch: LibraryTagMatch = .any {
        didSet { if tagMatch != oldValue { rebuildOutline() } }
    }

    // MARK: - Outline

    @Published private(set) var outline: LibraryOutline = .empty
    @Published private(set) var outlineRevision = 0
    @Published private(set) var sortMode: LibrarySortMode
    @Published var expandedGroupIds: Set<UUID> = [] {
        didSet { groupExpansionStore.save(expandedGroupIds) }
    }
    @Published var selection: [LibraryRowID] = []

    // MARK: - Presentation

    @Published private(set) var hasImportableApp = false
    @Published var presentsWelcomeSheet = false
    @Published var connectionsToDelete: [DatabaseConnection] = []
    @Published var showDeleteConfirmation = false
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
    @Published var importResultCount: Int?
    /// Set when a sheet (import file / import-from-app) finishes work and is about to dismiss.
    /// Flushed in the sheet's `onDismiss` so the result alert appears after the sheet animation.
    @Published var pendingImportResultCount: Int?

    // MARK: - Observers

    private var connectionUpdatedCancellable: AnyCancellable?
    private var listStateCancellable: AnyCancellable?
    private var linkedFoldersCancellable: AnyCancellable?
    private var teamLibraryCancellable: AnyCancellable?
    private var licenseCancellable: AnyCancellable?
    private var connectionStatusCancellable: AnyCancellable?
    private var welcomeRouterTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private let importableAppDetector: @MainActor () -> Bool
    private let groupExpansionStore: WelcomeGroupExpansionStore
    private let hasStoredGroupExpansion: Bool

    // MARK: - Initialization

    convenience init() {
        self.init(services: .live)
    }

    init(
        services: AppServices,
        importableAppDetector: @escaping @MainActor () -> Bool = WelcomeViewModel.detectImportableApp,
        groupExpansionStore: WelcomeGroupExpansionStore = WelcomeGroupExpansionStore(),
        recentConnections: RecentConnectionsStore = .shared,
        listPreferences: ConnectionListPreferences = .shared
    ) {
        self.services = services
        self.importableAppDetector = importableAppDetector
        self.groupExpansionStore = groupExpansionStore
        self.recentConnections = recentConnections
        self.listPreferences = listPreferences
        self.sortMode = listPreferences.sortMode
        let storedExpansion = groupExpansionStore.load()
        self.hasStoredGroupExpansion = storedExpansion != nil
        self.expandedGroupIds = storedExpansion ?? []
    }

    static func detectImportableApp() -> Bool {
        ForeignAppImporterRegistry.all.contains { importer in
            importer.importFileTypes == nil && importer.isAvailable()
        }
    }

    deinit {
        welcomeRouterTask?.cancel()
        searchDebounceTask?.cancel()
    }

    // MARK: - Derived State

    var availableTags: [ConnectionTag] {
        let usedIds = Set(connections.flatMap(\.tagIds))
        return tags.filter { usedIds.contains($0.id) }
    }

    var suggestedTokens: [WelcomeTagToken] {
        let chosen = Set(searchTokens.map(\.id))
        return availableTags.filter { !chosen.contains($0.id) }.map(Self.token(for:))
    }

    static func token(for tag: ConnectionTag) -> WelcomeTagToken {
        WelcomeTagToken(id: tag.id, name: tag.name, color: tag.color)
    }

    var query: LibraryQuery {
        LibraryQuery(text: searchText, tagIds: Set(searchTokens.map(\.id)), tagMatch: tagMatch)
    }

    var isFiltering: Bool {
        query.isActive
    }

    var presentableLinkedConnections: [LinkedConnection] {
        guard services.licenseManager.isFeatureAvailable(.linkedFolders) else { return [] }
        return linkedConnections
    }

    var presentableTeamLibraryConnections: [LinkedConnection] {
        guard services.licenseManager.isFeatureAvailable(.teamLibrary) else { return [] }
        return teamLibraryConnections
    }

    var sharedConnectionsById: [UUID: LinkedConnection] {
        Dictionary(
            (presentableLinkedConnections + presentableTeamLibraryConnections).map { ($0.id, $0) },
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
            isTagFiltered: !searchTokens.isEmpty
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
        guard filtersStillApply() else { return }
        connectionsById = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tagsById = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupGraph = LibraryGroupGraph(groups: groups)
        outline = LibraryOutlineBuilder.build(outlineRequest(query: query))
        groupConnectionCounts = Self.groupCounts(in: outline)
        let visible = visibleRowIds()
        selection = selection.filter { visible.contains($0) }
        outlineRevision += 1
    }

    func outlineRequest(query: LibraryQuery) -> LibraryOutlineRequest<DatabaseConnection, ConnectionGroup, ConnectionTag> {
        LibraryOutlineRequest(
            connections: connections,
            groups: groups,
            tags: tags,
            sortMode: sortMode,
            query: query,
            favoritesOrder: listPreferences.favoritesOrder,
            lastConnected: recentConnections.lastConnected,
            includesRecent: services.appSettings.general.showRecentConnections,
            externalSections: [
                LibraryExternalSection(kind: .linkedFolders, entries: presentableLinkedConnections.map(\.libraryEntry)),
                LibraryExternalSection(kind: .teamLibrary, entries: presentableTeamLibraryConnections.map(\.libraryEntry)),
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
        let usedTagIds = Set(connections.flatMap(\.tagIds))
        let keptTokens = searchTokens.filter { usedTagIds.contains($0.id) }
        guard keptTokens.count == searchTokens.count else {
            searchTokens = keptTokens
            return false
        }
        return true
    }

    private func scheduleRebuild(previous: String) {
        searchDebounceTask?.cancel()
        if searchText.isEmpty || previous.isEmpty {
            rebuildOutline()
            return
        }
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.rebuildOutline()
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

    // MARK: - Setup

    func refreshImportableApp() {
        hasImportableApp = importableAppDetector()
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

        /// A row's status badge reads `DatabaseManager.activeSessions`, which is not observable, and
        /// the row is only rewritten when the outline revision moves. Nothing here listened for a
        /// connection coming up or going away, so a row that said Connected went on saying it after
        /// a Disconnect, for as long as the window stayed open.
        connectionStatusCancellable = services.appEvents.connectionStatusChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.outlineRevision += 1
            }

        loadConnections()
        linkedConnections = services.linkedFolderWatcher.linkedConnections
        teamLibraryConnections = Self.buildTeamLibraryConnections()

        consumePendingRouterActions()
        presentWelcomeSheetIfFirstLaunch()
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

    private func pruneDeviceState() {
        let favoriteIds = Set(connections.filter(\.isFavorite).map(\.id))
        listPreferences.setFavoritesOrder(
            LibraryOrdering.favoritesOrder(listPreferences.favoritesOrder, keeping: favoriteIds)
        )
        guard !connections.isEmpty else { return }
        recentConnections.retain(only: Set(connections.map(\.id)))
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

    func connectToLinkedConnection(_ linked: LinkedConnection) {
        let connection = ConnectionExportService.buildDatabaseConnection(
            id: linked.id,
            from: linked.connection,
            name: linked.connection.name,
            tagIdsByName: [:],
            groupIdsByName: [:]
        )
        Task {
            do {
                try await TabRouter.shared.openTransientConnection(connection)
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    private static func buildTeamLibraryConnections() -> [LinkedConnection] {
        guard LicenseManager.shared.isFeatureAvailable(.teamLibrary) else { return [] }
        let placeholderURL = URL(fileURLWithPath: "/")
        var seen: Set<UUID> = []
        return TeamLibrarySyncCoordinator.shared.library.connections.compactMap { connection in
            let id = LinkedFolderWatcher.stableId(namespace: teamLibraryNamespace, key: connection.id)
            guard seen.insert(id).inserted else { return nil }
            return LinkedConnection(
                id: id,
                connection: connection.payload,
                folderId: teamLibraryNamespace,
                sourceFileURL: placeholderURL
            )
        }
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

    func showImportResult(count: Int) {
        importResultCount = count
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

    func handleConnectError(_ error: Error, connection: DatabaseConnection) {
        if error is CancellationError {
            Self.logger.info("Connection attempt cancelled for \(connection.name, privacy: .public)")
            return
        }

        if !WindowManager.shared.hasOpenWindow(for: connection.id) {
            Self.logger.info(
                "Connection failed after window was closed: \(error.publicLogShape, privacy: .public)")
            return
        }

        if case PluginError.pluginNotInstalled = error {
            Self.logger.info("Plugin not installed for \(connection.type.rawValue, privacy: .public)")
            WindowManager.shared.closeWindow(for: connection.id)
            pluginInstallConnection = connection
            return
        }

        Self.logger.error("Failed to connect: \(error.publicLogShape, privacy: .public)")
        WindowManager.shared.closeWindow(for: connection.id)
        presentConnectionFailure(error, connection: connection)
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
        ConnectionRecoveryPerformer.perform(recovery.action, for: recovery.connection) { [weak self] in
            self?.connectToDatabase(recovery.connection)
        }
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

    func createGroup(name: String, color: ConnectionColor, parentId: UUID?, moving connectionIds: [UUID]) throws {
        let group = ConnectionGroup(name: name, color: color, parentId: parentId)
        try groupStorage.addGroup(group)
        expandedGroupIds.insert(group.id)
        if let parentId {
            expandedGroupIds.insert(parentId)
        }
        groups = groupStorage.loadGroups()
        if !connectionIds.isEmpty,
           !storage.moveConnections(connectionIds, toGroup: group.id, before: nil, validGroupIds: Set(groups.map(\.id))) {
            reportLibraryWriteFailure()
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
