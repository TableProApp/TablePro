//
//  WelcomeViewModel.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProImport
import TableProPluginKit

enum WelcomeActiveSheet: Identifiable {
    case newGroup(parentId: UUID?)
    case activation
    case importFile(URL)
    case exportConnections([DatabaseConnection])
    case importFromApp
    case projectFolderScan(URL)
    case deeplinkImport(ExportableConnection)

    var id: String {
        switch self {
        case .newGroup(let parentId): "newGroup-\(parentId?.uuidString ?? "root")"
        case .activation: "activation"
        case .importFile(let u): "importFile-\(u.absoluteString)"
        case .exportConnections: "exportConnections"
        case .importFromApp: "importFromApp"
        case .projectFolderScan(let u): "projectFolderScan-\(u.absoluteString)"
        case .deeplinkImport(let c): "deeplinkImport-\(c.type)-\(c.name)-\(c.host)-\(c.port)"
        }
    }
}

@MainActor @Observable
final class WelcomeViewModel {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WelcomeViewModel")

    @ObservationIgnored let services: AppServices
    private var storage: ConnectionStorage { services.connectionStorage }
    private var groupStorage: GroupStorage { services.groupStorage }

    // MARK: - State

    var connections: [DatabaseConnection] = []
    var searchText = "" { didSet { scheduleRebuildTree(oldValue: oldValue) } }
    var tagFilter = TagFilter() { didSet { if tagFilter != oldValue { rebuildTree() } } }
    var selectedConnectionIds: Set<UUID> = []
    var groups: [ConnectionGroup] = []
    var linkedConnections: [LinkedConnection] = []
    var teamLibraryConnections: [LinkedConnection] = []
    var showOnboarding: Bool
    var connectionsToDelete: [DatabaseConnection] = []
    var showDeleteConfirmation = false
    var pendingDeleteHasFavorites = false
    private var deleteRequestToken = UUID()
    var showDeleteGroupConfirmation = false
    var groupToDelete: ConnectionGroup?
    var pendingMoveToNewGroup: [DatabaseConnection] = []
    var activeSheet: WelcomeActiveSheet?
    var pluginInstallConnection: DatabaseConnection?

    var databaseTypeChooser: DatabaseTypeChooserPayload?
    var urlImportPresented = false
    var pendingInstallType: DatabaseType?
    @ObservationIgnored var pendingInstallPayload: DatabaseTypeChooserPayload?

    var renameGroupTarget: ConnectionGroup?
    var renameGroupName = ""
    var showRenameGroupAlert = false

    /// Why a group change was refused. Renaming, recolouring and moving are commands with no
    /// surface of their own to report into, so the window presents this; creating a group has its
    /// own sheet and reports there instead.
    var groupErrorMessage: String?

    var connectionError: String?
    var showConnectionError = false
    var pluginDiagnostic: PluginDiagnosticItem?

    var showImportFilePanel = false
    var importResultCount: Int?
    /// Set when a sheet (import file / import-from-app) finishes work and is
    /// about to dismiss. Flushed in the sheet's `onDismiss` so the result
    /// alert appears after the sheet animation completes, no sleep needed.
    var pendingImportResultCount: Int?

    var expandedGroupIds: Set<UUID> = {
        let strings = AppStorageEnvironment.shared.defaults.stringArray(forKey: "com.TablePro.expandedGroupIds") ?? []
        if strings.isEmpty {
            AppStorageEnvironment.shared.defaults.removeObject(forKey: "com.TablePro.collapsedGroupIds")
        }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }() {
        didSet {
            AppStorageEnvironment.shared.defaults.set(
                Array(expandedGroupIds.map(\.uuidString)),
                forKey: "com.TablePro.expandedGroupIds"
            )
        }
    }

    // MARK: - Notification Observers

    @ObservationIgnored private var connectionUpdatedCancellable: AnyCancellable?
    @ObservationIgnored private var linkedFoldersCancellable: AnyCancellable?
    @ObservationIgnored private var teamLibraryCancellable: AnyCancellable?
    @ObservationIgnored private var welcomeRouterTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000

    // MARK: - Computed Properties

    private(set) var treeItems: [ConnectionGroupTreeNode] = []
    private(set) var favoriteConnections: [DatabaseConnection] = []
    private(set) var connectionCountByGroup: [UUID: Int] = [:]
    private(set) var depthByGroup: [UUID: Int] = [:]
    private(set) var maxDescendantDepthByGroup: [UUID: Int] = [:]

    var availableTags: [ConnectionTag] {
        let usedIds = Set(connections.flatMap { $0.tagIds })
        return TagStorage.shared.loadTags().filter { usedIds.contains($0.id) }
    }

