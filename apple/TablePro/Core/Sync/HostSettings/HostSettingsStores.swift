//
//  HostSettingsStores.swift
//  TablePro
//

import Foundation
import os

// Where this Mac keeps each settings category the `macos_settings` kind carries (core ADR 0044, What syncs; 0051, What
// syncs): the eleven preference categories, the slash commands, each table's column layout and each user theme, as
// the JSON the Mac writes them in.
@MainActor
protocol HostSettingsStores: AnyObject {
    // Every category written on this Mac. One still at the app's defaults was never written, so it holds nothing to
    // send, and a Mac that never touched it never sends defaults over another Mac's choice.
    func documents() throws -> [String: Data]

    func document(for category: String) throws -> Data?

    func write(_ document: Data, for category: String) throws -> HostSettingsWrite

    // A theme or a column layout; the engine removes nothing else.
    func remove(_ category: String) throws
}

enum HostSettingsWrite: Equatable {
    case written
    // No store here names the category, or this build cannot read the document.
    case unreadable
}

enum HostSettingsStoreError: Error {
    case unreadable(String)
    case unwritable(String)
    case overBudget(String)
}

enum HostSettingsCategoryKind: Equatable {
    case preferences
    case slashCommands
    case columnLayout(storageKey: String)
    case theme
    case unknown

    init(_ category: String) {
        if AppSettingsCategory.synced.contains(category) {
            self = .preferences
        } else if category == CustomSlashCommandStorage.syncCategory {
            self = .slashCommands
        } else if category.hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix) {
            self = .columnLayout(
                storageKey: String(category.dropFirst(FileColumnLayoutPersister.syncCategoryPrefix.count))
            )
        } else if ThemeCatalog.themeId(forSyncCategory: category) != nil {
            self = .theme
        } else {
            self = .unknown
        }
    }

    var keptShape: HostSettingsKept.Shape {
        switch self {
        case .preferences, .columnLayout: .options
        case .slashCommands: .items
        case .theme, .unknown: .document
        }
    }
}

@MainActor
final class AppHostSettingsStores: HostSettingsStores {
    private static let logger = Logger(subsystem: "com.TablePro", category: "HostSettings")

    private let manager: AppSettingsManager
    private let storage: AppSettingsStorage
    private let slashCommands: CustomSlashCommandStorage
    private let columnLayouts: FileColumnLayoutPersister
    private let themes: ThemeCatalog
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private let decoder = JSONDecoder()

    init(
        manager: AppSettingsManager = .shared,
        storage: AppSettingsStorage = .shared,
        slashCommands: CustomSlashCommandStorage = .shared,
        columnLayouts: FileColumnLayoutPersister = .shared,
        themes: ThemeCatalog = .shared
    ) {
        self.manager = manager
        self.storage = storage
        self.slashCommands = slashCommands
        self.columnLayouts = columnLayouts
        self.themes = themes
    }

    func documents() throws -> [String: Data] {
        var documents: [String: Data] = [:]
        for category in AppSettingsCategory.synced {
            documents[category] = try preferences(category)
        }
        if let commands = try slashCommands.syncedCommands() {
            documents[CustomSlashCommandStorage.syncCategory] = try encoder.encode(commands)
        }
        for (storageKey, data) in try columnLayouts.syncedLayouts() {
            documents[FileColumnLayoutPersister.syncCategory(for: storageKey)] = data
        }
        documents.merge(try themes.syncPayloads()) { _, theme in theme }
        return documents
    }

    func document(for category: String) throws -> Data? {
        switch HostSettingsCategoryKind(category) {
        case .preferences:
            return try preferences(category)
        case .slashCommands:
            return try slashCommands.syncedCommands().map { try encoder.encode($0) }
        case .columnLayout(let storageKey):
            return try columnLayouts.syncedLayout(storageKey: storageKey)
        case .theme:
            return try themes.syncPayloads()[category]
        case .unknown:
            return nil
        }
    }

