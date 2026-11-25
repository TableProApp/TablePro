import Combine
import Foundation
import TableProUtilities

internal enum SidebarTab: String, CaseIterable {
    case tables
    case favorites
}

internal enum SidebarLayout: String, CaseIterable, Sendable {
    case flat
    case tree

    static let fallback: SidebarLayout = .flat
}

// Shared by every window of one connection; window-scoped state lives in WindowSidebarState.
@MainActor
final class SharedSidebarState: ObservableObject {
    @Published var redisKeyTreeViewModel: RedisKeyTreeViewModel?

    @Published var searchText: String = ""
    @Published var favoritesSearchText: String = ""
    @Published var isFilterFieldFocused = false

    @Published var recentTables: [RecentTableEntry] = []

    private var pendingRecordTask: Task<Void, Never>?

    func recentEntries(inDatabase database: String?) -> [RecentTableEntry] {
        recentTables.filter { $0.database == normalizedDatabase(database) }
    }

    // isView stays beside objectType for callers that know only that much, and is what an older build reads.
    func recordTableOpen(
        database: String?,
        schema: String?,
        name: String,
        isView: Bool,
        objectType: TableInfo.TableType?,
        isPreview: Bool,
        connectionSwitchesDatabases: Bool
    ) {
        let frecencyKey = Self.tableFrecencyKey(
            database: database, schema: schema, name: name,
            connectionSwitchesDatabases: connectionSwitchesDatabases
        )
        guard isPreview else {
            pendingRecordTask?.cancel()
            pendingRecordTask = nil
            commitTableOpen(
                database: database, schema: schema, name: name,
                isView: isView, objectType: objectType, frecencyKey: frecencyKey
            )
            return
        }
        pendingRecordTask?.cancel()
        pendingRecordTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.commitTableOpen(
                database: database, schema: schema, name: name,
                isView: isView, objectType: objectType, frecencyKey: frecencyKey
            )
        }
    }

    nonisolated static func tableFrecencyKey(
        database: String?,
        schema: String?,
        name: String,
        connectionSwitchesDatabases: Bool
    ) -> String {
        QuickSwitcherFrecencyKey.table(
            name: name,
            schema: schema,
            in: QuickSwitcherFrecencyKey.DatabaseQualifier(
                database: database,
                connectionSwitchesDatabases: connectionSwitchesDatabases
            )
        )
    }

    private func commitTableOpen(
        database: String?,
        schema: String?,
        name: String,
        isView: Bool,
        objectType: TableInfo.TableType?,
        frecencyKey: String
    ) {
        QuickSwitcherFrecencyStore(connectionId: connectionId, defaults: AppStorageEnvironment.shared.defaults)
            .recordAccess(itemId: frecencyKey)
        guard AppSettingsManager.shared.general.showRecentTables else { return }
        recentTables = RecentTablesStore.shared.record(
            connectionId: connectionId, database: normalizedDatabase(database),
            schema: schema, name: name, isView: isView, objectType: objectType
        )
    }

    // Matches on the id (database, schema, name), so the kind recorded with the entry is not part of the lookup.
    func removeRecentTable(database: String?, schema: String?, name: String) {
        let entry = RecentTableEntry(
            database: normalizedDatabase(database), schema: schema, name: name,
            isView: false, objectType: nil, openedAt: Date()
        )
        recentTables = RecentTablesStore.shared.remove(connectionId: connectionId, entry: entry)
    }

    // Asks the store, not the live list: that list is empty while Show Recent Tables is off, and the entry is still on disk.
    func renameRecentTable(database: String?, schema: String?, from oldName: String, to newName: String) {
        let scope = normalizedDatabase(database)
        let existing = RecentTablesStore.shared.entries(connectionId: connectionId).first {
            $0.database == scope && $0.schema == schema && $0.name == oldName
        }
        guard let existing else { return }
        publish(RecentTablesStore.shared.rename(connectionId: connectionId, entry: existing, to: newName))
    }

    // Entries are keyed by the container's name, so each one has to follow the rename.
    func renameRecentDatabase(from oldName: String, to newName: String) {
        publish(RecentTablesStore.shared.renameDatabase(
            connectionId: connectionId, from: oldName, to: newName
        ))
    }

    func renameRecentSchema(database: String?, from oldName: String, to newName: String) {
        publish(RecentTablesStore.shared.renameSchema(
            connectionId: connectionId, database: normalizedDatabase(database), from: oldName, to: newName
        ))
    }

    // An entry recorded before the session knew its schema would open the name in whichever schema is browsed.
    func resolveRecentSchema(database: String?, name: String, to schema: String) {
        publish(RecentTablesStore.shared.resolveSchema(
            connectionId: connectionId, database: normalizedDatabase(database), name: name, to: schema
        ))
    }

    private func publish(_ entries: [RecentTableEntry]) {
        guard AppSettingsManager.shared.general.showRecentTables else { return }
        recentTables = entries
    }

    func clearRecentTables(inDatabase database: String?) {
        recentTables = RecentTablesStore.shared.clear(
            connectionId: connectionId, database: normalizedDatabase(database)
        )
    }

    func clearRecentTables(inDatabase database: String?, schema: String) {
        recentTables = RecentTablesStore.shared.clear(
            connectionId: connectionId, database: normalizedDatabase(database), schema: schema
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

    @Published var selectedSidebarTab: SidebarTab {
        didSet {
            AppStorageEnvironment.shared.defaults.set(
                selectedSidebarTab.rawValue,
                forKey: SidebarPersistenceKey.selectedTab(connectionId: connectionId)
            )
        }
    }

    @Published var sidebarLayout: SidebarLayout {
        didSet {
            AppStorageEnvironment.shared.defaults.set(
                sidebarLayout.rawValue,
                forKey: SidebarPersistenceKey.layout(connectionId: connectionId)
            )
        }
    }

    @Published var databaseFilterSelected: Set<String> {
        didSet {
            DatabaseTreeFilterStorage.shared.setSelectedDatabases(
                databaseFilterSelected,
                connectionId: connectionId
            )
        }
    }

    // Keyed by database name, "" without one. Written only through the methods below, which keep the stored copy in step.
    @Published private(set) var schemaFilterSelected: [String: Set<String>]

    func schemaFilter(for database: String?) -> Set<String> {
        schemaFilterSelected[Self.schemaFilterKey(database)] ?? []
    }

    func setSchemaFilter(_ schemas: Set<String>, for database: String?) {
        let key = Self.schemaFilterKey(database)
        guard schemaFilter(for: key) != schemas else { return }
        var selection = schemaFilterSelected
        selection[key] = schemas.isEmpty ? nil : schemas
        schemaFilterSelected = selection
        DatabaseTreeFilterStorage.shared.setSelectedSchemas(schemas, database: key, connectionId: connectionId)
    }

    func moveSchemaFilter(fromDatabase oldName: String, toDatabase newName: String) {
        let moved = schemaFilter(for: oldName)
        guard !moved.isEmpty, oldName != newName else { return }
        setSchemaFilter([], for: oldName)
        setSchemaFilter(schemaFilter(for: newName).union(moved), for: newName)
    }

    func renameSchemaInFilter(database: String?, from oldName: String, to newName: String) {
        var selected = schemaFilter(for: database)
        guard selected.remove(oldName) != nil else { return }
        selected.insert(newName)
        setSchemaFilter(selected, for: database)
    }

    // An empty selection is no filter, which is the list the user saw before picking the dropped schema.
    func removeSchemaFromFilter(database: String?, schema: String) {
        var selected = schemaFilter(for: database)
        guard selected.remove(schema) != nil else { return }
        setSchemaFilter(selected, for: database)
    }

    func filterSelection(for target: SidebarFilterTarget) -> Set<String> {
        switch target {
        case .databases: return databaseFilterSelected
        case .schemas(let database): return schemaFilter(for: database)
        }
    }

    func setFilterSelection(_ selection: Set<String>, for target: SidebarFilterTarget) {
        switch target {
        case .databases: databaseFilterSelected = selection
        case .schemas(let database): setSchemaFilter(selection, for: database)
        }
    }

    private static func schemaFilterKey(_ database: String?) -> String {
        database ?? ""
    }

    @Published var favoriteDatabaseEnvironmentFilter: FavoriteDatabaseEnvironmentFilter {
        didSet {
            AppStorageEnvironment.shared.defaults.set(
                favoriteDatabaseEnvironmentFilter.rawValue,
                forKey: SidebarPersistenceKey.favoriteDatabaseEnvironmentFilter(connectionId: connectionId)
            )
        }
    }

    @Published var selectedFavorite: FavoriteSelection? {
        didSet {
            guard oldValue != selectedFavorite else { return }
            let key = SidebarPersistenceKey.selectedFavorite(connectionId: connectionId)
            if let rawValue = selectedFavorite?.rawValue {
                AppStorageEnvironment.shared.defaults.set(rawValue, forKey: key)
            } else {
                AppStorageEnvironment.shared.defaults.removeObject(forKey: key)
            }
        }
    }

    static var defaultLayout: SidebarLayout {
        get {
            guard let raw = AppStorageEnvironment.shared.defaults.string(forKey: SidebarPersistenceKey.defaultLayout),
                  let layout = SidebarLayout(rawValue: raw) else {
                return .fallback
            }
            return layout
        }
        set {
            AppStorageEnvironment.shared.defaults.set(newValue.rawValue, forKey: SidebarPersistenceKey.defaultLayout)
        }
    }

    let connectionId: UUID

    private init(connectionId: UUID) {
        self.connectionId = connectionId
        let key = SidebarPersistenceKey.selectedTab(connectionId: connectionId)
        if let raw = AppStorageEnvironment.shared.defaults.string(forKey: key),
           let tab = SidebarTab(rawValue: raw) {
            self.selectedSidebarTab = tab
        } else {
            self.selectedSidebarTab = .tables
        }
        let layoutKey = SidebarPersistenceKey.layout(connectionId: connectionId)
        if let raw = AppStorageEnvironment.shared.defaults.string(forKey: layoutKey),
           let layout = SidebarLayout(rawValue: raw) {
            self.sidebarLayout = layout
        } else {
            self.sidebarLayout = SharedSidebarState.defaultLayout
        }
        self.databaseFilterSelected = DatabaseTreeFilterStorage.shared.selectedDatabases(connectionId: connectionId)
        self.schemaFilterSelected = DatabaseTreeFilterStorage.shared.allSelectedSchemas(connectionId: connectionId)
        let environmentFilterKey = SidebarPersistenceKey.favoriteDatabaseEnvironmentFilter(connectionId: connectionId)
        self.favoriteDatabaseEnvironmentFilter = AppStorageEnvironment.shared.defaults
            .string(forKey: environmentFilterKey)
            .flatMap(FavoriteDatabaseEnvironmentFilter.init(rawValue:)) ?? .all
        self.selectedFavorite = AppStorageEnvironment.shared.defaults.string(
            forKey: SidebarPersistenceKey.selectedFavorite(connectionId: connectionId)
        ).flatMap(FavoriteSelection.init(rawValue:))
        if AppSettingsManager.shared.general.showRecentTables {
            self.recentTables = RecentTablesStore.shared.entries(connectionId: connectionId)
        }
    }

    init() {
        self.connectionId = UUID()
        self.selectedSidebarTab = .tables
        self.sidebarLayout = .fallback
        self.databaseFilterSelected = []
        self.schemaFilterSelected = [:]
        self.favoriteDatabaseEnvironmentFilter = .all
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
