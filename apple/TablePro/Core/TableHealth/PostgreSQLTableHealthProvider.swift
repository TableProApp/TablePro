import Foundation

// scripts/probes/check-table-health-catalogs.sh runs these literals against real servers: keep them free of interpolation.
struct PostgreSQLTableHealthProvider: TableHealthProvider {
    let checks: [TableHealthCheckKind] = [.bloat, .unusedIndex, .missingPrimaryKey, .unindexedForeignKey]

    static let statisticsQuery = """
        SELECT pg_catalog.current_setting('track_counts') AS track_counts,
               pg_catalog.date_trunc('second', d.stats_reset)::pg_catalog.text AS stats_reset
        FROM pg_catalog.pg_stat_database d
        WHERE d.datname = pg_catalog.current_database()
        """

    // Autovacuum's own trigger is 20% dead rows plus 50; the floor keeps tiny tables out. A pg_
    // schema is another session's temporary one.
    static let bloatQuery = """
        SELECT s.schemaname AS schema_name,
               s.relname AS table_name,
               s.n_live_tup AS live_rows,
               s.n_dead_tup AS dead_rows,
               pg_catalog.date_trunc('second', GREATEST(s.last_vacuum, s.last_autovacuum))::pg_catalog.text AS last_vacuum
        FROM pg_catalog.pg_stat_user_tables s
        JOIN pg_catalog.pg_class c ON c.oid = s.relid
        WHERE c.relkind = 'r'
          AND pg_catalog.left(s.schemaname, 3) <> 'pg_'
          AND s.n_dead_tup >= 1000
          AND s.n_dead_tup >= s.n_live_tup / 5
        ORDER BY s.n_dead_tup DESC, s.schemaname, s.relname
        """

    // A unique or constraint index enforces something no scan counts, an index a foreign key's
    // checks use is needed the first time the referenced table deletes, and a partition's index
    // that a parent index owns cannot be dropped alone. The foreign key test is the one
    // unindexedForeignKeyQuery uses.
    static let unusedIndexQuery = """
        SELECT s.schemaname AS schema_name,
               s.relname AS table_name,
               s.indexrelname AS index_name,
               pg_catalog.pg_relation_size(s.indexrelid) AS index_bytes
        FROM pg_catalog.pg_stat_user_indexes s
        JOIN pg_catalog.pg_index i ON i.indexrelid = s.indexrelid
        JOIN pg_catalog.pg_class t ON t.oid = s.relid
        WHERE s.idx_scan = 0
          AND t.relkind = 'r'
          AND pg_catalog.left(s.schemaname, 3) <> 'pg_'
          AND NOT i.indisunique
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c WHERE c.conindid = s.indexrelid)
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid = s.indexrelid)
          AND NOT (
              i.indpred IS NULL
              AND i.indisvalid
              AND EXISTS (
                  SELECT 1 FROM pg_catalog.pg_constraint fk
                  WHERE fk.contype = 'f'
                    AND fk.conrelid = i.indrelid
                    AND pg_catalog.array_length(fk.conkey, 1)
                        <= COALESCE((pg_catalog.row_to_json(i) ->> 'indnkeyatts')::pg_catalog.int4, i.indnatts)
                    AND (i.indkey::pg_catalog.int2[])[0:pg_catalog.array_length(fk.conkey, 1) - 1] @> fk.conkey
              )
          )
        ORDER BY index_bytes DESC, schema_name, index_name
        """

    // A partition takes its primary key from its parent, so only the parent is listed.
    static let missingPrimaryKeyQuery = """
        SELECT n.nspname AS schema_name,
               c.relname AS table_name
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname <> 'information_schema'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_constraint con
              WHERE con.conrelid = c.oid AND con.contype = 'p'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_inherits h
              JOIN pg_catalog.pg_class p ON p.oid = h.inhparent
              WHERE h.inhrelid = c.oid AND p.relkind = 'p'
          )
        ORDER BY n.nspname, c.relname
        """

    // One row per referencing column. An index covers the key when its leading key columns are the
    // key's columns in any order; a partial or invalid index does not, nor does an INCLUDE column.
    // A partition's clone of its parent's key (conparentid) is left to the parent's finding.
    // indnkeyatts and conparentid go through row_to_json because servers before 11 lack them.
    static let unindexedForeignKeyQuery = """
        SELECT n.nspname AS schema_name,
               c.relname AS table_name,
               c.relkind AS table_kind,
               con.conname AS constraint_name,
               a.attname AS column_name
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL pg_catalog.unnest(con.conkey) WITH ORDINALITY AS k(attnum, position)
        JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
        WHERE con.contype = 'f'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND COALESCE(pg_catalog.row_to_json(con) ->> 'conparentid', '0') = '0'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_index i
              WHERE i.indrelid = con.conrelid
                AND i.indpred IS NULL
                AND i.indisvalid
                AND pg_catalog.array_length(con.conkey, 1)
                    <= COALESCE((pg_catalog.row_to_json(i) ->> 'indnkeyatts')::pg_catalog.int4, i.indnatts)
                AND (i.indkey::pg_catalog.int2[])[0:pg_catalog.array_length(con.conkey, 1) - 1] @> con.conkey
          )
        ORDER BY n.nspname, c.relname, con.conname, k.position
        """

