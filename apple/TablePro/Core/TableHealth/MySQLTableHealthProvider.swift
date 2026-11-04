import Foundation

// InnoDB indexes a foreign key's columns itself, so there is no unindexed foreign key check.
// scripts/probes/check-table-health-catalogs.sh runs these literals against real servers: keep them free of interpolation.
struct MySQLTableHealthProvider: TableHealthProvider {
    let checks: [TableHealthCheckKind] = [.unusedIndex, .redundantIndex, .missingPrimaryKey]

    static let performanceSchemaQuery = "SELECT @@GLOBAL.performance_schema AS performance_schema"

    static let uptimeQuery = "SHOW GLOBAL STATUS LIKE 'Uptime'"

    // Each of these stops index reads being counted with Performance Schema on: the handler
    // instrument, the global consumer, or setup_objects and setup_actors leaving this database out.
    static let usageCountingQuery = """
        SELECT (SELECT i.ENABLED FROM performance_schema.setup_instruments i
                WHERE i.NAME = 'wait/io/table/sql/handler') AS table_io_instrument,
               (SELECT c.ENABLED FROM performance_schema.setup_consumers c
                WHERE c.NAME = 'global_instrumentation') AS global_instrumentation,
               (SELECT COUNT(*) FROM performance_schema.table_io_waits_summary_by_table t
                WHERE t.OBJECT_SCHEMA = DATABASE() AND t.COUNT_STAR > 0) AS counted_tables
        """

    // The table sys.schema_unused_indexes reads; MariaDB before 10.6 has no sys schema. A table
    // setup_objects leaves out keeps its index rows at zero, so only a table with counted I/O counts.
    static let unusedIndexQuery = """
        SELECT u.OBJECT_NAME AS table_name,
               u.INDEX_NAME AS index_name
        FROM performance_schema.table_io_waits_summary_by_index_usage u
        WHERE u.OBJECT_SCHEMA = DATABASE()
          AND u.INDEX_NAME IS NOT NULL
          AND u.INDEX_NAME <> 'PRIMARY'
          AND u.COUNT_STAR = 0
          AND EXISTS (
              SELECT 1 FROM performance_schema.table_io_waits_summary_by_table t
              WHERE t.OBJECT_TYPE = u.OBJECT_TYPE
                AND t.OBJECT_SCHEMA = u.OBJECT_SCHEMA
                AND t.OBJECT_NAME = u.OBJECT_NAME
                AND t.COUNT_STAR > 0
          )
        ORDER BY u.OBJECT_NAME, u.INDEX_NAME
        """

    // Every column, so MySQL 8's IS_VISIBLE and MariaDB 10.6's IGNORED come back where the server has them.
    static let indexQuery = """
        SELECT *
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
        ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
        """

    // Both ends, from any database: InnoDB checks a key through an index on each side, and MariaDB
    // lets the referenced one be non-unique.
    static let foreignKeyQuery = """
        SELECT k.TABLE_SCHEMA AS table_schema,
               k.TABLE_NAME AS table_name,
               k.CONSTRAINT_NAME AS constraint_name,
               k.COLUMN_NAME AS column_name,
               k.REFERENCED_TABLE_NAME AS referenced_table_name,
               k.REFERENCED_COLUMN_NAME AS referenced_column_name,
               k.ORDINAL_POSITION AS ordinal_position,
               k.TABLE_SCHEMA = DATABASE() AS is_local,
               k.REFERENCED_TABLE_SCHEMA = DATABASE() AS references_here
        FROM information_schema.KEY_COLUMN_USAGE k
        WHERE k.REFERENCED_TABLE_NAME IS NOT NULL
          AND (k.TABLE_SCHEMA = DATABASE() OR k.REFERENCED_TABLE_SCHEMA = DATABASE())
        ORDER BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
        """

    // MariaDB lists a system-versioned table under its own type.
    static let missingPrimaryKeyQuery = """
        SELECT t.TABLE_NAME AS table_name
        FROM information_schema.TABLES t
        WHERE t.TABLE_SCHEMA = DATABASE()
          AND t.TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED')
          AND NOT EXISTS (
              SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c
              WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA
                AND c.TABLE_NAME = t.TABLE_NAME
                AND c.CONSTRAINT_TYPE = 'PRIMARY KEY'
          )
        ORDER BY t.TABLE_NAME
        """

    var statisticsQueries: [String] {
        [Self.performanceSchemaQuery, Self.uptimeQuery, Self.usageCountingQuery]
    }

