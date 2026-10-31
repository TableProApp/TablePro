//
//  PostgreSQLTableHealthProvider.swift
//  TablePro
//

import Foundation

/// Reads the current database. `scripts/probes/check-table-health-catalogs.sh` runs these queries
/// against a real server, so keep each one a plain literal with no interpolation.
struct PostgreSQLTableHealthProvider: TableHealthProvider {
    let checks: [TableHealthCheckKind] = [.bloat, .unusedIndex, .missingPrimaryKey, .unindexedForeignKey]
    let schemaNamesDatabase = false

    // Autovacuum's own trigger is 20% dead rows plus 50; the floor keeps tiny tables out.
    static let bloatQuery = """
        SELECT schemaname AS schema_name,
               relname AS table_name,
               n_live_tup AS live_rows,
               n_dead_tup AS dead_rows,
               pg_catalog.date_trunc('second', GREATEST(last_vacuum, last_autovacuum))::pg_catalog.text AS last_vacuum
        FROM pg_catalog.pg_stat_user_tables
        WHERE n_dead_tup >= 1000 AND n_dead_tup >= n_live_tup / 5
        ORDER BY n_dead_tup DESC, schemaname, relname
        LIMIT 500
        """

    // A unique or constraint index enforces something even when no query reads it.
    static let unusedIndexQuery = """
        SELECT s.schemaname AS schema_name,
               s.relname AS table_name,
               s.indexrelname AS index_name,
               pg_catalog.pg_relation_size(s.indexrelid) AS index_bytes
        FROM pg_catalog.pg_stat_user_indexes s
        JOIN pg_catalog.pg_index i ON i.indexrelid = s.indexrelid
        WHERE s.idx_scan = 0
          AND NOT i.indisunique
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c WHERE c.conindid = s.indexrelid)
        ORDER BY index_bytes DESC, schema_name, index_name
        LIMIT 500
        """

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
        ORDER BY n.nspname, c.relname
        LIMIT 500
        """

    // One row per referencing column. An index covers the key when its leading key columns are the
    // key's columns in any order. A partial or invalid index does not, and neither does an INCLUDE
    // column, which is stored but not searchable; indnkeyatts is read through row_to_json because
    // servers before 11 have no such column.
    static let unindexedForeignKeyQuery = """
        SELECT n.nspname AS schema_name,
               c.relname AS table_name,
               con.conname AS constraint_name,
               a.attname AS column_name
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL pg_catalog.unnest(con.conkey) WITH ORDINALITY AS k(attnum, position)
        JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
        WHERE con.contype = 'f'
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

    static let statisticsResetQuery = """
        SELECT pg_catalog.date_trunc('second', stats_reset)::pg_catalog.text AS stats_reset
        FROM pg_catalog.pg_stat_database
        WHERE datname = pg_catalog.current_database()
        """

    static let databaseNameQuery = "SELECT pg_catalog.current_database() AS database_name"

    var statisticsQueries: [String] { [Self.statisticsResetQuery] }

    var databaseQuery: String? { Self.databaseNameQuery }

    func query(for check: TableHealthCheckKind) -> String {
        switch check {
        case .bloat: return Self.bloatQuery
        case .unusedIndex: return Self.unusedIndexQuery
        case .missingPrimaryKey: return Self.missingPrimaryKeyQuery
        case .unindexedForeignKey: return Self.unindexedForeignKeyQuery
        case .redundantIndex: return ""
        }
    }

    func findings(for check: TableHealthCheckKind, from result: QueryResult) -> [TableHealthFinding] {
        let rows = TableHealthRow.rows(of: result)
        switch check {
        case .bloat:
            return rows.map(bloatFinding)
        case .unusedIndex:
            return rows.map(unusedIndexFinding)
        case .missingPrimaryKey:
            return rows.map(missingPrimaryKeyFinding)
        case .unindexedForeignKey:
            return unindexedForeignKeyFindings(rows)
        case .redundantIndex:
            return []
        }
    }

