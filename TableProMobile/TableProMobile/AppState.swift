//
//  AppState.swift
//  TableProMobile
//

import CoreSpotlight
import Foundation
import Observation
import TableProDatabase
import TableProModels
import WidgetKit

@MainActor @Observable
final class AppState {
    var connections: [DatabaseConnection] = []
    var groups: [ConnectionGroup] = []
    var tags: [ConnectionTag] = []
    var pendingConnectionId: UUID?
    var pendingTableName: String?
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
        connections = storage.load()
        groups = groupStorage.load()
        tags = tagStorage.load()
        secureStore.cleanOrphanedCredentials(validConnectionIds: Set(connections.map(\.id)))
        Task {
            updateWidgetData()
            updateSpotlightIndex()
        }

        syncCoordinator.onConnectionsChanged = { [weak self] merged in
            guard let self else { return }
            self.connections = merged
            self.storage.save(merged)
            self.updateWidgetData()
            self.updateSpotlightIndex()
        }

        syncCoordinator.onGroupsChanged = { [weak self] merged in
            guard let self else { return }
            self.groups = merged
            self.groupStorage.save(merged)
        }

        syncCoordinator.onTagsChanged = { [weak self] merged in
            guard let self else { return }
            self.tags = merged
            self.tagStorage.save(merged)
        }

        syncCoordinator.getCurrentState = { [weak self] in
            guard let self else { return ([], [], []) }
            return (self.connections, self.groups, self.tags)
        }
    }

    // MARK: - Connections

    func addConnection(_ connection: DatabaseConnection) {
        connections.append(connection)
        storage.save(connections)
        updateWidgetData()
        updateSpotlightIndex()
        syncCoordinator.markDirty(connection.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func updateConnection(_ connection: DatabaseConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            storage.save(connections)
            updateWidgetData()
            updateSpotlightIndex()
            syncCoordinator.markDirty(connection.id)
            syncCoordinator.scheduleSyncAfterChange()
        }
    }

    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "com.TablePro.hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "com.TablePro.hasCompletedOnboarding") }
    }

    func reorderConnections(_ reordered: [DatabaseConnection]) {
        connections = reordered
        storage.save(connections)
        updateWidgetData()
        for connection in reordered {
            syncCoordinator.markDirty(connection.id)
        }
        syncCoordinator.scheduleSyncAfterChange()
    }

    func removeConnection(_ connection: DatabaseConnection) {
        connections.removeAll { $0.id == connection.id }
        try? connectionManager.deletePassword(for: connection.id)
        try? secureStore.delete(forKey: "com.TablePro.sshpassword.\(connection.id.uuidString)")
        try? secureStore.delete(forKey: "com.TablePro.keypassphrase.\(connection.id.uuidString)")
        try? secureStore.delete(forKey: "com.TablePro.sshkeydata.\(connection.id.uuidString)")
        storage.save(connections)
        updateWidgetData()
        updateSpotlightIndex()
        syncCoordinator.markDeleted(connection.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    // MARK: - Groups

    func addGroup(_ group: ConnectionGroup) {
        groups.append(group)
        groupStorage.save(groups)
        syncCoordinator.markDirtyGroup(group.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func updateGroup(_ group: ConnectionGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
            groupStorage.save(groups)
            syncCoordinator.markDirtyGroup(group.id)
            syncCoordinator.scheduleSyncAfterChange()
        }
    }

    func reorderGroups(_ reordered: [ConnectionGroup]) {
        groups = reordered
        groupStorage.save(groups)
        for group in reordered {
            syncCoordinator.markDirtyGroup(group.id)
        }
        syncCoordinator.scheduleSyncAfterChange()
    }

    func deleteGroup(_ groupId: UUID) {
        groups.removeAll { $0.id == groupId }
        groupStorage.save(groups)

        for index in connections.indices where connections[index].groupId == groupId {
            connections[index].groupId = nil
            syncCoordinator.markDirty(connections[index].id)
        }
        storage.save(connections)
        updateWidgetData()

        syncCoordinator.markDeletedGroup(groupId)
        syncCoordinator.scheduleSyncAfterChange()
    }

    // MARK: - Tags

    func addTag(_ tag: ConnectionTag) {
        tags.append(tag)
        tagStorage.save(tags)
        syncCoordinator.markDirtyTag(tag.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func updateTag(_ tag: ConnectionTag) {
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = tag
            tagStorage.save(tags)
            syncCoordinator.markDirtyTag(tag.id)
            syncCoordinator.scheduleSyncAfterChange()
        }
    }

    func deleteTag(_ tagId: UUID) {
        guard let tag = tags.first(where: { $0.id == tagId }), !tag.isPreset else { return }

        tags.removeAll { $0.id == tagId }
        tagStorage.save(tags)

        for index in connections.indices where connections[index].tagId == tagId {
            connections[index].tagId = nil
            syncCoordinator.markDirty(connections[index].id)
        }
        storage.save(connections)
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
                    host: conn.host,
                    port: conn.port,
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

    func save(_ connections: [DatabaseConnection]) {
        guard let fileURL, let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func load() -> [DatabaseConnection] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let connections = try? JSONDecoder().decode([DatabaseConnection].self, from: data) else {
            return []
        }
        return connections
    }
}