    func queries(for check: TableHealthCheckKind) -> [String] {
        switch check {
        case .unusedIndex: return [Self.unusedIndexQuery, Self.indexQuery, Self.foreignKeyQuery]
        case .redundantIndex: return [Self.indexQuery]
        case .missingPrimaryKey: return [Self.missingPrimaryKeyQuery]
        case .bloat, .unindexedForeignKey: return []
        }
    }

    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics {
        func value(_ position: Int, _ column: String) -> String? {
            guard position < results.count, let result = results[position] else { return nil }
            return TableHealthRow.rows(of: result).first?[column]
        }
        func skippingUnused(_ reason: String) -> TableHealthStatistics {
            TableHealthStatistics(skippedChecks: [.unusedIndex: reason])
        }

        if let enabled = value(0, "performance_schema"), enabled != "1", enabled.uppercased() != "ON" {
            return skippingUnused(String(localized: "Performance Schema is off, so the server records no index reads."))
        }
        if value(2, "table_io_instrument") == "NO" {
            return skippingUnused(String(localized: "The wait/io/table/sql/handler instrument is disabled, so the server records no index reads."))
        }
        if value(2, "global_instrumentation") == "NO" {
            return skippingUnused(String(localized: "The global_instrumentation consumer is disabled, so the server records no index reads."))
        }
        if value(2, "counted_tables") == "0" {
            return skippingUnused(String(
                localized: "No table in this database has a recorded read or write since the server started, so an unread index cannot be told from an uncounted one."
            ))
        }

        guard let uptime = value(1, "value").flatMap(Double.init) else { return TableHealthStatistics() }
        let start = now.addingTimeInterval(-uptime).formatted(date: .abbreviated, time: .shortened)
        return TableHealthStatistics(
            note: String(format: String(localized: "Index usage counts since the server started at %@."), start)
        )
    }

    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext
    ) -> [TableHealthFinding] {
        switch check {
        case .unusedIndex:
            guard results.count == 3 else { return [] }
            return unusedIndexFindings(
                candidates: TableHealthRow.rows(of: results[0]),
                tables: MySQLIndexShape.tables(from: TableHealthRow.rows(of: results[1])),
                foreignKeys: MySQLIndexShape.foreignKeys(from: TableHealthRow.rows(of: results[2])),
                context: context
            )
        case .redundantIndex:
            guard let result = results.first else { return [] }
            return redundantIndexFindings(MySQLIndexShape.tables(from: TableHealthRow.rows(of: result)), context)
        case .missingPrimaryKey:
            guard let result = results.first else { return [] }
            return TableHealthRow.rows(of: result).map { missingPrimaryKeyFinding($0["table_name"], context) }
        case .bloat, .unindexedForeignKey:
            return []
        }
    }

    // A unique index enforces something no read counts, and a MATCH search reads a full-text index
    // uncounted. InnoDB checks a foreign key through an index that leads with its columns on either
    // end without counting a read, and refuses to drop the last one.
    private func unusedIndexFindings(
        candidates: [TableHealthRow],
        tables: [MySQLIndexShape],
        foreignKeys: [String: [[String]]],
        context: TableHealthQueryContext
    ) -> [TableHealthFinding] {
        let shapes = Dictionary(tables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.compactMap { row in
            let table = row["table_name"], indexName = row["index_name"]
            guard let index = shapes[table]?.indexes.first(where: { $0.name == indexName }),
                  !index.isUnique,
                  index.type != "FULLTEXT",
                  !(foreignKeys[table] ?? []).contains(where: index.serves)
            else { return nil }
            return TableHealthFinding(
                kind: .unusedIndex, schema: nil, table: table, objectName: indexName,
                detail: String(format: String(localized: "%@ has no recorded reads."), indexName),
                fixSQL: dropIndexSQL(table: table, index: indexName, context)
            )
        }
    }

    private func redundantIndexFindings(
        _ tables: [MySQLIndexShape],
        _ context: TableHealthQueryContext
    ) -> [TableHealthFinding] {
        var findings: [TableHealthFinding] = []
        for table in tables {
            for index in table.indexes {
                guard let dominant = table.indexes.first(where: { index.isRedundant(to: $0) }) else { continue }
                findings.append(TableHealthFinding(
                    kind: .redundantIndex, schema: nil, table: table.name, objectName: index.name,
                    detail: String(format: String(localized: "%1$@ is covered by %2$@."), index.name, dominant.name),
                    fixSQL: dropIndexSQL(table: table.name, index: index.name, context)
                ))
            }
        }
        return findings
    }

    private func missingPrimaryKeyFinding(_ table: String, _ context: TableHealthQueryContext) -> TableHealthFinding {
        TableHealthFinding(
            kind: .missingPrimaryKey, schema: nil, table: table, objectName: nil,
            detail: String(localized: "No primary key. Replace column_name with the columns that identify a row."),
            fixSQL: "ALTER TABLE \(context.qualified(context.database, table)) ADD PRIMARY KEY (column_name);"
        )
    }

    private func dropIndexSQL(table: String, index: String, _ context: TableHealthQueryContext) -> String {
        "ALTER TABLE \(context.qualified(context.database, table)) DROP INDEX \(context.quote(index));"
    }
}

// The indexes of one table, from information_schema.STATISTICS rows ordered by table, index and position.
struct MySQLIndexShape {
    struct Column: Equatable {
        let name: String
        let prefixLength: String
        let sortOrder: String
    }

