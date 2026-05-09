//
//  SyncCoordinator.swift
//  TablePro
//
//  Orchestrates sync: license gating, scheduling, push/pull coordination
//

import CloudKit
import Combine
import Foundation
import Observation
import os

/// Central coordinator for iCloud sync
@MainActor @Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncCoordinator")

    private(set) var syncStatus: SyncStatus = .disabled(.userDisabled)
    private(set) var lastSyncDate: Date?
    private(set) var iCloudAccountAvailable: Bool = false

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let engine = CloudKitSyncEngine()
    @ObservationIgnored private let changeTracker: SyncChangeTracker
    @ObservationIgnored private let metadataStorage: SyncMetadataStorage
    @ObservationIgnored private let conflictResolver: ConflictResolver
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var changeCancellable: AnyCancellable?
    @ObservationIgnored private var licenseCancellable: AnyCancellable?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(services: AppServices = .live) {
        self.services = services
        self.changeTracker = services.syncTracker
        self.metadataStorage = services.syncMetadataStorage
        self.conflictResolver = services.conflictResolver
        lastSyncDate = metadataStorage.lastSyncDate
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        syncTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Call from AppDelegate at launch
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        observeAccountChanges()
        observeLocalChanges()
        observeLicenseChanges()

        // If local storage is empty (fresh install or wiped), clear the sync token
        // to force a full fetch instead of a delta that returns nothing
        if services.connectionStorage.loadConnections().isEmpty {
            metadataStorage.clearSyncToken()
            Self.logger.info("No local connections — cleared sync token for full fetch")
        }

        Task {
            await checkAccountStatus()
            evaluateStatus()

            if syncStatus.isEnabled {
                await syncNow()
            }
        }
    }

    /// Called when the app comes to the foreground
    func syncIfNeeded() {
        guard syncStatus.isEnabled, !syncStatus.isSyncing else { return }

        Task {
            await syncNow()
        }
    }

    /// Manual full sync (push then pull)
    func syncNow() async {
        guard canSync() else {
            Self.logger.info("syncNow: canSync() returned false, skipping")
            return
        }

        syncStatus = .syncing

        do {
            try await engine.ensureZoneExists()
            await performPush()
            await performPull()

            lastSyncDate = Date()
            metadataStorage.lastSyncDate = lastSyncDate
            syncStatus = .idle
            metadataStorage.pruneTombstones(olderThan: 30)

            Self.logger.info("Sync completed successfully")
        } catch {
            let syncError = SyncError.from(error)
            syncStatus = .error(syncError)
            Self.logger.error("Sync failed: \(error.localizedDescription)")
        }
    }

    /// Triggered by remote push notification
    func handleRemoteNotification() {
        guard syncStatus.isEnabled else { return }

        Task {
            await performPull()
        }
    }

    /// Called when user enables sync in settings
    func enableSync() {
        Self.logger.info("enableSync() called")

        // Clear token to force a full fetch on first sync after enabling
        metadataStorage.clearSyncToken()

        // Mark ALL existing local data as dirty so it gets pushed on first sync
        markAllLocalDataDirty()
        let dirtyCount = changeTracker.dirtyRecords(for: .connection).count
        Self.logger.info("enableSync() dirty marking done, dirty connections: \(dirtyCount)")

        Task {
            await checkAccountStatus()
            evaluateStatus()

            if syncStatus.isEnabled {
                await syncNow()
            }
        }
    }

    /// Marks all existing local data as dirty so it will be pushed on the next sync.
    /// Called when sync is first enabled to upload existing connections/groups/tags/settings.
    private func markAllLocalDataDirty() {
        let connections = services.connectionStorage.loadConnections()
        for connection in connections where !connection.localOnly {
            changeTracker.markDirty(.connection, id: connection.id.uuidString)
        }

        let groups = services.groupStorage.loadGroups()
        for group in groups {
            changeTracker.markDirty(.group, id: group.id.uuidString)
        }

        let tags = services.tagStorage.loadTags()
        for tag in tags {
            changeTracker.markDirty(.tag, id: tag.id.uuidString)
        }

        let sshProfiles = services.sshProfileStorage.loadProfiles()
        for profile in sshProfiles {
            changeTracker.markDirty(.sshProfile, id: profile.id.uuidString)
        }

        // Mark all settings categories as dirty
        for category in ["general", "appearance", "editor", "dataGrid", "history", "tabs", "keyboard", "ai"] {
            changeTracker.markDirty(.settings, id: category)
        }

        Self.logger.info("Marked all local data dirty: \(connections.count) connections, \(groups.count) groups, \(tags.count) tags, \(sshProfiles.count) SSH profiles, 8 settings categories")
    }

    /// Called when user disables sync in settings
    func disableSync() {
        syncTask?.cancel()
        syncStatus = .disabled(.userDisabled)
    }

    // MARK: - Status

    private func evaluateStatus() {
        let licenseManager = services.licenseManager

        // Check license
        guard licenseManager.isFeatureAvailable(.iCloudSync) else {
            switch licenseManager.status {
            case .expired:
                syncStatus = .disabled(.licenseExpired)
            default:
                syncStatus = .disabled(.licenseRequired)
            }
            return
        }

        // Check sync settings
        let syncSettings = services.appSettingsStorage.loadSync()
        guard syncSettings.enabled else {
            syncStatus = .disabled(.userDisabled)
            return
        }

        // Check iCloud account
        guard iCloudAccountAvailable else {
            syncStatus = .disabled(.noAccount)
            return
        }

        // If we were in an error or disabled state, transition to idle
        if !syncStatus.isSyncing {
            syncStatus = .idle
        }
    }

    private func canSync() -> Bool {
        let licenseManager = services.licenseManager
        guard licenseManager.isFeatureAvailable(.iCloudSync) else {
            Self.logger.trace("Sync skipped: license not available")
            return false
        }

        let syncSettings = services.appSettingsStorage.loadSync()
        guard syncSettings.enabled else {
            Self.logger.trace("Sync skipped: disabled by user")
            return false
        }

        guard iCloudAccountAvailable else {
            Self.logger.trace("Sync skipped: no iCloud account")
            return false
        }

        return true
    }

    // MARK: - Push

    private func performPush() async {
        let settings = services.appSettingsStorage.loadSync()
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        let zoneID = await engine.zoneID

        // Collect dirty connections
        if settings.syncConnections {
            let dirtyConnectionIds = changeTracker.dirtyRecords(for: .connection)
            if !dirtyConnectionIds.isEmpty {
                let connections = services.connectionStorage.loadConnections()
                for id in dirtyConnectionIds {
                    if let connection = connections.first(where: { $0.id.uuidString == id }),
                       !connection.localOnly {
                        recordsToSave.append(
                            SyncRecordMapper.toCKRecord(connection, in: zoneID)
                        )
                    }
                }
            }

            let connectionTombstones = metadataStorage.tombstones(for: .connection)
            for tombstone in connectionTombstones {
                recordIDsToDelete.append(
                    SyncRecordMapper.recordID(type: .connection, id: tombstone.id, in: zoneID)
                )
            }
        }

        // Collect dirty groups and tags
        if settings.syncGroupsAndTags {
            collectDirtyGroups(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
            collectDirtyTags(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        // Collect dirty SSH profiles
        if settings.syncSSHProfiles {
            collectDirtySSHProfiles(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        // Collect dirty settings
        if settings.syncSettings {
            let dirtySettingsIds = changeTracker.dirtyRecords(for: .settings)
            for category in dirtySettingsIds {
                if let data = settingsData(for: category) {
                    recordsToSave.append(
                        SyncRecordMapper.toCKRecord(category: category, settingsData: data, in: zoneID)
                    )
                }
            }
        }

        // Deduplicate deletion IDs to prevent CloudKit "can't delete same record twice" error
        let uniqueDeletions = Array(Set(recordIDsToDelete))

        guard !recordsToSave.isEmpty || !uniqueDeletions.isEmpty else { return }

        do {
            try await engine.push(records: recordsToSave, deletions: uniqueDeletions)

            if settings.syncConnections {
                changeTracker.clearAllDirty(.connection)
            }
            if settings.syncGroupsAndTags {
                changeTracker.clearAllDirty(.group)
                changeTracker.clearAllDirty(.tag)
            }
            if settings.syncSSHProfiles {
                changeTracker.clearAllDirty(.sshProfile)
            }
            if settings.syncSettings {
                changeTracker.clearAllDirty(.settings)
            }

            // Clear tombstones only for types that were actually pushed
            if settings.syncConnections {
                for tombstone in metadataStorage.tombstones(for: .connection) {
                    metadataStorage.removeTombstone(type: .connection, id: tombstone.id)
                }
            }
            if settings.syncGroupsAndTags {
                for tombstone in metadataStorage.tombstones(for: .group) {
                    metadataStorage.removeTombstone(type: .group, id: tombstone.id)
                }
                for tombstone in metadataStorage.tombstones(for: .tag) {
                    metadataStorage.removeTombstone(type: .tag, id: tombstone.id)
                }
            }
            if settings.syncSSHProfiles {
                for tombstone in metadataStorage.tombstones(for: .sshProfile) {
                    metadataStorage.removeTombstone(type: .sshProfile, id: tombstone.id)
                }
            }
            if settings.syncSettings {
                for tombstone in metadataStorage.tombstones(for: .settings) {
                    metadataStorage.removeTombstone(type: .settings, id: tombstone.id)
                }
            }

            Self.logger.info("Push completed: \(recordsToSave.count) saved, \(recordIDsToDelete.count) deleted")
        } catch let error as CKError where error.code == .serverRecordChanged {
            Self.logger.warning("Server record changed during push — conflicts detected")
            handlePushConflicts(error)
        } catch {
            Self.logger.error("Push failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pull

    private func performPull() async {
        let token = metadataStorage.loadSyncToken()
        let tokenStatus = token == nil ? "nil (full fetch)" : "present (delta)"
        Self.logger.info("Pull starting, token: \(tokenStatus)")

        do {
            let result = try await engine.pull(since: token)
            applyPullResult(result)
        } catch let error as CKError where error.code == .changeTokenExpired {
            Self.logger.warning("Change token expired, clearing and retrying with full fetch")
            metadataStorage.clearSyncToken()
            do {
                let result = try await engine.pull(since: nil)
                applyPullResult(result)
            } catch {
                Self.logger.error("Full fetch after token expiry failed: \(error.localizedDescription)")
            }
        } catch {
            Self.logger.error("Pull failed: \(error.localizedDescription)")
        }
    }

    private func applyPullResult(_ result: PullResult) {
        if let newToken = result.newToken {
            metadataStorage.saveSyncToken(newToken)
        }

        applyRemoteChanges(result)

        Self.logger.info(
            "Pull completed: \(result.changedRecords.count) changed, \(result.deletedRecordIDs.count) deleted"
        )
    }

    // Performance: storage reads here (loadSync, loadConnections, loadGroups, etc.) run on
    // @MainActor and can block the UI on large sync batches. Consider moving to Task.detached
    // for large payloads.
    private func applyRemoteChanges(_ result: PullResult) {
        let settings = services.appSettingsStorage.loadSync()

        services.connectionStorage.invalidateCache()

        changeTracker.isSuppressed = true
        defer {
            changeTracker.isSuppressed = false
        }

        var actualConnectionChanges = false
        var groupsOrTagsChanged = false

        let connectionTombstoneIds = Set(metadataStorage.tombstones(for: .connection).map(\.id))
        let groupTombstoneIds = Set(metadataStorage.tombstones(for: .group).map(\.id))
        let tagTombstoneIds = Set(metadataStorage.tombstones(for: .tag).map(\.id))
        let sshTombstoneIds = Set(metadataStorage.tombstones(for: .sshProfile).map(\.id))

        for record in result.changedRecords {
            switch record.recordType {
            case SyncRecordType.connection.rawValue where settings.syncConnections:
                if applyRemoteConnection(record, tombstoneIds: connectionTombstoneIds) {
                    actualConnectionChanges = true
                }
            case SyncRecordType.group.rawValue where settings.syncGroupsAndTags:
                if applyRemoteGroup(record, tombstoneIds: groupTombstoneIds) {
                    groupsOrTagsChanged = true
                }
            case SyncRecordType.tag.rawValue where settings.syncGroupsAndTags:
                if applyRemoteTag(record, tombstoneIds: tagTombstoneIds) {
                    groupsOrTagsChanged = true
                }
            case SyncRecordType.sshProfile.rawValue where settings.syncSSHProfiles:
                applyRemoteSSHProfile(record, tombstoneIds: sshTombstoneIds)
            case SyncRecordType.settings.rawValue where settings.syncSettings:
                applyRemoteSettings(record)
            default:
                break
            }
        }

        var connectionIdsToDelete: Set<UUID> = []
        var groupIdsToDelete: Set<UUID> = []
        var tagIdsToDelete: Set<UUID> = []
        var sshProfileIdsToDelete: Set<UUID> = []

        for recordID in result.deletedRecordIDs {
            let name = recordID.recordName
            if name.hasPrefix("Connection_"),
               let uuid = UUID(uuidString: String(name.dropFirst("Connection_".count))) {
                connectionIdsToDelete.insert(uuid)
                actualConnectionChanges = true
            } else if name.hasPrefix("Group_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("Group_".count))) {
                groupIdsToDelete.insert(uuid)
                groupsOrTagsChanged = true
            } else if name.hasPrefix("Tag_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("Tag_".count))) {
                tagIdsToDelete.insert(uuid)
                groupsOrTagsChanged = true
            } else if name.hasPrefix("SSHProfile_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("SSHProfile_".count))) {
                sshProfileIdsToDelete.insert(uuid)
            }
        }

        if !connectionIdsToDelete.isEmpty {
            var connections = services.connectionStorage.loadConnections()
            connections.removeAll { connectionIdsToDelete.contains($0.id) }
            if !services.connectionStorage.saveConnections(connections) {
                Self.logger.error("Failed to apply remote connection deletions: persistence error")
            }
        }
        if !groupIdsToDelete.isEmpty {
            var groups = services.groupStorage.loadGroups()
            groups.removeAll { groupIdsToDelete.contains($0.id) }
            services.groupStorage.saveGroups(groups)
        }
        if !tagIdsToDelete.isEmpty {
            var tags = services.tagStorage.loadTags()
            tags.removeAll { tagIdsToDelete.contains($0.id) }
            services.tagStorage.saveTags(tags)
        }
        if !sshProfileIdsToDelete.isEmpty {
            var profiles = services.sshProfileStorage.loadProfiles()
            profiles.removeAll { sshProfileIdsToDelete.contains($0.id) }
            services.sshProfileStorage.saveProfilesWithoutSync(profiles)
        }

        if actualConnectionChanges || groupsOrTagsChanged {
            services.appEvents.connectionUpdated.send(nil)
        }
    }

    @discardableResult
    private func applyRemoteConnection(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        let remoteConnection: DatabaseConnection
        do {
            remoteConnection = try SyncRecordMapper.toConnection(record)
        } catch {
            Self.logger.error("Skipping remote connection \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }

        if tombstoneIds.contains(remoteConnection.id.uuidString) {
            return false
        }

        var connections = services.connectionStorage.loadConnections()
        if let index = connections.firstIndex(where: { $0.id == remoteConnection.id }) {
            if changeTracker.dirtyRecords(for: .connection).contains(remoteConnection.id.uuidString) {
                let localRecord = SyncRecordMapper.toCKRecord(
                    connections[index],
                    in: CKRecordZone.ID(
                        zoneName: "TableProSync",
                        ownerName: CKCurrentUserDefaultName
                    )
                )
                let conflict = SyncConflict(
                    recordType: .connection,
                    entityName: remoteConnection.name,
                    localRecord: localRecord,
                    serverRecord: record,
                    localModifiedAt: (localRecord["modifiedAtLocal"] as? Date) ?? Date(),
                    serverModifiedAt: (record["modifiedAtLocal"] as? Date) ?? Date()
                )
                conflictResolver.addConflict(conflict)
                return false
            }
            var merged = remoteConnection
            merged.localOnly = connections[index].localOnly
            connections[index] = merged
        } else {
            connections.append(remoteConnection)
        }
        guard services.connectionStorage.saveConnections(connections) else {
            Self.logger.error("Failed to apply remote connection update: persistence error for \(remoteConnection.id, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    private func applyRemoteGroup(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        guard let remoteGroup = SyncRecordMapper.toGroup(record) else { return false }
        if tombstoneIds.contains(remoteGroup.id.uuidString) { return false }

        var groups = services.groupStorage.loadGroups()
        if let index = groups.firstIndex(where: { $0.id == remoteGroup.id }) {
            groups[index] = remoteGroup
        } else {
            groups.append(remoteGroup)
        }
        services.groupStorage.saveGroups(groups)
        return true
    }

    @discardableResult
    private func applyRemoteTag(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        guard let remoteTag = SyncRecordMapper.toTag(record) else { return false }
        if tombstoneIds.contains(remoteTag.id.uuidString) { return false }

        var tags = services.tagStorage.loadTags()
        if let index = tags.firstIndex(where: { $0.id == remoteTag.id }) {
            tags[index] = remoteTag
        } else {
            tags.append(remoteTag)
        }
        services.tagStorage.saveTags(tags)
        return true
    }

    private func applyRemoteSSHProfile(_ record: CKRecord, tombstoneIds: Set<String>) {
        let remoteProfile: SSHProfile
        do {
            remoteProfile = try SyncRecordMapper.toSSHProfile(record)
        } catch {
            Self.logger.error("Skipping remote SSH profile \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        if tombstoneIds.contains(remoteProfile.id.uuidString) { return }

        var profiles = services.sshProfileStorage.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == remoteProfile.id }) {
            profiles[index] = remoteProfile
        } else {
            profiles.append(remoteProfile)
        }
        services.sshProfileStorage.saveProfilesWithoutSync(profiles)
    }

    private func applyRemoteSettings(_ record: CKRecord) {
        guard let category = SyncRecordMapper.settingsCategory(from: record),
              let data = SyncRecordMapper.settingsData(from: record)
        else { return }
        do {
            try applySettingsData(data, for: category)
        } catch {
            Self.logger.error("Skipping remote settings \(record.recordID.recordName, privacy: .public) (\(category, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Observers

    private func observeAccountChanges() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await checkAccountStatus()
                evaluateStatus()

                // If account changed, clear metadata and re-sync
                let currentAccountId = metadataStorage.lastAccountId
                if let newAccountId = try? await self.currentAccountId(),
                   currentAccountId != nil, currentAccountId != newAccountId {
                    Self.logger.warning("iCloud account changed, clearing sync metadata")
                    metadataStorage.clearAll()
                    metadataStorage.lastAccountId = newAccountId
                }
            }
        }
    }

    private func observeLocalChanges() {
        changeCancellable = services.appEvents.syncChangeTracked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard syncStatus.isEnabled, !syncStatus.isSyncing else { return }
                syncTask?.cancel()
                syncTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self.syncNow()
                }
            }
    }

    private func observeLicenseChanges() {
        licenseCancellable = services.appEvents.licenseStatusDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                evaluateStatus()
                if syncStatus.isEnabled {
                    Task { await self.syncNow() }
                }
            }
    }

    // MARK: - Account

    private func checkAccountStatus() async {
        do {
            let status = try await engine.checkAccountStatus()
            iCloudAccountAvailable = (status == .available)

            if iCloudAccountAvailable {
                if let accountId = try? await currentAccountId() {
                    metadataStorage.lastAccountId = accountId
                }
            }
        } catch {
            iCloudAccountAvailable = false
            Self.logger.warning("Failed to check iCloud account: \(error.localizedDescription)")
        }
    }

    private func currentAccountId() async throws -> String? {
        try await engine.currentAccountId()
    }

    // MARK: - Conflict Handling

    private func handlePushConflicts(_ error: CKError) {
        guard let partialErrors = error.partialErrorsByItemID else { return }

        for (_, itemError) in partialErrors {
            guard let ckError = itemError as? CKError,
                  ckError.code == .serverRecordChanged,
                  let serverRecord = ckError.serverRecord,
                  let clientRecord = ckError.clientRecord
            else { continue }

            let recordType = serverRecord.recordType
            let entityName = (serverRecord["name"] as? String) ?? recordType

            let syncRecordType: SyncRecordType
            switch recordType {
            case SyncRecordType.connection.rawValue: syncRecordType = .connection
            case SyncRecordType.group.rawValue: syncRecordType = .group
            case SyncRecordType.tag.rawValue: syncRecordType = .tag
            case SyncRecordType.settings.rawValue: syncRecordType = .settings
            case SyncRecordType.sshProfile.rawValue: syncRecordType = .sshProfile
            default: continue
            }

            let conflict = SyncConflict(
                recordType: syncRecordType,
                entityName: entityName,
                localRecord: clientRecord,
                serverRecord: serverRecord,
                localModifiedAt: (clientRecord["modifiedAtLocal"] as? Date) ?? Date(),
                serverModifiedAt: (serverRecord["modifiedAtLocal"] as? Date) ?? Date()
            )
            conflictResolver.addConflict(conflict)
        }
    }

    /// Push a resolved conflict record back to CloudKit
    func pushResolvedConflict(_ record: CKRecord) {
        Task {
            do {
                try await engine.push(records: [record], deletions: [])
            } catch {
                Self.logger.error("Failed to push resolved conflict: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Settings Helpers

    private func settingsData(for category: String) -> Data? {
        let storage = services.appSettingsStorage
        let encoder = JSONEncoder()

        do {
            switch category {
            case "general": return try encoder.encode(storage.loadGeneral())
            case "appearance": return try encoder.encode(storage.loadAppearance())
            case "editor": return try encoder.encode(storage.loadEditor())
            case "dataGrid": return try encoder.encode(storage.loadDataGrid())
            case "history": return try encoder.encode(storage.loadHistory())
            case "tabs": return try encoder.encode(storage.loadTabs())
            case "keyboard": return try encoder.encode(storage.loadKeyboard())
            case "ai": return try encoder.encode(storage.loadAI())
            default: return nil
            }
        } catch {
            Self.logger.error("Failed to encode settings category '\(category)': \(error.localizedDescription)")
            return nil
        }
    }

    private func applySettingsData(_ data: Data, for category: String) throws {
        let manager = services.appSettings
        let decoder = JSONDecoder()

        do {
            switch category {
            case "general": manager.general = try decoder.decode(GeneralSettings.self, from: data)
            case "appearance": manager.appearance = try decoder.decode(AppearanceSettings.self, from: data)
            case "editor": manager.editor = try decoder.decode(EditorSettings.self, from: data)
            case "dataGrid": manager.dataGrid = try decoder.decode(DataGridSettings.self, from: data)
            case "history": manager.history = try decoder.decode(HistorySettings.self, from: data)
            case "tabs": manager.tabs = try decoder.decode(TabSettings.self, from: data)
            case "keyboard": manager.keyboard = try decoder.decode(KeyboardSettings.self, from: data)
            case "ai": manager.ai = try decoder.decode(AISettings.self, from: data)
            default: return
            }
        } catch {
            throw SyncDecodeError.decodeFailure(field: category, underlying: error)
        }
    }

    // MARK: - Group/Tag Collection Helpers

    private func collectDirtyGroups(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyGroupIds = changeTracker.dirtyRecords(for: .group)
        if !dirtyGroupIds.isEmpty {
            let groups = services.groupStorage.loadGroups()
            for id in dirtyGroupIds {
                if let group = groups.first(where: { $0.id.uuidString == id }) {
                    records.append(SyncRecordMapper.toCKRecord(group, in: zoneID))
                }
            }
        }

        for tombstone in metadataStorage.tombstones(for: .group) {
            deletions.append(
                SyncRecordMapper.recordID(type: .group, id: tombstone.id, in: zoneID)
            )
        }
    }

    private func collectDirtyTags(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyTagIds = changeTracker.dirtyRecords(for: .tag)
        if !dirtyTagIds.isEmpty {
            let tags = services.tagStorage.loadTags()
            for id in dirtyTagIds {
                if let tag = tags.first(where: { $0.id.uuidString == id }) {
                    records.append(SyncRecordMapper.toCKRecord(tag, in: zoneID))
                }
            }
        }

        for tombstone in metadataStorage.tombstones(for: .tag) {
            deletions.append(
                SyncRecordMapper.recordID(type: .tag, id: tombstone.id, in: zoneID)
            )
        }
    }

    private func collectDirtySSHProfiles(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyProfileIds = changeTracker.dirtyRecords(for: .sshProfile)
        if !dirtyProfileIds.isEmpty {
            let profiles = services.sshProfileStorage.loadProfiles()
            for id in dirtyProfileIds {
                if let profile = profiles.first(where: { $0.id.uuidString == id }) {
                    records.append(SyncRecordMapper.toCKRecord(profile, in: zoneID))
                }
            }
        }

        for tombstone in metadataStorage.tombstones(for: .sshProfile) {
            deletions.append(
                SyncRecordMapper.recordID(type: .sshProfile, id: tombstone.id, in: zoneID)
            )
        }
    }
}
