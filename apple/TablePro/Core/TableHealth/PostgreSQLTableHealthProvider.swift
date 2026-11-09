import Foundation

// scripts/probes/check-table-health-catalogs.sh runs these literals against real servers: keep them free of interpolation.
// Every query leaves out what an extension owns, by relation and by schema: TimescaleDB's chunk tables are not extension
// members themselves, but their schema is, and a fix there would change the extension's own objects.
struct PostgreSQLTableHealthProvider: TableHealthProvider {
    let checks: [TableHealthCheckKind] = [.bloat, .unusedIndex, .missingPrimaryKey, .unindexedForeignKey]

    // The checks that read activity counters, which a standby keeps for its own queries only.
    private static let counterChecks: [TableHealthCheckKind] = [.bloat, .unusedIndex, .staleStatistics]

    static let statisticsQuery = """
        SELECT pg_catalog.current_setting('track_counts') AS track_counts,
               pg_catalog.date_part('epoch', d.stats_reset) AS stats_reset,
               pg_catalog.current_setting('server_version_num') AS server_version_num,
               pg_catalog.pg_is_in_recovery() AS in_recovery
        FROM pg_catalog.pg_stat_database d
        WHERE d.datname = pg_catalog.current_database()
        """

    // The floor keeps tiny tables out. A pg_ schema is another session's temporary one.
    static let bloatQuery = """
        SELECT s.schemaname AS schema_name,
               s.relname AS table_name,
               s.n_live_tup AS live_rows,
               s.n_dead_tup AS dead_rows,
               pg_catalog.date_part('epoch', GREATEST(s.last_vacuum, s.last_autovacuum)) AS last_vacuum,
               pg_catalog.pg_table_size(c.oid) AS table_bytes
        FROM pg_catalog.pg_stat_user_tables s
        JOIN pg_catalog.pg_class c ON c.oid = s.relid
        WHERE c.relkind = 'r'
          AND pg_catalog.left(s.schemaname, 3) <> 'pg_'
          AND s.n_dead_tup >= 1000
          AND s.n_dead_tup >= s.n_live_tup / 5
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = c.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = c.relnamespace
                AND x.deptype = 'e'
          )
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
                        <= COALESCE((pg_catalog.row_to_json(i) OPERATOR(pg_catalog.->>) 'indnkeyatts'::pg_catalog.text)::pg_catalog.int4, i.indnatts)
                    AND (i.indkey::pg_catalog.int2[])[0:pg_catalog.array_length(fk.conkey, 1) - 1] OPERATOR(pg_catalog.@>) fk.conkey
              )
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = t.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = t.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY index_bytes DESC, schema_name, index_name
        """

    // A partition takes its primary key from its parent, so only the parent is listed.
    static let missingPrimaryKeyQuery = """
        SELECT n.nspname AS schema_name,
               c.relname AS table_name,
               GREATEST(c.reltuples, 0)::pg_catalog.int8 AS estimated_rows,
               pg_catalog.pg_table_size(c.oid) AS table_bytes
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
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = c.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = c.relnamespace
                AND x.deptype = 'e'
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
               a.attname AS column_name,
               rn.nspname AS referenced_schema,
               rc.relname AS referenced_table,
               GREATEST(c.reltuples, 0)::pg_catalog.int8 AS estimated_rows,
               pg_catalog.pg_table_size(c.oid) AS table_bytes
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_class rc ON rc.oid = con.confrelid
        JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
        CROSS JOIN LATERAL pg_catalog.unnest(con.conkey) WITH ORDINALITY AS k(attnum, position)
        JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
        WHERE con.contype = 'f'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND COALESCE(pg_catalog.row_to_json(con) OPERATOR(pg_catalog.->>) 'conparentid'::pg_catalog.text, '0') = '0'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_index i
              WHERE i.indrelid = con.conrelid
                AND i.indpred IS NULL
                AND i.indisvalid
                AND pg_catalog.array_length(con.conkey, 1)
                    <= COALESCE((pg_catalog.row_to_json(i) OPERATOR(pg_catalog.->>) 'indnkeyatts'::pg_catalog.text)::pg_catalog.int4, i.indnatts)
                AND (i.indkey::pg_catalog.int2[])[0:pg_catalog.array_length(con.conkey, 1) - 1] OPERATOR(pg_catalog.@>) con.conkey
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = c.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = c.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY n.nspname, c.relname, con.conname, k.position
        """

