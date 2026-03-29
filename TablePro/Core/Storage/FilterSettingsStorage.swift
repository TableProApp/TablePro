//
//  FilterSettingsStorage.swift
//  TablePro
//
//  Persistent storage for filter settings and last-used filters
//

import Foundation
import os

/// Default column selection for new filters
enum FilterDefaultColumn: String, CaseIterable, Identifiable, Codable {
    case rawSQL = "rawSQL"
    case primaryKey = "primaryKey"
    case anyColumn = "anyColumn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rawSQL: return "Raw SQL"
        case .primaryKey: return "Primary Key"
        case .anyColumn: return "Any Column"
        }
    }
}

/// Default operator for new filters
enum FilterDefaultOperator: String, CaseIterable, Identifiable, Codable {
    case equal = "equal"
    case contains = "contains"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .equal: return "Equal (=)"
        case .contains: return "Contains"
        }
    }

    func toFilterOperator() -> FilterOperator {
        switch self {
        case .equal: return .equal
        case .contains: return .contains
        }
    }
}

/// Default panel state when opening a table
enum FilterPanelDefaultState: String, CaseIterable, Identifiable, Codable {
    case restoreLast = "restoreLast"
    case alwaysShow = "alwaysShow"
    case alwaysHide = "alwaysHide"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .restoreLast: return "Restore Last Filter"
        case .alwaysShow: return "Always Show"
        case .alwaysHide: return "Always Hide"
        }
    }
}

/// Settings for filter behavior
struct FilterSettings: Codable, Equatable {
    var defaultColumn: FilterDefaultColumn
    var defaultOperator: FilterDefaultOperator
    var panelState: FilterPanelDefaultState

    init(
        defaultColumn: FilterDefaultColumn = .rawSQL,
        defaultOperator: FilterDefaultOperator = .equal,
        panelState: FilterPanelDefaultState = .alwaysHide
    ) {
        self.defaultColumn = defaultColumn
        self.defaultOperator = defaultOperator
        self.panelState = panelState
    }
}

/// Persistent storage for filter settings and per-table last-used filters
@MainActor
final class FilterSettingsStorage {
    static let shared = FilterSettingsStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "FilterSettingsStorage")

    private let settingsKey = "com.TablePro.filter.settings"
    private let lastFiltersKeyPrefix = "com.TablePro.filter.lastFilters."
    /// Key used to persist the set of known per-table filter keys for efficient bulk removal.
    private let knownFilterKeysKey = "com.TablePro.filter.knownFilterKeys"
    private let defaults = UserDefaults.standard

    /// Cached settings to avoid repeated UserDefaults read + JSON decode
    private var cachedSettings: FilterSettings?

    /// In-memory cache for tracked filter keys. Lazy-loaded on first access
    /// so that `trackKey`/`removeTrackedKey` avoid redundant UserDefaults reads.
    private var _trackedKeys: Set<String>?

    private var trackedKeys: Set<String> {
        get {
            if let cached = _trackedKeys { return cached }
            let array = defaults.stringArray(forKey: knownFilterKeysKey) ?? []
            let keys = Set(array)
            _trackedKeys = keys
            return keys
        }
        set {
            _trackedKeys = newValue
            defaults.set(Array(newValue), forKey: knownFilterKeysKey)
        }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Settings

    /// Load filter settings (cached after first read)
    func loadSettings() -> FilterSettings {
        if let cached = cachedSettings { return cached }

        guard let data = defaults.data(forKey: settingsKey) else {
            let defaultSettings = FilterSettings()
            cachedSettings = defaultSettings
            return defaultSettings
        }

        do {
            let decoded = try decoder.decode(FilterSettings.self, from: data)
            cachedSettings = decoded
            return decoded
        } catch {
            Self.logger.error("Failed to decode filter settings: \(error)")
            let defaultSettings = FilterSettings()
            cachedSettings = defaultSettings
            return defaultSettings
        }
    }

    /// Save filter settings
    func saveSettings(_ settings: FilterSettings) {
        cachedSettings = settings
        do {
            let data = try encoder.encode(settings)
            defaults.set(data, forKey: settingsKey)
        } catch {
            Self.logger.error("Failed to encode filter settings: \(error)")
        }
    }

    // MARK: - Per-Table Last Filters

    /// Load last-used filters for a specific table
    func loadLastFilters(for tableName: String) -> [TableFilter] {
        let key = lastFiltersKeyPrefix + sanitizeTableName(tableName)

        guard let data = defaults.data(forKey: key) else {
            return []
        }

        do {
            return try decoder.decode([TableFilter].self, from: data)
        } catch {
            Self.logger.error("Failed to decode last filters for \(tableName): \(error)")
            return []
        }
    }

    /// Save last-used filters for a specific table
    func saveLastFilters(_ filters: [TableFilter], for tableName: String) {
        let key = lastFiltersKeyPrefix + sanitizeTableName(tableName)

        // Only save non-empty filter configurations
        guard !filters.isEmpty else {
            defaults.removeObject(forKey: key)
            removeTrackedKey(key)
            return
        }

        do {
            let data = try encoder.encode(filters)
            defaults.set(data, forKey: key)
            trackKey(key)
        } catch {
            Self.logger.error("Failed to encode last filters for \(tableName): \(error)")
        }
    }

    /// Clear last filters for a specific table
    func clearLastFilters(for tableName: String) {
        let key = lastFiltersKeyPrefix + sanitizeTableName(tableName)
        defaults.removeObject(forKey: key)
        removeTrackedKey(key)
    }

    /// Clear all stored last filters using the tracked key set instead of
    /// loading the full UserDefaults plist via `dictionaryRepresentation()`.
    func clearAllLastFilters() {
        for key in trackedKeys {
            defaults.removeObject(forKey: key)
        }
        _trackedKeys = nil
        defaults.removeObject(forKey: knownFilterKeysKey)
    }

    // MARK: - Key Tracking

    /// Add a key to the tracked set.
    private func trackKey(_ key: String) {
        var keys = trackedKeys
        if keys.insert(key).inserted {
            trackedKeys = keys
        }
    }

    /// Remove a key from the tracked set.
    private func removeTrackedKey(_ key: String) {
        var keys = trackedKeys
        if keys.remove(key) != nil {
            trackedKeys = keys
        }
    }

    // MARK: - Helpers

    /// Sanitize table name for use as UserDefaults key
    private func sanitizeTableName(_ tableName: String) -> String {
        // Replace special characters that might cause issues in keys
        tableName
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }
}
