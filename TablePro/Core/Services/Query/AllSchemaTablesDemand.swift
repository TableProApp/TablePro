//
//  AllSchemaTablesDemand.swift
//  TablePro
//

import Foundation

/// Asks once per listing revision and selection: a failed read retried on every observed change
/// would repeat it forever. Never asks while disconnected, or the revision counts as asked for with
/// no read started, which left a search stale after every reconnect.
@MainActor
internal struct AllSchemaTablesDemand {
    private var requested: [String: Int] = [:]

    internal mutating func reset() {
        requested.removeAll()
    }

    /// The selection is recorded first because a new one moves the revision this notes.
    internal mutating func noteRequested(
        connectionId: UUID,
        database: String,
        selection: CatalogTableListing.SchemaSelection = .all,
        service: DatabaseTreeMetadataService
    ) {
        service.selectAllSchemaTables(selection, connectionId: connectionId, database: database)
        requested[database] = service.allSchemaTablesRevision(connectionId: connectionId, database: database)
    }

    internal mutating func requestIfNeeded(
        connectionId: UUID,
        database: String,
        selection: CatalogTableListing.SchemaSelection = .all,
        isConnected: Bool,
        service: DatabaseTreeMetadataService
    ) {
        guard isConnected,
              needsRequest(connectionId: connectionId, database: database, selection: selection, service: service)
        else { return }
        noteRequested(connectionId: connectionId, database: database, selection: selection, service: service)
        Task {
            await service.loadAllSchemaTables(connectionId: connectionId, database: database, selection: selection)
        }
    }

    internal func needsRequest(
        connectionId: UUID,
        database: String,
        selection: CatalogTableListing.SchemaSelection = .all,
        service: DatabaseTreeMetadataService
    ) -> Bool {
        let state = service.allSchemaTablesLoadState(connectionId: connectionId, database: database)
        if case .idle = state { return true }
        let recorded = service.requestedAllSchemaTablesSelection(connectionId: connectionId, database: database)
        if recorded != selection { return true }
        switch state {
        case .loading:
            return false
        case .idle:
            return true
        case .loaded, .failed:
            return requested[database] != service.allSchemaTablesRevision(connectionId: connectionId, database: database)
        }
    }
}
