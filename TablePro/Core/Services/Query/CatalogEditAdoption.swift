//
//  CatalogEditAdoption.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The browse database's catalog as loaded, and the questions a stale reference asks of it.
struct LoadedBrowseCatalog: Sendable, Equatable {
    let database: String
    let schemas: Set<String>
    let tables: [TableInfo]

    /// A reference is judged only when the loaded catalog covers the place it points at: the browse
    /// database, and a schema this catalog holds. One queued in another database or an unloaded
    /// schema is left alone, because this list cannot say whether its object still exists.
    func staleRefs(in refs: Set<DatabaseTreeTableRef>) -> Set<DatabaseTreeTableRef> {
        refs.filter { ref in
            guard (ref.database ?? database) == database else { return false }
            let schema = ref.qualifyingSchema
            if let schema, !covers(schema: schema) { return false }
            return !tables.contains { table in
                guard table.name == ref.table.name else { return false }
                guard let schema, let tableSchema = table.schema?.nilIfEmpty else { return true }
                return tableSchema == schema
            }
        }
    }

    private func covers(schema: String) -> Bool {
        schemas.contains(schema) || tables.contains { $0.schema?.nilIfEmpty == schema }
    }
}

/// Moves the state a connection keeps about its objects onto what the catalog now holds.
///
/// Everything here belongs to the connection rather than to a window: the Truncate and Drop queues
/// live on the session, and favorites, recents, per-table settings and the database filter are keyed
/// by connection. It runs once per change, however many windows show the connection.
@MainActor
struct CatalogEditAdoption {
    private let databaseManager: DatabaseManager
    private let schemaService: SchemaService
    private let connectionStorage: ConnectionStorage
    private let appSettings: AppSettingsStorage
    private let settingsStores: [any TableScopedSettingsStore]
    private let favoriteTables: FavoriteTablesStorage
    private let favoriteDatabases: FavoriteDatabasesStorage

    init(
        databaseManager: DatabaseManager = .shared,
        schemaService: SchemaService = .shared,
        connectionStorage: ConnectionStorage = .shared,
        appSettings: AppSettingsStorage = .shared,
        settingsStores: [any TableScopedSettingsStore]? = nil,
        favoriteTables: FavoriteTablesStorage = .shared,
        favoriteDatabases: FavoriteDatabasesStorage = .shared
    ) {
        self.databaseManager = databaseManager
        self.schemaService = schemaService
        self.connectionStorage = connectionStorage
        self.appSettings = appSettings
        self.settingsStores = settingsStores ?? TableScopedSettingsRegistry.stores
        self.favoriteTables = favoriteTables
        self.favoriteDatabases = favoriteDatabases
    }

    /// Where the object lives. A reference without a database means the one being browsed, and the
    /// schema resolves the way a tab stores it.
    func objectScope(for ref: DatabaseTreeTableRef, connectionId: UUID) -> DatabaseScope? {
        containerScope(database: ref.database, schema: ref.qualifyingSchema, connectionId: connectionId)
    }

    /// The same resolution for a database or schema the sidebar names, so a folder made on a
    /// section and a table filed into it land in one scope.
    func containerScope(database: String?, schema: String?, connectionId: UUID) -> DatabaseScope? {
        guard let session = databaseManager.session(for: connectionId) else { return nil }
        let database = database ?? databaseManager.browseDatabaseName(for: session.connection)
        return DatabaseScope(
            connectionId: connectionId,
            database: database,
            schema: databaseManager.resolvedSchemaName(schema, inDatabase: database, for: connectionId)
        )
    }

    /// A dropped table takes its saved settings with it, the way a renamed one takes them along.
    /// Left behind, they outlive the table and come back on a table that is recreated with the same
    /// name: a filter on a column the new table does not have opens the tab on a server error.
    func adoptDroppedTables(_ refs: [DatabaseTreeTableRef], connectionId: UUID) {
        let dropped = Set(refs.compactMap { tableScope(for: $0, connectionId: connectionId) })
        updatePendingOperations(connectionId: connectionId) { ref in
            guard let identity = tableScope(for: ref, connectionId: connectionId),
                  dropped.contains(identity) else { return ref }
            return nil
        }
        let droppedFavorites = Set(refs.map { favoriteEntry(for: $0, connectionId: connectionId) })
        favoriteTables.retarget(connectionId: connectionId) { droppedFavorites.contains($0) ? nil : $0 }
        let sidebarState = SharedSidebarState.forConnection(connectionId)
        for ref in refs {
            sidebarState.removeRecentTable(database: ref.database, schema: ref.schema, name: ref.table.name)
            guard let droppedScope = tableScope(for: ref, connectionId: connectionId) else { continue }
            for store in settingsStores {
                store.dropTable(droppedScope)
            }
        }
    }

