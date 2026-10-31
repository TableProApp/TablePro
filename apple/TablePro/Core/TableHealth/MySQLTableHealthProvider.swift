//
//  MySQLTableHealthProvider.swift
//  TablePro
//

import Foundation

/// Reads every user schema on the server. InnoDB indexes a foreign key's columns itself, so there
/// is no unindexed foreign key check. `scripts/probes/check-table-health-catalogs.sh` runs these
/// queries against a real server, so keep each one a plain literal with no interpolation.
struct MySQLTableHealthProvider: TableHealthProvider {
    let checks: [TableHealthCheckKind] = [.unusedIndex, .redundantIndex, .missingPrimaryKey]
    let schemaNamesDatabase = true

    // The table sys.schema_unused_indexes reads, queried directly since MariaDB before 10.6 has no sys
    // schema. A unique index enforces something even when no query reads it.
    static let unusedIndexQuery = """
        SELECT u.OBJECT_SCHEMA AS schema_name,
               u.OBJECT_NAME AS table_name,
               u.INDEX_NAME AS index_name
        FROM performance_schema.table_io_waits_summary_by_index_usage u
        WHERE u.INDEX_NAME IS NOT NULL
          AND u.INDEX_NAME <> 'PRIMARY'
          AND u.COUNT_STAR = 0
          AND u.OBJECT_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
          AND NOT EXISTS (
              SELECT 1 FROM information_schema.STATISTICS s
              WHERE s.TABLE_SCHEMA = u.OBJECT_SCHEMA
                AND s.TABLE_NAME = u.OBJECT_NAME
                AND s.INDEX_NAME = u.INDEX_NAME
                AND s.NON_UNIQUE = 0
          )
        ORDER BY u.OBJECT_SCHEMA, u.OBJECT_NAME, u.INDEX_NAME
        LIMIT 500
        """

    // The prefix comparison sys.schema_redundant_indexes makes, done in Swift so it needs no sys schema.
    static let redundantIndexQuery = """
        SELECT s.TABLE_SCHEMA AS schema_name,
               s.TABLE_NAME AS table_name,
               s.INDEX_NAME AS index_name,
               s.NON_UNIQUE AS non_unique,
               s.INDEX_TYPE AS index_type,
               s.COLUMN_NAME AS column_name,
               s.SUB_PART AS sub_part,
               s.COLLATION AS sort_order
        FROM information_schema.STATISTICS s
        WHERE s.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
        ORDER BY s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME, s.SEQ_IN_INDEX
        """

    static let missingPrimaryKeyQuery = """
        SELECT t.TABLE_SCHEMA AS schema_name,
               t.TABLE_NAME AS table_name
        FROM information_schema.TABLES t
        WHERE t.TABLE_TYPE = 'BASE TABLE'
          AND t.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
          AND NOT EXISTS (
              SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c
              WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA
                AND c.TABLE_NAME = t.TABLE_NAME
                AND c.CONSTRAINT_TYPE = 'PRIMARY KEY'
          )
        ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME
        LIMIT 500
        """

    static let performanceSchemaQuery = "SELECT @@GLOBAL.performance_schema AS performance_schema"

    static let uptimeQuery = "SHOW GLOBAL STATUS LIKE 'Uptime'"

    var statisticsQueries: [String] { [Self.performanceSchemaQuery, Self.uptimeQuery] }

    var databaseQuery: String? { nil }

    func query(for check: TableHealthCheckKind) -> String {
        switch check {
        case .unusedIndex: return Self.unusedIndexQuery
        case .redundantIndex: return Self.redundantIndexQuery
        case .missingPrimaryKey: return Self.missingPrimaryKeyQuery
        case .bloat, .unindexedForeignKey: return ""
        }
    }

    func findings(for check: TableHealthCheckKind, from result: QueryResult) -> [TableHealthFinding] {
        let rows = TableHealthRow.rows(of: result)
        switch check {
        case .unusedIndex:
            return rows.map(unusedIndexFinding)
        case .redundantIndex:
            return redundantIndexFindings(rows)
        case .missingPrimaryKey:
            return rows.map(missingPrimaryKeyFinding)
        case .bloat, .unindexedForeignKey:
            return []
        }
    }

    /// Performance Schema counts index reads from the server start, and records none while it is off.
    func statisticsNote(from results: [QueryResult], now: Date) -> String? {
        guard results.count == 2 else { return nil }
        let enabled = TableHealthRow.rows(of: results[0]).first?["performance_schema"] ?? ""
        guard enabled == "1" || enabled.uppercased() == "ON" else {
            return String(localized: "Performance Schema is off, so the server records no index usage and no index can show as unused.")
        }
        guard let uptime = TableHealthRow.rows(of: results[1]).first.flatMap({ Double($0["value"]) }) else { return nil }
        let start = now.addingTimeInterval(-uptime).formatted(date: .abbreviated, time: .shortened)
        return String(format: String(localized: "Index usage counts since the server started at %@."), start)
    }

