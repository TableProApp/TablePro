//
//  WelcomeViewModel.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI

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
    private let groupStorage = GroupStorage.shared

    // MARK: - State

    var connections: [DatabaseConnection] = []
    var searchText = "" { didSet { scheduleRebuildTree(oldValue: oldValue) } }
    var selectedConnectionIds: Set<UUID> = []
    var groups: [ConnectionGroup] = []
    var linkedConnections: [LinkedConnection] = []
    var showOnboarding = !AppSettingsStorage.shared.hasCompletedOnboarding()
    var connectionsToDelete: [DatabaseConnection] = []
    var showDeleteConfirmation = false
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

    var showImportFilePanel = false
    var importResultCount: Int?

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
    @ObservationIgnored private var exportObserver: NSObjectProtocol?
    @ObservationIgnored private var importObserver: NSObjectProtocol?
    @ObservationIgnored private var importFromAppObserver: NSObjectProtocol?
    @ObservationIgnored private var welcomeRouterTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000

    // MARK: - Computed Properties

    private(set) var treeItems: [ConnectionGroupTreeNode] = []
    private(set) var connectionCountByGroup: [UUID: Int] = [:]
    private(set) var depthByGroup: [UUID: Int] = [:]
    private(set) var maxDescendantDepthByGroup: [UUID: Int] = [:]

    func rebuildTree() {
        let tree = buildGroupTree(groups: groups, connections: connections, parentId: nil)
        if searchText.isEmpty {
            treeItems = tree
        } else {
            treeItems = filterGroupTree(tree, searchText: searchText)
        }

        var counts: [UUID: Int] = [:]
        var depths: [UUID: Int] = [:]
        var descendantDepths: [UUID: Int] = [:]
        for group in groups {
            counts[group.id] = connectionCount(in: group.id, connections: connections, groups: groups)
            depths[group.id] = depthOf(groupId: group.id, groups: groups)
            descendantDepths[group.id] = maxDescendantDepth(groupId: group.id, groups: groups)
        }
        connectionCountByGroup = counts
        depthByGroup = depths
        maxDescendantDepthByGroup = descendantDepths
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

        connectionUpdatedCancellable = AppEvents.shared.connectionUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loadConnections()
            }

        exportObserver = NotificationCenter.default.addObserver(
            forName: .exportConnections, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.connections.isEmpty else { return }
                self.activeSheet = .exportConnections(self.connections)
            }
        }

        importObserver = NotificationCenter.default.addObserver(
            forName: .importConnections, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.importConnectionsFromFile()
            }
        }

        importFromAppObserver = NotificationCenter.default.addObserver(
            forName: .importConnectionsFromApp, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeSheet = .importFromApp
            }
        }

        linkedFoldersCancellable = AppEvents.shared.linkedFoldersDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.linkedConnections = LinkedFolderWatcher.shared.linkedConnections
            }

        loadConnections()
        linkedConnections = LinkedFolderWatcher.shared.linkedConnections

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
        [exportObserver, importObserver, importFromAppObserver].forEach {
            if let observer = $0 {
                NotificationCenter.default.removeObserver(observer)
            }
        }
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
            } catch is CancellationError {
                closeConnectionWindows(for: connection.id)
                WindowOpener.shared.openWelcome()
            } catch {
                if case PluginError.pluginNotInstalled = error {
                    Self.logger.info("Plugin not installed for \(connection.type.rawValue), prompting install")
                    handleMissingPlugin(connection: connection)
                } else {
                    Self.logger.error(
                        "Failed to connect: \(error.localizedDescription, privacy: .public)")
                    handleConnectionFailure(error: error, connectionId: connection.id)
                }
            }
        }
    }

    func connectAfterInstall(_ connection: DatabaseConnection) {
        WindowOpener.shared.orderOutWelcome()
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
            } catch is CancellationError {
                closeConnectionWindows(for: connection.id)
                WindowOpener.shared.openWelcome()
            } catch {
                Self.logger.error(
                    "Failed to connect after plugin install: \(error.localizedDescription, privacy: .public)")
                handleConnectionFailure(error: error, connectionId: connection.id)
            }
        }
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

    // MARK: - Delete

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
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = groupId
        }
        storage.saveConnections(connections)
        rebuildTree()
    }

    func removeFromGroup(_ targets: [DatabaseConnection]) {
        let ids = Set(targets.map(\.id))
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = nil
        }
        storage.saveConnections(connections)
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
        var dirtyIds: [String] = []
        for i in connections.indices {
            let isUngrouped = connections[i].groupId.map { !updatedValidGroupIds.contains($0) } ?? true
            if isUngrouped {
                if connections[i].sortOrder != order {
                    connections[i].sortOrder = order
                    dirtyIds.append(connections[i].id.uuidString)
                }
                order += 1
            }
        }

        storage.saveConnections(connections)
        if !dirtyIds.isEmpty {
            services.syncTracker.markDirty(.connection, ids: dirtyIds)
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
        var dirtyIds: [String] = []
        for i in connections.indices where connections[i].groupId == group.id {
            if connections[i].sortOrder != order {
                connections[i].sortOrder = order
                dirtyIds.append(connections[i].id.uuidString)
            }
            order += 1
        }

        storage.saveConnections(connections)
        if !dirtyIds.isEmpty {
            services.syncTracker.markDirty(.connection, ids: dirtyIds)
        }
        rebuildTree()
    }

    func focusConnectionFormWindow() {
        NotificationCenter.default.post(name: .focusConnectionFormWindowRequested, object: nil)
    }

    // MARK: - Private Helpers

    private func handleConnectionFailure(error: Error, connectionId: UUID) {
        closeConnectionWindows(for: connectionId)
        connectionError = error.localizedDescription
        showConnectionError = true
        WindowOpener.shared.openWelcome()
    }

    private func handleMissingPlugin(connection: DatabaseConnection) {
        closeConnectionWindows(for: connection.id)
        WindowOpener.shared.openWelcome()
        pluginInstallConnection = connection
    }

    /// Close windows for a specific connection only, preserving other connections' windows.
    private func closeConnectionWindows(for connectionId: UUID) {
        for window in WindowLifecycleMonitor.shared.windows(for: connectionId) {
            window.close()
        }
    }
}
