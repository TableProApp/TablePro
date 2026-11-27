//
//  QueryHistoryCoreMirror.swift
//  TablePro
//

import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The core's history is the one record of every run, this Mac's and the ones other devices synced, and the History
// pane reads it (core ADR 0052, History). `query_history.db` keeps what only this device needs (plan and Rewind
// snapshots, Insights) and what the previous stable reads, so it follows the core: each run recorded here goes up,
// each run another device synced comes down, and a run the core let go after both held it, as a deletion another
// device synced, goes here too. The person's deletion leaves a tombstone in the core so it syncs, noted here first so
// a core that cannot be reached gets it on a later push; a run this store let go on its own (retention, or the
// previous stable after a downgrade) leaves the core without one.
internal actor QueryHistoryCoreMirror {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryHistoryCoreMirror")
    private static let entriesPerWrite = 500

    private let storage: QueryHistoryStorage
    private let database: CoreHistoryDatabase
    private let connectionNames: @Sendable (Set<UUID>) async -> [UUID: String]
    // Told after a write changed what the pane or Insights show.
    private let changed: @Sendable () async -> Void
    private var tail: Task<Void, Never>?
    private var cleanupRunsSeen = 0

    internal init(
        storage: QueryHistoryStorage,
        database: CoreHistoryDatabase,
        connectionNames: @escaping @Sendable (Set<UUID>) async -> [UUID: String],
        changed: @escaping @Sendable () async -> Void = {}
    ) {
        self.storage = storage
        self.database = database
        self.connectionNames = connectionNames
        self.changed = changed
    }

    nonisolated internal func schedulePush() {
        Task { await self.push() }
    }

    nonisolated internal func scheduleRecorded(_ id: UUID) {
        Task { await self.recorded(id) }
    }

    // A retention pass the record ran drops runs here too. The pane reads the core, so it hears of the run once the
    // core holds it.
    internal func recorded(_ id: UUID) async {
        _ = await serialized { [self] in await recordedOnce(id) }
    }

    private func recordedOnce(_ id: UUID) async -> Bool {
        do {
            let rows = await storage.coreRows(ids: [id])
            if try await put(rows).contains(id) {
                await storage.updateCoreMirrorBase(adding: [id], removing: [])
                await changed()
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

    // MARK: - The person's deletions

    // Each deletion is noted before the run leaves this store, then sent with its tombstone; `delete` is the local
    // part. False while the core still holds a run the person deleted.
    internal func deleted(_ ids: Set<UUID>, locally delete: @escaping @Sendable () async -> Bool) async -> Bool {
        await serialized { [self] in
            guard await storage.notePendingCoreDeletions(ids) else { return false }
            guard await delete() else { return false }
            return await pushOnce()
        }
    }

    // A whole connection's runs, or every run: the core drops other devices' too, each with a tombstone.
    internal func cleared(connectionId: UUID?, ids: Set<UUID>, locally delete: @escaping @Sendable () async -> Bool) async -> Bool {
        await serialized { [self] in
            guard await storage.notePendingCoreDeletions(ids) else { return false }
            guard await delete() else { return false }
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
    }

    // What the pane shows for `filter`, which the core matches, other devices' runs included; this store drops the
    // same runs by id, and the ones its own search matches, so a run not in the core yet does not come back.
    internal func cleared(matching filter: QueryHistoryFilter, localIds: Set<UUID>, locally delete: @escaping @Sendable (Set<UUID>) async -> Bool) async -> Bool {
        await serialized { [self] in
            var coreIds: Set<UUID> = []
            var reached = true
            if let arg = CoreHistoryMapping.filter(filter) {
                do {
                    coreIds = Set(try await database.history().deleteMatching(filter: arg).compactMap(UUID.init(uuidString:)))
                } catch {
                    Self.logger.error("The core's history kept runs cleared here: \(LogRedaction.publicDescription(of: error), privacy: .public)")
                    reached = false
                }
            }
            let ids = localIds.union(coreIds)
            guard await storage.notePendingCoreDeletions(ids) else { return false }
            guard await delete(ids) else { return false }
            return await pushOnce() && reached
        }
    }

    // MARK: - The pane

    // A page of the core's history, newest first. Nil when the core's store cannot be read.
    internal func search(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) async -> QueryHistoryPage? {
        guard limit > 0, let arg = CoreHistoryMapping.filter(filter) else { return .empty }
        let after: HistoryCursorArg?
        switch cursor {
        case nil:
            after = nil
        case .core(let pinned, let executedAtSecs, let row)?:
            after = HistoryCursorArg(pinned: pinned, executedAtSecs: executedAtSecs, id: row)
        // A cursor from this store's page means nothing in the core's.
        case .local?:
            return nil
        }
        do {
            let page = try await database.history().search(filter: arg, after: after, limit: UInt32(clamping: limit))
            return QueryHistoryPage(
                entries: page.entries.compactMap(CoreHistoryMapping.entry),
                nextCursor: page.next.map { .core(pinned: $0.pinned, executedAtSecs: $0.executedAtSecs, row: $0.id) }
            )
        } catch {
            Self.logger.error("The core's history did not read: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Shapes

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

    // MARK: - Agreement

    private func serialized(_ work: @escaping @Sendable () async -> Bool) async -> Bool {
        let previous = tail
        let run = Task { () -> Bool in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await run.value }
        return await run.value
    }

    // The two stores against what both held when they last agreed (`base`):
    // - a deletion the person made here goes up with its tombstone first;
    // - a run in `base` this store let go leaves the core without one (`gone`);
    // - a run in `base` the core let go leaves this store (`lost`);
    // - a run only this store holds goes up (`missing`), one only the core holds comes down (`incoming`).
    private func pushOnce() async -> Bool {
        cleanupRunsSeen = await storage.cleanupRuns
        guard let pending = await storage.pendingCoreDeletions() else { return false }
        do {
            let store = try await database.history()
            if !pending.isEmpty {
                let ids = pending.map(\.uuidString)
                for start in stride(from: 0, to: ids.count, by: Self.entriesPerWrite) {
                    _ = try await store.deleteEntries(recordIds: Array(ids[start..<min(start + Self.entriesPerWrite, ids.count)]))
                }
                guard await storage.updateCoreMirrorBase(adding: [], removing: pending),
                      await storage.clearPendingCoreDeletions(pending)
                else { return false }
            }
            guard let mine = await storage.entryIds(), let base = await storage.coreMirrorBase() else { return false }
            let held = Set(try await store.recordIds().compactMap(UUID.init(uuidString:)))
            try await fillDetailsOnce(store, agreed: base.intersection(mine).intersection(held))

            let gone = base.subtracting(mine).intersection(held)
            let goneIds = gone.map(\.uuidString)
            for start in stride(from: 0, to: goneIds.count, by: Self.entriesPerWrite) {
                _ = try await store.removeEntries(recordIds: Array(goneIds[start..<min(start + Self.entriesPerWrite, goneIds.count)]))
            }

            let lost = base.intersection(mine).subtracting(held)
            guard await storage.deleteRuns(lost) else { return false }

            let missing = Array(mine.subtracting(held).subtracting(base))
            var written: Set<UUID> = []
            for start in stride(from: 0, to: missing.count, by: Self.entriesPerWrite) {
                let chunk = Array(missing[start..<min(start + Self.entriesPerWrite, missing.count)])
                written.formUnion(try await put(await storage.coreRows(ids: chunk)))
            }

            let incoming = Array(held.subtracting(mine).subtracting(base))
            var taken: Set<UUID> = []
            for start in stride(from: 0, to: incoming.count, by: Self.entriesPerWrite) {
                let chunk = incoming[start..<min(start + Self.entriesPerWrite, incoming.count)].map(\.uuidString)
                let entries = try await store.entries(recordIds: chunk).compactMap(CoreHistoryMapping.entry)
                taken.formUnion(await storage.takePulled(entries))
            }

            let kept = mine.subtracting(lost).union(taken)
            let agreed = kept.intersection(held.union(written))
            let based = await storage.updateCoreMirrorBase(
                adding: agreed.subtracting(base),
                removing: base.subtracting(agreed)
            )
            if !written.isEmpty || !gone.isEmpty || !lost.isEmpty || !taken.isEmpty || !pending.isEmpty {
                Self.logger.info("""
                    The history agreed: \(written.count, privacy: .public) up, \(taken.count, privacy: .public) down, \
                    \(gone.count, privacy: .public) let go here, \(lost.count, privacy: .public) let go in the core, \
                    \(pending.count, privacy: .public) deleted
                    """)
                await changed()
            }
            return based && written.count == missing.count
        } catch {
            Self.logger.error("The core's history was not brought up to date: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return false
        }
    }

    // Runs mirrored before the core kept their details get them once, from this store's rows; the core fills only what
    // it lacks.
    private func fillDetailsOnce(_ store: QueryHistoryStore, agreed: Set<UUID>) async throws {
        guard !agreed.isEmpty else { return }
        guard await storage.coreDetailsFilled() == false else { return }
        let ids = Array(agreed)
        for start in stride(from: 0, to: ids.count, by: Self.entriesPerWrite) {
            let rows = await storage.coreRows(ids: Array(ids[start..<min(start + Self.entriesPerWrite, ids.count)]))
            let records = rows.map { HistoryDetailsRecord(recordId: $0.id.uuidString, details: CoreHistoryMapping.details($0)) }
            _ = try await store.fillDetails(entries: records)
        }
        await storage.markCoreDetailsFilled()
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

// The Mac's history terms and the core's (core ADR 0060, History pane).
nonisolated enum CoreHistoryMapping {
    // Nil for a filter that matches nothing, which the core is never asked.
    static func filter(_ filter: QueryHistoryFilter) -> HistoryFilterArg? {
        guard !filter.matchesNothing else { return nil }
        var connections = filter.allowedConnectionIds
        if let scoped = filter.scope.connectionId {
            connections = (connections ?? [scoped]).intersection([scoped])
        }
        if let connections, connections.isEmpty { return nil }
        // Every source is no filter at all, so a run another app recorded without one still shows.
        let sources = filter.sources == Set(QueryHistorySource.allCases) ? nil : filter.sources.map(sourceTag)
        let status: HistoryStatusTag
        switch filter.outcome {
        case .any: status = .any
        case .succeeded: status = .succeeded
        case .failed: status = .failed
        }
        return HistoryFilterArg(
            text: filter.searchText ?? "",
            connectionIds: connections.map { $0.map(\.uuidString).sorted() },
            sources: sources,
            status: status,
            executedAfterMs: filter.since.map(CoreMirrorTime.milliseconds),
            executedBeforeMs: filter.until.map(CoreMirrorTime.milliseconds)
        )
    }

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

    // Nil for a run with no connection or an id that is not a UUID, which neither the pane nor this store has a row for.
    static func entry(_ info: HistoryEntryInfo) -> QueryHistoryEntry? {
        guard let id = UUID(uuidString: info.recordId),
              let connectionId = info.connectionId.flatMap(UUID.init(uuidString:))
        else { return nil }
        let succeeded: Bool
        let message: String?
        switch info.outcome {
        case .succeeded:
            succeeded = true
            message = nil
        case .failed(let text):
            succeeded = false
            message = text.isEmpty ? nil : text
        case .cancelled:
            succeeded = false
            message = nil
        }
        return QueryHistoryEntry(
            id: id,
            query: info.sql,
            connectionId: connectionId,
            databaseName: info.details.database ?? "",
            databaseType: DatabaseType(rawValue: info.driverId),
            schemaName: info.details.schema,
            source: info.details.source.map(source) ?? .editor,
            statementType: info.details.statementType.map(statementType),
            executedAt: CoreMirrorTime.date(info.executedAtMs),
            executionTime: Double(info.durationMs ?? 0) / 1_000,
            rowCount: info.rowsAffected.map { Int(clamping: $0) } ?? -1,
            wasSuccessful: succeeded,
            errorMessage: message,
            firstRowTime: info.details.firstRowMs.map { Double($0) / 1_000 },
            serverTime: info.details.serverMs.map { Double($0) / 1_000 }
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

    static func source(_ tag: HistorySourceTag) -> QueryHistorySource {
        switch tag {
        case .editor: .editor
        case .explain: .explain
        case .tableBrowse: .tableBrowse
        case .rowEdit: .rowEdit
        case .structureDdl: .structureDDL
        case .import: .dataImport
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

    static func statementType(_ tag: StatementTypeTag) -> QueryHistoryStatementType {
        switch tag {
        case .select: .select
        case .insert: .insert
        case .update: .update
        case .delete: .delete
        case .ddl: .ddl
        case .other: .other
        }
    }
}
