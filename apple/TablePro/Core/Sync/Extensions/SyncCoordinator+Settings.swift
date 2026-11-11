import CloudKit
import Foundation
import os
import TableProSyncTransport
import TableProTheme

extension SyncCoordinator {
    func settingsData(for category: String) -> Data? {
        let storage = services.appSettingsStorage
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        do {
            switch category {
            case AppSettingsCategory.general: return try encoder.encode(storage.loadGeneral())
            case AppSettingsCategory.appearance: return try encoder.encode(storage.loadAppearance())
            case AppSettingsCategory.editor: return try encoder.encode(storage.loadEditor())
            case AppSettingsCategory.dataGrid: return try encoder.encode(storage.loadDataGrid())
            case AppSettingsCategory.history: return try encoder.encode(storage.loadHistory())
            case AppSettingsCategory.tabs: return try encoder.encode(storage.loadTabs())
            case AppSettingsCategory.keyboard: return try encoder.encode(storage.loadKeyboard())
            case AppSettingsCategory.ai: return try encoder.encode(storage.loadAI())
            case AppSettingsCategory.notifications: return try encoder.encode(storage.loadNotifications())
            case AppSettingsCategory.formatter: return try encoder.encode(storage.loadFormatter())
            case AppSettingsCategory.valueColors: return try encoder.encode(storage.loadValueColors())
            case CustomSlashCommandStorage.syncCategory:
                return try encoder.encode(CustomSlashCommandStorage.shared.commands)
            case let category where category.hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix):
                return columnLayouts().rawData(
                    forStorageKey: String(category.dropFirst(FileColumnLayoutPersister.syncCategoryPrefix.count))
                )
            case let category where ThemeCatalog.themeId(forSyncCategory: category) != nil:
                return themeCatalog.syncPayload(forCategory: category)
            default: return nil
            }
        } catch {
            Self.logger.error("Failed to encode settings category '\(category)': \(error.localizedDescription)")
            return nil
        }
    }

    func applySettingsData(_ data: Data, for category: String) throws {
        let manager = services.appSettings
        let decoder = JSONDecoder()

        do {
            switch category {
            case AppSettingsCategory.general: manager.general = try decoder.decode(GeneralSettings.self, from: data)
            case AppSettingsCategory.appearance:
                manager.appearance = try decoder.decode(AppearanceSettings.self, from: data)
            case AppSettingsCategory.editor: manager.editor = try decoder.decode(EditorSettings.self, from: data)
            case AppSettingsCategory.dataGrid: manager.dataGrid = try decoder.decode(DataGridSettings.self, from: data)
            case AppSettingsCategory.history: manager.history = try decoder.decode(HistorySettings.self, from: data)
            case AppSettingsCategory.tabs: manager.tabs = try decoder.decode(TabSettings.self, from: data)
            case AppSettingsCategory.keyboard: manager.keyboard = try decoder.decode(KeyboardSettings.self, from: data)
            case AppSettingsCategory.ai: manager.ai = try decoder.decode(AISettings.self, from: data)
            case AppSettingsCategory.notifications:
                manager.notifications = try decoder.decode(NotificationSettings.self, from: data)
            case AppSettingsCategory.formatter:
                manager.formatter = try decoder.decode(SQLFormatterSettings.self, from: data)
            case AppSettingsCategory.valueColors:
                manager.valueColors = try decoder.decode(ValueColorSettings.self, from: data)
            case CustomSlashCommandStorage.syncCategory:
                CustomSlashCommandStorage.shared.applyRemote(try decoder.decode([CustomSlashCommand].self, from: data))
            case let category where category.hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix):
                columnLayouts().applyRemote(
                    storageKey: String(category.dropFirst(FileColumnLayoutPersister.syncCategoryPrefix.count)),
                    data: data
                )
            default: return
            }
        } catch {
            throw SyncDecodeError.decodeFailure(field: category, underlying: error)
        }
    }
}