    var statisticsQueries: [String] { [Self.statisticsQuery] }

    func queries(for check: TableHealthCheckKind) -> [String] {
        switch check {
        case .bloat: return [Self.bloatQuery]
        case .unusedIndex: return [Self.unusedIndexQuery]
        case .missingPrimaryKey: return [Self.missingPrimaryKeyQuery]
        case .unindexedForeignKey: return [Self.unindexedForeignKeyQuery]
        case .redundantIndex: return []
        }
    }

    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics {
        guard let result = results.first.flatMap({ $0 }),
              let row = TableHealthRow.rows(of: result).first
        else { return TableHealthStatistics() }

        if row["track_counts"] == "off" {
            let reason = String(localized: "track_counts is off, so the server records no table or index activity.")
            return TableHealthStatistics(skippedChecks: [.bloat: reason, .unusedIndex: reason])
        }
        let reset = row["stats_reset"]
        guard !reset.isEmpty else {
            return TableHealthStatistics(
                note: String(localized: "Index usage counts since the statistics were first collected; they have never been reset.")
            )
        }
        return TableHealthStatistics(
            note: String(format: String(localized: "Index usage counts since the statistics were last reset at %@."), reset)
        )
    }

    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext
    ) -> [TableHealthFinding] {
        guard let result = results.first else { return [] }
        let rows = TableHealthRow.rows(of: result)
        switch check {
        case .bloat:
            return rows.map { bloatFinding($0, context) }
        case .unusedIndex:
            return rows.map { unusedIndexFinding($0, context) }
        case .missingPrimaryKey:
            return rows.map { missingPrimaryKeyFinding($0, context) }
        case .unindexedForeignKey:
            return unindexedForeignKeyFindings(rows, context)
        case .redundantIndex:
            return []
        }
    }

    private func bloatFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        let dead = TableHealthFormatting.count(row["dead_rows"])
        let live = TableHealthFormatting.count(row["live_rows"])
        let lastVacuum = row["last_vacuum"]
        let detail = lastVacuum.isEmpty
            ? String(format: String(localized: "%1$@ dead rows, %2$@ live. Never vacuumed."), dead, live)
            : String(format: String(localized: "%1$@ dead rows, %2$@ live. Last vacuumed %3$@."), dead, live, lastVacuum)
        return TableHealthFinding(
            kind: .bloat, schema: schema, table: table, objectName: nil, detail: detail,
            fixSQL: "VACUUM (ANALYZE) \(context.qualified(schema, table));"
        )
    }

    private func unusedIndexFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], index = row["index_name"]
        let size = ByteSizeFormatting.string(byteString: row["index_bytes"])
        return TableHealthFinding(
            kind: .unusedIndex, schema: schema, table: row["table_name"], objectName: index,
            detail: String(format: String(localized: "%1$@ has never been scanned. It takes %2$@."), index, size),
            fixSQL: "DROP INDEX CONCURRENTLY \(context.qualified(schema, index));"
        )
    }

    private func missingPrimaryKeyFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        return TableHealthFinding(
            kind: .missingPrimaryKey, schema: schema, table: table, objectName: nil,
            detail: String(localized: "No primary key. Replace column_name with the columns that identify a row."),
            fixSQL: "ALTER TABLE \(context.qualified(schema, table)) ADD PRIMARY KEY (column_name);"
        )
    }

    private struct ForeignKey {
        let schema: String
        let table: String
        let isPartitioned: Bool
        let constraint: String
        var columns: [String]
    }

    private func unindexedForeignKeyFindings(
        _ rows: [TableHealthRow],
        _ context: TableHealthQueryContext
    ) -> [TableHealthFinding] {
        var keys: [ForeignKey] = []
        for row in rows {
            let schema = row["schema_name"], table = row["table_name"], constraint = row["constraint_name"]
            if let last = keys.last, last.schema == schema, last.table == table, last.constraint == constraint {
                keys[keys.count - 1].columns.append(row["column_name"])
            } else {
                keys.append(ForeignKey(
                    schema: schema, table: table, isPartitioned: row["table_kind"] == "p",
                    constraint: constraint, columns: [row["column_name"]]
                ))
            }
        }
        return keys.map { key in
            let columnList = key.columns.map(context.quote).joined(separator: ", ")
            // PostgreSQL cannot build an index on a partitioned table concurrently.
            let create = key.isPartitioned ? "CREATE INDEX" : "CREATE INDEX CONCURRENTLY"
            return TableHealthFinding(
                kind: .unindexedForeignKey, schema: key.schema, table: key.table, objectName: key.constraint,
                detail: String(
                    format: String(localized: "%1$@ on (%2$@) has no index, so deletes and updates on the referenced table scan this one."),
                    key.constraint,
                    key.columns.joined(separator: ", ")
                ),
                fixSQL: "\(create) ON \(context.qualified(key.schema, key.table)) (\(columnList));"
            )
        }
    }
}
