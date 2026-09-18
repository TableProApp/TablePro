//
//  PostgreSQLCommentStatements.swift
//  PostgreSQLDriverPlugin
//
//  The COMMENT statements that reattach one relation's comment and its column comments. Pure, so it
//  is testable without a server.
//

import Foundation

public enum PostgreSQLCommentStatements {
    /// The relation's own comment first, then one row per commented column in `attnum` order, which
    /// is the order `pg_dump` writes them in.
    ///
    /// `relkind` rides on every row, the column rows included, because it is what decides the
    /// keyword `COMMENT ON` takes and a relation with no comment of its own still has columns to
    /// write. A row with no description is filtered out here rather than rendered as `IS NULL`, which
    /// would erase a comment instead of restoring one.
    public static func catalogQuery(name: String, schema: String) -> String {
        let nameLiteral = PostgreSQLObjectQueries.quoteLiteral(name)
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        return """
        SELECT relkind, attname, description
        FROM (
            SELECT
                c.relkind::text AS relkind,
                NULL::text AS attname,
                pg_catalog.obj_description(c.oid, 'pg_class') AS description,
                0 AS ordinal,
                0 AS attnum
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schemaLiteral)
              AND c.relname = \(nameLiteral)
              AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
              AND pg_catalog.obj_description(c.oid, 'pg_class') IS NOT NULL
            UNION ALL
            SELECT
                c.relkind::text AS relkind,
                a.attname AS attname,
                pg_catalog.col_description(c.oid, a.attnum) AS description,
                1 AS ordinal,
                a.attnum AS attnum
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
            WHERE n.nspname = \(schemaLiteral)
              AND c.relname = \(nameLiteral)
              AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND pg_catalog.col_description(c.oid, a.attnum) IS NOT NULL
        ) AS relation_comments
        ORDER BY ordinal, attnum
        """
    }

    /// Renders what `catalogQuery` answered. Rows are projected as `relkind`, `attname`,
    /// `description`, and a nil `attname` marks the relation's own comment.
    public static func statements(name: String, schema: String, rows: [[String?]]) -> [String] {
        let target = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: name)
        return rows.compactMap { statement(target: target, row: $0) }
    }

    private static func statement(target: String, row: [String?]) -> String? {
        guard row.count >= 3,
              let relkind = row[0],
              let keyword = PostgreSQLRelationSQL.commentKeyword(forRelkind: relkind),
              let description = row[2],
              !description.isEmpty
        else { return nil }
        let literal = PostgreSQLObjectQueries.quoteLiteral(description)
        guard let column = row[1], !column.isEmpty else {
            return "COMMENT ON \(keyword) \(target) IS \(literal)"
        }
        let columnRef = "\(target).\(PostgreSQLObjectQueries.quoteIdentifier(column))"
        return "COMMENT ON COLUMN \(columnRef) IS \(literal)"
    }
}