// MARK: - Themes

// nil for a record the pull deleted or could not read.
struct PulledThemeRecords {
    var records: [String: Data?] = [:]
    var isFullFetch = false
}

extension SyncCoordinator {
    // A build that reads a newer theme format names a new kind, so it fetches the zone once and
    // picks up the theme records an older build skipped.
    static let themeContentKind = "\(SyncRecordType.settings.rawValue)/theme.v\(ThemeSchema.current)"

    // Fetches the zone once for a formatter record this Mac skipped while on an older build.
    static let formatterContentKind = "\(SyncRecordType.settings.rawValue)/\(AppSettingsCategory.formatter).v1"

    // Fetches the zone once for a value colors record this Mac skipped while on an older build.
    static let valueColorsContentKind = "\(SyncRecordType.settings.rawValue)/\(AppSettingsCategory.valueColors).v1"

    static var readableContent: Set<String> {
        Set(SyncRecordType.verifiedInProduction.map(\.rawValue))
            .union([
                Self.themeContentKind,
                Self.formatterContentKind,
                Self.valueColorsContentKind,
                ConnectionSyncField.sshRouteContentKind,
            ])
    }

    // Only what this Mac applies: a pull skips a category that is off and still moves the token past it.
    static func readableContent(for settings: SyncSettings) -> Set<String> {
        var content = Set(SyncRecordType.verifiedInProduction.filter { settings.syncs($0) }.map(\.rawValue))
        if settings.syncs(.connection) {
            content.insert(ConnectionSyncField.sshRouteContentKind)
        }
        if settings.syncs(.settings) {
            content.insert(Self.themeContentKind)
            content.insert(Self.formatterContentKind)
            content.insert(Self.valueColorsContentKind)
        }
        return content
    }

    // Read before any record is applied, so a theme new to this Mac finds its newer formats' records
    // whichever comes first in the pull.
    func pulledThemeRecords(
        _ changedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        unreadRecordIDs: [CKRecord.ID],
        isFullFetch: Bool,
        echoGuard: SyncEchoGuard?
    ) -> PulledThemeRecords {
        var pulled = PulledThemeRecords(isFullFetch: isFullFetch)
        for record in changedRecords where record.recordType == SyncRecordType.settings.rawValue {
            guard echoGuard?.withholds(record.recordID, tracker: changeTracker) != true,
                  let category = SyncRecordMapper.settingsCategory(from: record),
                  Self.isNewerThemeFormat(category),
                  let data = SyncRecordMapper.settingsData(from: record)
            else { continue }
            pulled.records[category] = data
        }
        // An unread record changed since the cached copy, so its keys stay unknown until the pull that reads it.
        for recordID in deletedRecordIDs + unreadRecordIDs {
            guard let parsed = SyncRecordType.parse(recordName: recordID.recordName),
                  parsed.type == .settings,
                  Self.isNewerThemeFormat(parsed.id)
            else { continue }
            pulled.records.updateValue(nil, forKey: parsed.id)
        }
        return pulled
    }

    // A full fetch lists every record the zone holds, so a cached record it lacks was deleted.
    func newerThemeRecord(_ category: String, in pulled: PulledThemeRecords) -> Data? {
        if let record = pulled.records[category] {
            return record
        }
        guard !pulled.isFullFetch else { return nil }
        return recordCache.record(named: SyncRecordType.settings.recordName(for: category))
            .flatMap(SyncRecordMapper.settingsData(from:))
    }

