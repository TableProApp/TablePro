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
final class AppSettingsStorage: Sendable {
    static let shared = AppSettingsStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppSettingsStorage")

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let general = "com.TablePro.settings.general"
        static let appearance = "com.TablePro.settings.appearance"
        static let appearanceMode = "com.TablePro.settings.appearanceMode"
        static let editor = "com.TablePro.settings.editor"
        static let formatter = "com.TablePro.settings.formatter"
        static let dataGrid = "com.TablePro.settings.dataGrid"
        static let history = "com.TablePro.settings.history"
        static let tabs = "com.TablePro.settings.tabs"
        static let keyboard = "com.TablePro.settings.keyboard"
        static let ai = "com.TablePro.settings.ai"
        static let sync = "com.TablePro.settings.sync"
        static let mcp = "com.TablePro.settings.mcp"
        static let notifications = "com.TablePro.settings.notifications"
        static let typography = "com.TablePro.settings.typography"
        static let hasSeenWelcomeSheet = "com.TablePro.settings.hasCompletedOnboarding"
        static let startupReopenMigration = "com.TablePro.settings.didMigrateStartupToReopenLast"
        // One height per editor kind, before a height belonged to its column.
        static let retiredFieldHeights = [
            "rightSidebar.jsonFieldHeight",
            "com.TablePro.rightSidebar.jsonFieldHeight",
            "com.TablePro.rightSidebar.textFieldHeight",
            "com.TablePro.rightSidebar.geometryFieldHeight",
            "com.TablePro.settings.didMigrateJsonFieldHeightKey",
        ]
    }

    /// The storage environment's defaults, not `.standard`. A UI test runs against a per-sandbox
    /// suite, and reading the standard domain here put every setting, the onboarding flag among
    /// them, in the machine's real preferences: a developer who had finished onboarding never saw
    /// it under test, a fresh runner saw it until the first case skipped it, and every case after
    /// that inherited the skip.
    init(userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = userDefaults
    }

    // MARK: - General Settings

    func loadGeneral() -> GeneralSettings {
        load(key: Keys.general, default: .default)
    }

    func saveGeneral(_ settings: GeneralSettings) {
        save(settings, key: Keys.general)
    }

    func migrateStartupBehaviorToReopenLastIfNeeded() {
        guard !defaults.bool(forKey: Keys.startupReopenMigration) else { return }
        defaults.set(true, forKey: Keys.startupReopenMigration)

        guard defaults.data(forKey: Keys.general) != nil else { return }
        var general = loadGeneral()
        guard general.startupBehavior == .showWelcome else { return }
        general.startupBehavior = .reopenLast
        saveGeneral(general)
    }

    func removeRetiredFieldHeightKeys() {
        for key in Keys.retiredFieldHeights where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Appearance Settings

    func loadAppearance() -> AppearanceSettings {
        load(key: Keys.appearance, default: .default)
    }

    func saveAppearance(_ settings: AppearanceSettings) {
        save(settings, key: Keys.appearance)
    }

    // Older builds kept the mode inside the synced appearance blob. The first load carries it to its
    // own key and writes it there, because the next save of the blob drops the field.
    func loadAppearanceMode() -> AppAppearanceMode {
        if let stored = defaults.string(forKey: Keys.appearanceMode) {
            guard let mode = AppAppearanceMode(rawValue: stored) else {
                Self.logger.error("Unknown appearance mode \(stored, privacy: .public)")
                return .auto
            }
            return mode
        }

        let carried = legacyAppearanceMode() ?? .auto
        saveAppearanceMode(carried)
        return carried
    }

    func saveAppearanceMode(_ mode: AppAppearanceMode) {
        defaults.set(mode.rawValue, forKey: Keys.appearanceMode)
    }

    private struct LegacyAppearanceModeField: Decodable {
        var appearanceMode: AppAppearanceMode?
    }

    private func legacyAppearanceMode() -> AppAppearanceMode? {
        guard let data = defaults.data(forKey: Keys.appearance) else { return nil }
        do {
            return try decoder.decode(LegacyAppearanceModeField.self, from: data).appearanceMode
        } catch {
            Self.logger.error("Failed to read the appearance mode from the appearance settings: \(error)")
            return nil
        }
    }

    /// The first launch with no typography setting lifts the fonts out of the old theme files once,
    /// so an upgrade does not return everyone to System Mono 13.
    func loadTypography(
        systemIsDark: Bool,
        legacyThemesDirectory: URL = ThemeCatalog.defaultUserDirectory
    ) -> TypographySettings {
        if let stored = defaults.data(forKey: Keys.typography) {
            do {
                return try decoder.decode(TypographySettings.self, from: stored)
            } catch {
                Self.logger.error("Failed to decode typography settings: \(error)")
                return .default
            }
        }

        let carried = LegacyThemeFonts.read(
            appearance: loadAppearance(),
            mode: loadAppearanceMode(),
            systemIsDark: systemIsDark,
            themesDirectory: legacyThemesDirectory
        )
        saveTypography(carried)
        return carried
    }

    func saveTypography(_ settings: TypographySettings) {
        save(settings, key: Keys.typography)
    }

    // MARK: - Editor Settings

    func loadEditor() -> EditorSettings {
        load(key: Keys.editor, default: .default)
    }

    func saveEditor(_ settings: EditorSettings) {
        save(settings, key: Keys.editor)
    }

    // MARK: - Formatter Settings

    func loadFormatter() -> SQLFormatterSettings {
        load(key: Keys.formatter, default: .default)
    }

    func saveFormatter(_ settings: SQLFormatterSettings) {
        save(settings, key: Keys.formatter)
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
        load(key: Keys.keyboard, default: KeyboardSettings.default).sanitized()
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

    // MARK: - MCP Settings

    func loadNotifications() -> NotificationSettings {
        load(key: Keys.notifications, default: .default)
    }

    func saveNotifications(_ settings: NotificationSettings) {
        save(settings, key: Keys.notifications)
    }

    func loadMCP() -> MCPSettings {
        load(key: Keys.mcp, default: .default)
    }

    func saveMCP(_ settings: MCPSettings) {
        save(settings, key: Keys.mcp)
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

    // MARK: - Last Selected Schema (per connection)

    func saveLastSchema(_ schema: String?, for connectionId: UUID) {
        if let schema {
            defaults.set(schema, forKey: "com.TablePro.lastSelectedSchema.\(connectionId)")
        } else {
            defaults.removeObject(forKey: "com.TablePro.lastSelectedSchema.\(connectionId)")
        }
    }

    func loadLastSchema(for connectionId: UUID) -> String? {
        defaults.string(forKey: "com.TablePro.lastSelectedSchema.\(connectionId)")
    }

    // MARK: - Welcome Sheet

    func hasSeenWelcomeSheet() -> Bool {
        defaults.bool(forKey: Keys.hasSeenWelcomeSheet)
    }

    func markWelcomeSheetSeen() {
        defaults.set(true, forKey: Keys.hasSeenWelcomeSheet)
    }

    // MARK: - Reset

    /// Reset all settings to defaults
    func resetToDefaults() {
        saveGeneral(.default)
        saveAppearance(.default)
        saveAppearanceMode(.auto)
        saveEditor(.default)
        saveFormatter(.default)
        saveDataGrid(.default)
        saveHistory(.default)
        saveTabs(.default)
        saveKeyboard(.default)
        saveAI(.default)
        saveSync(.default)
        saveMCP(.default)
        saveTypography(.default)
        defaults.removeObject(forKey: PreferenceKeys.selectedSettingsPane.name)
        defaults.removeObject(forKey: PreferenceKeys.rowInspectorFieldHeights.name)
        defaults.removeObject(forKey: PreferenceKeys.rowInspectorGeometryFieldMode.name)
        defaults.removeObject(forKey: SidebarPersistenceKey.defaultLayout)
        RoutineDebugOptionStore(defaults: { [defaults] in defaults }).removeAll()
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
