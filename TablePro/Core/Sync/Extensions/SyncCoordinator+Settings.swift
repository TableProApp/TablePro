import Foundation
import os

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