    func statisticsNote(from results: [QueryResult], now: Date) -> String? {
        guard let result = results.first, let row = TableHealthRow.rows(of: result).first else { return nil }
        let reset = row["stats_reset"]
        guard !reset.isEmpty else {
            return String(localized: "Index usage counts since the statistics were first collected; they have never been reset.")
        }
        return String(format: String(localized: "Index usage counts since the statistics were last reset at %@."), reset)
    }

    // MARK: - Fix SQL

    static func vacuumSQL(schema: String, table: String) -> String {
        "VACUUM (ANALYZE) \(qualified(schema, table));"
    }

    static func dropIndexSQL(schema: String, index: String) -> String {
        "DROP INDEX CONCURRENTLY \(qualified(schema, index));"
    }

    static func addPrimaryKeySQL(schema: String, table: String) -> String {
        "ALTER TABLE \(qualified(schema, table)) ADD PRIMARY KEY (column_name);"
    }

    static func createIndexSQL(schema: String, table: String, columns: [String]) -> String {
        let columnList = columns.map(SQLEscaping.quoteIdentifier).joined(separator: ", ")
        return "CREATE INDEX CONCURRENTLY ON \(qualified(schema, table)) (\(columnList));"
    }

    private static func qualified(_ schema: String, _ name: String) -> String {
        "\(SQLEscaping.quoteIdentifier(schema)).\(SQLEscaping.quoteIdentifier(name))"
    }

    // MARK: - Parsing

    private func bloatFinding(_ row: TableHealthRow) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        let dead = TableHealthFormatting.count(row["dead_rows"])
        let live = TableHealthFormatting.count(row["live_rows"])
        let lastVacuum = row["last_vacuum"]
        let detail = lastVacuum.isEmpty
            ? String(format: String(localized: "%1$@ dead rows, %2$@ live. Never vacuumed."), dead, live)
            : String(format: String(localized: "%1$@ dead rows, %2$@ live. Last vacuumed %3$@."), dead, live, lastVacuum)
        return TableHealthFinding(
            kind: .bloat, schema: schema, table: table, objectName: nil,
            detail: detail, fixSQL: Self.vacuumSQL(schema: schema, table: table)
        )
    }

    private func unusedIndexFinding(_ row: TableHealthRow) -> TableHealthFinding {
        let schema = row["schema_name"], index = row["index_name"]
        let size = ByteSizeFormatting.string(byteString: row["index_bytes"])
        return TableHealthFinding(
            kind: .unusedIndex, schema: schema, table: row["table_name"], objectName: index,
            detail: String(format: String(localized: "%1$@ has never been scanned. It takes %2$@."), index, size),
            fixSQL: Self.dropIndexSQL(schema: schema, index: index)
        )
    }

    private func missingPrimaryKeyFinding(_ row: TableHealthRow) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        return TableHealthFinding(
            kind: .missingPrimaryKey, schema: schema, table: table, objectName: nil,
            detail: String(localized: "No primary key. Replace column_name with the columns that identify a row."),
            fixSQL: Self.addPrimaryKeySQL(schema: schema, table: table)
        )
    }

    private func unindexedForeignKeyFindings(_ rows: [TableHealthRow]) -> [TableHealthFinding] {
        var order: [String] = []
        var grouped: [String: (schema: String, table: String, constraint: String, columns: [String])] = [:]
        for row in rows {
            let key = [row["schema_name"], row["table_name"], row["constraint_name"]].joined(separator: "\u{1F}")
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (row["schema_name"], row["table_name"], row["constraint_name"], [])
            }
            grouped[key]?.columns.append(row["column_name"])
        }
        return order.prefix(TableHealthCheckResult.findingLimit).compactMap { key in
            guard let key = grouped[key] else { return nil }
            return TableHealthFinding(
                kind: .unindexedForeignKey, schema: key.schema, table: key.table, objectName: key.constraint,
                detail: String(
                    format: String(localized: "%1$@ on (%2$@) has no index, so deletes and updates on the referenced table scan this one."),
                    key.constraint,
                    key.columns.joined(separator: ", ")
                ),
                fixSQL: Self.createIndexSQL(schema: key.schema, table: key.table, columns: key.columns)
            )
        }
    }
}

enum TableHealthFormatting {
    static func count(_ text: String) -> String {
        guard let value = Int64(text) else { return text }
        return value.formatted()
    }
}
