import CloudKit
import Foundation
import os
import TableProSyncTransport
import TableProTheme

extension SyncCoordinator {
    func settingsData(for category: String) -> Data? {
        let storage = services.appSettingsStorage
        let encoder = JSONEncoder()

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
            case CustomSlashCommandStorage.syncCategory:
                return try encoder.encode(CustomSlashCommandStorage.shared.commands)
            case let category where category.hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix):
                return columnLayouts().rawData(
                    forStorageKey: String(category.dropFirst(FileColumnLayoutPersister.syncCategoryPrefix.count))
                )
            case let category where category.hasPrefix(ThemeCatalog.syncCategoryPrefix):
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

extension SyncCoordinator {
    // A build that reads a newer theme format names a new kind, so it fetches the zone once and
    // picks up the theme records an older build skipped.
    static let themeContentKind = "\(SyncRecordType.settings.rawValue)/theme.v\(ThemeSchema.current)"

    static var readableContent: Set<String> {
        Set(SyncRecordType.verifiedInProduction.map(\.rawValue)).union([Self.themeContentKind])
    }

    func applyRemoteThemeDeletions(_ settingsRecordNames: Set<String>) -> Bool {
        let prefix = SyncRecordType.settings.recordNamePrefix + ThemeCatalog.syncCategoryPrefix
        let ids = Set(settingsRecordNames.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        guard !ids.isEmpty else { return true }
        return themeCatalog.removeWithoutSync(ids: ids)
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
