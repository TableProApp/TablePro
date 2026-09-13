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

    init(databaseManager: DatabaseManager = .shared, schemaService: SchemaService = .shared) {
        self.databaseManager = databaseManager
        self.schemaService = schemaService
    }

    /// Where the object lives. A reference without a database means the one being browsed, and the
    /// schema resolves the way a tab stores it.
    func objectScope(for ref: DatabaseTreeTableRef, connectionId: UUID) -> DatabaseScope? {
        guard let session = databaseManager.session(for: connectionId) else { return nil }
        let database = ref.database ?? databaseManager.browseDatabaseName(for: session.connection)
        return DatabaseScope(
            connectionId: connectionId,
            database: database,
            schema: databaseManager.resolvedSchemaName(ref.qualifyingSchema, inDatabase: database, for: connectionId)
        )
    }

    func adoptDroppedTables(_ refs: [DatabaseTreeTableRef], connectionId: UUID) {
        let dropped = Set(refs)
        updatePendingOperations(connectionId: connectionId) { dropped.contains($0) ? nil : $0 }
        let sidebarState = SharedSidebarState.forConnection(connectionId)
        for ref in refs {
            sidebarState.removeRecentTable(database: ref.database, schema: ref.schema, name: ref.table.name)
        }
    }

    /// A queued Truncate or Drop against the old name would either miss or, once a new table takes
    /// that name, reach the wrong object. It is dropped rather than moved, because the confirmation
    /// the user gave named the object they were looking at.
    func adoptTableRename(_ ref: DatabaseTreeTableRef, to newName: String, connectionId: UUID) {
        guard let scope = objectScope(for: ref, connectionId: connectionId) else { return }
        let oldScope = TableScope(connectionId: connectionId, database: scope.database, schema: scope.schema, table: ref.table.name)
        let newScope = TableScope(connectionId: connectionId, database: scope.database, schema: scope.schema, table: newName)
        for store in TableScopedSettingsRegistry.stores {
            store.renameTable(from: oldScope, to: newScope)
        }
        moveFavorite(ref, to: newName, connectionId: connectionId)
        SharedSidebarState.forConnection(connectionId).renameRecentTable(
            database: ref.database, schema: ref.schema, from: ref.table.name, to: newName
        )
        updatePendingOperations(connectionId: connectionId) { $0 == ref ? nil : $0 }
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
            FavoriteDatabasesStorage.shared.rename(database: oldDatabase, to: newName, connectionId: connectionId)
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
        guard container.kind == .database else { return }
        let sidebarState = SharedSidebarState.forConnection(connectionId)
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
        var schemas = Set(schemaService.schemas(for: connectionId).filter {
            schemaService.hasLoadedContent(for: connectionId, schema: $0)
        })
        if let schema = loadedScope.schema {
            schemas.insert(schema)
        }
        return LoadedBrowseCatalog(
            database: browseDatabase,
            schemas: schemas,
            tables: schemaService.allLoadedTables(for: connectionId)
        )
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

    private func moveFavorite(_ ref: DatabaseTreeTableRef, to newName: String, connectionId: UUID) {
        let storage = FavoriteTablesStorage.shared
        guard storage.isFavorite(
            name: ref.table.name, schema: ref.schema, database: ref.database, connectionId: connectionId
        ) else { return }
        storage.removeFavorite(name: ref.table.name, schema: ref.schema, database: ref.database, connectionId: connectionId)
        storage.addFavorite(name: newName, schema: ref.schema, database: ref.database, connectionId: connectionId)
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
        for store in TableScopedSettingsRegistry.stores {
            store.renameContainer(
                connectionId: connectionId, fromDatabase: database, fromSchema: schema,
                toDatabase: toDatabase, toSchema: toSchema
            )
        }
        let storage = FavoriteTablesStorage.shared
        for entry in storage.favorites(for: connectionId) where entry.database == database {
            if let schema, entry.schema != schema { continue }
            storage.removeFavorite(
                name: entry.name, schema: entry.schema, database: entry.database, connectionId: connectionId
            )
            storage.addFavorite(
                name: entry.name,
                schema: schema == nil ? entry.schema : toSchema,
                database: toDatabase,
                connectionId: connectionId
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
    private func retargetSavedConnectionDatabase(from oldName: String, to newName: String, connectionId: UUID) {
        guard var saved = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }),
              saved.database == oldName else { return }
        saved.database = newName
        ConnectionStorage.shared.updateConnection(saved)
    }

    private func retargetBrowseCursor(_ connection: DatabaseConnection, from oldName: String, to newName: String) {
        guard databaseManager.browseDatabaseName(for: connection) == oldName,
              let coordinator = WindowManager.shared.coordinators(for: connection.id).first else { return }
        Task { await coordinator.switchContainers(database: newName, schema: nil) }
    }
}
