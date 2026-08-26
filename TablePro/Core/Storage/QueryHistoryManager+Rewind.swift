//
//  QueryHistoryManager+Rewind.swift
//  TablePro
//

import Foundation

extension QueryHistoryManager {
    @discardableResult
    func recordRewindSnapshot(_ record: RewindRecord) async -> Bool {
        await storage.recordRewindSnapshot(record)
    }

    func rewindSnapshots(
        connectionId: UUID,
        database: String,
        schema: String?,
        table: String,
        limit: Int = 20
    ) async -> [RewindRecord] {
        await storage.rewindSnapshots(
            connectionId: connectionId, database: database, schema: schema, table: table, limit: limit
        )
    }

    func rewindSnapshot(id: UUID) async -> RewindRecord? {
        await storage.rewindSnapshot(id: id)
    }

    func rewindSnapshotId(forHistoryId historyId: UUID) async -> UUID? {
        await storage.rewindSnapshotId(forHistoryId: historyId)
    }

    @discardableResult
    func deleteRewindSnapshot(id: UUID) async -> Bool {
        await storage.deleteRewindSnapshot(id: id)
    }

    /// Drops every stored save, and the key that reads them.
    @discardableResult
    func clearRewindSnapshots() async -> Bool {
        let cleared = await storage.clearRewindSnapshots()
        RewindCipher().discardKey()
        return cleared
    }
}