    /// A queued Truncate or Drop against the old name would either miss or, once a new table takes
    /// that name, reach the wrong object. It is dropped rather than moved, because the confirmation
    /// the user gave named the object they were looking at.
    func adoptTableRename(_ ref: DatabaseTreeTableRef, to newName: String, connectionId: UUID) {
        guard let oldScope = tableScope(for: ref, connectionId: connectionId) else { return }
        let newScope = TableScope(
            connectionId: connectionId, database: oldScope.database, schema: oldScope.schema, table: newName
        )
        for store in settingsStores {
            store.renameTable(from: oldScope, to: newScope)
        }
        let oldFavorite = favoriteEntry(for: ref, connectionId: connectionId)
        let newFavorite = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId, database: ref.database, schema: ref.favoriteSchema, name: newName
        )
        favoriteTables.retarget(connectionId: connectionId) { $0 == oldFavorite ? newFavorite : $0 }
        SharedSidebarState.forConnection(connectionId).renameRecentTable(
            database: ref.database, schema: ref.schema, from: ref.table.name, to: newName
        )
        updatePendingOperations(connectionId: connectionId) { queued in
            tableScope(for: queued, connectionId: connectionId) == oldScope ? nil : queued
        }
    }

    /// The object a reference names, which is what a queued operation and the saved settings are
    /// matched on. Two references to one table can differ in how their `TableInfo` spells its
    /// schema, and a table named by SQL carries no row the sidebar built at all.
    private func tableScope(for ref: DatabaseTreeTableRef, connectionId: UUID) -> TableScope? {
        guard let scope = objectScope(for: ref, connectionId: connectionId) else { return nil }
        return TableScope(connectionId: connectionId, database: scope.database, schema: scope.schema, table: ref.table.name)
    }

    /// A table a statement named, as a reference spelled the way the sidebar spells its row, so
    /// the favorite and the Recent entry it keys are the ones found. The sidebar takes a favorite's
    /// schema from the driver's listing, which Oracle, MySQL and SQLite leave empty, so an entry
    /// already saved without one is matched in that spelling.
    func tableRef(for table: TablePlacement, kind: TableInfo.TableType, connectionId: UUID) -> DatabaseTreeTableRef {
        let saved = favoriteTables.favorites(for: connectionId).filter {
            $0.name == table.name && $0.database == table.database.nilIfEmpty
        }
        let listsWithoutSchema = !saved.contains { $0.schema == table.schema } && saved.contains { $0.schema == nil }
        return DatabaseTreeTableRef(
            database: table.database,
            schema: table.schema,
            table: TableInfo(
                name: table.name, type: kind, rowCount: nil, schema: listsWithoutSchema ? nil : table.schema
            )
        )
    }

    func adoptContainerRename(_ container: DatabaseContainerRef, to newName: String, connectionId: UUID) {
        guard let session = databaseManager.session(for: connectionId) else { return }
        switch container.kind {
        case .database:
            guard let oldDatabase = container.database else { return }
            retargetContainer(
                database: oldDatabase, schema: nil, toDatabase: newName, toSchema: nil, connectionId: connectionId
            )
            SharedSidebarState.forConnection(connectionId).renameRecentDatabase(from: oldDatabase, to: newName)
            favoriteDatabases.rename(database: oldDatabase, to: newName, connectionId: connectionId)
            retargetDatabaseFilter(from: oldDatabase, to: newName, connectionId: connectionId)
            retargetSavedConnectionDatabase(from: oldDatabase, to: newName, connectionId: connectionId)
            retargetBrowseCursor(session.connection, from: oldDatabase, to: newName)
        case .schema:
            guard let oldSchema = container.schema else { return }
            let database = container.database ?? databaseManager.browseDatabaseName(for: session.connection)
            retargetContainer(
                database: database, schema: oldSchema, toDatabase: database, toSchema: newName, connectionId: connectionId
            )
            SharedSidebarState.forConnection(connectionId).renameRecentSchema(
                database: database, from: oldSchema, to: newName
            )
        }
    }

    /// A queued operation inside a dropped container can only fail at Save, and Recent entries and a
    /// filter selection for a dropped database point at nothing.
    func adoptContainerDrop(_ container: DatabaseContainerRef, connectionId: UUID) {
        guard let session = databaseManager.session(for: connectionId) else { return }
        let browseDatabase = databaseManager.browseDatabaseName(for: session.connection)
        let database = container.database ?? browseDatabase
        let schema = container.kind == .schema ? container.schema : nil
        updatePendingOperations(connectionId: connectionId) { ref in
            guard (ref.database ?? browseDatabase) == database else { return ref }
            if let schema, ref.qualifyingSchema != schema { return ref }
            return nil
        }
        /// Every table inside the container loses its saved settings and its favorite, for the
        /// reason a dropped table does. Swept by prefix rather than by table, because the table
        /// list is lazy and a table nobody opened this session still has settings on disk.
        for store in settingsStores {
            store.dropContainer(connectionId: connectionId, database: database, schema: schema)
        }
        favoriteTables.removeFavorites(inDatabase: database, schema: schema, connectionId: connectionId)

        let sidebarState = SharedSidebarState.forConnection(connectionId)
        /// A dropped schema takes its own Recent entries with it and leaves its siblings alone.
        /// Skipping this left every Recent row for that schema opening a tab whose query failed
        /// with "relation does not exist", and the entries outlived a reconnect and a restart
        /// because they persist per connection in UserDefaults.
        if let schema {
            sidebarState.clearRecentTables(inDatabase: database, schema: schema)
            return
        }
        guard container.kind == .database else { return }
        favoriteDatabases.removeFavorite(database: database, connectionId: connectionId)
        clearSavedConnectionDatabase(named: database, connectionId: connectionId)
        sidebarState.clearRecentTables(inDatabase: database)
        var selected = sidebarState.databaseFilterSelected
        guard selected.remove(database) != nil else { return }
        sidebarState.databaseFilterSelected = selected
    }

    func loadedBrowseCatalog(connectionId: UUID) -> LoadedBrowseCatalog? {
        guard let session = databaseManager.session(for: connectionId),
              case .loaded = schemaService.state(for: connectionId),
              let loadedScope = schemaService.loadedScope(for: connectionId) else { return nil }
        let browseDatabase = databaseManager.browseDatabaseName(for: session.connection)
        guard loadedScope.database == browseDatabase else { return nil }
        var schemas = schemaService.schemasWithCurrentTables(for: connectionId)
        if let schema = loadedScope.schema, holdsBrowsedSchemaInFlatList(session.connection.type) {
            schemas.insert(schema)
        }
        return LoadedBrowseCatalog(
            database: browseDatabase,
            schemas: schemas,
            tables: schemaService.currentTables(for: connectionId)
        )
    }

    /// A schema-grouped engine's flat list is the browsed schema's, so that schema is answered for
    /// even when it holds nothing. A hierarchical engine's flat list is empty, and its browsed schema
    /// is answered for only by a per-schema list read since the last catalog change.
    private func holdsBrowsedSchemaInFlatList(_ type: DatabaseType) -> Bool {
        PluginManager.shared.databaseGroupingStrategy(for: type) != .hierarchicalSchema
    }

    /// Unstages queued operations whose object the freshly loaded catalog no longer has, judged by
    /// the object each one names rather than by a bare table name.
    func pruneStaleOperations(connectionId: UUID) {
        guard let session = databaseManager.session(for: connectionId),
              let catalog = loadedBrowseCatalog(connectionId: connectionId) else { return }
        let stale = catalog.staleRefs(in: session.pendingTruncates.union(session.pendingDeletes))
        guard !stale.isEmpty else { return }
        updatePendingOperations(connectionId: connectionId) { stale.contains($0) ? nil : $0 }
    }

    private func updatePendingOperations(
        connectionId: UUID,
        _ transform: (DatabaseTreeTableRef) -> DatabaseTreeTableRef?
    ) {
        guard let session = databaseManager.session(for: connectionId) else { return }
        let truncates = Set(session.pendingTruncates.compactMap(transform))
        let deletes = Set(session.pendingDeletes.compactMap(transform))
        var options: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        for (ref, value) in session.tableOperationOptions {
            guard let moved = transform(ref) else { continue }
            options[moved] = value
        }
        guard truncates != session.pendingTruncates
            || deletes != session.pendingDeletes
            || Set(options.keys) != Set(session.tableOperationOptions.keys)
        else { return }
        databaseManager.updateSession(connectionId) { session in
            session.pendingTruncates = truncates
            session.pendingDeletes = deletes
            session.tableOperationOptions = options
        }
    }

    private func favoriteEntry(
        for ref: DatabaseTreeTableRef,
        connectionId: UUID
    ) -> FavoriteTablesStorage.FavoriteEntry {
        FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId, database: ref.database, schema: ref.favoriteSchema, name: ref.table.name
        )
    }

    private func retargetContainer(
        database: String,
        schema: String?,
        toDatabase: String,
        toSchema: String?,
        connectionId: UUID
    ) {
        updatePendingOperations(connectionId: connectionId) { ref in
            guard ref.database == database else { return ref }
            if let schema, ref.qualifyingSchema != schema { return ref }
            return DatabaseTreeTableRef(
                database: toDatabase,
                schema: schema == nil ? ref.schema : toSchema,
                table: ref.table
            )
        }
        for store in settingsStores {
            store.renameContainer(
                connectionId: connectionId, fromDatabase: database, fromSchema: schema,
                toDatabase: toDatabase, toSchema: toSchema
            )
        }
        favoriteTables.retarget(connectionId: connectionId) { entry in
            guard entry.database == database else { return entry }
            if let schema, entry.schema != schema { return entry }
            return FavoriteTablesStorage.FavoriteEntry(
                connectionId: connectionId,
                database: toDatabase,
                schema: schema == nil ? entry.schema : toSchema,
                name: entry.name
            )
        }
    }

    private func retargetDatabaseFilter(from oldName: String, to newName: String, connectionId: UUID) {
        let state = SharedSidebarState.forConnection(connectionId)
        var selected = state.databaseFilterSelected
        guard selected.remove(oldName) != nil else { return }
        selected.insert(newName)
        state.databaseFilterSelected = selected
    }

    /// The saved default is what a reconnect and Reopen Last Session both use, so a database renamed
    /// out from under it leaves the connection opening onto nothing.
    internal func retargetSavedConnectionDatabase(from oldName: String, to newName: String, connectionId: UUID) {
        guard var saved = connectionStorage.loadConnections().first(where: { $0.id == connectionId }),
              saved.database == oldName else { return }
        saved.database = newName
        connectionStorage.updateConnection(saved)
    }

    /// A rename has a new name to point the saved default at. A drop has none, so it is emptied,
    /// along with the last database the session remembered.
    ///
    /// Both, because `selectDatabaseFromLastSession` fires precisely when the saved default is
    /// empty: emptying one and leaving the other would turn that action on and point it at the
    /// database that was just dropped, so every later connect would try to switch to it and fail.
    ///
    /// Not for a type that requires a value. Emptying is the repair for an engine that accepts a
    /// blank database, which is what the form already allows there, and MySQL connects with no
    /// default while MongoDB picks one. A type whose form refuses to save without a value would be
    /// left failing its own validation with nothing on screen saying why.
    internal func clearSavedConnectionDatabase(named database: String, connectionId: UUID) {
        guard var saved = connectionStorage.loadConnections().first(where: { $0.id == connectionId }),
              saved.database == database,
              !ConnectionDatabaseRequirement.requiresValue(for: saved.type) else { return }
        saved.database = ""
        connectionStorage.updateConnection(saved)
        appSettings.saveLastDatabase(nil, for: connectionId)
    }

    private func retargetBrowseCursor(_ connection: DatabaseConnection, from oldName: String, to newName: String) {
        guard databaseManager.browseDatabaseName(for: connection) == oldName,
              let coordinator = WindowManager.shared.coordinators(for: connection.id).first else { return }
        Task { await coordinator.switchContainers(database: newName, schema: nil) }
    }
}
