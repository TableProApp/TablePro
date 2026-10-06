//
//  FavoriteTableCatalogReader.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

internal struct FavoriteTableLoadRequest: Equatable {
    internal let database: String?
    internal let schemas: Set<String>

    internal static let none = FavoriteTableLoadRequest(database: nil, schemas: [])
}

internal struct FavoriteTableRead: Equatable {
    internal let resolution: FavoriteTableResolution
    internal let loadRequest: FavoriteTableLoadRequest
}

@MainActor
internal struct FavoriteTableCatalogReader {
    internal let connectionId: UUID
    internal let grouping: GroupingStrategy
    internal let isConnected: Bool
    internal let schemaService: SchemaService
    internal let treeService: DatabaseTreeMetadataService

    internal init(
        connectionId: UUID,
        grouping: GroupingStrategy,
        isConnected: Bool,
        schemaService: SchemaService = .shared,
        treeService: DatabaseTreeMetadataService = .shared
    ) {
        self.connectionId = connectionId
        self.grouping = grouping
        self.isConnected = isConnected
        self.schemaService = schemaService
        self.treeService = treeService
    }

    internal func read(
        _ entries: [FavoriteTablesStorage.FavoriteEntry],
        scope: FavoriteTableBrowseScope,
        search: SidebarSearch
    ) -> FavoriteTableRead {
        let catalog = catalog(for: entries, scope: scope)
        return FavoriteTableRead(
            resolution: FavoriteTableResolver.resolve(entries, scope: scope, catalog: catalog, search: search),
            loadRequest: loadRequest(for: entries, scope: scope, catalog: catalog)
        )
    }

    internal func catalog(
        for entries: [FavoriteTablesStorage.FavoriteEntry],
        scope: FavoriteTableBrowseScope
    ) -> FavoriteTableCatalog {
        let browsed = entries.filter(scope.contains)
        guard !browsed.isEmpty else { return .empty }
        let names = Set(browsed.map(\.name))
        let schemas = Set(browsed.map { $0.schema ?? "" })
        var sources: [FavoriteTableCatalog.Source] = []
        if let loadedScope = schemaServiceScope(browsing: scope.database) {
            sources += flatListSource(loadedScope: loadedScope, names: names)
            sources += perSchemaSources(schemas: schemas, names: names)
        }
        sources += treeSources(database: scope.database, schemas: schemas, names: names)
        sources += listingSource(database: scope.database, names: names)
        return FavoriteTableCatalog(sources: sources)
    }

    internal func load(_ request: FavoriteTableLoadRequest) {
        for schema in request.schemas.sorted() {
            Task { await load(schema: schema, database: request.database) }
        }
    }

    internal func rowForOpening(
        _ entry: FavoriteTablesStorage.FavoriteEntry,
        scope: FavoriteTableBrowseScope
    ) async -> FavoriteTableRow? {
        if let row = row(for: entry, scope: scope), row.isVerified { return row }
        await schemaService.waitForRefresh(connectionId: connectionId)
        if let row = row(for: entry, scope: scope), row.isVerified { return row }
        await loadList(for: entry, scope: scope)
        return row(for: entry, scope: scope)
    }

    private func row(
        for entry: FavoriteTablesStorage.FavoriteEntry,
        scope: FavoriteTableBrowseScope
    ) -> FavoriteTableRow? {
        FavoriteTableResolver.resolve(
            [entry],
            scope: scope,
            catalog: catalog(for: [entry], scope: scope),
            search: SidebarSearch("")
        ).rows.first
    }

    private func loadList(for entry: FavoriteTablesStorage.FavoriteEntry, scope: FavoriteTableBrowseScope) async {
        guard isConnected, scope.listsTablesPerSchema, scope.contains(entry),
              let schema = entry.schema?.nilIfEmpty,
              schemaServiceScope(browsing: scope.database) != nil else { return }
        if grouping == .hierarchicalSchema {
            await schemaService.loadSchemaObjects(connectionId: connectionId, schema: schema, database: scope.database)
            return
        }
        let database = scope.database ?? ""
        await treeService.loadTables(connectionId: connectionId, database: database, schema: schema)
        let key = DatabaseTreeMetadataService.ObjectsKey(connectionId: connectionId, database: database, schema: schema)
        for await states in treeService.$tablesState.values {
            guard case .loading = states[key] else { return }
        }
    }

