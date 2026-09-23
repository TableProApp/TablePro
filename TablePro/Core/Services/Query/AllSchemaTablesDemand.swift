//
//  AllSchemaTablesDemand.swift
//  TablePro
//

import Foundation

/// When a reader holding a database's all-schema listing on screen should ask for it again.
///
/// A reader asks when nothing is held, and otherwise once the listing's revision has moved past
/// the one it last asked at: after a catalog change, a reconnect or a database switch. It never
/// asks twice for the same revision, or a read that failed would be retried on every change the
/// reader observes. And it never asks while the session is not connected, because the load would
/// return without starting and the revision would count as asked for all the same, which left a
/// search stale after every reconnect.
@MainActor
internal struct AllSchemaTablesDemand {
    private var requested: [String: Int] = [:]

    internal mutating func reset() {
        requested.removeAll()
    }

    internal mutating func noteRequested(connectionId: UUID, database: String, service: DatabaseTreeMetadataService) {
        requested[database] = service.allSchemaTablesRevision(connectionId: connectionId, database: database)
    }

    internal mutating func requestIfNeeded(
        connectionId: UUID,
        database: String,
        isConnected: Bool,
        service: DatabaseTreeMetadataService
    ) {
        guard isConnected, needsRequest(connectionId: connectionId, database: database, service: service) else { return }
        noteRequested(connectionId: connectionId, database: database, service: service)
        Task { await service.loadAllSchemaTables(connectionId: connectionId, database: database) }
    }

    internal func needsRequest(connectionId: UUID, database: String, service: DatabaseTreeMetadataService) -> Bool {
        switch service.allSchemaTablesLoadState(connectionId: connectionId, database: database) {
        case .loading:
            return false
        case .idle:
            return true
        case .loaded, .failed:
            return requested[database] != service.allSchemaTablesRevision(connectionId: connectionId, database: database)
        }
    }
}
