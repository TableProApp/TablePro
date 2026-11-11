//
//  PostgreSQLTableDDL.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPostgreSQLCore

// What a table's CREATE statement says outside its column list. The table listing hides the partitions of a
// partitioned table, so the parent's script creates them, with what each holds of its own: without them a restore has
// nowhere to put a row, and a partition's own check, key, default and index would be lost.
enum PostgreSQLTableDDL {
    struct Shape: Equatable {
        var isUnlogged = false
        var partitionKey: String?
        var partitionOf: String?
        var partitionBound: String?
        var partitionElements: [String] = []
    }

    struct Partition: Equatable {
        let name: String
        let parent: String
        let bound: String
        let partitionKey: String?
        let isUnlogged: Bool
        var foreignServer: String?
        var foreignOptions: String?
        var elements: [String] = []
    }

    enum PartitionScope {
        case below
        case itself
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

    // Every partition below the table, a parent before its own partitions, foreign table partitions with their server
    // and options.
    static func partitionTreeQuery(schema: String, table: String) -> String {
        """
            \(partitionRelations(schema: schema, table: table, scope: .below))
            SELECT pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(c.relname),
                   pg_catalog.quote_ident(pn.nspname) || '.' || pg_catalog.quote_ident(p.relname),
                   pg_catalog.pg_get_expr(c.relpartbound, c.oid),
                   CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid) END,
                   c.relpersistence::text,
                   pg_catalog.quote_ident(fs.srvname),
                   (SELECT pg_catalog.string_agg(
                               pg_catalog.quote_ident(o.option_name) || ' ' || pg_catalog.quote_literal(o.option_value),
                               ', ')
                    FROM pg_catalog.pg_options_to_table(ft.ftoptions) o)
            FROM parts
            JOIN pg_catalog.pg_class c ON c.oid = parts.relid
            JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace
            JOIN pg_catalog.pg_class p ON p.oid = parts.parent
            JOIN pg_catalog.pg_namespace pn ON pn.oid = p.relnamespace
            LEFT JOIN pg_catalog.pg_foreign_table ft ON ft.ftrelid = c.oid AND c.relkind = 'f'
            LEFT JOIN pg_catalog.pg_foreign_server fs ON fs.oid = ft.ftserver
            WHERE c.relispartition
              AND c.relkind IN ('r', 'p', 'f')
            ORDER BY parts.depth, cn.nspname, c.relname
            """
    }

    // What a partition holds of its own, as `PARTITION OF` element list entries: a default or NOT NULL its parent's
    // column lacks, and a key or check it declares itself. The server copies the parent's into every new partition.
    static func partitionElementsQuery(
        schema: String,
        table: String,
        scope: PartitionScope,
        capabilities: PostgreSQLCapabilities
    ) -> String {
        let notGenerated = capabilities.hasGeneratedColumns ? "a.attgenerated = ''" : "true"
        let ownDefault = """
            d.oid IS NOT NULL AND (pd.oid IS NULL
                OR pg_catalog.pg_get_expr(d.adbin, d.adrelid) IS DISTINCT FROM pg_catalog.pg_get_expr(pd.adbin, pd.adrelid))
            """
        return """
            \(partitionRelations(schema: schema, table: table, scope: scope))
            SELECT pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(c.relname), elements.element
            FROM (
                SELECT parts.relid, parts.depth, 0 AS kind, a.attnum::int AS position,
                       pg_catalog.quote_ident(a.attname) || ' WITH OPTIONS'
                           || CASE WHEN \(ownDefault) THEN ' DEFAULT ' || pg_catalog.pg_get_expr(d.adbin, d.adrelid) ELSE '' END
                           || CASE WHEN a.attnotnull AND NOT pa.attnotnull THEN ' NOT NULL' ELSE '' END AS element
                FROM parts
                JOIN pg_catalog.pg_attribute a ON a.attrelid = parts.relid AND a.attnum > 0 AND NOT a.attisdropped
                JOIN pg_catalog.pg_attribute pa
                    ON pa.attrelid = parts.parent AND pa.attname = a.attname AND NOT pa.attisdropped
                LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                LEFT JOIN pg_catalog.pg_attrdef pd ON pd.adrelid = pa.attrelid AND pd.adnum = pa.attnum
                WHERE \(notGenerated)
                  AND ((\(ownDefault)) OR (a.attnotnull AND NOT pa.attnotnull))
                UNION ALL
                SELECT parts.relid, parts.depth, 1,
                       CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 ELSE 3 END,
                       'CONSTRAINT ' || pg_catalog.quote_ident(con.conname) || ' '
                           || pg_catalog.pg_get_constraintdef(con.oid, true)
                FROM parts
                JOIN pg_catalog.pg_constraint con ON con.conrelid = parts.relid
                WHERE con.contype IN ('p', 'u', 'c', 'x')
                  AND con.conislocal
                  AND con.coninhcount = 0
            ) AS elements
            JOIN pg_catalog.pg_class c ON c.oid = elements.relid
            JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace
            ORDER BY elements.depth, cn.nspname, c.relname, elements.kind, elements.position, elements.element
            """
    }