    func write(_ document: Data, for category: String) throws -> HostSettingsWrite {
        switch HostSettingsCategoryKind(category) {
        case .preferences:
            do {
                try writePreferences(document, category)
            } catch {
                Self.logger.error("A synced settings category did not decode: \(error.publicLogShape, privacy: .public)")
                return .unreadable
            }
            return .written
        case .slashCommands:
            guard let commands = try? decoder.decode([CustomSlashCommand].self, from: document) else {
                return .unreadable
            }
            // A name picks one command, and two Macs can each add one under a name before they sync.
            slashCommands.applyRemote(CustomSlashCommandStorage.renamingCollisions(commands))
            return .written
        case .columnLayout(let storageKey):
            return try columnLayouts.applyPulled(storageKey: storageKey, data: document) ? .written : .unreadable
        case .theme:
            guard themes.applyRemote(category: category, data: document, merge: .replace) != .failed else {
                throw HostSettingsStoreError.unwritable(category)
            }
            return .written
        case .unknown:
            return .unreadable
        }
    }

    func remove(_ category: String) throws {
        switch HostSettingsCategoryKind(category) {
        case .columnLayout(let storageKey):
            try columnLayouts.removePulled(storageKey: storageKey)
        case .theme:
            guard let id = ThemeCatalog.themeId(forSyncCategory: category) else { return }
            try themes.removePulled(id: id)
        case .preferences, .slashCommands, .unknown:
            return
        }
    }

    // Nil for a category never saved here. A saved one that no longer decodes throws: read as the defaults, it would go
    // up over every other Mac's choice.
    private func preferences(_ category: String) throws -> Data? {
        switch category {
        case AppSettingsCategory.general: try stored(GeneralSettings.self, category)
        case AppSettingsCategory.appearance: try stored(AppearanceSettings.self, category)
        case AppSettingsCategory.editor: try stored(EditorSettings.self, category)
        case AppSettingsCategory.dataGrid: try stored(DataGridSettings.self, category)
        case AppSettingsCategory.history: try stored(HistorySettings.self, category)
        case AppSettingsCategory.tabs: try stored(TabSettings.self, category)
        case AppSettingsCategory.keyboard: try stored(KeyboardSettings.self, category) { $0.sanitized() }
        case AppSettingsCategory.ai: try stored(AISettings.self, category)
        case AppSettingsCategory.notifications: try stored(NotificationSettings.self, category)
        case AppSettingsCategory.formatter: try stored(SQLFormatterSettings.self, category)
        case AppSettingsCategory.valueColors: try stored(ValueColorSettings.self, category)
        default: throw HostSettingsStoreError.unreadable(category)
        }
    }

    private func stored<Value: Codable>(
        _: Value.Type,
        _ category: String,
        _ normalized: (Value) -> Value = { $0 }
    ) throws -> Data? {
        guard let data = storage.storedData(forCategory: category) else { return nil }
        return try encoder.encode(normalized(try decoder.decode(Value.self, from: data)))
    }

    private func writePreferences(_ data: Data, _ category: String) throws {
        switch category {
        case AppSettingsCategory.general: try take(data, category, \.general)
        case AppSettingsCategory.appearance: try take(data, category, \.appearance)
        case AppSettingsCategory.editor: try take(data, category, \.editor)
        case AppSettingsCategory.dataGrid: try take(data, category, \.dataGrid)
        case AppSettingsCategory.history: try take(data, category, \.history)
        case AppSettingsCategory.tabs: try take(data, category, \.tabs)
        case AppSettingsCategory.keyboard: try take(data, category, \.keyboard)
        case AppSettingsCategory.ai: try take(data, category, \.ai)
        case AppSettingsCategory.notifications: try take(data, category, \.notifications)
        case AppSettingsCategory.formatter: try take(data, category, \.formatter)
        case AppSettingsCategory.valueColors: try take(data, category, \.valueColors)
        default: throw HostSettingsStoreError.unreadable(category)
        }
    }

    // Through the manager, so a pulled category takes effect as a change made in Settings does, then saved as the
    // manager holds it: the manager skips a value equal to what it has, and the category would stay unsaved.
    private func take<Value: Codable>(
        _ data: Data,
        _ category: String,
        _ setting: ReferenceWritableKeyPath<AppSettingsManager, Value>
    ) throws {
        manager[keyPath: setting] = try decoder.decode(Value.self, from: data)
        storage.store(manager[keyPath: setting], forCategory: category)
    }
}