    struct Index {
        let name: String
        let isUnique: Bool
        let type: String
        // An invisible (MySQL) or ignored (MariaDB) index serves no query.
        let isVisible: Bool
        var columns: [Column]
        // A functional key part has no column name and cannot be compared by prefix.
        var hasExpression: Bool

        var isPrimary: Bool { name == "PRIMARY" }

        // Only a B-tree serves a lookup on its leading columns, so another type is redundant only
        // to an identical index. A full-text index never is: STATISTICS does not name its parser.
        // Of two equal indexes the unique one stays, else the first by name.
        func isRedundant(to other: Index) -> Bool {
            guard other.name != name, other.isVisible, type != "FULLTEXT", !isPrimary, !hasExpression, !other.hasExpression,
                  other.type == type, columns.count <= other.columns.count,
                  type == "BTREE" || columns.count == other.columns.count,
                  Array(other.columns.prefix(columns.count)) == columns
            else { return false }
            if columns.count < other.columns.count { return !isUnique }
            if isUnique != other.isUnique { return other.isUnique }
            return other.isPrimary || other.name < name
        }

        // InnoDB needs the key's columns first, in order, and whole.
        func serves(foreignKey keyColumns: [String]) -> Bool {
            guard !hasExpression, columns.count >= keyColumns.count else { return false }
            return zip(columns, keyColumns).allSatisfy { column, key in
                column.prefixLength.isEmpty && column.name.lowercased() == key.lowercased()
            }
        }
    }

    let name: String
    var indexes: [Index]

    // Grouped by exact name and ordered by position: the catalog sorts names without case, so on a
    // case-sensitive server the rows of `Orders` and `orders` can interleave.
    static func tables(from rows: [TableHealthRow]) -> [MySQLIndexShape] {
        var tables: [MySQLIndexShape] = []
        var tablePositions: [String: Int] = [:]
        var keyParts: [String: [(position: Int, column: Column?)]] = [:]
        for row in rows {
            let table = row["table_name"], indexName = row["index_name"]
            let tablePosition: Int
            if let known = tablePositions[table] {
                tablePosition = known
            } else {
                tablePosition = tables.count
                tablePositions[table] = tablePosition
                tables.append(MySQLIndexShape(name: table, indexes: []))
            }
            if !tables[tablePosition].indexes.contains(where: { $0.name == indexName }) {
                tables[tablePosition].indexes.append(Index(
                    name: indexName,
                    isUnique: row["non_unique"] == "0",
                    type: row["index_type"],
                    isVisible: row["is_visible"] != "NO" && row["ignored"] != "YES",
                    columns: [],
                    hasExpression: false
                ))
            }
            let column = row["column_name"]
            keyParts[table + "\u{1F}" + indexName, default: []].append((
                Int(row["seq_in_index"]) ?? 0,
                column.isEmpty ? nil : Column(name: column, prefixLength: row["sub_part"], sortOrder: row["collation"])
            ))
        }
        for tablePosition in tables.indices {
            let table = tables[tablePosition].name
            for indexPosition in tables[tablePosition].indexes.indices {
                let parts = (keyParts[table + "\u{1F}" + tables[tablePosition].indexes[indexPosition].name] ?? [])
                    .sorted { $0.position < $1.position }
                tables[tablePosition].indexes[indexPosition].hasExpression = parts.contains { $0.column == nil }
                tables[tablePosition].indexes[indexPosition].columns = parts.compactMap(\.column)
            }
        }
        return tables
    }

    // Per table of this database, the columns each foreign key reads through it, on the referencing
    // or the referenced end, in key order. Grouped by exact name, like the index rows.
    static func foreignKeys(from rows: [TableHealthRow]) -> [String: [[String]]] {
        struct Key {
            let isLocal: Bool
            let referencesHere: Bool
            let table: String
            let referencedTable: String
            var parts: [(position: Int, column: String, referencedColumn: String)]
        }
        var keys: [Key] = []
        var keyPositions: [String: Int] = [:]
        for row in rows {
            let identity = [row["table_schema"], row["table_name"], row["constraint_name"]].joined(separator: "\u{1F}")
            let part = (Int(row["ordinal_position"]) ?? 0, row["column_name"], row["referenced_column_name"])
            if let known = keyPositions[identity] {
                keys[known].parts.append(part)
            } else {
                keyPositions[identity] = keys.count
                keys.append(Key(
                    isLocal: row["is_local"] == "1", referencesHere: row["references_here"] == "1",
                    table: row["table_name"], referencedTable: row["referenced_table_name"], parts: [part]
                ))
            }
        }
        var byTable: [String: [[String]]] = [:]
        for key in keys {
            let parts = key.parts.sorted { $0.position < $1.position }
            if key.isLocal {
                byTable[key.table, default: []].append(parts.map(\.column))
            }
            if key.referencesHere {
                byTable[key.referencedTable, default: []].append(parts.map(\.referencedColumn))
            }
        }
        return byTable
    }
}
