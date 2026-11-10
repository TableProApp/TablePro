//
//  PostgreSQLTableDDL.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPostgreSQLCore

// What a table's CREATE statement says outside its column list. The table listing hides the partitions of a
// partitioned table, so the parent's script creates them: without them a restore has nowhere to put a row.
enum PostgreSQLTableDDL {
    struct Shape: Equatable {
        var isUnlogged = false
        var partitionKey: String?
        var partitionOf: String?
        var partitionBound: String?
    }

    struct Partition: Equatable {
        let name: String
        let parent: String
        let bound: String
        let partitionKey: String?
        let isUnlogged: Bool
    }

    // `relispartition`, `relpartbound` and `pg_get_partkeydef` are PostgreSQL 10.
    static func shapeQuery(schema: String, table: String, capabilities: PostgreSQLCapabilities) -> String {
        let partitionColumns = capabilities.hasDeclarativePartitioning ? """
            CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid) END,
                   CASE WHEN c.relispartition THEN pg_catalog.pg_get_expr(c.relpartbound, c.oid) END,
                   CASE WHEN c.relispartition THEN (
                       SELECT pg_catalog.quote_ident(pn.nspname) || '.' || pg_catalog.quote_ident(p.relname)
                       FROM pg_catalog.pg_inherits i
                       JOIN pg_catalog.pg_class p ON p.oid = i.inhparent
                       JOIN pg_catalog.pg_namespace pn ON pn.oid = p.relnamespace
                       WHERE i.inhrelid = c.oid
                       LIMIT 1) END
            """ : "NULL::text, NULL::text, NULL::text"
        return """
            SELECT c.relpersistence::text,
                   \(partitionColumns)
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
              AND n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
            """
    }

    // Every partition below the table, a parent before its own partitions. A foreign table attached as a partition
    // is left out: CREATE TABLE cannot make one.
    static func partitionTreeQuery(schema: String, table: String) -> String {
        """
            WITH RECURSIVE parts AS (
                SELECT i.inhrelid AS relid, i.inhparent AS parent, 1 AS depth
                FROM pg_catalog.pg_inherits i
                JOIN pg_catalog.pg_class root ON root.oid = i.inhparent
                JOIN pg_catalog.pg_namespace rn ON rn.oid = root.relnamespace
                WHERE root.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
                  AND rn.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
                  AND root.relkind = 'p'
                UNION ALL
                SELECT i.inhrelid, i.inhparent, parts.depth + 1
                FROM pg_catalog.pg_inherits i
                JOIN parts ON parts.relid = i.inhparent
            )
            SELECT pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(c.relname),
                   pg_catalog.quote_ident(pn.nspname) || '.' || pg_catalog.quote_ident(p.relname),
                   pg_catalog.pg_get_expr(c.relpartbound, c.oid),
                   CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid) END,
                   c.relpersistence::text
            FROM parts
            JOIN pg_catalog.pg_class c ON c.oid = parts.relid
            JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace
            JOIN pg_catalog.pg_class p ON p.oid = parts.parent
            JOIN pg_catalog.pg_namespace pn ON pn.oid = p.relnamespace
            WHERE c.relispartition
              AND c.relkind IN ('r', 'p')
            ORDER BY parts.depth, cn.nspname, c.relname
            """
    }

    // A server that reports version 10 without these catalog functions fails the read; the table is then plain.
    static func shape(fromRows rows: [[String?]]?) -> Shape {
        rows?.first.map(shape(from:)) ?? Shape()
    }

    static func shape(from row: [String?]) -> Shape {
        func text(_ index: Int) -> String? {
            guard row.indices.contains(index), let value = row[index], !value.isEmpty else { return nil }
            return value
        }
        return Shape(
            isUnlogged: text(0) == "u",
            partitionKey: text(1),
            partitionOf: text(3),
            partitionBound: text(2)
        )
    }

    static func partition(from row: [String?]) -> Partition? {
        guard row.count >= 5,
              let name = row[0], !name.isEmpty,
              let parent = row[1], !parent.isEmpty,
              let bound = row[2], !bound.isEmpty
        else { return nil }
        let key = row[3].flatMap { $0.isEmpty ? nil : $0 }
        return Partition(name: name, parent: parent, bound: bound, partitionKey: key, isUnlogged: row[4] == "u")
    }

    static func createTable(name: String, definitions: [String], shape: Shape) -> String {
        let partitionBy = shape.partitionKey.map { " PARTITION BY \($0)" } ?? ""
        if let parent = shape.partitionOf, let bound = shape.partitionBound {
            let isUnlogged = shape.isUnlogged && shape.partitionKey == nil
            return "\(keyword(isUnlogged: isUnlogged)) \(name) PARTITION OF \(parent) \(bound)\(partitionBy);"
        }
        // PostgreSQL 18 refuses an unlogged partitioned table, and before it the flag did nothing on the parent.
        let isUnlogged = shape.isUnlogged && shape.partitionKey == nil
        return "\(keyword(isUnlogged: isUnlogged)) \(name) (\n  "
            + definitions.joined(separator: ",\n  ")
            + "\n)\(partitionBy);"
    }

    static func createPartition(_ partition: Partition) -> String {
        createTable(
            name: partition.name,
            definitions: [],
            shape: Shape(
                isUnlogged: partition.isUnlogged,
                partitionKey: partition.partitionKey,
                partitionOf: partition.parent,
                partitionBound: partition.bound
            )
        )
    }

    static func script(name: String, definitions: [String], shape: Shape, partitions: [Partition]) -> String {
        ([createTable(name: name, definitions: definitions, shape: shape)] + partitions.map(createPartition))
            .joined(separator: "\n\n")
    }

    // `pg_get_indexdef` writes ON ONLY for an index over a partitioned table, and replayed that builds nothing on the
    // partitions and leaves the index invalid. Without it the server builds each partition's index itself.
    static func indexCoveringPartitions(_ definition: String) -> String {
        guard let keyword = ["CREATE UNIQUE INDEX ", "CREATE INDEX "].first(where: { definition.hasPrefix($0) }) else {
            return definition
        }
        var index = definition.index(definition.startIndex, offsetBy: keyword.count)
        if index < definition.endIndex, definition[index] == "\"" {
            index = definition.index(after: index)
            while index < definition.endIndex {
                let next = definition.index(after: index)
                if definition[index] == "\"" {
                    guard next < definition.endIndex, definition[next] == "\"" else {
                        index = next
                        break
                    }
                    index = definition.index(after: next)
                } else {
                    index = next
                }
            }
        } else {
            index = definition[index...].firstIndex(of: " ") ?? definition.endIndex
        }
        let marker = " ON ONLY "
        guard definition[index...].hasPrefix(marker) else { return definition }
        let rest = definition[definition.index(index, offsetBy: marker.count)...]
        return String(definition[..<index]) + " ON " + String(rest)
    }

    private static func keyword(isUnlogged: Bool) -> String {
        isUnlogged ? "CREATE UNLOGGED TABLE" : "CREATE TABLE"
    }
}
