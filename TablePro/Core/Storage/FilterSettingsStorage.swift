//
//  FilterSettingsStorage.swift
//  TablePro
//

import Foundation
import os

enum FilterDefaultColumn: String, CaseIterable, Identifiable, Codable {
    case rawSQL = "rawSQL"
    case primaryKey = "primaryKey"
    case anyColumn = "anyColumn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rawSQL: return "Raw SQL"
        case .primaryKey: return String(localized: "Primary Key")
        case .anyColumn: return String(localized: "Any Column")
        }
    }
}

enum FilterDefaultOperator: String, CaseIterable, Identifiable, Codable {
    case equal = "equal"
    case contains = "contains"

    var id: String { rawValue }

    var displayName: String {
        let op = toFilterOperator()
        if op.symbol.isEmpty { return op.displayName }
        return "\(op.symbol)  \(op.displayName)"
    }

    func toFilterOperator() -> FilterOperator {
        switch self {
        case .equal: return .equal
        case .contains: return .contains
        }
    }
}

enum FilterPanelDefaultState: String, CaseIterable, Identifiable, Codable {
    case restoreLast = "restoreLast"
    case alwaysShow = "alwaysShow"
    case alwaysHide = "alwaysHide"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .restoreLast: return String(localized: "Restore Last Filter")
        case .alwaysShow: return String(localized: "Always Show")
        case .alwaysHide: return String(localized: "Always Hide")
        }
    }
}

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

@MainActor
final class FilterSettingsStorage {
    static let shared = FilterSettingsStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "FilterSettingsStorage")

    private static let legacyLastFiltersKeyPrefix = "com.TablePro.filter.lastFilters."
    private static let legacyKnownFilterKeysKey = "com.TablePro.filter.knownFilterKeys"
    private static let migrationCompleteKey = "com.TablePro.filterStateMigrationComplete"

    private let settingsKey = "com.TablePro.filter.settings"
    private let defaults = UserDefaults.standard

    private let filterStateDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cachedSettings: FilterSettings?
    private var lastFiltersCache: [String: [TableFilter]] = [:]

    private init() {
        filterStateDirectory = Self.resolvedFilterStateDirectory()

        do {
            try FileManager.default.createDirectory(
                at: filterStateDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create filter state directory: \(error.localizedDescription)")
        }

        Self.performMigrationIfNeeded(filterStateDirectory: filterStateDirectory)
    }

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

    func saveSettings(_ settings: FilterSettings) {
        cachedSettings = settings
        do {
            let data = try encoder.encode(settings)
            defaults.set(data, forKey: settingsKey)
        } catch {
            Self.logger.error("Failed to encode filter settings: \(error)")
        }
    }

    func loadLastFilters(for tableName: String) -> [TableFilter] {
        let sanitized = sanitizeTableName(tableName)
        if let cached = lastFiltersCache[sanitized] { return cached }

        let fileURL = fileURL(forSanitizedName: sanitized)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastFiltersCache[sanitized] = []
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let filters = try decoder.decode([TableFilter].self, from: data)
            lastFiltersCache[sanitized] = filters
            return filters
        } catch {
            Self.logger.error("Failed to load last filters for \(tableName): \(error)")
            lastFiltersCache[sanitized] = []
            return []
        }
    }

    func saveLastFilters(_ filters: [TableFilter], for tableName: String) {
        let sanitized = sanitizeTableName(tableName)
        let fileURL = fileURL(forSanitizedName: sanitized)

        guard !filters.isEmpty else {
            removeFile(at: fileURL, label: tableName)
            lastFiltersCache.removeValue(forKey: sanitized)
            return
        }

        do {
            let data = try encoder.encode(filters)
            try data.write(to: fileURL, options: .atomic)
            lastFiltersCache[sanitized] = filters
        } catch {
            Self.logger.error("Failed to save last filters for \(tableName): \(error)")
        }
    }

    func clearLastFilters(for tableName: String) {
        let sanitized = sanitizeTableName(tableName)
        let fileURL = fileURL(forSanitizedName: sanitized)
        removeFile(at: fileURL, label: tableName)
        lastFiltersCache.removeValue(forKey: sanitized)
    }

    func clearAllLastFilters() {
        let fm = FileManager.default
        do {
            let files = try fm.contentsOfDirectory(at: filterStateDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                try? fm.removeItem(at: file)
            }
        } catch {
            Self.logger.error("Failed to enumerate filter state directory: \(error.localizedDescription)")
        }
        lastFiltersCache.removeAll()
    }

    private func fileURL(forSanitizedName sanitized: String) -> URL {
        filterStateDirectory.appendingPathComponent("\(sanitized).json")
    }

    private func removeFile(at fileURL: URL, label: String) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Self.logger.error("Failed to remove last filters file for \(label): \(error.localizedDescription)")
        }
    }

    private func sanitizeTableName(_ tableName: String) -> String {
        tableName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tableName
    }

    private static func resolvedFilterStateDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("FilterState", isDirectory: true)
    }

    private static func performMigrationIfNeeded(filterStateDirectory: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationCompleteKey) else { return }

        let allKeys = defaults.dictionaryRepresentation().keys
        let legacyKeys = allKeys.filter { $0.hasPrefix(legacyLastFiltersKeyPrefix) }

        var migrated = 0
        for key in legacyKeys {
            let sanitized = String(key.dropFirst(legacyLastFiltersKeyPrefix.count))
            guard !sanitized.isEmpty,
                  let data = defaults.data(forKey: key) else {
                defaults.removeObject(forKey: key)
                continue
            }

            let fileURL = filterStateDirectory.appendingPathComponent("\(sanitized).json")
            do {
                try data.write(to: fileURL, options: .atomic)
                migrated += 1
            } catch {
                logger.error("Failed to migrate last filters for \(sanitized): \(error.localizedDescription)")
            }
            defaults.removeObject(forKey: key)
        }

        defaults.removeObject(forKey: legacyKnownFilterKeysKey)
        defaults.set(true, forKey: migrationCompleteKey)

        if migrated > 0 {
            logger.trace("Migrated \(migrated) per-table filter entries to file storage")
        }
    }
}
