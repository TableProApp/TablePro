import CoreSpotlight
import Foundation
import Observation
import os
import TableProDatabase
import TableProModels
import WidgetKit

@MainActor @Observable
final class AppState {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppState")

    private var connectionsState: Loadable<[DatabaseConnection]> = .loading
    private var groupsState: Loadable<[ConnectionGroup]> = .loading
    private var tagsState: Loadable<[ConnectionTag]> = .loading

    var connections: [DatabaseConnection] { connectionsState.value ?? [] }
    var groups: [ConnectionGroup] { groupsState.value ?? [] }
    var tags: [ConnectionTag] { tagsState.value ?? ConnectionTag.presets }

    var loadStatus: LoadStatus {
        if connectionsState.isFailed || groupsState.isFailed || tagsState.isFailed {
            return .failed
        }
        if connectionsState.isLoaded && groupsState.isLoaded && tagsState.isLoaded {
            return .ready
        }
        return .loading
    }

    var pendingConnectionId: UUID?
    var pendingTableName: String?
    var pendingImportURL: URL?
    let connectionManager: ConnectionManager
    let syncCoordinator = IOSSyncCoordinator()
    let sshProvider: IOSSSHProvider
    let secureStore: KeychainSecureStore

    private let storage = ConnectionPersistence()
    private let groupStorage = GroupPersistence()
    private let tagStorage = TagPersistence()

    init() {
        let driverFactory = IOSDriverFactory()
        let secureStore = KeychainSecureStore()
        self.secureStore = secureStore
        let sshProvider = IOSSSHProvider(secureStore: secureStore)
        self.sshProvider = sshProvider
        self.connectionManager = ConnectionManager(
            driverFactory: driverFactory,
            secureStore: secureStore,
            sshProvider: sshProvider
        )
        loadPersistedData()

        guard !TestRuntime.isActive else { return }

        secureStore.cleanOrphanedCredentials(validConnectionIds: Set(connections.map(\.id)))
        Task {
            updateWidgetData()
            updateSpotlightIndex()
        }

        syncCoordinator.onConnectionsChanged = { [weak self] merged in
            guard let self else { return }
            guard merged != self.connections else { return }
            self.persist(connections: merged)
            self.updateWidgetData()
            self.updateSpotlightIndex()
        }

        syncCoordinator.onGroupsChanged = { [weak self] merged in
            guard let self else { return }
            guard merged != self.groups else { return }
            self.persist(groups: merged)
        }

        syncCoordinator.onTagsChanged = { [weak self] merged in
            guard let self else { return }
            guard merged != self.tags else { return }
            self.persist(tags: merged)
        }

        syncCoordinator.getCurrentState = { [weak self] in
            guard let self, self.loadStatus == .ready else { return nil }
            return (self.connections, self.groups, self.tags)
        }
    }

    // MARK: - Load / Retry

    func retryLoadIfFailed() {
        guard loadStatus == .failed else { return }
        Self.logger.info("Retrying persistence load after previous failure")
        loadPersistedData()
    }

