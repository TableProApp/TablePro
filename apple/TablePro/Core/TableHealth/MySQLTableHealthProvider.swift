import Foundation

// InnoDB indexes a foreign key's columns itself, so there is no unindexed foreign key check.
// scripts/probes/check-table-health-catalogs.sh runs these literals against real servers: keep them free of interpolation.
struct MySQLTableHealthProvider: TableHealthProvider {
    let checks: [TableHealthCheckKind] = [.unusedIndex, .redundantIndex, .missingPrimaryKey, .nearLimit, .reclaimableSpace]

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
        SELECT t.TABLE_NAME AS table_name,
               t.TABLE_ROWS AS estimated_rows,
               t.DATA_LENGTH + t.INDEX_LENGTH AS table_bytes
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

    // Joined to the unused index candidates in Swift by exact name, like the index rows, so no SQL
    // compares performance_schema names with information_schema ones, whose collations differ.
    static let tableRowsQuery = """
        SELECT t.TABLE_NAME AS table_name,
               t.TABLE_ROWS AS estimated_rows
        FROM information_schema.TABLES t
        WHERE t.TABLE_SCHEMA = DATABASE()
          AND t.TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED')
        ORDER BY t.TABLE_NAME
        """

    static let versionQuery = "SELECT VERSION() AS version"

    // PROCESS gates every InnoDB table in information_schema. This one exists on MySQL and MariaDB and holds a
    // row per buffer pool, so it answers for the tablespace tables the reclaimable space check reads.
    static let processPrivilegeQuery = "SELECT COUNT(*) AS buffer_pools FROM information_schema.INNODB_BUFFER_POOL_STATS"

    // The limits sys.schema_auto_increment_columns uses; AUTO_INCREMENT is the next value the table hands out.
    // The 75% threshold compares integers, since 100 * AUTO_INCREMENT overflows BIGINT UNSIGNED near a bigint limit.
    // A FLOAT or DOUBLE column has no limit here and drops out.
    static let autoIncrementQuery = """
        SELECT r.table_name, r.column_name, r.data_type, r.column_type, r.is_nullable, r.column_comment, r.extra,
               r.auto_increment, r.max_value, r.table_bytes
        FROM (
            SELECT t.TABLE_NAME AS table_name,
                   c.COLUMN_NAME AS column_name,
                   c.DATA_TYPE AS data_type,
                   c.COLUMN_TYPE AS column_type,
                   c.IS_NULLABLE AS is_nullable,
                   c.COLUMN_COMMENT AS column_comment,
                   c.EXTRA AS extra,
                   t.AUTO_INCREMENT AS auto_increment,
                   (CASE c.DATA_TYPE
                        WHEN 'tinyint' THEN 255
                        WHEN 'smallint' THEN 65535
                        WHEN 'mediumint' THEN 16777215
                        WHEN 'int' THEN 4294967295
                        WHEN 'bigint' THEN 18446744073709551615
                    END >> IF(LOCATE('unsigned', c.COLUMN_TYPE) > 0, 0, 1)) AS max_value,
                   t.DATA_LENGTH + t.INDEX_LENGTH AS table_bytes
            FROM information_schema.TABLES t
            JOIN information_schema.COLUMNS c
              ON c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME
            WHERE t.TABLE_SCHEMA = DATABASE()
              AND t.TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED')
              AND c.EXTRA LIKE '%auto_increment%'
              AND t.AUTO_INCREMENT IS NOT NULL
        ) r
        WHERE r.auto_increment >= r.max_value - r.max_value DIV 4
        ORDER BY r.auto_increment / r.max_value DESC, r.table_name
        """

