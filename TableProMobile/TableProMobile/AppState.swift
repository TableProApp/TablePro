import CoreSpotlight
import Foundation
import Observation
import os
import TableProDatabase
import TableProModels
import WidgetKit

enum PersistenceIntegrity: Equatable {
    case ok
    case loadFailed
}

@MainActor @Observable
final class AppState {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppState")

    var connections: [DatabaseConnection] = []
    var groups: [ConnectionGroup] = []
    var tags: [ConnectionTag] = []
    var pendingConnectionId: UUID?
    var pendingTableName: String?
    var persistenceIntegrity: PersistenceIntegrity = .ok
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

        // Skip side-effecting callbacks (Spotlight, WidgetKit, sync wiring) when
        // running unit tests inside the host app. These rely on entitlements
        // that the CI simulator does not have and have caused the test runner
        // to crash before it could connect to xctest.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        secureStore.cleanOrphanedCredentials(validConnectionIds: Set(connections.map(\.id)))
        Task {
            updateWidgetData()
            updateSpotlightIndex()
        }

        syncCoordinator.onConnectionsChanged = { [weak self] merged in
            guard let self else { return }
            self.connections = merged
            self.storage.save(merged)
            self.persistenceIntegrity = .ok
            self.updateWidgetData()
            self.updateSpotlightIndex()
        }

        syncCoordinator.onGroupsChanged = { [weak self] merged in
            guard let self else { return }
            self.groups = merged
            self.groupStorage.save(merged)
            self.persistenceIntegrity = .ok
        }

        syncCoordinator.onTagsChanged = { [weak self] merged in
            guard let self else { return }
            self.tags = merged
            self.tagStorage.save(merged)
            self.persistenceIntegrity = .ok
        }

        syncCoordinator.getCurrentState = { [weak self] in
            guard let self else { return ([], [], []) }
            return (self.connections, self.groups, self.tags)
        }
    }

    // MARK: - Load / Retry

    func retryLoadIfFailed() {
        guard persistenceIntegrity == .loadFailed else { return }
        Self.logger.info("Retrying persistence load after previous failure")
        loadPersistedData()
    }

    private func loadPersistedData() {
        var failed = false

        do {
            connections = try storage.load()
        } catch {
            connections = []
            failed = true
            Self.logger.error("Connections load failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            groups = try groupStorage.load()
        } catch {
            groups = []
            failed = true
            Self.logger.error("Groups load failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            tags = try tagStorage.load()
        } catch {
            tags = ConnectionTag.presets
            failed = true
            Self.logger.error("Tags load failed: \(error.localizedDescription, privacy: .public)")
        }

        persistenceIntegrity = failed ? .loadFailed : .ok
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
        clearPerConnectionPreferences(for: connection.id)
        storage.save(connections)
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
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionPersistence")

    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = dir.appendingPathComponent("TableProMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("connections.json")
    }

    func save(_ connections: [DatabaseConnection]) {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(connections)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Failed to save connections: \(error.localizedDescription, privacy: .public)")
        }
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