    private func loadPersistedData() {
        do {
            connectionsState = .loaded(try storage.load())
        } catch {
            connectionsState = .failed(error)
            Self.logger.error("Connections load failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            groupsState = .loaded(try groupStorage.load())
        } catch {
            groupsState = .failed(error)
            Self.logger.error("Groups load failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            tagsState = .loaded(try tagStorage.load())
        } catch {
            tagsState = .failed(error)
            Self.logger.error("Tags load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Persistence Bridges

    private func persist(connections: [DatabaseConnection]) {
        connectionsState = .loaded(connections)
        do {
            try storage.save(connections)
        } catch {
            Self.logger.error("Failed to save connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist(groups: [ConnectionGroup]) {
        groupsState = .loaded(groups)
        do {
            try groupStorage.save(groups)
        } catch {
            Self.logger.error("Failed to save groups: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist(tags: [ConnectionTag]) {
        tagsState = .loaded(tags)
        do {
            try tagStorage.save(tags)
        } catch {
            Self.logger.error("Failed to save tags: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connections

    func addConnection(_ connection: DatabaseConnection) {
        var updated = connections
        updated.append(connection)
        persist(connections: updated)
        updateWidgetData()
        updateSpotlightIndex()
        syncCoordinator.markDirty(connection.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func updateConnection(_ connection: DatabaseConnection) {
        var updated = connections
        guard let index = updated.firstIndex(where: { $0.id == connection.id }) else { return }
        updated[index] = connection
        persist(connections: updated)
        updateWidgetData()
        updateSpotlightIndex()
        syncCoordinator.markDirty(connection.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "com.TablePro.hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "com.TablePro.hasCompletedOnboarding") }
    }

    func reorderConnections(_ reordered: [DatabaseConnection]) {
        persist(connections: reordered)
        updateWidgetData()
        for connection in reordered {
            syncCoordinator.markDirty(connection.id)
        }
        syncCoordinator.scheduleSyncAfterChange()
    }

    func removeConnection(_ connection: DatabaseConnection) {
        var updated = connections
        updated.removeAll { $0.id == connection.id }
        try? connectionManager.deletePassword(for: connection.id)
        try? secureStore.delete(forKey: "com.TablePro.sshpassword.\(connection.id.uuidString)")
        try? secureStore.delete(forKey: "com.TablePro.keypassphrase.\(connection.id.uuidString)")
        try? secureStore.delete(forKey: "com.TablePro.sshkeydata.\(connection.id.uuidString)")
        FileBookmarkStore().delete(for: connection.id)
        clearPerConnectionPreferences(for: connection.id)
        persist(connections: updated)
        updateWidgetData()
        updateSpotlightIndex()
        syncCoordinator.markDeleted(connection.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    private func clearPerConnectionPreferences(for id: UUID) {
        let suffix = id.uuidString
        let defaults = UserDefaults.standard
        for prefix in ["lastTab.", "lastDB.", "lastSchema.", "lastQuery."] {
            defaults.removeObject(forKey: prefix + suffix)
        }
    }

    // MARK: - Groups

    func addGroup(_ group: ConnectionGroup) {
        var updated = groups
        updated.append(group)
        persist(groups: updated)
        syncCoordinator.markDirtyGroup(group.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func updateGroup(_ group: ConnectionGroup) {
        var updated = groups
        guard let index = updated.firstIndex(where: { $0.id == group.id }) else { return }
        updated[index] = group
        persist(groups: updated)
        syncCoordinator.markDirtyGroup(group.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func reorderGroups(_ reordered: [ConnectionGroup]) {
        persist(groups: reordered)
        for group in reordered {
            syncCoordinator.markDirtyGroup(group.id)
        }
        syncCoordinator.scheduleSyncAfterChange()
    }

    func deleteGroup(_ groupId: UUID) {
        var updatedGroups = groups
        updatedGroups.removeAll { $0.id == groupId }
        persist(groups: updatedGroups)

        var updatedConnections = connections
        for index in updatedConnections.indices where updatedConnections[index].groupId == groupId {
            updatedConnections[index].groupId = nil
            syncCoordinator.markDirty(updatedConnections[index].id)
        }
        persist(connections: updatedConnections)
        updateWidgetData()

        syncCoordinator.markDeletedGroup(groupId)
        syncCoordinator.scheduleSyncAfterChange()
    }

    // MARK: - Tags

    func addTag(_ tag: ConnectionTag) {
        var updated = tags
        updated.append(tag)
        persist(tags: updated)
        syncCoordinator.markDirtyTag(tag.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func updateTag(_ tag: ConnectionTag) {
        var updated = tags
        guard let index = updated.firstIndex(where: { $0.id == tag.id }) else { return }
        updated[index] = tag
        persist(tags: updated)
        syncCoordinator.markDirtyTag(tag.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func deleteTag(_ tagId: UUID) {
        guard let tag = tags.first(where: { $0.id == tagId }), !tag.isPreset else { return }

        var updatedTags = tags
        updatedTags.removeAll { $0.id == tagId }
        persist(tags: updatedTags)

        var updatedConnections = connections
        for index in updatedConnections.indices where updatedConnections[index].tagId == tagId {
            updatedConnections[index].tagId = nil
            syncCoordinator.markDirty(updatedConnections[index].id)
        }
        persist(connections: updatedConnections)
        updateWidgetData()

        syncCoordinator.markDeletedTag(tagId)
        syncCoordinator.scheduleSyncAfterChange()
    }

    // MARK: - Spotlight

    private func updateSpotlightIndex() {
        let items = connections.map { conn in
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = conn.name.isEmpty ? conn.host : conn.name
            attributes.contentDescription = "\(conn.type.rawValue) · \(conn.host):\(conn.port)"
            return CSSearchableItem(
                uniqueIdentifier: conn.id.uuidString,
                domainIdentifier: "com.TablePro.connections",
                attributeSet: attributes
            )
        }
        if items.isEmpty {
            CSSearchableIndex.default().deleteAllSearchableItems()
        } else {
            CSSearchableIndex.default().indexSearchableItems(items)
        }
    }

    // MARK: - Widget

    private func updateWidgetData() {
        let items = connections
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map { conn in
                WidgetConnectionItem(
                    id: conn.id,
                    name: conn.name.isEmpty ? conn.host : conn.name,
                    type: conn.type.rawValue,
                    sortOrder: conn.sortOrder
                )
            }
        SharedConnectionStore.write(items)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Helpers

    func group(for id: UUID?) -> ConnectionGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func tag(for id: UUID?) -> ConnectionTag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }
}

// MARK: - Persistence

private struct ConnectionPersistence {
    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = dir.appendingPathComponent("TableProMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("connections.json")
    }

    func save(_ connections: [DatabaseConnection]) throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(connections)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load() throws -> [DatabaseConnection] {
        guard let fileURL else { return [] }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([DatabaseConnection].self, from: data)
    }
}
