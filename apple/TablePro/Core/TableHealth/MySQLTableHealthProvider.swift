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

    // The table sys.schema_unused_indexes reads; MariaDB before 10.6 has no sys schema.
    static let unusedIndexQuery = """
        SELECT u.OBJECT_NAME AS table_name,
               u.INDEX_NAME AS index_name
        FROM performance_schema.table_io_waits_summary_by_index_usage u
        WHERE u.OBJECT_SCHEMA = DATABASE()
          AND u.INDEX_NAME IS NOT NULL
          AND u.INDEX_NAME <> 'PRIMARY'
          AND u.COUNT_STAR = 0
        ORDER BY u.OBJECT_NAME, u.INDEX_NAME
        """

    // Every column, so MySQL 8's IS_VISIBLE and MariaDB 10.6's IGNORED come back where the server has them.
    static let indexQuery = """
        SELECT *
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
        ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
        """

    static let foreignKeyQuery = """
        SELECT k.TABLE_NAME AS table_name,
               k.CONSTRAINT_NAME AS constraint_name,
               k.COLUMN_NAME AS column_name
        FROM information_schema.KEY_COLUMN_USAGE k
        WHERE k.TABLE_SCHEMA = DATABASE()
          AND k.REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
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

    // A unique index enforces something no read counts. InnoDB checks a foreign key through the
    // index that leads with its columns without counting a read, and refuses to drop the last one.
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
        // to an identical index. Of two equal indexes the unique one stays, else the first by name.
        func isRedundant(to other: Index) -> Bool {
            guard other.name != name, other.isVisible, !isPrimary, !hasExpression, !other.hasExpression,
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

    static func tables(from rows: [TableHealthRow]) -> [MySQLIndexShape] {
        var tables: [MySQLIndexShape] = []
        for row in rows {
            let table = row["table_name"], indexName = row["index_name"]
            if tables.last?.name != table {
                tables.append(MySQLIndexShape(name: table, indexes: []))
            }
            let tableIndex = tables.count - 1
            if tables[tableIndex].indexes.last?.name != indexName {
                tables[tableIndex].indexes.append(Index(
                    name: indexName,
                    isUnique: row["non_unique"] == "0",
                    type: row["index_type"],
                    isVisible: row["is_visible"] != "NO" && row["ignored"] != "YES",
                    columns: [],
                    hasExpression: false
                ))
            }
            let last = tables[tableIndex].indexes.count - 1
            let column = row["column_name"]
            if column.isEmpty {
                tables[tableIndex].indexes[last].hasExpression = true
            } else {
                tables[tableIndex].indexes[last].columns.append(
                    Column(name: column, prefixLength: row["sub_part"], sortOrder: row["collation"])
                )
            }
        }
        return tables
    }

    // Each table's foreign keys, as their columns in key order.
    static func foreignKeys(from rows: [TableHealthRow]) -> [String: [[String]]] {
        var keys: [String: [[String]]] = [:]
        var previous: (table: String, constraint: String)?
        for row in rows {
            let table = row["table_name"], constraint = row["constraint_name"]
            var tableKeys = keys[table] ?? []
            if previous?.table == table, previous?.constraint == constraint, !tableKeys.isEmpty {
                tableKeys[tableKeys.count - 1].append(row["column_name"])
            } else {
                tableKeys.append([row["column_name"]])
            }
            keys[table] = tableKeys
            previous = (table, constraint)
        }
        return keys
    }
}
