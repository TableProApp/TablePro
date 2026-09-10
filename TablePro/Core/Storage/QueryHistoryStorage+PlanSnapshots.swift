//
//  QueryHistoryStorage+PlanSnapshots.swift
//  TablePro
//
//  Saved EXPLAIN plans.
//
//  They live in the query-history database because that is where a statement's runs already live,
//  but they are not owned by a history row. A plan is an artifact the user keeps deliberately, and
//  a foreign key that cascaded would delete a pinned baseline the moment ordinary history retention
//  aged out the run that produced it. `history_id` is provenance, nullable, and `ON DELETE SET
//  NULL`.
//
//  Writing a plan is a separate statement from writing the history row rather than one transaction
//  covering both. Sharing a transaction means a failure on the large write, which is the one that
//  can hit SQLITE_FULL, takes the small write down with it: SQLite auto-rolls back on a full disk,
//  the explicit ROLLBACK then fails with "cannot rollback - no transaction is active", and the
//  history entry is lost along with the plan.
//

import Foundation
import SQLite3
import TableProPluginKit

extension QueryHistoryStorage {
    /// A baseline list longer than this is a scrollbar, not a choice.
    static let maximumPlanSnapshotListLength = 100

    func createPlanSnapshotStorage() {
        execute("""
            CREATE TABLE IF NOT EXISTS plan_snapshots (
                id TEXT PRIMARY KEY NOT NULL,
                history_id TEXT REFERENCES history(id) ON DELETE SET NULL,
                fingerprint_hash INTEGER NOT NULL,
                subject_sql TEXT NOT NULL,
                connection_id TEXT NOT NULL,
                database_name TEXT NOT NULL,
                database_type TEXT NOT NULL,
                schema_name TEXT,
                variant_key TEXT NOT NULL,
                format TEXT NOT NULL,
                raw_plan TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                execution_time REAL NOT NULL,
                captured_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0
            );
            """)
        execute("""
            CREATE INDEX IF NOT EXISTS idx_plan_snapshots_identity
                ON plan_snapshots(fingerprint_hash, connection_id, database_name, variant_key, captured_at DESC);
            """)
        execute("""
            CREATE INDEX IF NOT EXISTS idx_plan_snapshots_retention
                ON plan_snapshots(is_pinned, captured_at DESC);
            """)
    }

    // MARK: - Writing

