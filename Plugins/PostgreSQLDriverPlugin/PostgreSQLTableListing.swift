import Foundation
import TableProPluginKit

nonisolated enum PostgreSQLTableListingScope: Sendable, Equatable {
    case schema(String)
    case allSchemas
}

nonisolated enum PostgreSQLTableListing {
    /// Lists user-visible schemas, excluding PostgreSQL's built-in `pg_*`
    /// namespaces and `information_schema`.
    ///
    /// The underscore in the `LIKE` pattern is escaped so it is matched
    /// literally; without an `ESCAPE` clause, `_` would be SQL LIKE's
    /// single-char wildcard and `'pg_%'` would also exclude legitimate user
    /// schemas such as `pgboss`, `pgcrypto`, or `pgvector`.
    static let visibleSchemas = """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT LIKE 'pg!_%' ESCAPE '!'
          AND schema_name <> 'information_schema'
        ORDER BY schema_name
        """

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
        query(
            in: .schema(schema),
            includeMaterializedViews: includeMaterializedViews,
            includeForeignTables: includeForeignTables,
            includeComments: includeComments,
            includePartitionAwareness: includePartitionAwareness
        )
    }

    /// The same listing over one schema or over every schema `visibleSchemas` returns. The second
    /// filters by that query itself rather than restating its predicate, so a table is listed here
    /// exactly when its schema is listed there, and projects each row's schema, which the
    /// one-schema listing leaves to the caller.
    static func query(
        in listing: PostgreSQLTableListingScope,
        includeMaterializedViews: Bool,
        includeForeignTables: Bool,
        includeComments: Bool = true,
        includePartitionAwareness: Bool = true
    ) -> String {
        func schemaFilter(_ column: String) -> String {
            switch listing {
            case .schema(let schema):
                return "\(column) = \(PostgreSQLObjectQueries.quoteLiteral(schema))"
            case .allSchemas:
                return "\(column) IN (\n\(visibleSchemas)\n)"
            }
        }
        func schemaColumn(_ column: String) -> String {
            listing == .allSchemas ? ",\n       \(column) AS schema_name" : ""
        }
        let orderBy = listing == .allSchemas ? "ORDER BY schema_name, table_name" : "ORDER BY table_name"
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
                   \(partitionCountColumn) AS partition_count\(schemaColumn("t.table_schema"))
            FROM information_schema.tables t\(classJoin)
            WHERE \(schemaFilter("t.table_schema"))
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
                       NULL::bigint AS partition_count\(schemaColumn("m.schemaname"))
                FROM pg_matviews m\(matviewJoin)
                WHERE \(schemaFilter("m.schemaname"))
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
                       NULL::bigint AS partition_count\(schemaColumn("n.nspname"))
                FROM pg_foreign_table ft
                JOIN pg_class c ON c.oid = ft.ftrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE \(schemaFilter("n.nspname"))\(foreignPartitionFilter)
                """
            )
        }

        return unions.joined(separator: "\nUNION ALL\n") + "\n" + orderBy
    }

    static func table(fromRow row: [String?]) -> PluginTableInfo? {
        guard let name = row[safe: 0] ?? nil else { return nil }
        return PluginTableInfo(
            name: name,
            type: relationType(listed: row[safe: 1] ?? nil),
            schema: row[safe: 4] ?? nil,
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