    // A newer format's record the fetch does not list is gone from the server. Every theme that exists
    // anywhere is listed or held here, and only a Mac that holds a theme deletes its newer records.
    func themeRecordsGone(
        afterFullFetch result: PullResult,
        zoneID: CKRecordZone.ID,
        pushed: Set<CKRecord.ID>
    ) -> [CKRecord.ID] {
        let listed = Set((result.changedRecords.map(\.recordID) + result.unreadRecordIDs).map(\.recordName))
        let listedIds = listed.compactMap { name -> String? in
            guard let parsed = SyncRecordType.parse(recordName: name),
                  parsed.type == .settings,
                  ThemeCatalog.syncSchema(forCategory: parsed.id) == ThemeSchema.oldestReadable
            else { return nil }
            return ThemeCatalog.themeId(forSyncCategory: parsed.id)
        }
        let heldIds = themeCatalog.syncCategories.compactMap(ThemeCatalog.themeId(forSyncCategory:))
        return Set(listedIds + heldIds).sorted()
            .flatMap { id in
                ThemeCatalog.newerSyncSchemas.map { schema in
                    SyncRecordMapper.recordID(type: .settings, id: ThemeCatalog.syncCategory(for: id, schema: schema), in: zoneID)
                }
            }
            .filter { !listed.contains($0.recordName) && !pushed.contains($0) }
    }

    private static func isNewerThemeFormat(_ category: String) -> Bool {
        ThemeCatalog.syncSchema(forCategory: category).map { ThemeCatalog.newerSyncSchemas.contains($0) } == true
    }

    func applyRemoteThemeDeletions(_ settingsRecordNames: Set<String>) -> Bool {
        let prefix = SyncRecordType.settings.recordNamePrefix
        let deleted = settingsRecordNames.compactMap { name -> (id: String, schema: Int)? in
            guard name.hasPrefix(prefix) else { return nil }
            let category = String(name.dropFirst(prefix.count))
            guard let id = ThemeCatalog.themeId(forSyncCategory: category),
                  let schema = ThemeCatalog.syncSchema(forCategory: category)
            else { return nil }
            return (id, schema)
        }
        let trashed = Set(deleted.filter { $0.schema == ThemeSchema.oldestReadable }.map(\.id))
        var isPersisted = trashed.isEmpty || themeCatalog.removeWithoutSync(ids: trashed)
        for schema in ThemeCatalog.newerSyncSchemas {
            let ids = Set(deleted.filter { $0.schema == schema && !trashed.contains($0.id) }.map(\.id))
            guard !ids.isEmpty else { continue }
            isPersisted = themeCatalog.removeSlotsWithoutSync(introducedIn: schema, ids: ids) && isPersisted
        }
        return isPersisted
    }

    // Themes made before theme sync were never marked, and loads never mark. They wait for the
    // first full pull, because push runs first in a cycle and seeding earlier would overwrite a newer
    // copy another Mac already uploaded.
    func scheduleThemeSeedIfNeeded() {
        guard metadataStorage.themeSeedState == nil else { return }
        metadataStorage.themeSeedState = .pending
    }

    // 0.81 synced the slot ids but not the files, so two Macs can hold different themes under one
    // imported id. Until the seed runs, the local one may never have reached the server.
    var remoteThemeMerge: ThemeRemoteMerge {
        metadataStorage.themeSeedState == .pending ? .keepBoth : .replace
    }

    // Only themes the server lacks: a full fetch has no deletions, so it cannot tell a theme deleted
    // elsewhere from one never uploaded, and that is why this runs once rather than after every
    // full fetch.
    func seedLocalThemesIfPending(after result: PullResult) {
        guard metadataStorage.themeSeedState == .pending else { return }
        let held = Set(result.changedRecords.compactMap { record -> String? in
            guard record.recordType == SyncRecordType.settings.rawValue,
                  let category = SyncRecordMapper.settingsCategory(from: record),
                  ThemeCatalog.themeId(forSyncCategory: category) != nil
            else { return nil }
            return category
        })
        let missing = themeCatalog.syncCategories.filter { !held.contains($0) }
        changeTracker.markDirty(.settings, ids: missing)
        metadataStorage.themeSeedState = .done
        Self.logger.info("Seeded \(missing.count, privacy: .public) themes the server did not hold")
    }
}