    var statisticsQueries: [String] { [Self.statisticsQuery] }

    func check(_ kind: TableHealthCheckKind) -> TableHealthCheck {
        switch kind {
        case .bloat:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Tables with at least 1,000 dead rows, and at least 20% as many dead rows as live ones."
            ))
        case .unusedIndex:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Indexes never scanned since the statistics were last reset, leaving out unique, constraint and foreign key indexes."
            ))
        case .missingPrimaryKey:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Tables with no primary key; a partition takes its key from its parent, so only the parent is listed."
            ))
        case .unindexedForeignKey:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Foreign keys whose columns lead no valid, non-partial index, so a delete on the referenced table scans this one."
            ))
        case .redundantIndex, .invalidIndex, .nearLimit, .transactionIdAge, .staleStatistics, .reclaimableSpace:
            return TableHealthCheck(kind: kind, summary: "")
        }
    }

    func queries(for check: TableHealthCheckKind, statistics: TableHealthStatistics) -> [String] {
        switch check {
        case .bloat: return [Self.bloatQuery]
        case .unusedIndex: return [Self.unusedIndexQuery]
        case .missingPrimaryKey: return [Self.missingPrimaryKeyQuery]
        case .unindexedForeignKey: return [Self.unindexedForeignKeyQuery]
        case .redundantIndex, .invalidIndex, .nearLimit, .transactionIdAge, .staleStatistics, .reclaimableSpace:
            return []
        }
    }

    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics {
        guard let result = results.first.flatMap({ $0 }),
              let row = TableHealthRow.rows(of: result).first
        else { return TableHealthStatistics() }

        var statistics = TableHealthStatistics(
            serverVersion: row.int64("server_version_num").map { Int($0) },
            isStandby: row.flag("in_recovery") == true
        )
        let counterChecks = Self.counterChecks.filter(checks.contains)
        func skipCounterChecks(_ reason: String) {
            for kind in counterChecks {
                statistics.skippedChecks[kind] = reason
            }
        }

        if statistics.isStandby {
            statistics.notes.append(String(localized: "This server is a read-only standby. Run the fixes on the primary."))
            skipCounterChecks(String(localized: "This server is a standby. Its activity counters do not reflect the primary."))
        } else if row["track_counts"] == "off" {
            skipCounterChecks(String(localized: "track_counts is off, so the server records no table or index activity."))
        } else if let reset = row.date("stats_reset") {
            statistics.notes.append(String(
                format: String(localized: "Index usage counts since the statistics were last reset at %@."),
                TableHealthFormatting.date(reset)
            ))
        } else {
            statistics.notes.append(
                String(localized: "Index usage counts since the statistics were first collected; they have never been reset.")
            )
        }
        return statistics
    }

    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext,
        statistics: TableHealthStatistics
    ) -> (findings: [TableHealthFinding], note: String?) {
        guard let result = results.first else { return ([], nil) }
        let rows = TableHealthRow.rows(of: result)
        switch check {
        case .bloat:
            return (rows.map { bloatFinding($0, context) }, nil)
        case .unusedIndex:
            return (rows.map { unusedIndexFinding($0, context) }, nil)
        case .missingPrimaryKey:
            return (rows.map { missingPrimaryKeyFinding($0, context) }, nil)
        case .unindexedForeignKey:
            return (unindexedForeignKeyFindings(rows, context), nil)
        case .redundantIndex, .invalidIndex, .nearLimit, .transactionIdAge, .staleStatistics, .reclaimableSpace:
            return ([], nil)
        }
    }

    private func bloatFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        let deadRows = row.int64("dead_rows"), liveRows = row.int64("live_rows")
        let lastVacuum = row.date("last_vacuum")
        let dead = deadRows?.formatted() ?? row["dead_rows"]
        let live = liveRows?.formatted() ?? row["live_rows"]
        let detail = lastVacuum.map {
            String(format: String(localized: "%1$@ dead rows, %2$@ live. Last vacuumed %3$@."), dead, live, TableHealthFormatting.date($0))
        } ?? String(format: String(localized: "%1$@ dead rows, %2$@ live. Never vacuumed."), dead, live)

        var metrics: [TableHealthMetric] = []
        if let deadRows {
            metrics.append(TableHealthMetric(id: "dead_rows", label: String(localized: "Dead Rows"), value: .count(deadRows)))
        }
        if let liveRows {
            metrics.append(TableHealthMetric(id: "live_rows", label: String(localized: "Live Rows"), value: .count(liveRows)))
        }
        if let deadRows, let liveRows, Double(deadRows) + Double(liveRows) > 0 {
            let share = Double(deadRows) / (Double(deadRows) + Double(liveRows))
            metrics.append(TableHealthMetric(id: "dead_percent", label: String(localized: "Dead Row Share"), value: .percent(share)))
        }
        if let lastVacuum {
            metrics.append(TableHealthMetric(id: "last_vacuum", label: String(localized: "Last Vacuum"), value: .date(lastVacuum)))
        }
        return TableHealthFinding(
            kind: .bloat, schema: schema, table: table, objectName: nil, detail: detail,
            sizeBytes: row.int64("table_bytes"), metrics: metrics,
            fixSQL: "VACUUM (ANALYZE) \(context.qualified(schema, table));"
        )
    }

    private func unusedIndexFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], index = row["index_name"]
        let size = ByteSizeFormatting.string(byteString: row["index_bytes"])
        return TableHealthFinding(
            kind: .unusedIndex, schema: schema, table: row["table_name"], objectName: index,
            detail: String(format: String(localized: "%1$@ has never been scanned. It takes %2$@."), index, size),
            sizeBytes: row.int64("index_bytes"),
            fixSQL: "DROP INDEX CONCURRENTLY \(context.qualified(schema, index));"
        )
    }

    private func missingPrimaryKeyFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        return TableHealthFinding(
            kind: .missingPrimaryKey, schema: schema, table: table, objectName: nil,
            detail: String(localized: "No primary key. Replace column_name with the columns that identify a row."),
            sizeBytes: row.int64("table_bytes"),
            metrics: row.int64("estimated_rows").map { [TableHealthMetric.estimatedRows($0)] } ?? [],
            fixSQL: "ALTER TABLE \(context.qualified(schema, table)) ADD PRIMARY KEY (column_name);"
        )
    }

    private struct ForeignKey {
        let schema: String
        let table: String
        let isPartitioned: Bool
        let constraint: String
        var columns: [String]
        let referencedTable: String?
        let estimatedRows: Int64?
        let tableBytes: Int64?
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
                let referenced = [row["referenced_schema"], row["referenced_table"]].filter { !$0.isEmpty }
                keys.append(ForeignKey(
                    schema: schema, table: table, isPartitioned: row["table_kind"] == "p",
                    constraint: constraint, columns: [row["column_name"]],
                    referencedTable: referenced.isEmpty ? nil : referenced.joined(separator: "."),
                    estimatedRows: row.int64("estimated_rows"),
                    tableBytes: row.int64("table_bytes")
                ))
            }
        }
        return keys.map { key in
            let columnList = key.columns.map(context.quote).joined(separator: ", ")
            // PostgreSQL cannot build an index on a partitioned table concurrently.
            let create = key.isPartitioned ? "CREATE INDEX" : "CREATE INDEX CONCURRENTLY"
            var metrics = [
                TableHealthMetric(id: "columns", label: String(localized: "Columns"), value: .text(key.columns.joined(separator: ", ")))
            ]
            if let referenced = key.referencedTable {
                metrics.append(TableHealthMetric(
                    id: "referenced_table", label: String(localized: "Referenced Table"), value: .text(referenced)
                ))
            }
            if let rows = key.estimatedRows {
                metrics.append(.estimatedRows(rows))
            }
            return TableHealthFinding(
                kind: .unindexedForeignKey, schema: key.schema, table: key.table, objectName: key.constraint,
                detail: String(
                    format: String(localized: "%1$@ on (%2$@) has no index, so deletes and updates on the referenced table scan this one."),
                    key.constraint,
                    key.columns.joined(separator: ", ")
                ),
                sizeBytes: key.tableBytes,
                metrics: metrics,
                fixSQL: "\(create) ON \(context.qualified(key.schema, key.table)) (\(columnList));"
            )
        }
    }
}
