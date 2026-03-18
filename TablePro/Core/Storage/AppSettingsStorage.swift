//
//  AppSettingsStorage.swift
//  TablePro
//
//  Persistent storage for application settings using UserDefaults.
//  Follows FilterSettingsStorage pattern - singleton with JSON encoding.
//

import Foundation
import os

/// Persistent storage for app settings
final class AppSettingsStorage {
    static let shared = AppSettingsStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppSettingsStorage")

    private let defaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let general = "com.TablePro.settings.general"
        static let appearance = "com.TablePro.settings.appearance"
        static let editor = "com.TablePro.settings.editor"
        static let dataGrid = "com.TablePro.settings.dataGrid"
        static let history = "com.TablePro.settings.history"
        static let tabs = "com.TablePro.settings.tabs"
        static let keyboard = "com.TablePro.settings.keyboard"
        static let ai = "com.TablePro.settings.ai"
        static let sync = "com.TablePro.settings.sync"
        static let lastConnectionId = "com.TablePro.settings.lastConnectionId"
        static let hasCompletedOnboarding = "com.TablePro.settings.hasCompletedOnboarding"
    }

    private init() {}

    // MARK: - General Settings

    func loadGeneral() -> GeneralSettings {
        load(key: Keys.general, default: .default)
    }

    func saveGeneral(_ settings: GeneralSettings) {
        save(settings, key: Keys.general)
    }

    // MARK: - Appearance Settings

    func loadAppearance() -> AppearanceSettings {
        load(key: Keys.appearance, default: .default)
    }

    func saveAppearance(_ settings: AppearanceSettings) {
        save(settings, key: Keys.appearance)
    }

    // MARK: - Editor Settings

    func loadEditor() -> EditorSettings {
        load(key: Keys.editor, default: .default)
    }

    func saveEditor(_ settings: EditorSettings) {
        save(settings, key: Keys.editor)
    }

    // MARK: - Data Grid Settings

    func loadDataGrid() -> DataGridSettings {
        load(key: Keys.dataGrid, default: .default)
    }

    func saveDataGrid(_ settings: DataGridSettings) {
        save(settings, key: Keys.dataGrid)
    }

    // MARK: - History Settings

    func loadHistory() -> HistorySettings {
        load(key: Keys.history, default: .default)
    }

    func saveHistory(_ settings: HistorySettings) {
        save(settings, key: Keys.history)
    }


    // MARK: - Tab Settings

    func loadTabs() -> TabSettings {
        load(key: Keys.tabs, default: .default)
    }

    func saveTabs(_ settings: TabSettings) {
        save(settings, key: Keys.tabs)
    }

    // MARK: - Keyboard Settings

    func loadKeyboard() -> KeyboardSettings {
        load(key: Keys.keyboard, default: .default)
    }

    func saveKeyboard(_ settings: KeyboardSettings) {
        save(settings, key: Keys.keyboard)
    }

    // MARK: - AI Settings

    func loadAI() -> AISettings {
        load(key: Keys.ai, default: .default)
    }

    func saveAI(_ settings: AISettings) {
        save(settings, key: Keys.ai)
    }

    // MARK: - Sync Settings

    func loadSync() -> SyncSettings {
        load(key: Keys.sync, default: .default)
    }

    func saveSync(_ settings: SyncSettings) {
        save(settings, key: Keys.sync)
    }

    // MARK: - Last Connection (for Reopen Last Session)

    /// Load the last used connection ID
    func loadLastConnectionId() -> UUID? {
        guard let uuidString = defaults.string(forKey: Keys.lastConnectionId) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    /// Save the last used connection ID
    func saveLastConnectionId(_ connectionId: UUID?) {
        if let connectionId = connectionId {
            defaults.set(connectionId.uuidString, forKey: Keys.lastConnectionId)
        } else {
            defaults.removeObject(forKey: Keys.lastConnectionId)
        }
    }

    // MARK: - Last Selected Database (per connection)

    func saveLastDatabase(_ database: String?, for connectionId: UUID) {
        if let database {
            defaults.set(database, forKey: "com.TablePro.lastSelectedDatabase.\(connectionId)")
        } else {
            defaults.removeObject(forKey: "com.TablePro.lastSelectedDatabase.\(connectionId)")
        }
    }

    func loadLastDatabase(for connectionId: UUID) -> String? {
        defaults.string(forKey: "com.TablePro.lastSelectedDatabase.\(connectionId)")
    }

    // MARK: - Onboarding

    /// Check if user has completed onboarding
    func hasCompletedOnboarding() -> Bool {
        defaults.bool(forKey: Keys.hasCompletedOnboarding)
    }

    /// Mark onboarding as completed
    func setOnboardingCompleted() {
        defaults.set(true, forKey: Keys.hasCompletedOnboarding)
    }

    // MARK: - Reset

    /// Reset all settings to defaults
    func resetToDefaults() {
        saveGeneral(.default)
        saveAppearance(.default)
        saveEditor(.default)
        saveDataGrid(.default)
        saveHistory(.default)
        saveTabs(.default)
        saveKeyboard(.default)
        saveAI(.default)
        saveSync(.default)
    }

    // MARK: - Helpers

    private func load<T: Codable>(key: String, default defaultValue: T) -> T {
        guard let data = defaults.data(forKey: key) else {
            return defaultValue
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logger.error("Failed to decode settings for \(key): \(error)")
            return defaultValue
        }
    }

    private func save<T: Codable>(_ value: T, key: String) {
        do {
            let data = try encoder.encode(value)
            defaults.set(data, forKey: key)
        } catch {
            Self.logger.error("Failed to encode settings for \(key): \(error)")
        }
    }
}