    @discardableResult
    func recordPlanSnapshot(_ capture: QueryPlanCapture) -> Bool {
        guard let db, capture.isWithinPlanSizeLimit else { return false }

        let sql = """
            INSERT INTO plan_snapshots (
                id, history_id, fingerprint_hash, subject_sql, connection_id, database_name,
                database_type, schema_name, variant_key, format, raw_plan, byte_count,
                execution_time, captured_at, is_pinned
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare plan snapshot insert")
            return false
        }

        let identity = capture.identity
        let bindings: [QueryHistorySqlBinding?] = [
            .text(capture.id.uuidString),
            capture.historyId.map { .text($0.uuidString) },
            .int64(identity.fingerprintHash),
            .text(capture.subjectSQL),
            .text(identity.scope.connectionId.uuidString),
            .text(identity.scope.databaseName),
            .text(identity.scope.databaseType.rawValue),
            identity.scope.schemaName.map { .text($0) },
            .text(identity.variantKey.rawValue),
            .text(identity.format.rawValue),
            .text(capture.rawPlan),
            .int64(Int64(capture.byteCount)),
            .double(capture.executionTime),
            .double(capture.capturedAt.timeIntervalSince1970),
        ]
        bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "plan snapshot insert")
            return false
        }
        return true
    }

    @discardableResult
    func setPlanSnapshotPinned(id: UUID, isPinned: Bool) -> Bool {
        guard let db else { return false }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE plan_snapshots SET is_pinned = ? WHERE id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare plan snapshot pin")
            return false
        }
        QueryHistorySqlBinding.int(isPinned ? 1 : 0).bind(to: statement, at: 1)
        QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "plan snapshot pin")
            return false
        }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func deletePlanSnapshot(id: UUID) -> Bool {
        guard let db else { return false }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM plan_snapshots WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare plan snapshot delete")
            return false
        }
        QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "plan snapshot delete")
            return false
        }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    func clearPlanSnapshots() -> Bool {
        guard let db else { return false }
        execute("DELETE FROM plan_snapshots;")
        return sqlite3_changes(db) > 0
    }

    // MARK: - Reading

    /// Earlier runs of the same statement shape, newest first, excluding the run that is asking.
    func planSnapshots(
        matching identity: QueryPlanIdentity,
        excluding excludedId: UUID?,
        limit: Int
    ) -> [QueryPlanSnapshotSummary] {
        let boundedLimit = min(max(limit, 0), Self.maximumPlanSnapshotListLength)
        guard db != nil, boundedLimit > 0 else { return [] }

        var clause = QueryHistorySqlClause()
        clause.append("""
            SELECT id, subject_sql, execution_time, captured_at, is_pinned, byte_count
              FROM plan_snapshots
             WHERE fingerprint_hash = ?
               AND connection_id = ?
               AND database_name = ?
               AND database_type = ?
               AND variant_key = ?
               AND format = ?
            """,
            .int64(identity.fingerprintHash),
            .text(identity.scope.connectionId.uuidString),
            .text(identity.scope.databaseName),
            .text(identity.scope.databaseType.rawValue),
            .text(identity.variantKey.rawValue),
            .text(identity.format.rawValue)
        )
        appendNullSafeMatch(column: "schema_name", value: identity.scope.schemaName, to: &clause)
        if let excludedId {
            clause.append(" AND id <> ?", .text(excludedId.uuidString))
        }
        clause.append(
            " ORDER BY captured_at DESC, id DESC LIMIT ?;",
            .int(Int32(boundedLimit))
        )

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, clause.sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare plan snapshot list")
            return []
        }
        for (offset, binding) in clause.bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }

        var summaries: [QueryPlanSnapshotSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idRaw = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let id = UUID(uuidString: idRaw)
            else { continue }
            summaries.append(QueryPlanSnapshotSummary(
                id: id,
                subjectSQL: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                executionTime: sqlite3_column_double(statement, 2),
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                isPinned: sqlite3_column_int(statement, 4) != 0,
                byteCount: Int(sqlite3_column_int64(statement, 5))
            ))
        }
        return summaries
    }

    /// The plan text, loaded only when a baseline is actually selected.
    func planSnapshotRawText(id: UUID) -> String? {
        guard let db else { return nil }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT raw_plan FROM plan_snapshots WHERE id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare plan snapshot text")
            return nil
        }
        QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    func planSnapshotUsage() -> QueryPlanStorageUsage {
        guard let db else { return QueryPlanStorageUsage(byteCount: 0, snapshotCount: 0, pinnedCount: 0) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT COALESCE(SUM(byte_count), 0), COUNT(*), COALESCE(SUM(is_pinned), 0)
              FROM plan_snapshots;
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            logSqliteError(context: "plan snapshot usage")
            return QueryPlanStorageUsage(byteCount: 0, snapshotCount: 0, pinnedCount: 0)
        }
        return QueryPlanStorageUsage(
            byteCount: sqlite3_column_int64(statement, 0),
            snapshotCount: Int(sqlite3_column_int64(statement, 1)),
            pinnedCount: Int(sqlite3_column_int64(statement, 2))
        )
    }

    // MARK: - Retention

    /// Runs on query history's own cleanup cadence, never inside the per-EXPLAIN write, so a plan
    /// insert never pays for a full scan of the table and never holds the write lock while it does.
    ///
    /// Pinned plans are exempt. A user who pinned a baseline said the one thing retention exists to
    /// guess at.
    @discardableResult
    func prunePlanSnapshots(toByteLimit byteLimit: Int64) -> Bool {
        guard let db else { return false }
        let usage = planSnapshotUsage()
        guard usage.byteCount > byteLimit else { return false }

        let sql = """
            DELETE FROM plan_snapshots
             WHERE is_pinned = 0
               AND id IN (
                    SELECT id FROM (
                        SELECT id,
                               SUM(byte_count) OVER (
                                   ORDER BY captured_at DESC, id DESC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                               ) AS retained
                          FROM plan_snapshots
                         WHERE is_pinned = 0
                    )
                    WHERE retained > ?
               );
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare plan snapshot prune")
            return false
        }
        sqlite3_bind_int64(statement, 1, byteLimit)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "plan snapshot prune")
            return false
        }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Helpers

    private func bind(_ bindings: [QueryHistorySqlBinding?], to statement: OpaquePointer?) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            guard let binding else {
                sqlite3_bind_null(statement, index)
                continue
            }
            binding.bind(to: statement, at: index)
        }
    }

    private func appendNullSafeMatch(
        column: String,
        value: String?,
        to clause: inout QueryHistorySqlClause
    ) {
        if let value {
            clause.append(" AND \(column) = ?", .text(value))
        } else {
            clause.append(" AND \(column) IS NULL")
        }
    }
}

struct QueryPlanStorageUsage: Hashable, Sendable {
    let byteCount: Int64
    let snapshotCount: Int
    let pinnedCount: Int
}