    // An index a partition has of its own: no parent index it is attached to, and no constraint of the partition's
    // behind it, which the element list already declares.
    static func partitionIndexesQuery(schema: String, table: String) -> String {
        """
            \(partitionRelations(schema: schema, table: table, scope: .below))
            SELECT pg_catalog.pg_get_indexdef(i.indexrelid)
            FROM parts
            JOIN pg_catalog.pg_index i ON i.indrelid = parts.relid
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            JOIN pg_catalog.pg_class c ON c.oid = parts.relid
            JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace
            WHERE i.indisvalid
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_inherits ih WHERE ih.inhrelid = i.indexrelid)
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_constraint con
                  WHERE con.conrelid = parts.relid AND con.conindid = i.indexrelid AND con.contype IN ('p', 'u', 'x'))
            ORDER BY parts.depth, cn.nspname, c.relname, ic.relname
            """
    }

    // Rows are the partition, then what `PostgreSQLCommentStatements.catalogQuery` projects. A foreign table partition
    // is not created, so its comments are left out too.
    static func partitionCommentsQuery(schema: String, table: String) -> String {
        """
            \(partitionRelations(schema: schema, table: table, scope: .below))
            SELECT target, relkind, attname, description
            FROM (
                SELECT pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(c.relname) AS target,
                       parts.depth, c.relkind::text AS relkind, NULL::text AS attname,
                       pg_catalog.obj_description(c.oid, 'pg_class') AS description, 0 AS attnum
                FROM parts
                JOIN pg_catalog.pg_class c ON c.oid = parts.relid
                JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace
                WHERE c.relkind <> 'f'
                  AND pg_catalog.obj_description(c.oid, 'pg_class') IS NOT NULL
                UNION ALL
                SELECT pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(c.relname),
                       parts.depth, c.relkind::text, a.attname::text,
                       pg_catalog.col_description(c.oid, a.attnum), a.attnum::int
                FROM parts
                JOIN pg_catalog.pg_class c ON c.oid = parts.relid
                JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace
                JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                WHERE c.relkind <> 'f'
                  AND pg_catalog.col_description(c.oid, a.attnum) IS NOT NULL
            ) AS partition_comments
            ORDER BY depth, target, attnum
            """
    }

    private static func partitionRelations(schema: String, table: String, scope: PartitionScope) -> String {
        let nameLiteral = PostgreSQLObjectQueries.quoteLiteral(table)
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        switch scope {
        case .below:
            return """
                WITH RECURSIVE parts AS (
                    SELECT i.inhrelid AS relid, i.inhparent AS parent, 1 AS depth
                    FROM pg_catalog.pg_inherits i
                    JOIN pg_catalog.pg_class root ON root.oid = i.inhparent
                    JOIN pg_catalog.pg_namespace rn ON rn.oid = root.relnamespace
                    WHERE root.relname = \(nameLiteral)
                      AND rn.nspname = \(schemaLiteral)
                      AND root.relkind = 'p'
                    UNION ALL
                    SELECT i.inhrelid, i.inhparent, parts.depth + 1
                    FROM pg_catalog.pg_inherits i
                    JOIN parts ON parts.relid = i.inhparent
                )
                """
        case .itself:
            return """
                WITH parts AS (
                    SELECT c.oid AS relid, i.inhparent AS parent, 0 AS depth
                    FROM pg_catalog.pg_class c
                    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    JOIN pg_catalog.pg_inherits i ON i.inhrelid = c.oid
                    WHERE c.relname = \(nameLiteral)
                      AND n.nspname = \(schemaLiteral)
                      AND c.relispartition
                )
                """
        }
    }

