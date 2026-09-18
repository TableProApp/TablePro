import CoreSpotlight
import Foundation
import Observation
import os
import TableProConnectionLibrary
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

    private(set) var sampleResetRevision = 0
    let onboarding: OnboardingPreferences
    let connectionManager: ConnectionManager
    let backgroundRelease: BackgroundReleaseCoordinator
    let queryActivities = QueryActivityController()
    let syncCoordinator: IOSSyncCoordinator

    @ObservationIgnored private var automaticPresentationOwner: UUID?
    let libraryPreferences: ConnectionLibraryPreferences
    let sshProvider: IOSSSHProvider
    let secureStore: KeychainSecureStore

    private let sampleInstaller: SampleDatabaseInstaller
    private let storage: ConnectionPersistence
    private let groupStorage: GroupPersistence
    private let tagStorage: TagPersistence

    init(
        libraryDirectory: URL = LibraryStorage.defaultDirectory,
        defaults: UserDefaults = .standard,
        syncCoordinator injectedSyncCoordinator: IOSSyncCoordinator? = nil,
        sampleInstaller: SampleDatabaseInstaller = .live
    ) {
        self.sampleInstaller = sampleInstaller
        onboarding = OnboardingPreferences(defaults: defaults)
        libraryPreferences = ConnectionLibraryPreferences(defaults: defaults)
        syncCoordinator = injectedSyncCoordinator ?? IOSSyncCoordinator()
        storage = ConnectionPersistence(directory: libraryDirectory)
        groupStorage = GroupPersistence(directory: libraryDirectory)
        tagStorage = TagPersistence(directory: libraryDirectory)
        let driverFactory = IOSDriverFactory()
        let secureStore = KeychainSecureStore()
        self.secureStore = secureStore
        let sshProvider = IOSSSHProvider(secureStore: secureStore)
        self.sshProvider = sshProvider
        let connectionManager = ConnectionManager(
            driverFactory: driverFactory,
            secureStore: secureStore,
            sshProvider: sshProvider
        )
        self.connectionManager = connectionManager
        self.backgroundRelease = BackgroundReleaseCoordinator(connectionManager: connectionManager)
        loadPersistedData()

        guard !TestRuntime.isActive else { return }

        if loadStatus == .ready {
            secureStore.cleanOrphanedCredentials(validConnectionIds: Set(connections.map(\.id)))
            Task {
                publishLibrary()
            }
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

    var isLibraryWritable: Bool {
        loadStatus == .ready
    }

    func retryLoadIfFailed() {
        guard loadStatus == .failed else { return }
        Self.logger.info("Retrying persistence load after previous failure")
        loadPersistedData()
        guard loadStatus == .ready else { return }
        publishLibrary()
    }

    private func refuseWriteIfNotReady() -> Bool {
        guard isLibraryWritable else {
            Self.logger.error("Refusing a library write while the stored library is not loaded")
            return true
        }
        return false
    }

    private func publishLibrary() {
        guard loadStatus == .ready else { return }
        updateWidgetData()
        updateSpotlightIndex()
    }

    private func syncsConnection(_ id: UUID) -> Bool {
        connections.first { $0.id == id }?.participatesInSync ?? true
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
        pruneLibraryPreferences()
    }

    private func persist(groups: [ConnectionGroup]) {
        groupsState = .loaded(groups)
        do {
            try groupStorage.save(groups)
        } catch {
            Self.logger.error("Failed to save groups: \(error.localizedDescription, privacy: .public)")
        }
        pruneLibraryPreferences()
    }

    private func persist(tags: [ConnectionTag]) {
        tagsState = .loaded(tags)
        do {
            try tagStorage.save(tags)
        } catch {
            Self.logger.error("Failed to save tags: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pruneLibraryPreferences() {
        guard loadStatus == .ready else { return }
        libraryPreferences.prune(
            connectionIds: Set(connections.map(\.id)),
            favoriteIds: Set(connections.filter(\.isFavorite).map(\.id)),
            groupIds: Set(groups.map(\.id))
        )
    }

    private var validGroupIds: Set<UUID> {
        Set(groups.map(\.id))
    }

    // MARK: - Connections

    @discardableResult
    func addConnection(_ connection: DatabaseConnection) -> Bool {
        apply(ConnectionLibraryEditing.adding(connection, to: connections, validGroupIds: validGroupIds))
    }

    @discardableResult
    func updateConnection(_ connection: DatabaseConnection) -> Bool {
        guard let change = ConnectionLibraryEditing.updating(
            connection,
            in: connections,
            validGroupIds: validGroupIds
        ) else { return false }
        return apply(change)
    }

    func reorderConnections(_ orderedIds: [UUID]) {
        apply(ConnectionLibraryEditing.reordering(orderedIds, in: connections))
    }

    func moveConnections(_ ids: [UUID], toGroup groupId: UUID?, before: UUID? = nil) {
        apply(ConnectionLibraryEditing.moving(
            ids,
            toGroup: groupId,
            before: before,
            in: connections,
            validGroupIds: validGroupIds
        ))
    }

    func renameConnection(_ id: UUID, to name: String) {
        apply(ConnectionLibraryEditing.renaming(id, to: name, in: connections))
    }

    func setFavorite(_ ids: Set<UUID>, isFavorite: Bool) {
        let previousOrder = libraryPreferences.favoritesOrder
        guard apply(ConnectionLibraryEditing.settingFavorite(ids, to: isFavorite, in: connections)) else { return }
        guard isFavorite else {
            libraryPreferences.setFavoritesOrder(LibraryOrdering.favoritesOrder(previousOrder, removing: ids))
            return
        }
        let known = Set(previousOrder)
        let added = connections.map(\.id).filter { ids.contains($0) && !known.contains($0) }
        libraryPreferences.setFavoritesOrder(previousOrder + added)
    }

    func reorderFavorites(_ orderedIds: [UUID]) {
        libraryPreferences.setFavoritesOrder(orderedIds)
    }

    func duplicateConnection(_ connection: DatabaseConnection) {
        guard !refuseWriteIfNotReady() else { return }
        let result = ConnectionLibraryEditing.duplicating(
            connection,
            named: String(format: String(localized: "%@ Copy"), connection.name),
            in: connections,
            validGroupIds: validGroupIds
        )
        ConnectionSecrets(secureStore: secureStore).copy(from: connection.id, to: result.copy.id)
        apply(result.change)
    }

    func removeConnections(_ ids: Set<UUID>) {
        guard !refuseWriteIfNotReady() else { return }
        let removed = connections.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let secrets = ConnectionSecrets(secureStore: secureStore)
        for connection in removed {
            secrets.delete(for: connection.id)
            clearPerConnectionPreferences(for: connection.id)
        }
        persist(connections: connections.filter { !ids.contains($0.id) })
        publishLibrary()
        for connection in removed where connection.participatesInSync {
            syncCoordinator.markDeleted(connection.id)
        }
        syncCoordinator.scheduleSyncAfterChange()
    }

    @discardableResult
    private func apply(_ change: ConnectionLibraryChange) -> Bool {
        guard !refuseWriteIfNotReady() else { return false }
        guard !change.changedConnectionIds.isEmpty else { return false }
        persist(connections: change.connections)
        publishLibrary()
        let syncedIds = Set(change.connections.filter(\.participatesInSync).map(\.id))
        for id in change.changedConnectionIds where syncedIds.contains(id) {
            syncCoordinator.markDirty(id)
        }
        syncCoordinator.scheduleSyncAfterChange()
        return true
    }

    private func clearPerConnectionPreferences(for id: UUID) {
        let suffix = id.uuidString
        let defaults = UserDefaults.standard
        for prefix in ["lastTab.", "lastDB.", "lastSchema.", "lastQuery."] {
            defaults.removeObject(forKey: prefix + suffix)
        }
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(_ group: ConnectionGroup) -> Bool {
        guard !refuseWriteIfNotReady() else { return false }
        guard let updated = ConnectionLibraryEditing.addingGroup(group, to: groups) else { return false }
        persist(groups: updated)
        syncCoordinator.markDirtyGroup(group.id)
        syncCoordinator.scheduleSyncAfterChange()
        return true
    }

    @discardableResult
    func updateGroup(_ group: ConnectionGroup) -> Bool {
        guard !refuseWriteIfNotReady() else { return false }
        guard let updated = ConnectionLibraryEditing.updatingGroup(group, in: groups) else { return false }
        persist(groups: updated)
        syncCoordinator.markDirtyGroup(group.id)
        syncCoordinator.scheduleSyncAfterChange()
        return true
    }

    func reorderGroups(_ orderedIds: [UUID]) {
        guard !refuseWriteIfNotReady() else { return }
        let result = ConnectionLibraryEditing.reorderingGroups(orderedIds, in: groups)
        guard !result.changed.isEmpty else { return }
        persist(groups: result.groups)
        for id in result.changed {
            syncCoordinator.markDirtyGroup(id)
        }
        syncCoordinator.scheduleSyncAfterChange()
    }

    func deleteGroup(_ groupId: UUID) {
        guard !refuseWriteIfNotReady() else { return }
        let change = ConnectionLibraryEditing.deletingGroup(groupId, groups: groups, connections: connections)
        guard !change.removedGroupIds.isEmpty else { return }
        persist(groups: change.groups)
        persist(connections: change.connections)
        publishLibrary()

        for id in change.changedConnectionIds where syncsConnection(id) {
            syncCoordinator.markDirty(id)
        }
        for id in change.removedGroupIds {
            syncCoordinator.markDeletedGroup(id)
        }
        syncCoordinator.scheduleSyncAfterChange()
    }

    // MARK: - Tags

    func addTag(_ tag: ConnectionTag) {
        guard !refuseWriteIfNotReady() else { return }
        var updated = tags
        updated.append(tag)
        persist(tags: updated)
        syncCoordinator.markDirtyTag(tag.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func updateTag(_ tag: ConnectionTag) {
        guard !refuseWriteIfNotReady() else { return }
        var updated = tags
        guard let index = updated.firstIndex(where: { $0.id == tag.id }) else { return }
        updated[index] = tag
        persist(tags: updated)
        syncCoordinator.markDirtyTag(tag.id)
        syncCoordinator.scheduleSyncAfterChange()
    }

    func deleteTag(_ tagId: UUID) {
        guard !refuseWriteIfNotReady() else { return }
        guard let tag = tags.first(where: { $0.id == tagId }), !tag.isPreset else { return }

        var updatedTags = tags
        updatedTags.removeAll { $0.id == tagId }
        persist(tags: updatedTags)

        var updatedConnections = connections
        for index in updatedConnections.indices where updatedConnections[index].tagIds.contains(tagId) {
            updatedConnections[index].tagIds.removeAll { $0 == tagId }
            if updatedConnections[index].participatesInSync {
                syncCoordinator.markDirty(updatedConnections[index].id)
            }
        }
        persist(connections: updatedConnections)
        publishLibrary()

        syncCoordinator.markDeletedTag(tagId)
        syncCoordinator.scheduleSyncAfterChange()
    }

    // MARK: - First Run

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    func claimLaunchPresentation(for sceneId: UUID) -> LaunchPresentation {
        guard !TestRuntime.isActive else { return .none }
        guard automaticPresentationOwner == nil || automaticPresentationOwner == sceneId else { return .none }
        let version = currentAppVersion
        let presentation = FirstRunPlan(
            hasSeenWelcome: onboarding.hasSeenWelcome,
            syncChoice: onboarding.syncChoice,
            usageDataChoice: onboarding.usageDataChoice,
            lastSeenVersion: onboarding.lastSeenVersion,
            currentVersion: version,
            hasHighlightsForCurrentVersion: FeatureHighlights.release(version) != nil
        ).presentation
        onboarding.recordLaunch(version: version)
        guard presentation != .none else { return .none }
        automaticPresentationOwner = sceneId
        return presentation
    }

    func releaseLaunchPresentation(for sceneId: UUID) {
        guard automaticPresentationOwner == sceneId else { return }
        automaticPresentationOwner = nil
    }

    func finishFirstRun(pages: [FirstRunPage]) {
        if pages.contains(.welcome) {
            onboarding.markWelcomeSeen()
        }
        if pages.contains(.iCloud), onboarding.syncChoice == nil {
            setCloudSyncEnabled(false)
        }
        if pages.contains(.usageData), onboarding.usageDataChoice == nil {
            setUsageDataEnabled(false)
        }
    }

    func setCloudSyncEnabled(_ enabled: Bool) {
        onboarding.setSyncChoice(enabled)
        syncCoordinator.setEnabled(enabled)
    }

    func setUsageDataEnabled(_ enabled: Bool) {
        onboarding.setUsageDataChoice(enabled)
    }

    // MARK: - Sample Database

    func openSampleDatabase() throws -> UUID {
        try sampleInstaller.installIfNeeded()
        if let existing = connections.first(where: \.isSample) {
            return existing.id
        }
        let sample = DatabaseConnection(
            name: SampleDatabaseInstaller.connectionName,
            type: .sqlite,
            host: "",
            port: 0,
            database: SampleDatabaseInstaller.fileName,
            color: .green,
            isSample: true
        )
        guard addConnection(sample) else { throw SampleDatabaseError.libraryUnavailable }
        return sample.id
    }

    func resetSampleDatabase() async throws {
        let sampleIds = connections.filter(\.isSample).map(\.id)
        for id in sampleIds {
            await connectionManager.disconnect(id)
        }
        try sampleInstaller.reset()
        sampleResetRevision += 1
    }

    // MARK: - Spotlight

    private func updateSpotlightIndex() {
        let items = connections.map { conn in
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = conn.name.isEmpty ? conn.host : conn.name
            attributes.contentDescription = [conn.type.mobileDisplayName, ConnectionDetailFormatter.detail(for: conn)]
                .joined(separator: ", ")
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

nonisolated enum LibraryStorage {
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TableProMobile", isDirectory: true)
    }
}

private struct ConnectionPersistence {
    let directory: URL

    private var fileURL: URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("connections.json")
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
