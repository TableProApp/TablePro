//
//  SharedSidebarState.swift
//  TablePro
//
//  Connection-scoped sidebar state shared across all windows of the same
//  connection. Window-scoped state (table selection) lives in
//  `WindowSidebarState`.
//

import Foundation

/// Which sidebar tab is active
internal enum SidebarTab: String, CaseIterable {
    case tables
    case favorites
}

internal enum SidebarLayout: String, CaseIterable, Sendable {
    case flat
    case tree
}

@MainActor @Observable
final class SharedSidebarState {
    var redisKeyTreeViewModel: RedisKeyTreeViewModel?

    var searchText: String = ""
    var favoritesSearchText: String = ""

    var recentTables: [RecentTableEntry] = []

    @ObservationIgnored private var pendingRecordTask: Task<Void, Never>?

    func recentEntries(inDatabase database: String?) -> [RecentTableEntry] {
        recentTables.filter { $0.database == normalizedDatabase(database) }
    }

    func recordTableOpen(database: String?, schema: String?, name: String, isView: Bool, isPreview: Bool) {
        guard isPreview else {
            pendingRecordTask?.cancel()
            pendingRecordTask = nil
            commitTableOpen(database: database, schema: schema, name: name, isView: isView)
            return
        }
        pendingRecordTask?.cancel()
        pendingRecordTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.commitTableOpen(database: database, schema: schema, name: name, isView: isView)
        }
    }

    private func commitTableOpen(database: String?, schema: String?, name: String, isView: Bool) {
        QuickSwitcherFrecencyStore(connectionId: connectionId).recordAccess(
            itemId: QuickSwitcherItem.tableItemId(name: name, isView: isView)
        )
        guard AppSettingsManager.shared.general.showRecentTables else { return }
        recentTables = RecentTablesStore.shared.record(
            connectionId: connectionId, database: normalizedDatabase(database),
            schema: schema, name: name, isView: isView
        )
    }

    func removeRecentTable(database: String?, schema: String?, name: String) {
        let entry = RecentTableEntry(
            database: normalizedDatabase(database), schema: schema, name: name, isView: false, openedAt: Date()
        )
        recentTables = RecentTablesStore.shared.remove(connectionId: connectionId, entry: entry)
    }

    func clearRecentTables(inDatabase database: String?) {
        recentTables = RecentTablesStore.shared.clear(
            connectionId: connectionId, database: normalizedDatabase(database)
        )
    }

    func reloadRecentTablesFromStore() {
        recentTables = AppSettingsManager.shared.general.showRecentTables
            ? RecentTablesStore.shared.entries(connectionId: connectionId)
            : []
    }

    private func normalizedDatabase(_ database: String?) -> String? {
        guard let database, !database.isEmpty else { return nil }
        return database
    }

    var selectedSidebarTab: SidebarTab {
        didSet {
            UserDefaults.standard.set(
                selectedSidebarTab.rawValue,
                forKey: SidebarPersistenceKey.selectedTab(connectionId: connectionId)
            )
        }
    }

    var sidebarLayout: SidebarLayout {
        didSet {
            UserDefaults.standard.set(
                sidebarLayout.rawValue,
                forKey: SidebarPersistenceKey.layout(connectionId: connectionId)
            )
        }
    }

    var databaseFilterSelected: Set<String> {
        didSet {
            DatabaseTreeFilterStorage.shared.setSelectedDatabases(
                databaseFilterSelected,
                connectionId: connectionId
            )
        }
    }

    var selectedFavorite: FavoriteSelection? {
        didSet {
            guard oldValue != selectedFavorite else { return }
            let key = SidebarPersistenceKey.selectedFavorite(connectionId: connectionId)
            if let rawValue = selectedFavorite?.rawValue {
                UserDefaults.standard.set(rawValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static var defaultLayout: SidebarLayout {
        get {
            guard let raw = UserDefaults.standard.string(forKey: SidebarPersistenceKey.defaultLayout),
                  let layout = SidebarLayout(rawValue: raw) else {
                return .flat
            }
            return layout
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: SidebarPersistenceKey.defaultLayout)
        }
    }

    let connectionId: UUID

    private init(connectionId: UUID) {
        self.connectionId = connectionId
        let key = SidebarPersistenceKey.selectedTab(connectionId: connectionId)
        if let raw = UserDefaults.standard.string(forKey: key),
           let tab = SidebarTab(rawValue: raw) {
            self.selectedSidebarTab = tab
        } else {
            self.selectedSidebarTab = .tables
        }
        let layoutKey = SidebarPersistenceKey.layout(connectionId: connectionId)
        if let raw = UserDefaults.standard.string(forKey: layoutKey),
           let layout = SidebarLayout(rawValue: raw) {
            self.sidebarLayout = layout
        } else {
            self.sidebarLayout = SharedSidebarState.defaultLayout
        }
        self.databaseFilterSelected = DatabaseTreeFilterStorage.shared.selectedDatabases(connectionId: connectionId)
        self.selectedFavorite = UserDefaults.standard.string(
            forKey: SidebarPersistenceKey.selectedFavorite(connectionId: connectionId)
        ).flatMap(FavoriteSelection.init(rawValue:))
        if AppSettingsManager.shared.general.showRecentTables {
            self.recentTables = RecentTablesStore.shared.entries(connectionId: connectionId)
        }
    }

    /// Default init for previews and tests
    init() {
        self.connectionId = UUID()
        self.selectedSidebarTab = .tables
        self.sidebarLayout = .flat
        self.databaseFilterSelected = []
        self.selectedFavorite = nil
    }

    deinit {
        pendingRecordTask?.cancel()
    }

    private static var registry: [UUID: SharedSidebarState] = [:]

    static func forConnection(_ id: UUID) -> SharedSidebarState {
        if let existing = registry[id] { return existing }
        let state = SharedSidebarState(connectionId: id)
        registry[id] = state
        return state
    }

    static func removeConnection(_ id: UUID) {
        registry.removeValue(forKey: id)
    }
}