    // Rows from `partitionElementsQuery`, by the partition's qualified name.
    static func elementsByPartition(_ rows: [[String?]]) -> [String: [String]] {
        var grouped: [String: [String]] = [:]
        for row in rows {
            guard row.count >= 2, let name = row[0], let element = row[1], !element.isEmpty else { continue }
            grouped[name, default: []].append(element)
        }
        return grouped
    }

    static func partitionComments(_ rows: [[String?]]) -> [String] {
        rows.compactMap { row in
            guard let target = row.first ?? nil, !target.isEmpty else { return nil }
            return PostgreSQLCommentStatements.statement(target: target, row: Array(row.dropFirst()))
        }
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
        func text(_ index: Int) -> String? {
            guard row.indices.contains(index), let value = row[index], !value.isEmpty else { return nil }
            return value
        }
        return Partition(
            name: name,
            parent: parent,
            bound: bound,
            partitionKey: key,
            isUnlogged: row[4] == "u",
            foreignServer: text(5),
            foreignOptions: text(6)
        )
    }

    static func createTable(name: String, definitions: [String], shape: Shape) -> String {
        let partitionBy = shape.partitionKey.map { " PARTITION BY \($0)" } ?? ""
        if let parent = shape.partitionOf, let bound = shape.partitionBound {
            let isUnlogged = shape.isUnlogged && shape.partitionKey == nil
            let elements = elementList(shape.partitionElements)
            return "\(keyword(isUnlogged: isUnlogged)) \(name) PARTITION OF \(parent)\(elements) \(bound)\(partitionBy);"
        }
        // PostgreSQL 18 refuses an unlogged partitioned table, and before it the flag did nothing on the parent.
        let isUnlogged = shape.isUnlogged && shape.partitionKey == nil
        return "\(keyword(isUnlogged: isUnlogged)) \(name) (\n  "
            + definitions.joined(separator: ",\n  ")
            + "\n)\(partitionBy);"
    }

    // A foreign table partition is written as a comment. The export reads its rows through the parent, and replayed
    // into a partition on that server they would be written to the remote table a second time.
    static func createPartition(_ partition: Partition) -> String {
        if let server = partition.foreignServer {
            let options = partition.foreignOptions.map { " OPTIONS (\($0))" } ?? ""
            let statement = "CREATE FOREIGN TABLE \(partition.name) PARTITION OF \(partition.parent)"
                + "\(elementList(partition.elements)) \(partition.bound) SERVER \(server)\(options);"
            let note = "\(partition.name) is a foreign table partition on server \(server), left out so a restore writes"
                + " nothing\nto that server. Rows exported for it have no partition until it is created:\n"
            // Every line break the server's lexer ends a comment at, a carriage return included, starts a new comment.
            return (note + statement).components(separatedBy: .newlines).map { "-- " + $0 }.joined(separator: "\n")
        }
        return createTable(
            name: partition.name,
            definitions: [],
            shape: Shape(
                isUnlogged: partition.isUnlogged,
                partitionKey: partition.partitionKey,
                partitionOf: partition.parent,
                partitionBound: partition.bound,
                partitionElements: partition.elements
            )
        )
    }

    // A partition's own indexes and comments follow every partition, since one may name a partition created later.
    static func script(
        name: String,
        definitions: [String],
        shape: Shape,
        partitions: [Partition],
        partitionIndexes: [String] = [],
        partitionComments: [String] = []
    ) -> String {
        let indexes = partitionIndexes.map { indexCoveringPartitions($0) + ";" }
        let comments = partitionComments.map { $0 + ";" }
        return ([createTable(name: name, definitions: definitions, shape: shape)] + partitions.map(createPartition)
            + indexes + comments)
            .joined(separator: "\n\n")
    }

    private static func elementList(_ elements: [String]) -> String {
        elements.isEmpty ? "" : " (\n  " + elements.joined(separator: ",\n  ") + "\n)"
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
