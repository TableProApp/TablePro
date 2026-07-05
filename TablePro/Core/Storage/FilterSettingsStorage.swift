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
        panelState: FilterPanelDefaultState = .restoreLast
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
    private static let compositeKeyMigrationKey = "com.TablePro.filterStateCompositeKeyMigrationComplete"
    private static let settingsKey = "com.TablePro.filter.settings"

    private let defaults: UserDefaults

    private let filterStateDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let ioQueue = DispatchQueue(label: "com.TablePro.FilterSettingsStorage.io", qos: .utility)

    private var cachedSettings: FilterSettings?
    private var lastFiltersCache: [String: [TableFilter]] = [:]
    private var browseSearchCache: [String: BrowseSearchState] = [:]

    private convenience init() {
        self.init(filterStateDirectory: Self.resolvedFilterStateDirectory(), defaults: .standard)
    }

    init(filterStateDirectory: URL, defaults: UserDefaults) {
        self.filterStateDirectory = filterStateDirectory
        self.defaults = defaults

        do {
            try FileManager.default.createDirectory(
                at: filterStateDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create filter state directory: \(error.localizedDescription)")
        }

        Self.performMigrationIfNeeded(filterStateDirectory: filterStateDirectory, defaults: defaults)
        Self.performCompositeKeyMigrationIfNeeded(filterStateDirectory: filterStateDirectory, defaults: defaults)
    }

    func loadSettings() -> FilterSettings {
        if let cached = cachedSettings { return cached }

        guard let data = defaults.data(forKey: Self.settingsKey) else {
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
            defaults.set(data, forKey: Self.settingsKey)
        } catch {
            Self.logger.error("Failed to encode filter settings: \(error)")
        }
    }

    func loadLastFilters(
        for tableName: String,
        connectionId: UUID,
        databaseName: String,
        schemaName: String?
    ) -> [TableFilter] {
        let key = compositeKey(
            tableName: tableName,
            connectionId: connectionId,
            databaseName: databaseName,
            schemaName: schemaName
        )
        if let cached = lastFiltersCache[key] { return cached }

        let fileURL = fileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastFiltersCache[key] = []
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let filters = try decoder.decode([TableFilter].self, from: data)
            lastFiltersCache[key] = filters
            return filters
        } catch {
            Self.logger.error("Failed to load last filters for \(tableName): \(error)")
            lastFiltersCache[key] = []
            return []
        }
    }

    func saveLastFilters(
        _ filters: [TableFilter],
        for tableName: String,
        connectionId: UUID,
        databaseName: String,
        schemaName: String?
    ) {
        let key = compositeKey(
            tableName: tableName,
            connectionId: connectionId,
            databaseName: databaseName,
            schemaName: schemaName
        )
        let fileURL = fileURL(forKey: key)

        guard !filters.isEmpty else {
            lastFiltersCache.removeValue(forKey: key)
            ioQueue.async {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        lastFiltersCache[key] = filters
        do {
            let data = try encoder.encode(filters)
            ioQueue.async {
                do {
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    Self.logger.error("Failed to persist last filters for \(tableName): \(error.localizedDescription)")
                }
            }
        } catch {
            Self.logger.error("Failed to encode last filters for \(tableName): \(error)")
        }
    }

    func clearLastFilters(
        for tableName: String,
        connectionId: UUID,
        databaseName: String,
        schemaName: String?
    ) {
        let key = compositeKey(
            tableName: tableName,
            connectionId: connectionId,
            databaseName: databaseName,
            schemaName: schemaName
        )
        let fileURL = fileURL(forKey: key)
        lastFiltersCache.removeValue(forKey: key)
        ioQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func waitForPendingDiskWrites() {
        ioQueue.sync {}
    }

    func loadBrowseSearch(
        for tableName: String,
        connectionId: UUID,
        databaseName: String,
        schemaName: String?
    ) -> BrowseSearchState {
        let key = browseKey(
            tableName: tableName,
            connectionId: connectionId,
            databaseName: databaseName,
            schemaName: schemaName
        )
        if let cached = browseSearchCache[key] { return cached }

        let fileURL = fileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = BrowseSearchState()
            browseSearchCache[key] = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let state = try decoder.decode(BrowseSearchState.self, from: data)
            browseSearchCache[key] = state
            return state
        } catch {
            Self.logger.error("Failed to load browse search for \(tableName): \(error)")
            let empty = BrowseSearchState()
            browseSearchCache[key] = empty
            return empty
        }
    }

    func saveBrowseSearch(
        _ state: BrowseSearchState,
        for tableName: String,
        connectionId: UUID,
        databaseName: String,
        schemaName: String?
    ) {
        let key = browseKey(
            tableName: tableName,
            connectionId: connectionId,
            databaseName: databaseName,
            schemaName: schemaName
        )
        let fileURL = fileURL(forKey: key)

        guard state.isActive else {
            browseSearchCache.removeValue(forKey: key)
            ioQueue.async {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        do {
            let data = try encoder.encode(state)
            browseSearchCache[key] = state
            ioQueue.async {
                do {
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    Self.logger.error("Failed to persist browse search for \(tableName): \(error.localizedDescription)")
                }
            }
        } catch {
            Self.logger.error("Failed to encode browse search for \(tableName): \(error)")
        }
    }

    private func browseKey(
        tableName: String,
        connectionId: UUID,
        databaseName: String,
        schemaName: String?
    ) -> String {
        compositeKey(
            tableName: tableName,
            connectionId: connectionId,
            databaseName: databaseName,
            schemaName: schemaName
        ) + ".browse"
    }

    func removeFilters(for connectionId: UUID) {
        removeFilters(for: [connectionId])
    }

    func removeFilters(for connectionIds: Set<UUID>) {
        guard !connectionIds.isEmpty else { return }

        let encodedPrefixes = connectionIds.map { id in
            let idString = id.uuidString
            return (idString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? idString) + "."
        }
        let matchesConnection: (String) -> Bool = { name in
            encodedPrefixes.contains { name.hasPrefix($0) }
        }

        lastFiltersCache = lastFiltersCache.filter { !matchesConnection($0.key) }
        browseSearchCache = browseSearchCache.filter { !matchesConnection($0.key) }

        let directory = filterStateDirectory
        ioQueue.async {
            let fm = FileManager.default
            do {
                let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for file in files where encodedPrefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
                    try? fm.removeItem(at: file)
                }
            } catch {
                Self.logger.error("Failed to enumerate filter state directory: \(error.localizedDescription)")
            }
        }
    }

    func clearAllLastFilters() {
        lastFiltersCache.removeAll()
        browseSearchCache.removeAll()

        let directory = filterStateDirectory
        ioQueue.async {
            let fm = FileManager.default
            do {
                let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for file in files where file.pathExtension == "json" {
                    try? fm.removeItem(at: file)
                }
            } catch {
                Self.logger.error("Failed to enumerate filter state directory: \(error.localizedDescription)")
            }
        }
    }

    private func fileURL(forKey key: String) -> URL {
        filterStateDirectory.appendingPathComponent("\(key).json")
    }

    private func compositeKey(
        tableName: String,
        connectionId: UUID,
        databaseName: String,
        schemaName: String?
    ) -> String {
        [connectionId.uuidString, databaseName, schemaName ?? "", tableName]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            .joined(separator: ".")
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

    private static func performMigrationIfNeeded(filterStateDirectory: URL, defaults: UserDefaults) {
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

    private static func performCompositeKeyMigrationIfNeeded(filterStateDirectory: URL, defaults: UserDefaults) {
        guard !defaults.bool(forKey: compositeKeyMigrationKey) else { return }

        let fileManager = FileManager.default
        if let files = try? fileManager.contentsOfDirectory(
            at: filterStateDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                try? fileManager.removeItem(at: file)
            }
        }

        if let data = defaults.data(forKey: settingsKey),
           var settings = try? JSONDecoder().decode(FilterSettings.self, from: data),
           settings.panelState == .alwaysHide {
            settings.panelState = .restoreLast
            if let upgraded = try? JSONEncoder().encode(settings) {
                defaults.set(upgraded, forKey: settingsKey)
            }
        }

        defaults.set(true, forKey: compositeKeyMigrationKey)
    }
}
