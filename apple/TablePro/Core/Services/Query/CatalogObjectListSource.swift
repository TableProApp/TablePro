//
//  CatalogObjectListSource.swift
//  TablePro
//

import Foundation

/// Where an Objects tab reads every kind but Tables. The sidebar's own lists, so the tab and the
/// tree show the same objects, and a refresh in either reaches both.
@MainActor
internal protocol CatalogObjectListSource: AnyObject, Sendable {
    /// `rereading` asks the server again; otherwise a list the sidebar already holds is taken as it is.
    func objects(
        _ category: SidebarObjectCategory,
        in scope: DatabaseScope,
        rereading: Bool
    ) async -> MetadataFetchOutcome<CatalogObjectList>
}

extension DatabaseTreeMetadataService: CatalogObjectListSource {
    func objects(
        _ category: SidebarObjectCategory,
        in scope: DatabaseScope,
        rereading: Bool
    ) async -> MetadataFetchOutcome<CatalogObjectList> {
        let id = scope.connectionId
        let database = scope.database
        let schema = scope.schema
        switch category {
        case .table:
            return await listOutcome(
                rereading: rereading,
                reread: { await self.refreshTableObjects(connectionId: id, database: database, schema: schema) },
                load: { await self.loadTables(connectionId: id, database: database, schema: schema) },
                state: { self.tablesLoadState(connectionId: id, database: database, schema: schema) },
                wrap: CatalogObjectList.relations
            )
        case .routine:
            return await listOutcome(
                rereading: rereading,
                reread: { await self.refreshRoutineObjects(connectionId: id, database: database, schema: schema) },
                load: { await self.loadRoutines(connectionId: id, database: database, schema: schema) },
                state: { self.routinesLoadState(connectionId: id, database: database, schema: schema) },
                wrap: CatalogObjectList.routines
            )
        case .trigger:
            return await listOutcome(
                rereading: rereading,
                reread: { await self.refreshTriggerObjects(connectionId: id, database: database, schema: schema) },
                load: { await self.loadTriggers(connectionId: id, database: database, schema: schema) },
                state: { self.triggersLoadState(connectionId: id, database: database, schema: schema) },
                wrap: CatalogObjectList.triggers
            )
        case .type:
            return await listOutcome(
                rereading: rereading,
                reread: { await self.refreshUserDefinedTypeObjects(connectionId: id, database: database, schema: schema) },
                load: { await self.loadUserDefinedTypes(connectionId: id, database: database, schema: schema) },
                state: { self.typesLoadState(connectionId: id, database: database, schema: schema) },
                wrap: CatalogObjectList.types
            )
        }
    }

    private func listOutcome<Value>(
        rereading: Bool,
        reread: () async -> Void,
        load: () async -> Void,
        state: () -> MetadataLoadState<Value>,
        wrap: (Value) -> CatalogObjectList
    ) async -> MetadataFetchOutcome<CatalogObjectList> {
        if rereading {
            await reread()
        } else {
            await load()
        }
        // A read the sidebar started meanwhile owns the list; loading again joins it at its revision.
        if case .loading = state() {
            await load()
        }
        switch state() {
        case .loaded(let value):
            return .fetched(wrap(value))
        case .failed(let message):
            return .failed(message)
        case .loading:
            return .cancelled
        case .idle:
            // Nothing ran, which the service does only for a connection that is down.
            return .failed(DatabaseError.notConnected.localizedDescription)
        }
    }
}
