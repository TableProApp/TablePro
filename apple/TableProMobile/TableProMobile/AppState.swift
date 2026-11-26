import Foundation
import Observation
import os
import TableProConnectionLibrary
import TableProDatabase
import TableProLogRedaction
import TableProModels
import TableProSyncTransport

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
    // Bumped when a connection's SSH tunnel stops on its own, so its screen redials.
    private(set) var tunnelDeaths: [UUID: Int] = [:]
    private var sessionRevisions: [UUID: Int] = [:]
    private var editorHolders: [UUID: Set<ObjectIdentifier>] = [:]
    let onboarding: OnboardingPreferences
    let connectionManager: ConnectionManager
    let sessionTransactions: SessionTransactionMonitor
    let sessionRedialer: SessionRedialer
    let backgroundRelease: BackgroundReleaseCoordinator
    let queryActivities = QueryActivityController()
    let catalogChanges = CatalogChangeBoard()
    let sessionModels = ConnectionSessionModels()
    let syncCoordinator: IOSSyncCoordinator
    let account: AccountModel

    @ObservationIgnored private var automaticPresentationOwner: UUID?
    @ObservationIgnored private var pastedSSHKeysAwaitingKeychain: [UUID: String] = [:]
    // A failed save leaves the change in memory only, so sync must not take an equal download as already saved.
    @ObservationIgnored private var unsavedLibraryParts: Set<LibraryPart> = []
    // Set by a write that went on top of a sync pass, so the part's write ends by taking what the store holds.
    @ObservationIgnored private var adoptAfterWrite = false
    let libraryPreferences: ConnectionLibraryPreferences
    let sshProvider: IOSSSHProvider
    let secureStore: any SecureStore
    let localDatabaseFiles: LocalDatabaseFileLocator
    let queryHistory: QueryHistoryStorage
    // Outside `loadStatus`, so a saved queries file that fails to load never locks the connections.
    let savedQueries: SavedQueryLibrary

    private let sampleInstaller: SampleDatabaseInstaller
    private let libraryPublisher: ConnectionLibraryPublisher
    private let library: CoreLibraryStore

    init(
        libraryDirectory: URL = LibraryStorage.defaultDirectory,
        defaults: UserDefaults = .standard,
        secureStore: any SecureStore = KeychainSecureStore(),
        syncCoordinator injectedSyncCoordinator: IOSSyncCoordinator? = nil,
        sampleInstaller: SampleDatabaseInstaller = .live,
        localDatabaseFiles: LocalDatabaseFileLocator = .live,
        bookmarkStore: FileBookmarkStore = FileBookmarkStore(),
        libraryPublisher: ConnectionLibraryPublisher? = nil,
        driverFactory injectedDriverFactory: (any DriverFactory)? = nil,
        account injectedAccount: AccountModel? = nil
    ) {
        self.sampleInstaller = sampleInstaller
        self.libraryPublisher = libraryPublisher ?? .live(defaults: defaults)
        self.localDatabaseFiles = localDatabaseFiles
        localDatabaseFiles.container.recordCurrentContainer()
        onboarding = OnboardingPreferences(defaults: defaults)
        libraryPreferences = ConnectionLibraryPreferences(defaults: defaults)
        let account = injectedAccount ?? .live(configuration: onboarding.managed)
        self.account = account
        let library = CoreLibraryStore(directory: libraryDirectory, defaults: defaults, secureStore: secureStore)
        self.library = library
        syncCoordinator = injectedSyncCoordinator ?? Self.liveSyncCoordinator(core: library.host, account: account)
        queryHistory = QueryHistoryStorage(directory: libraryDirectory)
        savedQueries = SavedQueryLibrary(
            directory: libraryDirectory,
            store: CoreSavedQueryStore(host: library.host, directory: libraryDirectory, defaults: defaults)
        )
        let driverFactory: any DriverFactory = injectedDriverFactory
            ?? IOSDriverFactory(bookmarkStore: bookmarkStore, localFiles: localDatabaseFiles, secureStore: secureStore)
        self.secureStore = secureStore
        let sshProvider = IOSSSHProvider(secureStore: secureStore, container: localDatabaseFiles.container)
        self.sshProvider = sshProvider
        let connectionManager = ConnectionManager(
            driverFactory: driverFactory,
            secureStore: secureStore,
            sshProvider: sshProvider
        )
        self.connectionManager = connectionManager
        self.sessionTransactions = SessionTransactionMonitor { [connectionManager] id in
            connectionManager.session(for: id)?.driver
        }
        self.sessionRedialer = SessionRedialer(connectionManager: connectionManager)
        self.backgroundRelease = BackgroundReleaseCoordinator(connectionManager: connectionManager)
        sshProvider.observeTunnelDeaths { [weak self] connectionId in
            Task { @MainActor in
                self?.tunnelDeaths[connectionId, default: 0] += 1
            }
        }
        connectionManager.observeSessionEnds { [weak self] id, driver in
            Task { @MainActor in
                self?.sessionEnded(id, driver: driver)
            }
        }
        loadPersistedData()

        guard !TestRuntime.isActive else { return }

        account.openIfNeeded()
        observeManagedConfiguration()

        if loadStatus == .ready {
            removeWhatDeletedConnectionsLeft()
            Task {
                publishLibrary()
            }
        }

        connectSync()
    }

    // The Keychain and certificate folder listings block, so they run off the main actor at utility
    // priority, against the library as it stands once the Keychain listing returns, not at launch.
    private func removeWhatDeletedConnectionsLeft() {
        Task.detached(priority: .utility) { [self] in
            await KeychainSecureStore.cleanOrphanedCredentials { self.loadedConnectionIds }
            guard let kept = await loadedConnectionIds else { return }
            CertificateMaterializer().releaseAll(except: kept)
        }
    }

    // A record this build cannot read still owns its secrets and files.
    private var loadedConnectionIds: Set<UUID>? {
        loadStatus == .ready ? Set(connections.map(\.id)).union(library.unreadable.connections) : nil
    }

    // Separate from init, which skips it under tests, so a test can run the wiring the app runs.
    func connectSync() {
        syncCoordinator.onPassFinished = { [weak self] in
            self?.reloadAfterSync()
        }
        syncCoordinator.start()
    }

    private static func liveSyncCoordinator(core: MobileCoreHost, account: AccountModel) -> IOSSyncCoordinator {
        let metadata = SyncMetadataStorage(userDefaults: .standard)
        let host = IOSSyncEngineHost.live(
            core: core,
            account: account,
            metadata: metadata,
            recordCache: SyncRecordCache(directory: IOSSyncEngineHost.recordCacheDirectory, defaults: .standard),
            defaults: .standard
        )
        return IOSSyncCoordinator(host: host, metadata: metadata)
    }

    // A pass the engine finished may have written the stores, so each is read again when it moved. A part this device
    // could not save is written again first; if the store moved under it, only what the store holds can sync, so the
    // reload takes the store's.
    private func reloadAfterSync() {
        savedQueries.reloadAfterSync()
        guard loadStatus == .ready else { return }
        if !unsavedLibraryParts.isEmpty {
            persist(connections: connections)
        }
        reloadLibraryIfMoved()
        // Unread copies another device deleted leave the previous stable's files with a write, which also purges what
        // they left; one that fails is tried again after the next pass.
        let pending = pendingUnreadableRemovals
        let unreadable = library.unreadable
        let owed = !pending.connections.isDisjoint(with: unreadable.connections)
            || !pending.groups.isDisjoint(with: unreadable.groups)
            || !pending.tags.isDisjoint(with: unreadable.tags)
        if owed {
            persist(connections: connections)
        }
    }

    private func adoptWrittenOverPull() {
        guard adoptAfterWrite else { return }
        adoptAfterWrite = false
        reloadLibraryIfMoved(force: true)
    }

    private func reloadLibraryIfMoved(force: Bool = false) {
        let loaded: CoreLibraryStore.Library
        do {
            guard try force || library.changedSinceRead() else { return }
            loaded = try library.load()
        } catch {
            Self.logger.error("The library did not reload after a sync pass: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return
        }
        if !unsavedLibraryParts.isEmpty {
            Self.logger.error("A library change this device could not save gave way to what a sync pass wrote")
            unsavedLibraryParts.removeAll()
        }
        let removedIds = Set(connections.map(\.id))
            .subtracting(loaded.connections.map(\.id))
            .subtracting(library.unreadable.connections)
        adopt(loaded)
        localState.purge(removedIds)
        sessionModels.purge(removedIds)
        savedQueries.removeRecords(ofConnections: removedIds, tombstoning: false)
        publishLibrary()
    }

    // MARK: - Sessions

    // Every window of a connection shares one session, so each follows when another window ends, replaces or moves it.
    func sessionRevision(for connectionId: UUID) -> Int {
        sessionRevisions[connectionId, default: 0]
    }

    func bumpSessionRevision(_ connectionId: UUID) {
        sessionRevisions[connectionId, default: 0] += 1
    }

    // A window with unsaved row edits names its table without a database, so no other window may move the shared session.
    func setEditorHold(_ isHolding: Bool, by holder: AnyObject, on connectionId: UUID) {
        let id = ObjectIdentifier(holder)
        if isHolding {
            editorHolders[connectionId, default: []].insert(id)
        } else {
            editorHolders[connectionId]?.remove(id)
            if editorHolders[connectionId]?.isEmpty == true { editorHolders[connectionId] = nil }
        }
    }

    func holdsEditor(_ connectionId: UUID, besides holder: AnyObject) -> Bool {
        !(editorHolders[connectionId] ?? []).subtracting([ObjectIdentifier(holder)]).isEmpty
    }

    private func sessionEnded(_ connectionId: UUID, driver: any DatabaseDriver) {
        sessionTransactions.sessionEnded(connectionId, driver: driver)
        sessionModels.existing(connectionId)?.sessionEnded(driver)
        bumpSessionRevision(connectionId)
    }

    // MARK: - Load / Retry

    var isLibraryWritable: Bool {
        loadStatus == .ready
    }

    func retryLoadIfFailed() {
        savedQueries.retryLoadIfFailed()
        guard loadStatus == .failed else { return }
        Self.logger.info("Retrying persistence load after previous failure")
        loadPersistedData()
        guard loadStatus == .ready else { return }
        publishLibrary()
    }

    // A background wake can come while the device is locked and the library unreadable, so nothing runs until it loads.
    func syncFromBackground(_ trigger: SyncTrigger) async -> Bool {
        guard onboarding.isCloudSyncEnabled else { return false }
        retryLoadIfFailed()
        guard loadStatus == .ready else {
            Self.logger.warning("Background sync skipped: persistence load not ready (likely device locked)")
            return false
        }
        await syncCoordinator.sync(trigger)
        return true
    }

    // A record this build cannot read keeps its id: adding another with it, as an import can, would write over it.
    private func logUnreadableIdRefusal() {
        Self.logger.error("Refused a library write that reuses the id of a record this build cannot read")
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
        libraryPublisher.publish(connections)
    }



    private func loadPersistedData() {
        do {
            adopt(try library.load())
        } catch {
            connectionsState = .failed(error)
            groupsState = .failed(error)
            tagsState = .failed(error)
            Self.logger.error("Library load failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    // Connection-string secrets another device synced move to the Keychain here too, as a pull brings them.
    private func adopt(_ loaded: CoreLibraryStore.Library) {
        connectionsState = .loaded(loaded.connections)
        groupsState = .loaded(loaded.groups)
        tagsState = .loaded(loaded.tags)
        movePastedSSHKeysToKeychain()
        moveMongoURISecretsToKeychain(from: loaded.connections)
    }

    private func moveMongoURISecretsToKeychain(from loaded: [DatabaseConnection]) {
        let cleaned = loaded.map { MongoURISecretMigration.keepingSecretsInKeychain($0, in: secureStore) }
        guard cleaned != loaded else { return }
        connectionsState = .loaded(cleaned)
        do {
            try library.write(
                libraryImage(connections: cleaned),
                keepingPastedSSHKeys: pastedSSHKeysAwaitingKeychain,
                removingSecrets: true
            )
        } catch {
            Self.logger.error("Rewriting connections without MongoDB secrets failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func movePastedSSHKeysToKeychain() {
        let pending = library.pastedSSHKeys
        guard !pending.isEmpty else { return }
        let unstored = ConnectionSecrets(secureStore: secureStore).storeMissingPrivateKeys(pending)
        pastedSSHKeysAwaitingKeychain = unstored
        let movedCount = pending.count - unstored.count
        guard movedCount > 0 else {
            Self.logger.error("No pasted SSH key reached the Keychain; the connections file keeps them until the next launch")
            return
        }
        Self.logger.info("Moved \(movedCount) pasted SSH keys out of the connections file, \(unstored.count) left for the next launch")
        do {
            try library.write(libraryImage(), keepingPastedSSHKeys: unstored, removingSecrets: true)
        } catch {
            Self.logger.error("Rewriting connections without SSH keys failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    // The library is one store, so a write of one part carries the others as this device holds them.
    private func libraryImage(
        connections: [DatabaseConnection]? = nil,
        groups: [ConnectionGroup]? = nil,
        tags: [ConnectionTag]? = nil
    ) -> CoreLibraryStore.Library {
        CoreLibraryStore.Library(
            connections: connections ?? self.connections,
            groups: groups ?? self.groups,
            tags: tags ?? self.tags
        )
    }

    // MARK: - Persistence Bridges

    // A local change whose save failed is in memory only, so the next write saves it again.
    @discardableResult
    private func persist(connections: [DatabaseConnection]) -> Bool {
        let heldKeys = PastedSSHKeyMigration.keysStillHeld(
            pastedSSHKeysAwaitingKeychain,
            by: connections,
            orUnreadable: library.unreadable.connections
        )
        let saved = writeLibrary(libraryImage(connections: connections), keepingPastedSSHKeys: heldKeys, part: "connections")
        markLibraryPart(.connections, saved: saved)
        connectionsState = .loaded(connections)
        pastedSSHKeysAwaitingKeychain = heldKeys
        pruneLibraryPreferences()
        adoptWrittenOverPull()
        return saved
    }

    @discardableResult
    private func persist(groups: [ConnectionGroup]) -> Bool {
        let saved = writeLibrary(libraryImage(groups: groups), keepingPastedSSHKeys: pastedSSHKeysAwaitingKeychain, part: "groups")
        markLibraryPart(.groups, saved: saved)
        groupsState = .loaded(groups)
        pruneLibraryPreferences()
        adoptWrittenOverPull()
        return saved
    }

    @discardableResult
    private func persist(tags: [ConnectionTag]) -> Bool {
        let saved = writeLibrary(libraryImage(tags: tags), keepingPastedSSHKeys: pastedSSHKeysAwaitingKeychain, part: "tags")
        markLibraryPart(.tags, saved: saved)
        tagsState = .loaded(tags)
        adoptWrittenOverPull()
        return saved
    }

    // Every write carries each removal a pull left waiting, since one write saves every part. Only a copy still kept
    // unread is removed: one a newer build reads now is a live record.
    private func writeLibrary(
        _ image: CoreLibraryStore.Library,
        keepingPastedSSHKeys heldKeys: [UUID: String],
        part: String
    ) -> Bool {
        let pending = pendingUnreadableRemovals
        let unreadable = library.unreadable
        let removed = UnreadableCopies(
            connections: pending.connections.intersection(unreadable.connections),
            groups: pending.groups.intersection(unreadable.groups),
            tags: pending.tags.intersection(unreadable.tags)
        )
        do {
            try library.write(image, keepingPastedSSHKeys: heldKeys, removingUnreadable: removed)
        } catch CoreLibraryStore.Failure.changedSinceRead {
            guard writeOverPull(image, keepingPastedSSHKeys: heldKeys, removingUnreadable: removed, part: part) else {
                return false
            }
        } catch {
            Self.logger.error("Failed to save \(part, privacy: .public): \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return false
        }
        // An earlier write that failed after its copy went still owes that connection's local state its purge.
        let live = Set(image.connections.map(\.id)).union(library.unreadable.connections)
        purgeRemovedUnreadable(pending.connections.subtracting(live))
        return true
    }

    var unreadableCopies: UnreadableCopies {
        library.unreadable
    }

    // Unread copies another device deleted, removed by the next save of their file so their ids stay protected until
    // then. Kept with the sync metadata, which an account switch clears.
    private var pendingUnreadableRemovals: UnreadableCopies {
        UnreadableCopies(recordNames: syncCoordinator.metadata.removalsPendingForUnreadableCopies)
    }

    // A pass wrote the store since this device read it: the write goes on top of what the pass wrote, and the device
    // takes the result once the part's own state is set.
    private func writeOverPull(
        _ image: CoreLibraryStore.Library,
        keepingPastedSSHKeys heldKeys: [UUID: String],
        removingUnreadable removed: UnreadableCopies,
        part: String
    ) -> Bool {
        do {
            let stored = try library.load()
            let rebased = LibraryRebase.rebased(image, from: libraryImage(), onto: stored)
            try library.write(rebased, keepingPastedSSHKeys: heldKeys, removingUnreadable: removed)
            adoptAfterWrite = true
            return true
        } catch {
            Self.logger.error("Failed to save \(part, privacy: .public) over a sync pass: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
    }


    // What belonged to a connection another device deleted goes with it, as for one this device could read.
    private func purgeRemovedUnreadable(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        localState.purge(ids)
        sessionModels.purge(ids)
        savedQueries.removeRecords(ofConnections: ids, tombstoning: false)
    }

    // One write saves every part, so a part an earlier write left unsaved is saved too.
    private func markLibraryPart(_ part: LibraryPart, saved: Bool) {
        if saved {
            unsavedLibraryParts.removeAll()
        } else {
            unsavedLibraryParts.insert(part)
        }
    }

    private func pruneLibraryPreferences() {
        guard loadStatus == .ready else { return }
        let unreadable = library.unreadable
        let unreadableConnectionIds = unreadable.connections
        libraryPreferences.prune(
            connectionIds: Set(connections.map(\.id)).union(unreadableConnectionIds),
            favoriteIds: Set(connections.filter(\.isFavorite).map(\.id)).union(unreadableConnectionIds),
            groupIds: Set(groups.map(\.id)).union(unreadable.groups)
        )
    }

    private var validGroupIds: Set<UUID> {
        Set(groups.map(\.id))
    }

    // MARK: - Connections

    func isConnectionRemoved(_ id: UUID) -> Bool {
        loadStatus == .ready && !connections.contains { $0.id == id }
    }

    func offersHandoff(for connection: DatabaseConnection) -> Bool {
        !connection.isSample && !isConnectionRemoved(connection.id)
    }

    @discardableResult
    func addConnection(_ connection: DatabaseConnection) -> Bool {
        apply(ConnectionLibraryEditing.adding(connection, to: connections, validGroupIds: validGroupIds))
    }

    @discardableResult
    func mutateConnection(_ id: UUID, _ mutate: (inout DatabaseConnection) -> Void) -> LibraryWriteOutcome {
        guard !refuseWriteIfNotReady() else { return .refused }
        guard let change = ConnectionLibraryEditing.mutatingConnection(
            id,
            in: connections,
            validGroupIds: validGroupIds,
            mutate
        ) else { return .missing }
        return apply(change) ? .applied : .unchanged
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
        persist(connections: connections.filter { !ids.contains($0.id) })
        localState.purge(Set(removed.map(\.id)))
        sessionModels.purge(Set(removed.map(\.id)))
        let syncedIds = Set(removed.filter(\.participatesInSync).map(\.id))
        savedQueries.removeRecords(ofConnections: syncedIds, tombstoning: true)
        savedQueries.removeRecords(ofConnections: Set(removed.map(\.id)).subtracting(syncedIds), tombstoning: false)
        publishLibrary()
    }

    @discardableResult
    private func apply(_ change: ConnectionLibraryChange) -> Bool {
        guard !refuseWriteIfNotReady() else { return false }
        guard !change.changedConnectionIds.isEmpty else { return false }
        guard library.unreadable.connections.isDisjoint(with: change.changedConnectionIds) else {
            logUnreadableIdRefusal()
            return false
        }
        persist(connections: change.connections)
        publishLibrary()
        return true
    }

    private var localState: ConnectionLocalState {
        ConnectionLocalState(
            secrets: ConnectionSecrets(secureStore: secureStore),
            queryHistory: queryHistory,
            defaults: .standard
        )
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(_ group: ConnectionGroup) -> LibraryWriteOutcome {
        guard !refuseWriteIfNotReady() else { return .refused }
        guard !library.unreadable.groups.contains(group.id) else {
            logUnreadableIdRefusal()
            return .refused
        }
        guard let updated = ConnectionLibraryEditing.addingGroup(group, to: groups) else { return .invalidPlacement }
        persist(groups: updated)
        return .applied
    }

    @discardableResult
    func mutateGroup(_ id: UUID, _ mutate: (inout ConnectionGroup) -> Void) -> LibraryWriteOutcome {
        guard !refuseWriteIfNotReady() else { return .refused }
        guard groups.contains(where: { $0.id == id }) else { return .missing }
        guard let result = ConnectionLibraryEditing.mutatingGroup(id, in: groups, mutate) else {
            return .invalidPlacement
        }
        guard result.changed else { return .unchanged }
        persist(groups: result.groups)
        return .applied
    }

    func reorderGroups(_ orderedIds: [UUID]) {
        guard !refuseWriteIfNotReady() else { return }
        let result = ConnectionLibraryEditing.reorderingGroups(orderedIds, in: groups)
        guard !result.changed.isEmpty else { return }
        persist(groups: result.groups)
    }

    func deleteGroup(_ groupId: UUID) {
        guard !refuseWriteIfNotReady() else { return }
        let change = ConnectionLibraryEditing.deletingGroup(groupId, groups: groups, connections: connections)
        guard !change.removedGroupIds.isEmpty else { return }
        persist(groups: change.groups)
        persist(connections: change.connections)
        publishLibrary()

    }

    // MARK: - Tags

    @discardableResult
    func addTag(_ tag: ConnectionTag) -> LibraryWriteOutcome {
        guard !refuseWriteIfNotReady() else { return .refused }
        guard !library.unreadable.tags.contains(tag.id) else {
            logUnreadableIdRefusal()
            return .refused
        }
        var updated = tags
        updated.append(tag)
        persist(tags: updated)
        return .applied
    }

    @discardableResult
    func mutateTag(_ id: UUID, _ mutate: (inout ConnectionTag) -> Void) -> LibraryWriteOutcome {
        guard !refuseWriteIfNotReady() else { return .refused }
        guard let result = ConnectionLibraryEditing.mutatingTag(id, in: tags, mutate) else { return .missing }
        guard result.changed else { return .unchanged }
        persist(tags: result.tags)
        return .applied
    }

    @discardableResult
    func deleteTag(_ tagId: UUID) -> Bool {
        guard !refuseWriteIfNotReady() else { return false }
        guard let change = ConnectionLibraryEditing.deletingTag(tagId, tags: tags, connections: connections) else {
            return false
        }
        persist(connections: change.connections)
        persist(tags: change.tags)
        publishLibrary()

        return true
    }

    // MARK: - First Run

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    func claimLaunchPresentation(for sceneId: UUID) -> LaunchPresentation {
        guard !TestRuntime.isActive else { return .none }
        guard automaticPresentationOwner == nil || automaticPresentationOwner == sceneId else { return .none }
        let presentation = planLaunch(version: currentAppVersion)
        guard presentation != .none else { return .none }
        automaticPresentationOwner = sceneId
        return presentation
    }

    // Records the launch as it plans it: the version, and the origin as seen when connections leave it out.
    func planLaunch(version: String) -> LaunchPresentation {
        let plan = FirstRunPlan(
            hasSeenOrigin: onboarding.hasSeenOrigin,
            hasConnections: loadedConnectionIds.map { !$0.isEmpty },
            syncChoice: onboarding.syncChoice,
            usageDataChoice: onboarding.usageDataChoice,
            iCloudSyncAllowed: !onboarding.managed.locksICloudSync,
            usageDataAllowed: onboarding.managed.allowsUsageData,
            lastSeenVersion: onboarding.lastSeenVersion,
            currentVersion: version,
            hasHighlightsForCurrentVersion: FeatureHighlights.release(version) != nil
        )
        if plan.leavesOutOriginForConnections {
            onboarding.markOriginSeen()
        }
        onboarding.recordLaunch(version: version)
        return plan.presentation
    }

    func releaseLaunchPresentation(for sceneId: UUID) {
        guard automaticPresentationOwner == sceneId else { return }
        automaticPresentationOwner = nil
    }

    func finishFirstRun(pages: [FirstRunPage]) {
        if pages.contains(.origin) {
            onboarding.markOriginSeen()
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

    // ADR 0055: iCloud sync stops at once when the organization takes it away, with no last pass, starts when it
    // forces it, and comes back to the person's own choice when it lets go.
    func refreshManagedConfiguration() {
        let wasEnabled = onboarding.isCloudSyncEnabled
        onboarding.refreshManagedConfiguration()
        account.apply(onboarding.managed)
        let enabled = onboarding.isCloudSyncEnabled
        guard enabled != wasEnabled else { return }
        syncCoordinator.setEnabled(enabled)
    }

    // An MDM's new values post a defaults change, as any write to the domain does (Apple's managed app configuration).
    private func observeManagedConfiguration() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.refreshManagedConfiguration()
            }
        }
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

private enum LibraryPart {
    case connections
    case groups
    case tags
}