    private func load(schema: String, database: String?) async {
        guard canStartLoad(schema: schema, database: database) else { return }
        if grouping == .hierarchicalSchema {
            await schemaService.loadSchemaObjects(connectionId: connectionId, schema: schema, database: database)
        } else {
            await treeService.loadTables(connectionId: connectionId, database: database ?? "", schema: schema)
        }
    }

    private func loadRequest(
        for entries: [FavoriteTablesStorage.FavoriteEntry],
        scope: FavoriteTableBrowseScope,
        catalog: FavoriteTableCatalog
    ) -> FavoriteTableLoadRequest {
        guard isConnected, schemaServiceScope(browsing: scope.database) != nil else { return .none }
        let schemas = FavoriteTableResolver.schemasNeedingLoad(entries, scope: scope, catalog: catalog)
            .filter { canStartLoad(schema: $0, database: scope.database) }
        guard !schemas.isEmpty else { return .none }
        return FavoriteTableLoadRequest(database: scope.database, schemas: schemas)
    }

    private func canStartLoad(schema: String, database: String?) -> Bool {
        if grouping == .hierarchicalSchema {
            return schemaService.schemaObjectsNeedFetch(for: connectionId, schema: schema)
        }
        guard case .idle = treeService.tablesLoadState(
            connectionId: connectionId, database: database ?? "", schema: schema
        ) else { return false }
        return true
    }

    private func schemaServiceScope(browsing database: String?) -> DatabaseScope? {
        guard let loadedScope = schemaService.loadedScope(for: connectionId),
              loadedScope.database.nilIfEmpty == database else { return nil }
        return loadedScope
    }

    private func flatListSource(loadedScope: DatabaseScope, names: Set<String>) -> [FavoriteTableCatalog.Source] {
        guard grouping != .hierarchicalSchema,
              case .loaded(let tables) = schemaService.state(for: connectionId) else { return [] }
        let coverage: FavoriteTableCatalog.Source.Coverage = grouping == .bySchema
            ? .schemas(Set(tables.map { $0.schema ?? "" } + [loadedScope.schema].compactMap { $0 }))
            : .everySchema
        return [FavoriteTableCatalog.Source(
            tables: tables.filter { names.contains($0.name) },
            coverage: coverage,
            isCurrent: !schemaService.isRefreshing(connectionId: connectionId)
                && schemaService.isCatalogCurrent(for: connectionId)
        )]
    }

    private func perSchemaSources(schemas: Set<String>, names: Set<String>) -> [FavoriteTableCatalog.Source] {
        schemas.filter { !$0.isEmpty }.compactMap { schema in
            guard case .loaded(let tables) = schemaService.schemaState(for: connectionId, schema: schema) else {
                return nil
            }
            return FavoriteTableCatalog.Source(
                tables: tables.filter { names.contains($0.name) },
                coverage: .schemas([schema]),
                isCurrent: schemaService.isSchemaCurrent(for: connectionId, schema: schema)
            )
        }
    }

    private func treeSources(
        database: String?,
        schemas: Set<String>,
        names: Set<String>
    ) -> [FavoriteTableCatalog.Source] {
        schemas.compactMap { schema in
            let state = treeService.tablesLoadState(
                connectionId: connectionId, database: database ?? "", schema: schema.nilIfEmpty
            )
            guard case .loaded(let tables) = state else { return nil }
            return FavoriteTableCatalog.Source(
                tables: tables.filter { names.contains($0.name) },
                coverage: .schemas([schema]),
                isCurrent: true
            )
        }
    }

    private func listingSource(database: String?, names: Set<String>) -> [FavoriteTableCatalog.Source] {
        let state = treeService.allSchemaTablesLoadState(connectionId: connectionId, database: database ?? "")
        guard case .loaded(let listing) = state else { return [] }
        return [FavoriteTableCatalog.Source(
            tables: listing.tables.filter { names.contains($0.name) },
            coverage: .schemas(Set(listing.tables.map { $0.schema ?? "" })),
            isCurrent: false
        )]
    }
}
