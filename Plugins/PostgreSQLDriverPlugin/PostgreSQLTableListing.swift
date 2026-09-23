import Foundation
import TableProPluginKit

nonisolated enum PostgreSQLTableListing {
    /// Lists tables and views, optionally including materialized views and
    /// foreign tables. The optional unions reference `pg_matviews` and
    /// `pg_foreign_table`, which some PostgreSQL-compatible engines do not
    /// implement; the caller passes `false` when those catalogs are absent so
    /// the whole query does not fail with `relation does not exist`.
    ///
    /// `includeComments` projects each table's comment via `obj_description`
    /// over the relation's oid. Engines that lack that function fail the whole
    /// listing, so the caller passes `false` to fall back to a comment-free
    /// listing.
    ///
    /// `includePartitionAwareness` labels a declarative partition parent as
    /// `PARTITIONED TABLE`, counts its partitions, and drops its partition
    /// children, which `information_schema.tables` reports as plain
    /// `BASE TABLE` rows indistinguishable from the parent. The test is
    /// `pg_inherits` joined to the parent's `relkind`, not
    /// `pg_class.relispartition`: `relispartition` only exists from PostgreSQL
    /// 10, and referencing a missing column fails at parse time, which would
    /// break the listing outright on older servers. Comparing `relkind` against
    /// `'p'`/`'I'` is a value test on a column present since PostgreSQL 8, so it
    /// parses everywhere and simply matches nothing before declarative
    /// partitioning existed. Rows still come from `information_schema.tables`,
    /// which keeps its privilege filtering; the catalog joins only label, count
    /// and exclude rows it already returned. The caller passes `false` for
    /// engines without these catalogs.
    ///
    /// A child is dropped only when its parent is itself listed. Keying the
    /// exclusion on the child alone hid a partition whose parent the role cannot
    /// read: granting `SELECT` on one partition and nothing on its parent left
    /// the whole schema listing empty while that partition was perfectly
    /// readable. The visibility test reuses `information_schema.tables` rather
    /// than restating its privilege predicate, so the two cannot drift.
    ///
    /// Legacy `INHERITS` children stay listed on purpose. Their parent is an
    /// ordinary table (`relkind = 'r'`), and they are independently useful
    /// tables rather than an implementation detail of one parent.
    static func query(
        schema: String,
        includeMaterializedViews: Bool,
        includeForeignTables: Bool,
        includeComments: Bool = true,
        includePartitionAwareness: Bool = true
    ) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        func commentColumn(_ oidExpression: String) -> String {
            includeComments ? "obj_description(\(oidExpression), 'pg_class')" : "NULL::text"
        }

        let classJoin = (includeComments || includePartitionAwareness) ? """

            LEFT JOIN pg_catalog.pg_namespace pn ON pn.nspname = t.table_schema
            LEFT JOIN pg_catalog.pg_class pc ON pc.relnamespace = pn.oid AND pc.relname = t.table_name
            """ : ""

        let tableTypeColumn = includePartitionAwareness
            ? "CASE WHEN pc.relkind = 'p' THEN 'PARTITIONED TABLE' ELSE t.table_type END"
            : "t.table_type"

        let partitionCountColumn = includePartitionAwareness ? """
            CASE WHEN pc.relkind = 'p' THEN (
                       SELECT count(*)
                       FROM pg_catalog.pg_inherits ci
                       WHERE ci.inhparent = pc.oid) END
            """ : "NULL::bigint"

        let partitionFilter = includePartitionAwareness
            ? "\n  " + partitionChildExclusion(childOidExpression: "pc.oid")
            : ""

        var unions: [String] = [
            """
            SELECT t.table_name, \(tableTypeColumn) AS table_type,
                   \(commentColumn("pc.oid")) AS table_comment,
                   \(partitionCountColumn) AS partition_count
            FROM information_schema.tables t\(classJoin)
            WHERE t.table_schema = \(schemaLiteral)
              AND t.table_type IN ('BASE TABLE', 'VIEW')\(partitionFilter)
            """
        ]

        if includeMaterializedViews {
            let matviewJoin = includeComments ? """

                LEFT JOIN pg_catalog.pg_namespace mn ON mn.nspname = m.schemaname
                LEFT JOIN pg_catalog.pg_class mc ON mc.relnamespace = mn.oid AND mc.relname = m.matviewname
                """ : ""
            unions.append(
                """
                SELECT m.matviewname AS table_name, 'MATERIALIZED VIEW' AS table_type,
                       \(commentColumn("mc.oid")) AS table_comment,
                       NULL::bigint AS partition_count
                FROM pg_matviews m\(matviewJoin)
                WHERE m.schemaname = \(schemaLiteral)
                """
            )
        }

        if includeForeignTables {
            let foreignPartitionFilter = includePartitionAwareness
                ? "\n  " + partitionChildExclusion(childOidExpression: "c.oid")
                : ""
            unions.append(
                """
                SELECT c.relname AS table_name, 'FOREIGN TABLE' AS table_type,
                       \(commentColumn("c.oid")) AS table_comment,
                       NULL::bigint AS partition_count
                FROM pg_foreign_table ft
                JOIN pg_class c ON c.oid = ft.ftrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(schemaLiteral)\(foreignPartitionFilter)
                """
            )
        }

        return unions.joined(separator: "\nUNION ALL\n") + "\nORDER BY table_name"
    }

    static func table(fromRow row: [String?]) -> PluginTableInfo? {
        guard let name = row[safe: 0] ?? nil else { return nil }
        return PluginTableInfo(
            name: name,
            type: relationType(listed: row[safe: 1] ?? nil),
            comment: (row[safe: 2] ?? nil)?.nilIfEmpty,
            partitionCount: (row[safe: 3] ?? nil).flatMap(Int.init)
        )
    }

    private static func relationType(listed: String?) -> String {
        switch listed {
        case "PARTITIONED TABLE": return "PARTITIONED TABLE"
        case "MATERIALIZED VIEW": return "MATERIALIZED VIEW"
        case "FOREIGN TABLE": return "FOREIGN TABLE"
        case "VIEW": return "VIEW"
        default: return "TABLE"
        }
    }

    /// The predicate that keeps a partition out of a flat listing. A foreign
    /// table can be a partition from PostgreSQL 11, so the foreign-table union
    /// arm needs it as much as the base arm does: without it one relation was
    /// listed flat under Foreign Tables and nested under its parent at once.
    private static func partitionChildExclusion(childOidExpression: String) -> String {
        """
            AND NOT EXISTS (
                  SELECT 1
                  FROM pg_catalog.pg_inherits i
                  JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                  JOIN pg_catalog.pg_namespace parentns ON parentns.oid = parent.relnamespace
                  WHERE i.inhrelid = \(childOidExpression)
                    AND parent.relkind IN ('p', 'I')
                    AND EXISTS (
                          SELECT 1
                          FROM information_schema.tables pt
                          WHERE pt.table_schema = parentns.nspname
                            AND pt.table_name = parent.relname))
        """
    }
}
