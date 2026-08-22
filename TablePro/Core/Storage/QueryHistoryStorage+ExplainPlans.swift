import Foundation
import SQLite3

extension QueryHistoryStorage {
    private static let maximumExplainPlanHistoryLimit = 100

    func createExplainPlanStorage() {
        execute("""
            CREATE TABLE IF NOT EXISTS query_plan_snapshots (
                history_id TEXT PRIMARY KEY NOT NULL REFERENCES history(id) ON DELETE CASCADE,
                subject_query TEXT NOT NULL,
                subject_fingerprint_hash INTEGER NOT NULL,
                variant_id TEXT,
                format TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                raw_byte_count INTEGER NOT NULL,
                parser_schema_version INTEGER NOT NULL
            );
            """)
        execute("""
            CREATE INDEX IF NOT EXISTS idx_query_plan_snapshots_subject
                ON query_plan_snapshots(subject_fingerprint_hash, format, variant_id);
            """)
        execute("""
            CREATE TRIGGER IF NOT EXISTS history_plan_snapshots_ad AFTER DELETE ON history BEGIN
                DELETE FROM query_plan_snapshots WHERE history_id = old.id;
            END;
            """)
    }

    func insertExplainPlanSnapshot(_ record: ExplainPlanHistoryRecord) -> Bool {
        guard let db, record.isWithinStorageLimit else { return false }

        let sql = """
            INSERT INTO query_plan_snapshots (
                history_id, subject_query, subject_fingerprint_hash, variant_id,
                format, raw_text, raw_byte_count, parser_schema_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare explain plan insert")
            return false
        }

        let context = record.context
        let transient = QueryHistorySqlBinding.transient
        sqlite3_bind_text(statement, 1, context.historyId.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, context.subjectQuery, -1, transient)
        sqlite3_bind_int64(
            statement,
            3,
            SQLQueryFingerprint.hash(context.subjectQuery, databaseType: context.databaseType)
        )
        if let variantId = context.variantId {
            sqlite3_bind_text(statement, 4, variantId, -1, transient)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_text(statement, 5, context.formatRawValue, -1, transient)
        sqlite3_bind_text(statement, 6, record.rawText, -1, transient)
        sqlite3_bind_int64(statement, 7, Int64(record.rawByteCount))
        sqlite3_bind_int(statement, 8, Int32(clamping: record.parserSchemaVersion))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "explain plan insert")
            return false
        }
        return true
    }

    func explainPlanHistory(
        matching context: ExplainPlanHistoryContext,
        limit: Int
    ) -> [ExplainPlanHistorySnapshot] {
        let boundedLimit = min(max(limit, 0), Self.maximumExplainPlanHistoryLimit)
        guard db != nil, boundedLimit > 0 else { return [] }

        var clause = QueryHistorySqlClause()
        clause.append("""
            SELECT p.history_id, h.connection_id, h.database_name, h.database_type,
                   h.schema_name, p.variant_id, p.format,
                   h.executed_at, h.execution_time
              FROM query_plan_snapshots p
              JOIN history h ON h.id = p.history_id
             WHERE p.subject_fingerprint_hash = ?
               AND p.subject_query = ?
               AND h.connection_id = ?
               AND h.database_name = ?
               AND h.database_type = ?
               AND p.format = ?
               AND h.was_successful = 1
               AND h.executed_at < ?
               AND p.history_id <> ?
            """,
            .int64(SQLQueryFingerprint.hash(context.subjectQuery, databaseType: context.databaseType)),
            .text(context.subjectQuery),
            .text(context.connectionId.uuidString),
            .text(context.databaseName),
            .text(context.databaseType.rawValue),
            .text(context.formatRawValue),
            .double(context.capturedAt.timeIntervalSince1970),
            .text(context.historyId.uuidString)
        )
        appendNullSafeMatch(column: "h.schema_name", value: context.schemaName, to: &clause)
        appendNullSafeMatch(column: "p.variant_id", value: context.variantId, to: &clause)
        clause.append(
            " ORDER BY h.executed_at DESC, p.history_id DESC LIMIT ?;",
            .int(Int32(boundedLimit))
        )

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, clause.sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare explain plan history")
            return []
        }
        for (offset, binding) in clause.bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }

        var snapshots: [ExplainPlanHistorySnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let snapshot = parseExplainPlanSnapshot(
                from: statement,
                subjectQuery: context.subjectQuery
            ) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    func explainPlanRawText(historyId: UUID) -> String? {
        guard !Task.isCancelled, let db else { return nil }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT raw_text FROM query_plan_snapshots WHERE history_id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare explain plan raw text")
            return nil
        }
        QueryHistorySqlBinding.text(historyId.uuidString).bind(to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    func pruneExplainPlanSnapshots(
        toRawByteLimit rawByteLimit: Int64,
        snapshotLimit: Int
    ) -> Bool {
        guard let db else { return false }
        guard let usage = explainPlanStorageUsage() else { return false }
        guard usage.rawBytes > rawByteLimit || usage.snapshotCount > snapshotLimit else { return true }

        let sql = """
            DELETE FROM query_plan_snapshots
             WHERE history_id IN (
                SELECT history_id
                  FROM (
                    SELECT p.history_id,
                           SUM(p.raw_byte_count) OVER (
                               ORDER BY h.executed_at DESC, p.history_id DESC
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                           ) AS retained_bytes,
                           ROW_NUMBER() OVER (
                               ORDER BY h.executed_at DESC, p.history_id DESC
                           ) AS retained_count
                      FROM query_plan_snapshots p
                      JOIN history h ON h.id = p.history_id
                  )
                 WHERE retained_bytes > ? OR retained_count > ?
             );
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare explain plan prune")
            return false
        }
        sqlite3_bind_int64(statement, 1, rawByteLimit)
        sqlite3_bind_int64(statement, 2, Int64(snapshotLimit))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "explain plan prune")
            return false
        }
        return true
    }

    private func explainPlanStorageUsage() -> (rawBytes: Int64, snapshotCount: Int)? {
        guard let db else { return nil }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT COALESCE(SUM(raw_byte_count), 0), COUNT(*) FROM query_plan_snapshots;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare explain plan byte count")
            return nil
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            logSqliteError(context: "explain plan byte count")
            return nil
        }
        return (
            rawBytes: sqlite3_column_int64(statement, 0),
            snapshotCount: Int(sqlite3_column_int64(statement, 1))
        )
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

    private func parseExplainPlanSnapshot(
        from statement: OpaquePointer?,
        subjectQuery: String
    ) -> ExplainPlanHistorySnapshot? {
        guard let statement,
              let historyIdRaw = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let historyId = UUID(uuidString: historyIdRaw),
              let connectionIdRaw = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let connectionId = UUID(uuidString: connectionIdRaw),
              let databaseName = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
              let databaseTypeRaw = sqlite3_column_text(statement, 3).map({ String(cString: $0) }),
              let formatRawValue = sqlite3_column_text(statement, 6).map({ String(cString: $0) })
        else {
            return nil
        }

        let context = ExplainPlanHistoryContext(
            historyId: historyId,
            subjectQuery: subjectQuery,
            connectionId: connectionId,
            databaseName: databaseName,
            databaseType: DatabaseType(rawValue: databaseTypeRaw),
            schemaName: sqlite3_column_text(statement, 4).map { String(cString: $0) },
            variantId: sqlite3_column_text(statement, 5).map { String(cString: $0) },
            formatRawValue: formatRawValue,
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
        return ExplainPlanHistorySnapshot(
            context: context,
            executionTime: sqlite3_column_double(statement, 8)
        )
    }
}
