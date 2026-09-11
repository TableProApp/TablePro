//
//  PostgreSQLRelationSQL.swift
//  PostgreSQLDriverPlugin
//
//  Statements that act on one table-like relation by name: comments and materialized view
//  refreshes. Pure, so it is testable without a server.
//

import Foundation
import TableProPluginKit

public enum PostgreSQLRelationSQL {
    /// The keyword `COMMENT ON` needs for each relation kind. PostgreSQL checks it against the
    /// relation's `relkind` and refuses a mismatch: `COMMENT ON TABLE` on a view fails with
    /// "is not a table", and `COMMENT ON VIEW` on a materialized view with "is not a view".
    public static func commentKeyword(forObjectType objectType: String) -> String? {
        switch objectType.uppercased() {
        case "TABLE", "PARTITIONED TABLE":
            return "TABLE"
        case "VIEW":
            return "VIEW"
        case "MATERIALIZED VIEW":
            return "MATERIALIZED VIEW"
        case "FOREIGN TABLE":
            return "FOREIGN TABLE"
        default:
            return nil
        }
    }

    /// `COMMENT` takes a literal and nothing else, so the value is quoted here rather than bound. The
    /// quoting reads the same whatever `standard_conforming_strings` is set to.
    public static func commentStatement(
        name: String,
        schema: String,
        objectType: String,
        comment: String?
    ) -> String? {
        guard let keyword = commentKeyword(forObjectType: objectType) else { return nil }
        let target = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: name)
        return "COMMENT ON \(keyword) \(target) IS \(commentValue(comment))"
    }

    public static func commentValue(_ comment: String?) -> String {
        guard let comment, !comment.isEmpty else { return "NULL" }
        return PostgreSQLObjectQueries.quoteLiteral(comment)
    }

    public static func refreshStatement(name: String, schema: String, concurrently: Bool) -> String {
        let target = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: name)
        return concurrently
            ? "REFRESH MATERIALIZED VIEW CONCURRENTLY \(target)"
            : "REFRESH MATERIALIZED VIEW \(target)"
    }

    /// A concurrent refresh diffs the new result against the stored rows through a unique index,
    /// so it needs one the server can use for every row: valid, immediate, on plain columns and
    /// without a predicate. It also needs rows to diff against, which an unpopulated view lacks.
    /// Measured on PostgreSQL 17 against every index shape `scripts/check-postgres-matview-refresh.sh`
    /// builds; that script re-checks the predicate against a live server.
    public static func concurrentRefreshQuery(name: String, schema: String) -> String {
        """
        SELECT
            CASE WHEN c.relispopulated THEN 1 ELSE 0 END,
            CASE WHEN EXISTS (
                SELECT 1
                FROM pg_catalog.pg_index i
                JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
                JOIN pg_catalog.pg_am am ON am.oid = ic.relam
                WHERE i.indrelid = c.oid
                  AND i.indisunique
                  AND i.indimmediate
                  AND i.indisvalid
                  AND i.indpred IS NULL
                  AND i.indexprs IS NULL
                  AND am.amname = 'btree'
            ) THEN 1 ELSE 0 END
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'm'
          AND n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral(name))
        """
    }

    /// Population is checked first: an unpopulated view is refused even when its index is fine, and
    /// the fix the user needs is a plain refresh, not a new index.
    public static func concurrentRefreshAvailability(
        isPopulated: Bool,
        hasUsableUniqueIndex: Bool
    ) -> PluginConcurrentRefreshAvailability {
        guard isPopulated else { return .requiresPopulatedView }
        return hasUsableUniqueIndex ? .available : .requiresUniqueIndex
    }
}
