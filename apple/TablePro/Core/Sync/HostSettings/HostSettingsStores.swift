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
        for category in AppSettingsCategory.synced where storage.holdsValue(forCategory: category) {
            documents[category] = try preferences(category)
        }
        if slashCommands.holdsValue {
            documents[CustomSlashCommandStorage.syncCategory] = try encoder.encode(slashCommands.commands)
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
            return storage.holdsValue(forCategory: category) ? try preferences(category) : nil
        case .slashCommands:
            return slashCommands.holdsValue ? try encoder.encode(slashCommands.commands) : nil
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
            guard let id = ThemeCatalog.themeId(forSyncCategory: category),
                  themes.removeWithoutSync(ids: [id])
            else { throw HostSettingsStoreError.unwritable(category) }
        case .preferences, .slashCommands, .unknown:
            return
        }
    }

    private func preferences(_ category: String) throws -> Data {
        switch category {
        case AppSettingsCategory.general: try encoder.encode(storage.loadGeneral())
        case AppSettingsCategory.appearance: try encoder.encode(storage.loadAppearance())
        case AppSettingsCategory.editor: try encoder.encode(storage.loadEditor())
        case AppSettingsCategory.dataGrid: try encoder.encode(storage.loadDataGrid())
        case AppSettingsCategory.history: try encoder.encode(storage.loadHistory())
        case AppSettingsCategory.tabs: try encoder.encode(storage.loadTabs())
        case AppSettingsCategory.keyboard: try encoder.encode(storage.loadKeyboard())
        case AppSettingsCategory.ai: try encoder.encode(storage.loadAI())
        case AppSettingsCategory.notifications: try encoder.encode(storage.loadNotifications())
        case AppSettingsCategory.formatter: try encoder.encode(storage.loadFormatter())
        case AppSettingsCategory.valueColors: try encoder.encode(storage.loadValueColors())
        default: throw HostSettingsStoreError.unreadable(category)
        }
    }

    // Through the manager, so a pulled category takes effect as a change made in Settings does.
    private func writePreferences(_ data: Data, _ category: String) throws {
        switch category {
        case AppSettingsCategory.general: manager.general = try decoder.decode(GeneralSettings.self, from: data)
        case AppSettingsCategory.appearance: manager.appearance = try decoder.decode(AppearanceSettings.self, from: data)
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
        default: throw HostSettingsStoreError.unreadable(category)
        }
    }
}
