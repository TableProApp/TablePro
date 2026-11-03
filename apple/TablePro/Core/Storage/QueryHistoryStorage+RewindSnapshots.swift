//
//  QueryHistoryStorage+RewindSnapshots.swift
//  TablePro
//
//  What each committed save looked like before it ran.
//
//  These live in the query-history database because that is already where a statement's runs live,
//  and the History drawer is one of the places a save is reached from. They are not owned by a
//  history row: `history_id` is provenance, nullable and `ON DELETE SET NULL`, and every column a
//  lookup needs is denormalized onto the row itself, so retention aging out the run does not take
//  the only route to the record with it.
//
//  Writing a snapshot is a separate statement from writing the history row, for the same reason
//  plan_snapshots is: sharing a transaction means the large write, which is the one that can hit
//  SQLITE_FULL, takes the small one down with it.
//
//  The payload is encrypted. It is real row data, unlike everything else in this database.
//

import Foundation
import os
import SQLite3

extension QueryHistoryStorage {
    /// A save older than this is not worth the disk. Long enough to cover "I noticed the next
    /// morning", short enough that production values are not sitting there for a quarter.
    static let rewindSnapshotRetention: TimeInterval = 7 * 24 * 60 * 60
    static let rewindSnapshotByteLimit: Int64 = 32 * 1_024 * 1_024
    static let maximumRewindSnapshotsPerTable = 50

    private static var rewindLogger: Logger {
        Logger(subsystem: "com.TablePro", category: "RewindSnapshots")
    }

    func createRewindSnapshotStorage() {
        execute("""
            CREATE TABLE IF NOT EXISTS rewind_snapshots (
                id TEXT PRIMARY KEY NOT NULL,
                history_id TEXT REFERENCES history(id) ON DELETE SET NULL,
                connection_id TEXT NOT NULL,
                database_name TEXT NOT NULL,
                schema_name TEXT,
                table_name TEXT NOT NULL,
                database_type TEXT NOT NULL,
                captured_at REAL NOT NULL,
                operation_count INTEGER NOT NULL,
                reversible_count INTEGER NOT NULL,
                byte_count INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
            """)
        execute("""
            CREATE INDEX IF NOT EXISTS idx_rewind_snapshots_target
                ON rewind_snapshots(connection_id, database_name, table_name, captured_at DESC);
            """)
        execute("""
            CREATE INDEX IF NOT EXISTS idx_rewind_snapshots_retention
                ON rewind_snapshots(captured_at DESC);
            """)
    }

    // MARK: - Writing