    // A table in a shared tablespace reports the free space of the whole tablespace, so InnoDB counts only with a
    // file of its own. INNODB_TABLES encodes special characters in a name (`@0020`), so such a table drops out
    // rather than being judged by another table's tablespace.
    static let reclaimableSpaceQuery = """
        SELECT t.TABLE_NAME AS table_name,
               t.ENGINE AS engine,
               t.TABLE_ROWS AS estimated_rows,
               t.DATA_LENGTH + t.INDEX_LENGTH AS table_bytes,
               t.DATA_FREE AS free_bytes
        FROM information_schema.TABLES t
        WHERE t.TABLE_SCHEMA = DATABASE()
          AND t.TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED')
          AND t.DATA_FREE >= 104857600
          AND t.DATA_FREE * 10 >= t.DATA_LENGTH + t.INDEX_LENGTH + t.DATA_FREE
          AND (t.ENGINE IN ('MyISAM', 'Aria')
               OR (t.ENGINE = 'InnoDB' AND EXISTS (
                   SELECT 1
                   FROM information_schema.INNODB_TABLES it
                   JOIN information_schema.INNODB_TABLESPACES ts ON ts.SPACE = it.SPACE
                   WHERE ts.SPACE_TYPE = 'Single'
                     AND (it.NAME = CONCAT(t.TABLE_SCHEMA, '/', t.TABLE_NAME)
                          OR LEFT(it.NAME, CHAR_LENGTH(t.TABLE_SCHEMA) + CHAR_LENGTH(t.TABLE_NAME) + 4)
                             = CONCAT(t.TABLE_SCHEMA, '/', t.TABLE_NAME, '#p#')))))
        ORDER BY t.DATA_FREE DESC, t.TABLE_NAME
        """

    // MariaDB has no INNODB_TABLES and no general tablespaces: space 0 is the system tablespace.
    static let mariaDBReclaimableSpaceQuery = """
        SELECT t.TABLE_NAME AS table_name,
               t.ENGINE AS engine,
               t.TABLE_ROWS AS estimated_rows,
               t.DATA_LENGTH + t.INDEX_LENGTH AS table_bytes,
               t.DATA_FREE AS free_bytes
        FROM information_schema.TABLES t
        WHERE t.TABLE_SCHEMA = DATABASE()
          AND t.TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED')
          AND t.DATA_FREE >= 104857600
          AND t.DATA_FREE * 10 >= t.DATA_LENGTH + t.INDEX_LENGTH + t.DATA_FREE
          AND (t.ENGINE IN ('MyISAM', 'Aria')
               OR (t.ENGINE = 'InnoDB' AND EXISTS (
                   SELECT 1
                   FROM information_schema.INNODB_SYS_TABLES it
                   WHERE it.SPACE <> 0
                     AND (it.NAME = CONCAT(t.TABLE_SCHEMA, '/', t.TABLE_NAME)
                          OR LEFT(it.NAME, CHAR_LENGTH(t.TABLE_SCHEMA) + CHAR_LENGTH(t.TABLE_NAME) + 4)
                             = CONCAT(t.TABLE_SCHEMA, '/', t.TABLE_NAME, '#P#')))))
        ORDER BY t.DATA_FREE DESC, t.TABLE_NAME
        """

    var statisticsQueries: [String] {
        [Self.performanceSchemaQuery, Self.uptimeQuery, Self.usageCountingQuery, Self.versionQuery, Self.processPrivilegeQuery]
    }

