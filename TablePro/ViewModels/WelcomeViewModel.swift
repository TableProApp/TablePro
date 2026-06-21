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
    case deeplinkImport(ExportableConnection)

    var id: String {
        switch self {
        case .newGroup(let parentId): "newGroup-\(parentId?.uuidString ?? "root")"
        case .activation: "activation"
        case .importFile(let u): "importFile-\(u.absoluteString)"
        case .exportConnections: "exportConnections"
        case .importFromApp: "importFromApp"
        case .deeplinkImport(let c): "deeplinkImport-\(c.type)-\(c.name)-\(c.host)-\(c.port)"
        }
    }
}

@MainActor @Observable
final class WelcomeViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WelcomeViewModel")

    @ObservationIgnored let services: AppServices
    private var storage: ConnectionStorage { services.connectionStorage }
    private var groupStorage: GroupStorage { services.groupStorage }

    // MARK: - State

    var connections: [DatabaseConnection] = []
    var searchText = "" { didSet { scheduleRebuildTree(oldValue: oldValue) } }
    var selectedConnectionIds: Set<UUID> = []
    var groups: [ConnectionGroup] = []
    var linkedConnections: [LinkedConnection] = []
    var showOnboarding: Bool
    var connectionsToDelete: [DatabaseConnection] = []
    var showDeleteConfirmation = false
    var pendingDeleteHasFavorites = false
    var showDeleteGroupConfirmation = false
    var groupToDelete: ConnectionGroup?
    var pendingMoveToNewGroup: [DatabaseConnection] = []
    var activeSheet: WelcomeActiveSheet?
    var pluginInstallConnection: DatabaseConnection?

    var renameGroupTarget: ConnectionGroup?
    var renameGroupName = ""
    var showRenameGroupAlert = false

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
        let strings = UserDefaults.standard.stringArray(forKey: "com.TablePro.expandedGroupIds") ?? []
        if strings.isEmpty {
            UserDefaults.standard.removeObject(forKey: "com.TablePro.collapsedGroupIds")
        }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }() {
        didSet {
            UserDefaults.standard.set(
                Array(expandedGroupIds.map(\.uuidString)),
                forKey: "com.TablePro.expandedGroupIds"
            )
        }
    }

    // MARK: - Notification Observers

    @ObservationIgnored private var connectionUpdatedCancellable: AnyCancellable?
    @ObservationIgnored private var linkedFoldersCancellable: AnyCancellable?
    @ObservationIgnored private var exportConnectionsCancellable: AnyCancellable?
    @ObservationIgnored private var importConnectionsCancellable: AnyCancellable?
    @ObservationIgnored private var importFromAppCancellable: AnyCancellable?
    @ObservationIgnored private var welcomeRouterTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000

    // MARK: - Computed Properties

    private(set) var treeItems: [ConnectionGroupTreeNode] = []
    private(set) var favoriteConnections: [DatabaseConnection] = []
    private(set) var connectionCountByGroup: [UUID: Int] = [:]
    private(set) var depthByGroup: [UUID: Int] = [:]
    private(set) var maxDescendantDepthByGroup: [UUID: Int] = [:]

    func rebuildTree() {
        favoriteConnections = connections
            .filter(\.isFavorite)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let (tree, indices) = buildGroupTreeWithIndices(groups: groups, connections: connections)
        let baseItems = searchText.isEmpty ? tree : filterGroupTree(tree, searchText: searchText)
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
        flattenVisibleConnections(tree: treeItems, expandedGroupIds: expandedGroupIds)
    }

    var selectedConnections: [DatabaseConnection] {
        connections.filter { selectedConnectionIds.contains($0.id) }
    }

    func groupName(for groupId: UUID?) -> String? {
        guard let groupId else { return nil }
        return groups.first { $0.id == groupId }?.name
    }

    // MARK: - Initialization

    init(services: AppServices = .live) {
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

        exportConnectionsCancellable = AppCommands.shared.exportConnections
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.connections.isEmpty else { return }
                self.activeSheet = .exportConnections(self.connections)
            }

        importConnectionsCancellable = AppCommands.shared.importConnections
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.importConnectionsFromFile()
            }

        importFromAppCancellable = AppCommands.shared.importConnectionsFromApp
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.activeSheet = .importFromApp
            }

        linkedFoldersCancellable = services.appEvents.linkedFoldersDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.linkedConnections = self.services.linkedFolderWatcher.linkedConnections
            }

        loadConnections()
        linkedConnections = services.linkedFolderWatcher.linkedConnections

        consumePendingRouterActions()
        startWelcomeRouterObservation()
    }

    private func consumePendingRouterActions() {
        if let pendingURL = WelcomeRouter.shared.consumePendingShare() {
            activeSheet = .importFile(pendingURL)
            return
        }
        if let pendingImport = WelcomeRouter.shared.consumePendingImport() {
            activeSheet = .deeplinkImport(pendingImport)
            return
        }
        if let pendingInstall = WelcomeRouter.shared.consumePendingPluginInstall() {
            pluginInstallConnection = pendingInstall
            return
        }
        if let pendingError = WelcomeRouter.shared.consumePendingError() {
            presentConnectionFailure(pendingError.error, connection: pendingError.connection)
        }
    }

    private func startWelcomeRouterObservation() {
        welcomeRouterTask?.cancel()
        welcomeRouterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let didChange = await Self.awaitWelcomeRouterChange()
                guard didChange else { return }
                self?.consumePendingRouterActions()
            }
        }
    }

    private static func awaitWelcomeRouterChange() async -> Bool {
        let box = ContinuationBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.set(continuation)
                withObservationTracking({
                    _ = WelcomeRouter.shared.pendingImport
                    _ = WelcomeRouter.shared.pendingConnectionShare
                    _ = WelcomeRouter.shared.pendingError
                    _ = WelcomeRouter.shared.pendingPluginInstall
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
        WindowOpener.shared.orderOutWelcome()
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
        connectToDatabase(connection)
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
        connectionsToDelete = targets
        pendingDeleteHasFavorites = false
        showDeleteConfirmation = true
        Task {
            pendingDeleteHasFavorites = await services.sqlFavoriteManager.hasFavorites(for: targets.map(\.id))
        }
    }

    func deleteSelectedConnections() {
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        storage.deleteConnections(connectionsToDelete)
        connections.removeAll { idsToDelete.contains($0.id) }
        selectedConnectionIds.subtract(idsToDelete)
        connectionsToDelete = []
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
        guard !isDuplicate else { return }
        var updated = target
        updated.name = newName
        groupStorage.updateGroup(updated)
        groups = groupStorage.loadGroups()
        rebuildTree()
        renameGroupTarget = nil
    }

    func updateGroupColor(_ group: ConnectionGroup, color: ConnectionColor) {
        var updated = group
        updated.color = color
        groupStorage.updateGroup(updated)
        groups = groupStorage.loadGroups()
        rebuildTree()
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

    func createGroup(name: String, color: ConnectionColor, parentId: UUID?) {
        let group = ConnectionGroup(name: name, color: color, parentId: parentId)
        groupStorage.addGroup(group)
        groups = groupStorage.loadGroups()
        guard groups.contains(where: { $0.id == group.id }) else { return }
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

    func moveGroup(_ group: ConnectionGroup, toParent newParentId: UUID?) {
        guard !wouldCreateCircle(movingGroupId: group.id, toParentId: newParentId, groups: groups) else { return }

        let newParentDepth = depthOf(groupId: newParentId, groups: groups)
        let subtreeDepth = maxDescendantDepth(groupId: group.id, groups: groups)
        guard newParentDepth + 1 + subtreeDepth <= 3 else { return }

        var updated = group
        updated.parentId = newParentId
        groupStorage.updateGroup(updated)
        groups = groupStorage.loadGroups()
        rebuildTree()
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
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedGroupIds.remove(groupId)
        }
    }

    func expandSelectedGroup() {
        guard let id = selectedConnectionIds.first,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              !expandedGroupIds.contains(groupId) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedGroupIds.insert(groupId)
        }
    }

    // MARK: - Reorder

    func moveUngroupedConnections(from source: IndexSet, to destination: Int) {
        let validGroupIds = Set(groups.map(\.id))
        let ungroupedIndices = connections.indices.filter { index in
            guard let groupId = connections[index].groupId else { return true }
            return !validGroupIds.contains(groupId)
        }

        guard source.allSatisfy({ $0 < ungroupedIndices.count }),
              destination <= ungroupedIndices.count else { return }

        let globalSource = IndexSet(source.map { ungroupedIndices[$0] })
        let globalDestination: Int
        if destination < ungroupedIndices.count {
            globalDestination = ungroupedIndices[destination]
        } else if let last = ungroupedIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        connections.move(fromOffsets: globalSource, toOffset: globalDestination)

        let updatedValidGroupIds = Set(groups.map(\.id))
        var order = 0
        var updated: [DatabaseConnection] = []
        for i in connections.indices {
            let isUngrouped = connections[i].groupId.map { !updatedValidGroupIds.contains($0) } ?? true
            if isUngrouped {
                if connections[i].sortOrder != order {
                    connections[i].sortOrder = order
                    updated.append(connections[i])
                }
                order += 1
            }
        }

        guard storage.updateConnections(updated) else {
            connections = storage.loadConnections()
            rebuildTree()
            return
        }
        rebuildTree()
    }

    func moveGroupedConnections(in group: ConnectionGroup, from source: IndexSet, to destination: Int) {
        let groupIndices = connections.indices.filter { connections[$0].groupId == group.id }

        guard source.allSatisfy({ $0 < groupIndices.count }),
              destination <= groupIndices.count else { return }

        let globalSource = IndexSet(source.map { groupIndices[$0] })
        let globalDestination: Int
        if destination < groupIndices.count {
            globalDestination = groupIndices[destination]
        } else if let last = groupIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        connections.move(fromOffsets: globalSource, toOffset: globalDestination)

        var order = 0
        var updated: [DatabaseConnection] = []
        for i in connections.indices where connections[i].groupId == group.id {
            if connections[i].sortOrder != order {
                connections[i].sortOrder = order
                updated.append(connections[i])
            }
            order += 1
        }

        guard storage.updateConnections(updated) else {
            connections = storage.loadConnections()
            rebuildTree()
            return
        }
        rebuildTree()
    }

    func focusConnectionFormWindow() {
        if let window = NSApp.windows.first(where: { AppLaunchCoordinator.isConnectionFormWindow($0) }) {
            window.makeKeyAndOrderFront(nil)
        }
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
