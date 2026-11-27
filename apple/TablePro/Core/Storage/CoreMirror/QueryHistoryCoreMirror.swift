//
//  QueryHistoryCoreMirror.swift
//  TablePro
//

import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The history in `query_history.db` and the core's, entry for entry under the Mac's ids (core ADR 0052, History).
// The Mac's store keeps what only this device needs (plan and Rewind snapshots, the insights), so it stays what the
// History pane reads; the core holds the fields that sync. Each run goes to both. The person's deletion leaves a
// tombstone in the core so it syncs; a run the Mac's store let go on its own (retention, or the previous stable after a
// downgrade) leaves the core without one. A run the core let go after both held it, as a deletion another device
// synced, is never put back.
internal actor QueryHistoryCoreMirror {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryHistoryCoreMirror")
    private static let entriesPerWrite = 500

    private let storage: QueryHistoryStorage
    private let database: CoreHistoryDatabase
    private let connectionNames: @Sendable (Set<UUID>) async -> [UUID: String]
    private var tail: Task<Void, Never>?
    private var cleanupRunsSeen = 0

    internal init(
        storage: QueryHistoryStorage,
        database: CoreHistoryDatabase,
        connectionNames: @escaping @Sendable (Set<UUID>) async -> [UUID: String]
    ) {
        self.storage = storage
        self.database = database
        self.connectionNames = connectionNames
    }

    nonisolated internal func schedulePush() {
        Task { await self.push() }
    }

    nonisolated internal func scheduleRecorded(_ id: UUID) {
        Task { await self.recorded(id) }
    }

    // A retention pass the record ran drops runs here too.
    internal func recorded(_ id: UUID) async {
        _ = await serialized { [self] in await recordedOnce(id) }
    }

    private func recordedOnce(_ id: UUID) async -> Bool {
        do {
            let rows = await storage.coreRows(ids: [id])
            if try await put(rows).contains(id) {
                await storage.updateCoreMirrorBase(adding: [id], removing: [])
            }
        } catch {
            Self.logger.error("A run did not reach the core's history: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
        guard await storage.cleanupRuns != cleanupRunsSeen else { return true }
        return await pushOnce()
    }

    // False when the core may still hold a run the Mac's store no longer has, or lack one it has.
    @discardableResult
    internal func push() async -> Bool {
        await serialized { [self] in await pushOnce() }
    }

    // The person deleted these runs: each leaves the core with a tombstone, so the deletion syncs.
    internal func deleted(_ ids: Set<UUID>) async -> Bool {
        await serialized { [self] in await deletedOnce(ids) }
    }

    private func deletedOnce(_ ids: Set<UUID>) async -> Bool {
        do {
            let store = try await database.history()
            let gone = ids.map(\.uuidString)
            for start in stride(from: 0, to: gone.count, by: Self.entriesPerWrite) {
                _ = try await store.deleteEntries(recordIds: Array(gone[start..<min(start + Self.entriesPerWrite, gone.count)]))
            }
        } catch {
            Self.logger.error("The core's history kept runs deleted here: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
        await storage.updateCoreMirrorBase(adding: [], removing: ids)
        return await pushOnce()
    }

    // The person cleared every run, or a connection's went with it: the core drops them too, other devices' included,
    // each with a tombstone.
    internal func cleared(connectionId: UUID?) async -> Bool {
        await serialized { [self] in await clearedOnce(connectionId: connectionId) }
    }

    private func clearedOnce(connectionId: UUID?) async -> Bool {
        do {
            let store = try await database.history()
            if let connectionId {
                _ = try await store.deleteForConnection(connectionId: connectionId.uuidString)
            } else {
                try await store.clear()
            }
        } catch {
            Self.logger.error("The core's history was not cleared: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
        return await pushOnce()
    }

    // Runs a pull or an older build brought have no shape, which never leaves a device: this build reads each with its
    // grammar, a page at a time, until none is left.
    @discardableResult
    internal func fillFingerprints() async -> Bool {
        await serialized { [self] in await fillFingerprintsOnce() }
    }

    private func fillFingerprintsOnce() async -> Bool {
        do {
            let store = try await database.history()
            var previous: Set<Int64> = []
            while true {
                let page = try await store.entriesWithoutFingerprint(limit: UInt32(Self.entriesPerWrite))
                guard !page.isEmpty else { return true }
                // The same page again means the last write took none of it, and asking more would never end.
                let ids = Set(page.map(\.id))
                guard ids != previous else { return false }
                previous = ids
                let read = page.map { entry in
                    HistoryFingerprintArg(
                        id: entry.id,
                        fingerprint: SQLQueryFingerprint.hash(entry.sql, databaseType: DatabaseType(rawValue: entry.driverId))
                    )
                }
                try await store.setFingerprints(fingerprints: read)
                // A short page was the last one; a full one may be followed by more.
                guard page.count == Self.entriesPerWrite else { return true }
            }
        } catch {
            Self.logger.error("The core's history kept runs without a shape: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
    }

    private func serialized(_ work: @escaping @Sendable () async -> Bool) async -> Bool {
        let previous = tail
        let run = Task { () -> Bool in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await run.value }
        return await run.value
    }

    private func pushOnce() async -> Bool {
        cleanupRunsSeen = await storage.cleanupRuns
        guard let mine = await storage.entryIds(), let base = await storage.coreMirrorBase() else { return false }
        do {
            let store = try await database.history()
            let held = Set(try await store.recordIds().compactMap(UUID.init(uuidString:)))
            // A run both held once and the core no longer has was let go there, so it stays out.
            let missing = Array(mine.subtracting(held).subtracting(base))
            var written: Set<UUID> = []
            for start in stride(from: 0, to: missing.count, by: Self.entriesPerWrite) {
                let chunk = Array(missing[start..<min(start + Self.entriesPerWrite, missing.count)])
                written.formUnion(try await put(await storage.coreRows(ids: chunk)))
            }
            let gone = Array(base.subtracting(mine).intersection(held))
            for start in stride(from: 0, to: gone.count, by: Self.entriesPerWrite) {
                let chunk = gone[start..<min(start + Self.entriesPerWrite, gone.count)].map(\.uuidString)
                _ = try await store.removeEntries(recordIds: chunk)
            }
            // Runs the core let go stay in the agreement, so no later push takes them for new.
            let agreed = mine.intersection(held.union(written).union(base).subtracting(gone))
            let based = await storage.updateCoreMirrorBase(
                adding: agreed.subtracting(base),
                removing: base.subtracting(agreed)
            )
            if !written.isEmpty || !gone.isEmpty {
                Self.logger.info("The core's history took \(written.count, privacy: .public) runs and dropped \(gone.count, privacy: .public)")
            }
            return based && written.count == missing.count
        } catch {
            Self.logger.error("The core's history was not brought up to date: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
    }

    // Returns the ids the core took.
    private func put(_ rows: [CoreHistoryRow]) async throws -> Set<UUID> {
        guard !rows.isEmpty else { return [] }
        let names = await connectionNames(Set(rows.map(\.connectionId)))
        let entries = rows.map { row in
            HistoryEntryRecord(
                recordId: row.id.uuidString,
                sql: row.query,
                driverId: row.databaseType,
                connectionId: row.connectionId.uuidString,
                connectionName: names[row.connectionId] ?? "",
                executedAtMs: CoreMirrorTime.milliseconds(row.executedAt),
                durationMs: CoreMirrorTime.milliseconds(seconds: row.executionTime),
                rowsAffected: Int64(row.rowCount),
                outcome: row.wasSuccessful ? .succeeded : .failed(message: row.errorMessage ?? ""),
                details: CoreHistoryMapping.details(row)
            )
        }
        let store = try await database.history()
        do {
            _ = try await store.putEntries(entries: entries)
            return Set(rows.map(\.id))
        } catch {
            // One run the core refuses, such as one past its size cap, keeps the others out of a single write.
            var taken: Set<UUID> = []
            for (row, entry) in zip(rows, entries) {
                if (try? await store.putEntries(entries: [entry])) != nil {
                    taken.insert(row.id)
                }
            }
            Self.logger.error("The core's history refused \(rows.count - taken.count, privacy: .public) runs")
            return taken
        }
    }
}

// The Mac's history terms in the core's (core ADR 0060).
nonisolated enum CoreHistoryMapping {
    static func details(_ row: CoreHistoryRow) -> HistoryRunDetails {
        HistoryRunDetails(
            database: row.databaseName.isEmpty ? nil : row.databaseName,
            schema: row.schemaName,
            source: row.source.map(sourceTag),
            statementType: row.statementType.map(statementTag),
            firstRowMs: row.firstRowTime.map { CoreMirrorTime.milliseconds(seconds: $0) },
            serverMs: row.serverTime.map { CoreMirrorTime.milliseconds(seconds: $0) },
            fingerprint: row.shapeHash == 0 ? nil : row.shapeHash
        )
    }

    static func sourceTag(_ source: QueryHistorySource) -> HistorySourceTag {
        switch source {
        case .editor: .editor
        case .explain: .explain
        case .tableBrowse: .tableBrowse
        case .rowEdit: .rowEdit
        case .structureDDL: .structureDdl
        case .dataImport: .import
        case .mcp: .mcp
        case .script: .script
        case .shortcuts: .shortcuts
        case .commandLine: .commandLine
        }
    }

    static func statementTag(_ type: QueryHistoryStatementType) -> StatementTypeTag {
        switch type {
        case .select: .select
        case .insert: .insert
        case .update: .update
        case .delete: .delete
        case .ddl: .ddl
        case .other: .other
        }
    }
}