    func check(_ kind: TableHealthCheckKind) -> TableHealthCheck {
        switch kind {
        case .unusedIndex:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Indexes with no recorded reads since the server started, leaving out unique, full-text and foreign key indexes."
            ))
        case .redundantIndex:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Indexes whose columns lead another visible index of the same type on the same table."
            ))
        case .missingPrimaryKey:
            return TableHealthCheck(kind: kind, summary: String(localized: "Tables with no primary key."))
        case .nearLimit:
            return TableHealthCheck(
                kind: kind,
                title: String(localized: "AUTO_INCREMENT Near Its Limit"),
                summary: String(localized: "AUTO_INCREMENT columns whose next value has reached 75% of the largest value their type holds.")
            )
        case .reclaimableSpace:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Tables stored in their own files whose free space is at least 100 MiB and at least 10% of their size on disk."
            ))
        case .bloat, .unindexedForeignKey, .invalidIndex, .transactionIdAge, .staleStatistics:
            return TableHealthCheck(kind: kind, summary: "")
        }
    }

    func queries(for check: TableHealthCheckKind, statistics: TableHealthStatistics) -> [String] {
        switch check {
        case .unusedIndex: return [Self.unusedIndexQuery, Self.indexQuery, Self.foreignKeyQuery, Self.tableRowsQuery]
        case .redundantIndex: return [Self.indexQuery]
        case .missingPrimaryKey: return [Self.missingPrimaryKeyQuery]
        case .nearLimit: return [Self.autoIncrementQuery, Self.foreignKeyQuery]
        case .reclaimableSpace:
            return [statistics.isMariaDB ? Self.mariaDBReclaimableSpaceQuery : Self.reclaimableSpaceQuery]
        case .bloat, .unindexedForeignKey, .invalidIndex, .transactionIdAge, .staleStatistics:
            return []
        }
    }

    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics {
        func value(_ position: Int, _ column: String) -> String? {
            guard position < results.count, let result = results[position] else { return nil }
            return TableHealthRow.rows(of: result).first?[column]
        }

        var statistics = TableHealthStatistics()
        if let version = value(3, "version") {
            statistics.serverVersion = Self.serverVersion(from: version)
            statistics.isMariaDB = version.range(of: "MariaDB", options: .caseInsensitive) != nil
        }
        if !statistics.isMariaDB, let version = statistics.serverVersion, version < 80_000 {
            statistics.skippedChecks[.reclaimableSpace] = String(localized: "Needs MySQL 8.0 or later.")
        } else if (value(4, "buffer_pools").flatMap { Int($0) } ?? 0) == 0 {
            statistics.skippedChecks[.reclaimableSpace] = String(
                localized: "Needs the PROCESS privilege to tell a table in its own file from one in a shared tablespace."
            )
        }
        if let reason = Self.unusedSkipReason(value) {
            statistics.skippedChecks[.unusedIndex] = reason
        } else if let uptime = value(1, "value").flatMap(Double.init) {
            let start = TableHealthFormatting.date(now.addingTimeInterval(-uptime))
            statistics.notes.append(String(format: String(localized: "Index usage counts since the server started at %@."), start))
        }
        return statistics
    }

    // MySQL 8 serves AUTO_INCREMENT and the sizes in information_schema.TABLES from a cache. Changing the expiry
    // would change a session the app pools, so the check says so instead.
    private static func statisticsCacheNote(_ statistics: TableHealthStatistics) -> String? {
        guard !statistics.isMariaDB, let version = statistics.serverVersion, version >= 80_000 else { return nil }
        return String(
            localized: "MySQL caches the values this check reads for information_schema_stats_expiry seconds, one day by default. ANALYZE TABLE refreshes a table's values."
        )
    }

    private static func unusedSkipReason(_ value: (Int, String) -> String?) -> String? {
        if let enabled = value(0, "performance_schema"), enabled != "1", enabled.uppercased() != "ON" {
            return String(localized: "Performance Schema is off, so the server records no index reads.")
        }
        if value(2, "table_io_instrument") == "NO" {
            return String(localized: "The wait/io/table/sql/handler instrument is disabled, so the server records no index reads.")
        }
        if value(2, "global_instrumentation") == "NO" {
            return String(localized: "The global_instrumentation consumer is disabled, so the server records no index reads.")
        }
        if value(2, "counted_tables") == "0" {
            return String(
                localized: "No table in this database has a recorded read or write since the server started, so an unread index cannot be told from an uncounted one."
            )
        }
        return nil
    }

    // "8.0.46" is 80046 and "10.6.28-MariaDB-1:10.6.28+maria~ubu2004" is 100628. A MariaDB server that
    // fronts its version with "5.5.5-" for old clients is read past that prefix.
    static func serverVersion(from text: String) -> Int? {
        var version = Substring(text.trimmingCharacters(in: .whitespaces))
        if version.hasPrefix("5.5.5-") { version = version.dropFirst(6) }
        let parts = version.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            .split(separator: ".", omittingEmptySubsequences: false)
            .prefix(3)
            .map { Int($0) }
        guard let major = parts.first ?? nil else { return nil }
        let minor = parts.count > 1 ? parts[1] ?? 0 : 0
        let patch = parts.count > 2 ? parts[2] ?? 0 : 0
        return major * 10_000 + minor * 100 + patch
    }

    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext,
        statistics: TableHealthStatistics
    ) -> (findings: [TableHealthFinding], note: String?) {
        switch check {
        case .unusedIndex:
            guard results.count == 4 else { return ([], nil) }
            return (unusedIndexFindings(
                candidates: TableHealthRow.rows(of: results[0]),
                tables: MySQLIndexShape.tables(from: TableHealthRow.rows(of: results[1])),
                foreignKeys: MySQLIndexShape.foreignKeys(from: TableHealthRow.rows(of: results[2])),
                tableRows: Self.estimatedRows(from: TableHealthRow.rows(of: results[3])),
                context: context
            ), nil)
        case .redundantIndex:
            guard let result = results.first else { return ([], nil) }
            return (redundantIndexFindings(MySQLIndexShape.tables(from: TableHealthRow.rows(of: result)), context), nil)
        case .missingPrimaryKey:
            guard let result = results.first else { return ([], nil) }
            return (TableHealthRow.rows(of: result).map { missingPrimaryKeyFinding($0, context) }, nil)
        case .nearLimit:
            guard results.count == 2 else { return ([], nil) }
            let keys = Self.foreignKeysByColumn(TableHealthRow.rows(of: results[1]))
            let findings = TableHealthRow.rows(of: results[0]).compactMap { nearLimitFinding($0, foreignKeys: keys, context) }
            return (findings, Self.statisticsCacheNote(statistics))
        case .reclaimableSpace:
            guard let result = results.first else { return ([], nil) }
            return (TableHealthRow.rows(of: result).map { reclaimableSpaceFinding($0, context) }, Self.statisticsCacheNote(statistics))
        case .bloat, .unindexedForeignKey, .invalidIndex, .transactionIdAge, .staleStatistics:
            return ([], nil)
        }
    }

    private static func estimatedRows(from rows: [TableHealthRow]) -> [String: Int64] {
        var byTable: [String: Int64] = [:]
        for row in rows {
            if let count = row.int64("estimated_rows") {
                byTable[row["table_name"]] = count
            }
        }
        return byTable
    }

    // A unique index enforces something no read counts, and a MATCH search reads a full-text index
    // uncounted. InnoDB checks a foreign key through an index that leads with its columns on either
    // end without counting a read, and refuses to drop the last one.
    private func unusedIndexFindings(
        candidates: [TableHealthRow],
        tables: [MySQLIndexShape],
        foreignKeys: [String: [[String]]],
        tableRows: [String: Int64],
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
                metrics: tableRows[table].map { [TableHealthMetric.estimatedRows($0)] } ?? [],
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
                    metrics: [TableHealthMetric(
                        id: "covering_index", label: String(localized: "Covering Index"), value: .text(dominant.name)
                    )],
                    fixSQL: dropIndexSQL(table: table.name, index: index.name, context)
                ))
            }
        }
        return findings
    }

    private func missingPrimaryKeyFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let table = row["table_name"]
        return TableHealthFinding(
            kind: .missingPrimaryKey, schema: nil, table: table, objectName: nil,
            detail: String(localized: "No primary key. Replace column_name with the columns that identify a row."),
            sizeBytes: row.int64("table_bytes"),
            metrics: row.int64("estimated_rows").map { [TableHealthMetric.estimatedRows($0)] } ?? [],
            fixSQL: "ALTER TABLE \(context.qualified(context.database, table)) ADD PRIMARY KEY (column_name);"
        )
    }

    private func dropIndexSQL(table: String, index: String, _ context: TableHealthQueryContext) -> String {
        "ALTER TABLE \(context.qualified(context.database, table)) DROP INDEX \(context.quote(index));"
    }

    private func nearLimitFinding(
        _ row: TableHealthRow,
        foreignKeys: [String: [String]],
        _ context: TableHealthQueryContext
    ) -> TableHealthFinding? {
        guard let next = row.uint64("auto_increment"), let limit = row.uint64("max_value"), limit > 0 else { return nil }
        let table = row["table_name"], column = row["column_name"], columnType = row["column_type"]
        let used = TableHealthMetric(
            id: "used_percent", label: String(localized: "Share Used"), value: .percent(Double(next) / Double(limit))
        )
        var detail = String(
            format: String(localized: "%1$@ is at %2$@ of the largest value %3$@ holds."), column, used.formattedValue, columnType
        )
        var fixSQL: String?
        if let type = Self.widenedType(dataType: row["data_type"], columnType: columnType) {
            fixSQL = "ALTER TABLE \(context.qualified(context.database, table)) MODIFY COLUMN \(context.quote(column)) "
                + Self.columnDefinition(type: type, row, context) + ";"
            if row["data_type"].lowercased() == "bigint" {
                detail += " " + String(localized: "Run the fix only if the column holds no negative values.")
            }
            if let keys = foreignKeys[Self.columnKey(table: table, column: column)] {
                detail += " " + String(
                    format: String(
                        localized: "Foreign keys use this column (%@): drop them, give the column at the other end of each the same type, then add them again."
                    ),
                    keys.joined(separator: ", ")
                )
            }
        } else {
            detail += " " + String(localized: "No integer type holds larger values.")
        }
        return TableHealthFinding(
            kind: .nearLimit, schema: nil, table: table, objectName: column, detail: detail,
            sizeBytes: row.int64("table_bytes"),
            metrics: [
                TableHealthMetric(id: "auto_increment", label: String(localized: "Next Value"), value: .bigCount(next)),
                TableHealthMetric(id: "max_value", label: String(localized: "Largest Value"), value: .bigCount(limit)),
                used,
                TableHealthMetric(id: "column_type", label: String(localized: "Column Type"), value: .text(columnType))
            ],
            fixSQL: fixSQL
        )
    }

    // A smaller integer widens to BIGINT with its sign kept, and ZEROFILL keeps the width it pads to. A signed
    // bigint can only give up its sign; an unsigned one is the widest integer there is.
    static func widenedType(dataType: String, columnType: String) -> String? {
        let words = columnType.lowercased().split(whereSeparator: \.isWhitespace)
        let isUnsigned = words.contains("unsigned"), isZerofill = words.contains("zerofill")
        if dataType.lowercased() == "bigint" { return isUnsigned ? nil : "BIGINT UNSIGNED" }
        var type = "BIGINT"
        if isZerofill, let declared = words.first, let width = declared.firstIndex(of: "(") {
            type += declared[width...]
        }
        if isUnsigned { type += " UNSIGNED" }
        if isZerofill { type += " ZEROFILL" }
        return type
    }

    // MODIFY replaces the whole definition, so what the column has besides its type is stated again.
    private static func columnDefinition(type: String, _ row: TableHealthRow, _ context: TableHealthQueryContext) -> String {
        var parts = [type, row["is_nullable"].uppercased() == "YES" ? "NULL" : "NOT NULL", "AUTO_INCREMENT"]
        let extra = row["extra"].split { !$0.isLetter && $0 != "_" }
        if extra.contains(where: { $0.uppercased() == "INVISIBLE" }) {
            parts.append("INVISIBLE")
        }
        let comment = row["column_comment"]
        if !comment.isEmpty {
            parts.append("COMMENT " + context.literal(comment))
        }
        return parts.joined(separator: " ")
    }

    // MySQL refuses to change the type of a column a foreign key uses at either end, even with the checks off.
    private static func foreignKeysByColumn(_ rows: [TableHealthRow]) -> [String: [String]] {
        var keys: [String: Set<String>] = [:]
        for row in rows {
            let isLocal = row["is_local"] == "1"
            let owner = isLocal ? row["table_name"] : row["table_schema"] + "." + row["table_name"]
            let key = String(format: String(localized: "%1$@ on %2$@"), row["constraint_name"], owner)
            if isLocal {
                keys[columnKey(table: row["table_name"], column: row["column_name"]), default: []].insert(key)
            }
            if row["references_here"] == "1" {
                keys[columnKey(table: row["referenced_table_name"], column: row["referenced_column_name"]), default: []]
                    .insert(key)
            }
        }
        return keys.mapValues { $0.sorted() }
    }

    // Column names never differ only in case; table names can.
    private static func columnKey(table: String, column: String) -> String {
        table + "\u{1F}" + column.lowercased()
    }

    private func reclaimableSpaceFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let table = row["table_name"]
        let tableBytes = row.int64("table_bytes"), freeBytes = row.int64("free_bytes") ?? 0
        let onDisk = Double(tableBytes ?? 0) + Double(freeBytes)
        let free = TableHealthMetric(id: "free_bytes", label: String(localized: "Reclaimable"), value: .bytes(freeBytes))
        let share = TableHealthMetric(
            id: "free_percent", label: String(localized: "Reclaimable Share"), value: .percent(onDisk > 0 ? Double(freeBytes) / onDisk : 0)
        )
        var metrics = [free, share]
        if let rows = row.int64("estimated_rows") {
            metrics.append(.estimatedRows(rows))
        }
        metrics.append(TableHealthMetric(id: "engine", label: String(localized: "Engine"), value: .text(row["engine"])))
        return TableHealthFinding(
            kind: .reclaimableSpace, schema: nil, table: table, objectName: nil,
            detail: String(
                format: String(localized: "%1$@ reclaimable, %2$@ of the table's size on disk."), free.formattedValue, share.formattedValue
            ),
            sizeBytes: tableBytes,
            metrics: metrics,
            fixSQL: "OPTIMIZE TABLE \(context.qualified(context.database, table));"
        )
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