    @discardableResult
    func recordRewindSnapshot(_ record: RewindRecord, cipher: RewindCipher = RewindCipher()) -> Bool {
        guard let db else { return false }
        let payload: Data
        do {
            payload = try cipher.seal(record)
        } catch {
            Self.rewindLogger.error(
                "Could not protect a save snapshot, so it was not kept: \(error.publicLogShape, privacy: .public)"
            )
            return false
        }

        let sql = """
            INSERT INTO rewind_snapshots (
                id, history_id, connection_id, database_name, schema_name, table_name,
                database_type, captured_at, operation_count, reversible_count, byte_count, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare rewind snapshot insert")
            return false
        }

        let bindings: [QueryHistorySqlBinding?] = [
            .text(record.id.uuidString),
            record.historyId.map { .text($0.uuidString) },
            .text(record.connectionId.uuidString),
            .text(record.target.database),
            record.target.schema.map { .text($0) },
            .text(record.target.table),
            .text(record.databaseType.rawValue),
            .double(record.capturedAt.timeIntervalSince1970),
            .int(Int32(record.operations.count)),
            .int(Int32(record.reversibleOperations.count)),
            .int64(Int64(payload.count)),
        ]
        bindRewind(bindings, to: statement)
        payload.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(
                statement, 12, buffer.baseAddress, Int32(buffer.count), QueryHistorySqlBinding.transient
            )
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "rewind snapshot insert")
            return false
        }
        rewindSnapshotsDidChange()
        return true
    }

    // MARK: - Reading

    func rewindSnapshot(id: UUID, cipher: RewindCipher = RewindCipher()) -> RewindRecord? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT payload FROM rewind_snapshots WHERE id = ?;", -1, &statement, nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare rewind snapshot read")
            return nil
        }
        QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeRewindPayload(from: statement, column: 0, cipher: cipher)
    }

    func rewindSnapshotId(forHistoryId historyId: UUID) -> UUID? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT id FROM rewind_snapshots WHERE history_id = ? LIMIT 1;", -1, &statement, nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare rewind snapshot lookup")
            return nil
        }
        QueryHistorySqlBinding.text(historyId.uuidString).bind(to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0)
        else { return nil }
        return UUID(uuidString: String(cString: raw))
    }

    /// The most recent saves against one table, newest first.
    func rewindSnapshots(
        connectionId: UUID,
        database: String,
        schema: String?,
        table: String,
        limit: Int = 20,
        cipher: RewindCipher = RewindCipher()
    ) -> [RewindRecord] {
        guard let db else { return [] }
        var clause = QueryHistorySqlClause()
        clause.append(
            "WHERE connection_id = ? AND database_name = ? AND table_name = ?",
            .text(connectionId.uuidString), .text(database), .text(table)
        )
        if let schema {
            clause.append(" AND schema_name = ?", .text(schema))
        } else {
            clause.append(" AND schema_name IS NULL")
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT payload FROM rewind_snapshots \(clause.sql)
             ORDER BY captured_at DESC LIMIT ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare rewind snapshot list")
            return []
        }
        bindRewind(clause.bindings, to: statement)
        QueryHistorySqlBinding.int(Int32(limit)).bind(to: statement, at: Int32(clause.bindings.count + 1))

        var records: [RewindRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decodeRewindPayload(from: statement, column: 0, cipher: cipher) {
                records.append(record)
            }
        }
        return records
    }

    // MARK: - Deleting

    @discardableResult
    func deleteRewindSnapshot(id: UUID) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "DELETE FROM rewind_snapshots WHERE id = ?;", -1, &statement, nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare rewind snapshot delete")
            return false
        }
        QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "rewind snapshot delete")
            return false
        }
        let deleted = sqlite3_changes(db) > 0
        if deleted { rewindSnapshotsDidChange() }
        return deleted
    }

    @discardableResult
    func clearRewindSnapshots() -> Bool {
        guard db != nil else { return false }
        execute("DELETE FROM rewind_snapshots;")
        rewindSnapshotsDidChange()
        return true
    }

    // MARK: - Retention

    // Runs on history's cleanup cadence, so a save never pays for a full scan. The byte budget
    // excludes the row being judged, so one save larger than the budget survives its own write.
    @discardableResult
    func pruneRewindSnapshots(
        now: Date = Date(),
        retention: TimeInterval = QueryHistoryStorage.rewindSnapshotRetention,
        byteLimit: Int64 = QueryHistoryStorage.rewindSnapshotByteLimit,
        perTableLimit: Int = QueryHistoryStorage.maximumRewindSnapshotsPerTable
    ) -> Bool {
        guard let db else { return false }
        var changed = false

        var ageStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "DELETE FROM rewind_snapshots WHERE captured_at < ?;", -1, &ageStatement, nil
        ) == SQLITE_OK {
            sqlite3_bind_double(ageStatement, 1, now.addingTimeInterval(-retention).timeIntervalSince1970)
            if sqlite3_step(ageStatement) == SQLITE_DONE {
                changed = changed || sqlite3_changes(db) > 0
            }
        }
        sqlite3_finalize(ageStatement)

        var depthStatement: OpaquePointer?
        let depthSQL = """
            DELETE FROM rewind_snapshots
             WHERE id IN (
                    SELECT id FROM (
                        SELECT id,
                               ROW_NUMBER() OVER (
                                   PARTITION BY connection_id, database_name, schema_name, table_name
                                   ORDER BY captured_at DESC, id DESC
                               ) AS depth
                          FROM rewind_snapshots
                    )
                    WHERE depth > ?
               );
            """
        if sqlite3_prepare_v2(db, depthSQL, -1, &depthStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(depthStatement, 1, Int32(perTableLimit))
            if sqlite3_step(depthStatement) == SQLITE_DONE {
                changed = changed || sqlite3_changes(db) > 0
            }
        }
        sqlite3_finalize(depthStatement)

        var byteStatement: OpaquePointer?
        let byteSQL = """
            DELETE FROM rewind_snapshots
             WHERE id IN (
                    SELECT id FROM (
                        SELECT id,
                               COALESCE(SUM(byte_count) OVER (
                                   ORDER BY captured_at DESC, id DESC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                               ), 0) AS retained
                          FROM rewind_snapshots
                    )
                    WHERE retained > ?
               );
            """
        if sqlite3_prepare_v2(db, byteSQL, -1, &byteStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(byteStatement, 1, byteLimit)
            if sqlite3_step(byteStatement) == SQLITE_DONE {
                changed = changed || sqlite3_changes(db) > 0
            }
        }
        sqlite3_finalize(byteStatement)

        if changed { rewindSnapshotsDidChange() }
        return changed
    }

    // MARK: - Availability

    // Plain columns only, so knowing a save is kept costs no decrypt.
    func rewindAvailability() -> RewindAvailability {
        var targets = Set<RewindAvailability.Target>()
        var historyIds = Set<UUID>()
        guard let db else {
            return RewindAvailability(revision: rewindRevision, targets: targets, historyIds: historyIds)
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT DISTINCT connection_id, database_name, schema_name, table_name, history_id
              FROM rewind_snapshots;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare rewind availability")
            return RewindAvailability(revision: rewindRevision, targets: targets, historyIds: historyIds)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let connectionId = Self.rewindUUID(statement, column: 0),
                  let database = Self.rewindText(statement, column: 1),
                  let table = Self.rewindText(statement, column: 3)
            else { continue }
            targets.insert(RewindAvailability.Target(
                connectionId: connectionId,
                database: database,
                schema: Self.rewindText(statement, column: 2),
                table: table
            ))
            if let historyId = Self.rewindUUID(statement, column: 4) {
                historyIds.insert(historyId)
            }
        }
        return RewindAvailability(revision: rewindRevision, targets: targets, historyIds: historyIds)
    }

    // Yields what is kept now, then again after every change that commits.
    func rewindAvailabilityUpdates() -> AsyncStream<RewindAvailability> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RewindAvailability.self, bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        rewindSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRewindSubscriber(id) }
        }
        continuation.yield(rewindAvailability())
        return stream
    }

    func rewindSnapshotsDidChange() {
        rewindRevision += 1
        guard !rewindSubscribers.isEmpty else { return }
        let current = rewindAvailability()
        for subscriber in rewindSubscribers.values {
            subscriber.yield(current)
        }
    }

    private func removeRewindSubscriber(_ id: UUID) {
        rewindSubscribers[id] = nil
    }

    private static func rewindText(_ statement: OpaquePointer?, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func rewindUUID(_ statement: OpaquePointer?, column: Int32) -> UUID? {
        rewindText(statement, column: column).flatMap(UUID.init(uuidString:))
    }

    // MARK: - Helpers

    private func decodeRewindPayload(
        from statement: OpaquePointer?,
        column: Int32,
        cipher: RewindCipher
    ) -> RewindRecord? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0 else { return nil }
        let payload = Data(bytes: bytes, count: length)
        do {
            return try cipher.open(payload)
        } catch {
            Self.rewindLogger.error(
                "Could not read a save snapshot: \(error.publicLogShape, privacy: .public)"
            )
            return nil
        }
    }

    private func bindRewind(_ bindings: [QueryHistorySqlBinding?], to statement: OpaquePointer?) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            guard let binding else {
                sqlite3_bind_null(statement, index)
                continue
            }
            binding.bind(to: statement, at: index)
        }
    }
}
