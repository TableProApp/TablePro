//
//  PostgreSQLCommentStatements.swift
//  PostgreSQLDriverPlugin
//
//  The COMMENT statements that reattach one relation's comment and its column comments. Pure, so it
//  is testable without a server.
//

import Foundation

nonisolated public enum PostgreSQLCommentStatements {
    /// The relation's own comment first, then one row per commented column in `attnum` order, which
    /// is the order `pg_dump` writes them in.
    ///
    /// `relkind` rides on every row, the column rows included, because it is what decides the
    /// keyword `COMMENT ON` takes and a relation with no comment of its own still has columns to
    /// write. A row with no description is filtered out here rather than rendered as `IS NULL`, which
    /// would erase a comment instead of restoring one.
    public static func catalogQuery(name: String, schema: String) -> String {
        catalogStatement(name: name, schema: schema)
    }

    // The per-relation read with its relname predicate dropped and the relation's name projected last.
    public static func schemaCatalogQuery(schema: String) -> String {
        catalogStatement(name: nil, schema: schema)
    }

    private static func catalogStatement(name: String?, schema: String) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let namePredicate = name.map { "\n      AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
        let relation = name == nil ? ",\n        c.relname AS relname" : ""
        let projection = name == nil ? "relkind, attname, description, relname" : "relkind, attname, description"
        let order = name == nil ? "relname, ordinal, attnum" : "ordinal, attnum"
        return """
        SELECT \(projection)
        FROM (
            SELECT
                c.relkind::text AS relkind,
                NULL::text AS attname,
                pg_catalog.obj_description(c.oid, 'pg_class') AS description,
                0 AS ordinal,
                0 AS attnum\(relation)
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schemaLiteral)\(namePredicate)
              AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
              AND pg_catalog.obj_description(c.oid, 'pg_class') IS NOT NULL
            UNION ALL
            SELECT
                c.relkind::text AS relkind,
                a.attname AS attname,
                pg_catalog.col_description(c.oid, a.attnum) AS description,
                1 AS ordinal,
                a.attnum AS attnum\(relation)
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
            WHERE n.nspname = \(schemaLiteral)\(namePredicate)
              AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND pg_catalog.col_description(c.oid, a.attnum) IS NOT NULL
        ) AS relation_comments
        ORDER BY \(order)
        """
    }

    /// `objsubid = 0` is the relation's own row; a column's row carries its ordinal.
    public static func relationCommentQuery(name: String, schema: String) -> String {
        """
        SELECT d.description
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_description d ON d.objoid = c.oid AND d.objsubid = 0
        WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral(name))
        """
    }

    /// Renders what `catalogQuery` answered. Rows are projected as `relkind`, `attname`,
    /// `description`, and a nil `attname` marks the relation's own comment.
    public static func statements(name: String, schema: String, rows: [[String?]]) -> [String] {
        let target = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: name)
        return rows.compactMap { statement(target: target, row: $0) }
    }

    // `target` is already qualified and quoted.
    static func statement(target: String, row: [String?]) -> String? {
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