    // MARK: - Fix SQL

    static func dropIndexSQL(schema: String, table: String, index: String) -> String {
        "ALTER TABLE \(qualified(schema, table)) DROP INDEX \(quote(index));"
    }

    static func addPrimaryKeySQL(schema: String, table: String) -> String {
        "ALTER TABLE \(qualified(schema, table)) ADD PRIMARY KEY (column_name);"
    }

    static func quote(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }

    private static func qualified(_ schema: String, _ name: String) -> String {
        "\(quote(schema)).\(quote(name))"
    }

    // MARK: - Parsing

    private func unusedIndexFinding(_ row: TableHealthRow) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"], index = row["index_name"]
        return TableHealthFinding(
            kind: .unusedIndex, schema: schema, table: table, objectName: index,
            detail: String(format: String(localized: "%@ has no recorded reads."), index),
            fixSQL: Self.dropIndexSQL(schema: schema, table: table, index: index)
        )
    }

    private func redundantIndexFindings(_ rows: [TableHealthRow]) -> [TableHealthFinding] {
        var findings: [TableHealthFinding] = []
        for table in MySQLIndexShape.tables(from: rows) {
            for index in table.indexes {
                guard let dominant = table.indexes.first(where: { index.isRedundant(to: $0) }) else { continue }
                findings.append(TableHealthFinding(
                    kind: .redundantIndex, schema: table.schema, table: table.name, objectName: index.name,
                    detail: String(format: String(localized: "%1$@ is covered by %2$@."), index.name, dominant.name),
                    fixSQL: Self.dropIndexSQL(schema: table.schema, table: table.name, index: index.name)
                ))
                if findings.count == TableHealthCheckResult.findingLimit { return findings }
            }
        }
        return findings
    }

    private func missingPrimaryKeyFinding(_ row: TableHealthRow) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        return TableHealthFinding(
            kind: .missingPrimaryKey, schema: schema, table: table, objectName: nil,
            detail: String(localized: "No primary key. Replace column_name with the columns that identify a row."),
            fixSQL: Self.addPrimaryKeySQL(schema: schema, table: table)
        )
    }
}

/// The indexes of one table, read from `information_schema.STATISTICS` rows ordered by index and position.
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
        var columns: [Column]
        /// A functional key part has no column name and cannot be compared by prefix.
        var hasExpression: Bool

        var isPrimary: Bool { name == "PRIMARY" }

        /// Redundant when another index of the same type starts with the same columns in the same
        /// directions. Only a B-tree serves a lookup on its leading columns, so any other type is
        /// redundant only to an identical index. Of two equal indexes, the unique one stays; of two
        /// equal unique or two equal plain ones, the first by name stays.
        func isRedundant(to other: Index) -> Bool {
            guard other.name != name, !isPrimary, !hasExpression, !other.hasExpression,
                  other.type == type, columns.count <= other.columns.count,
                  type == "BTREE" || columns.count == other.columns.count,
                  Array(other.columns.prefix(columns.count)) == columns
            else { return false }
            if columns.count < other.columns.count { return !isUnique }
            if isUnique != other.isUnique { return other.isUnique }
            return other.isPrimary || other.name < name
        }
    }

    let schema: String
    let name: String
    var indexes: [Index]

    static func tables(from rows: [TableHealthRow]) -> [MySQLIndexShape] {
        var tables: [MySQLIndexShape] = []
        for row in rows {
            let schema = row["schema_name"], table = row["table_name"], indexName = row["index_name"]
            if tables.last?.schema != schema || tables.last?.name != table {
                tables.append(MySQLIndexShape(schema: schema, name: table, indexes: []))
            }
            let column = row["column_name"]
            if tables[tables.count - 1].indexes.last?.name != indexName {
                tables[tables.count - 1].indexes.append(Index(
                    name: indexName,
                    isUnique: row["non_unique"] == "0",
                    type: row["index_type"],
                    columns: [],
                    hasExpression: false
                ))
            }
            let last = tables[tables.count - 1].indexes.count - 1
            if column.isEmpty {
                tables[tables.count - 1].indexes[last].hasExpression = true
            } else {
                tables[tables.count - 1].indexes[last].columns.append(
                    Column(name: column, prefixLength: row["sub_part"], sortOrder: row["sort_order"])
                )
            }
        }
        return tables
    }
}