    func rebuildTree() {
        favoriteConnections = connections
            .filter(\.isFavorite)
            .filter { tagFilter.matches($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let (tree, indices) = buildGroupTreeWithIndices(groups: groups, connections: connections)
        var baseItems = searchText.isEmpty ? tree : filterGroupTree(tree, searchText: searchText)
        if tagFilter.isActive {
            baseItems = filterGroupTreeByTags(baseItems, filter: tagFilter)
        }
        if searchText.isEmpty, !favoriteConnections.isEmpty {
            treeItems = baseItems.filter { node in
                if case .connection(let conn) = node, conn.isFavorite { return false }
                return true
            }
        } else {
            treeItems = baseItems
        }

        connectionCountByGroup = indices.connectionCountByGroup
        depthByGroup = indices.depthByGroup
        maxDescendantDepthByGroup = indices.maxDescendantDepthByGroup
    }

    private func scheduleRebuildTree(oldValue: String) {
        searchDebounceTask?.cancel()
        if searchText.isEmpty || oldValue.isEmpty {
            rebuildTree()
            return
        }
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.rebuildTree()
        }
    }

    var flatVisibleConnections: [DatabaseConnection] {
        let inTree = flattenVisibleConnections(tree: treeItems, expandedGroupIds: expandedGroupIds)
        guard searchText.isEmpty, !favoriteConnections.isEmpty else { return inTree }
        var seen = Set<UUID>()
        return (favoriteConnections + inTree).filter { seen.insert($0.id).inserted }
    }

    var selectedConnections: [DatabaseConnection] {
        connections.filter { selectedConnectionIds.contains($0.id) }
    }

    func groupName(for groupId: UUID?) -> String? {
        guard let groupId else { return nil }
        return groups.first { $0.id == groupId }?.name
    }

    // MARK: - Initialization

    convenience init() {
        self.init(services: .live)
    }

    init(services: AppServices) {
        self.services = services
        self.showOnboarding = !services.appSettingsStorage.hasCompletedOnboarding()
    }

    // MARK: - Setup & Teardown

    func setUp() {
        guard connectionUpdatedCancellable == nil else { return }

        if expandedGroupIds.isEmpty {
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
                withObservationTracking({
                    _ = router.pendingRequest
                    _ = router.pendingImport
                    _ = router.pendingConnectionShare
                    _ = router.pendingError
                    _ = router.pendingPluginInstall
                }, onChange: {
                    box.resume(with: true)
                })
            }
        } onCancel: {
            box.resume(with: false)
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()

        func set(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func resume(with value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    deinit {
        welcomeRouterTask?.cancel()
        searchDebounceTask?.cancel()
    }

    // MARK: - Data Loading

    func loadConnections() {
        connections = storage.loadConnections()
        loadGroups()
    }

    func loadGroups() {
        groups = groupStorage.loadGroups()
        rebuildTree()
    }

    // MARK: - Connection Actions

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
        let connection = DatabaseConnection(
            id: linked.id,
            name: linked.connection.name,
            host: linked.connection.host,
            port: linked.connection.port,
            database: linked.connection.database,
            username: linked.connection.username,
            type: DatabaseType(rawValue: linked.connection.type)
        )
        Task {
            do {
                try await TabRouter.shared.openTransientConnection(connection)
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    private static let teamLibraryFolderId = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    private static func buildTeamLibraryConnections() -> [LinkedConnection] {
        guard LicenseManager.shared.isFeatureAvailable(.teamLibrary) else { return [] }
        let placeholderURL = URL(fileURLWithPath: "/")
        return TeamLibrarySyncCoordinator.shared.library.connections.map { connection in
            LinkedConnection(
                id: LinkedFolderWatcher.stableId(
                    folderId: teamLibraryFolderId,
                    connection: connection.payload
                ),
                connection: connection.payload,
                folderId: teamLibraryFolderId,
                sourceFileURL: placeholderURL
            )
        }
    }

    func duplicateConnection(_ connection: DatabaseConnection) {
        let duplicate = storage.duplicateConnection(connection)
        loadConnections()
        WindowOpener.shared.openConnectionForm(editing: duplicate.id)
    }

    // MARK: - Favorites

    func toggleFavorite(_ targets: [DatabaseConnection]) {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let live = connections.filter { ids.contains($0.id) }
        guard !live.isEmpty else { return }
        let shouldFavorite = !live.allSatisfy(\.isFavorite)
        var updated: [DatabaseConnection] = []
        for index in connections.indices where ids.contains(connections[index].id) {
            connections[index].isFavorite = shouldFavorite
            updated.append(connections[index])
        }
        guard storage.updateConnections(updated) else {
            connections = storage.loadConnections()
            rebuildTree()
            return
        }
        rebuildTree()
        AppEvents.shared.connectionUpdated.send(targets.count == 1 ? targets.first?.id : nil)
    }

    // MARK: - Delete

    func requestDeleteConnections(_ targets: [DatabaseConnection]) {
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
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        guard storage.deleteConnections(connectionsToDelete) else {
            connectionsToDelete = []
            connections = storage.loadConnections()
            rebuildTree()
            return
        }
        connections.removeAll { idsToDelete.contains($0.id) }
        selectedConnectionIds.subtract(idsToDelete)
        connectionsToDelete = []
        rebuildTree()
    }

    // MARK: - Tags

    func deleteTag(_ tag: ConnectionTag) {
        guard !tag.isPreset else { return }
        TagStorage.shared.deleteTag(tag, clearingFrom: storage)
        connections = storage.loadConnections()
        tagFilter.selectedIds.remove(tag.id)
        rebuildTree()
    }

    // MARK: - Groups

    func requestDeleteGroup(_ group: ConnectionGroup) {
        groupToDelete = group
        showDeleteGroupConfirmation = true
    }

    func confirmDeleteGroup() {
        guard let group = groupToDelete else { return }
        groupStorage.deleteGroup(group)
        groupToDelete = nil
        loadConnections()
    }

    func beginRenameGroup(_ group: ConnectionGroup) {
        renameGroupTarget = group
        renameGroupName = group.name
        showRenameGroupAlert = true
    }

    func confirmRenameGroup() {
        guard let target = renameGroupTarget else { return }
        let newName = renameGroupName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let siblings = groups.filter { $0.parentId == target.parentId }
        let isDuplicate = siblings.contains {
            $0.id != target.id && $0.name.lowercased() == newName.lowercased()
        }
        guard !isDuplicate else {
            groupErrorMessage = GroupStorageError.duplicateName(newName).localizedDescription
            return
        }
        var updated = target
        updated.name = newName
        guard applyGroupUpdate(updated) else { return }
        renameGroupTarget = nil
    }

    func updateGroupColor(_ group: ConnectionGroup, color: ConnectionColor) {
        var updated = group
        updated.color = color
        applyGroupUpdate(updated)
    }

    func moveConnections(_ targets: [DatabaseConnection], toGroup groupId: UUID) {
        let ids = Set(targets.map(\.id))
        var updated: [DatabaseConnection] = []
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = groupId
            updated.append(connections[i])
        }
        guard storage.updateConnections(updated) else {
            connections = storage.loadConnections()
            rebuildTree()
            return
        }
        rebuildTree()
    }

    func removeFromGroup(_ targets: [DatabaseConnection]) {
        let ids = Set(targets.map(\.id))
        var updated: [DatabaseConnection] = []
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = nil
            updated.append(connections[i])
        }
        guard storage.updateConnections(updated) else {
            connections = storage.loadConnections()
            rebuildTree()
            return
        }
        rebuildTree()
    }

    func createGroup(name: String, color: ConnectionColor, parentId: UUID?) throws {
        let group = ConnectionGroup(name: name, color: color, parentId: parentId)
        try groupStorage.addGroup(group)
        groups = groupStorage.loadGroups()
        expandedGroupIds.insert(group.id)
        if let parentId {
            expandedGroupIds.insert(parentId)
        }
        if !pendingMoveToNewGroup.isEmpty {
            moveConnections(pendingMoveToNewGroup, toGroup: group.id)
            pendingMoveToNewGroup = []
        }
        rebuildTree()
    }

    func createSubgroup(under parentId: UUID) {
        activeSheet = .newGroup(parentId: parentId)
    }

    /// The placement rule lives in the storage that enforces it, so this no longer pre-checks what
    /// it would only have to keep in step. The menu dims an impossible target through the same
    /// `canPlaceGroup`, which leaves the throw for a graph that changed under the open menu.
    func moveGroup(_ group: ConnectionGroup, toParent newParentId: UUID?) {
        var updated = group
        updated.parentId = newParentId
        applyGroupUpdate(updated)
    }

    @discardableResult
    private func applyGroupUpdate(_ group: ConnectionGroup) -> Bool {
        do {
            try groupStorage.updateGroup(group)
        } catch {
            groupErrorMessage = error.localizedDescription
            return false
        }
        groups = groupStorage.loadGroups()
        rebuildTree()
        return true
    }

    // MARK: - Import / Export

    func exportConnections(_ connectionsToExport: [DatabaseConnection]) {
        activeSheet = .exportConnections(connectionsToExport)
    }

    func importConnectionsFromApp() {
        activeSheet = .importFromApp
    }

    func importConnectionsFromFile() {
        showImportFilePanel = true
    }

    func showImportResult(count: Int) {
        importResultCount = count
    }

    // MARK: - Keyboard Navigation

    func moveToNextConnection() {
        let visible = flatVisibleConnections
        guard !visible.isEmpty else { return }
        let anchorId = visible.last(where: { selectedConnectionIds.contains($0.id) })?.id
        guard let anchorId,
              let index = visible.firstIndex(where: { $0.id == anchorId }) else {
            selectedConnectionIds = Set([visible[0].id])
            return
        }
        let next = min(index + 1, visible.count - 1)
        selectedConnectionIds = [visible[next].id]
    }

    func moveToPreviousConnection() {
        let visible = flatVisibleConnections
        guard !visible.isEmpty else { return }
        let anchorId = visible.first(where: { selectedConnectionIds.contains($0.id) })?.id
        guard let anchorId,
              let index = visible.firstIndex(where: { $0.id == anchorId }) else {
            selectedConnectionIds = Set([visible[visible.count - 1].id])
            return
        }
        let prev = max(index - 1, 0)
        selectedConnectionIds = [visible[prev].id]
    }

    func collapseSelectedGroup() {
        guard let id = selectedConnectionIds.first,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              expandedGroupIds.contains(groupId) else { return }
        withMotion(.easeInOut(duration: 0.2)) {
            expandedGroupIds.remove(groupId)
        }
    }

    func expandSelectedGroup() {
        guard let id = selectedConnectionIds.first,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              !expandedGroupIds.contains(groupId) else { return }
        withMotion(.easeInOut(duration: 0.2)) {
            expandedGroupIds.insert(groupId)
        }
    }

    // MARK: - Reorder

    /// Reorder the rows the list actually drew.
    ///
    /// `.onMove` reports positions in the rendered node list, and that list is not `connections`:
    /// a top level hides every favorite, and a tag filter hides whatever it does not match. Mapping
    /// those offsets into the unfiltered array moved a different connection than the one dragged,
    /// so the ids come in from the view and the offsets are only ever applied to them.
    ///
    /// Connections the list did not draw keep the slots they held, so a drag between two visible
    /// rows cannot reshuffle the rows around them.
    func moveConnections(renderedIds: [UUID], from source: IndexSet, to destination: Int, inGroup groupId: UUID?) {
        guard source.allSatisfy({ $0 < renderedIds.count }), destination <= renderedIds.count else { return }

        var reordered = renderedIds
        reordered.move(fromOffsets: source, toOffset: destination)

        let renderedSet = Set(renderedIds)
        let scope = sortConnections(connections.filter { isInScope($0, groupId: groupId) })
        guard scope.filter({ renderedSet.contains($0.id) }).count == renderedIds.count else { return }

        var cursor = 0
        var rankById: [UUID: Int] = [:]
        for (rank, connection) in scope.enumerated() {
            if renderedSet.contains(connection.id) {
                rankById[reordered[cursor]] = rank
                cursor += 1
            } else {
                rankById[connection.id] = rank
            }
        }

        var updated: [DatabaseConnection] = []
        for index in connections.indices {
            guard let rank = rankById[connections[index].id], connections[index].sortOrder != rank else { continue }
            connections[index].sortOrder = rank
            updated.append(connections[index])
        }

        guard storage.updateConnections(updated) else {
            connections = storage.loadConnections()
            rebuildTree()
            return
        }
        rebuildTree()
    }

    /// A connection with a `groupId` no group answers to is ungrouped, which is where the tree
    /// draws it.
    private func isInScope(_ connection: DatabaseConnection, groupId: UUID?) -> Bool {
        guard let groupId else {
            guard let assigned = connection.groupId else { return true }
            return !groups.contains { $0.id == assigned }
        }
        return connection.groupId == groupId
    }

    // MARK: - Private Helpers

    private func handleConnectError(_ error: Error, connection: DatabaseConnection) {
        if error is CancellationError {
            Self.logger.info("Connection attempt cancelled for \(connection.name, privacy: .public)")
            return
        }

        if !WindowManager.shared.hasOpenWindow(for: connection.id) {
            Self.logger.info(
                "Connection failed after window was closed: \(error.localizedDescription, privacy: .public)")
            return
        }

        if case PluginError.pluginNotInstalled = error {
            Self.logger.info("Plugin not installed for \(connection.type.rawValue, privacy: .public)")
            WindowManager.shared.closeWindow(for: connection.id)
            pluginInstallConnection = connection
            return
        }

        Self.logger.error("Failed to connect: \(error.localizedDescription, privacy: .public)")
        WindowManager.shared.closeWindow(for: connection.id)
        presentConnectionFailure(error, connection: connection)
    }

    private func presentConnectionFailure(_ error: Error, connection: DatabaseConnection) {
        if let item = PluginDiagnosticItem.classify(
            error: error, connection: connection, username: connection.username
        ) {
            pluginDiagnostic = item
        } else {
            connectionError = SSLHandshakeError.formatted(error)
            showConnectionError = true
        }
    }
}
