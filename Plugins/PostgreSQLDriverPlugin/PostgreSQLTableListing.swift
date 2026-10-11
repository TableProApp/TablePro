import Foundation
import TableProPluginKit

nonisolated enum PostgreSQLTableListingScope: Sendable, Equatable {
    case schema(String)
    case schemas([String])
    case allSchemas

    var projectsSchema: Bool {
        switch self {
        case .schema: false
        case .schemas, .allSchemas: true
        }
    }
}

nonisolated enum PostgreSQLTableListing {
    /// The underscore is escaped because `_` is a LIKE wildcard: a bare `'pg_%'` also hid user
    /// schemas such as `pgboss` and `pgvector`.
    static let visibleSchemas = """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT LIKE 'pg!_%' ESCAPE '!'
          AND schema_name <> 'information_schema'
        ORDER BY schema_name
        """

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

    /// `pg_class` under `information_schema.tables`' own row test: the view runs its privilege
    /// checks on every relation in the database before any schema filter applies.
    static func query(
        in listing: PostgreSQLTableListingScope,
        includeMaterializedViews: Bool,
        includeForeignTables: Bool,
        includeComments: Bool = true,
        includePartitionAwareness: Bool = true
    ) -> String {
        var labels: [(kind: String, label: String)] = includePartitionAwareness ? [("p", "PARTITIONED TABLE")] : []
        labels.append(("v", "VIEW"))
        if includeMaterializedViews { labels.append(("m", "MATERIALIZED VIEW")) }
        if includeForeignTables { labels.append(("f", "FOREIGN TABLE")) }
        let kinds = ["r", "p"] + labels.map(\.kind).filter { $0 != "p" }
        let tableType = "CASE c.relkind\n"
            + labels.map {
                "           WHEN \(PostgreSQLObjectQueries.quoteLiteral($0.kind)) THEN \(PostgreSQLObjectQueries.quoteLiteral($0.label))\n"
            }.joined()
            + "           ELSE 'BASE TABLE' END"

        let commentColumn = includeComments ? "d.description" : "NULL::text"
        let partitionCountColumn = includePartitionAwareness
            ? "CASE WHEN c.relkind = 'p' THEN (SELECT pg_catalog.count(*) FROM pg_catalog.pg_inherits ci WHERE ci.inhparent = c.oid) END"
            : "NULL::bigint"
        let schemaColumn = listing.projectsSchema ? ",\n       c.nspname AS schema_name" : ""
        // Unfenced, a reader's five-schema listing ran 42 ms instead of 12; one schema is fastest unfenced.
        let fence = listing.projectsSchema ? "\n      OFFSET 0" : ""
        let commentJoin = includeComments ? """

            LEFT JOIN pg_catalog.pg_description d
                ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objsubid = 0
            """ : ""
        // `relkind = 'p'` rather than `relispartition`, which is PostgreSQL 10. `OFFSET 0` keeps one index
        // probe per row: as an anti join a misestimate rescanned every partition per row (76 ms, not 16).
        let partitionExclusion = includePartitionAwareness ? """

              AND NOT EXISTS (
                    SELECT 1
                    FROM pg_catalog.pg_inherits i
                    JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                    WHERE i.inhrelid = c.oid
                      AND parent.relkind = 'p'
                      AND NOT pg_catalog.pg_is_other_temp_schema(parent.relnamespace)
                      AND \(visibleRelation("parent"))
                    OFFSET 0)
            """ : ""

        return """
            SELECT c.relname AS table_name,
                   \(tableType) AS table_type,
                   \(commentColumn) AS table_comment,
                   \(partitionCountColumn) AS partition_count\(schemaColumn)
            FROM (SELECT rc.oid, rc.relname, rc.relkind, rc.relowner, n.oid AS nspoid, n.nspname
                  FROM pg_catalog.pg_class rc
                  JOIN pg_catalog.pg_namespace n ON n.oid = rc.relnamespace
                  WHERE \(namespaceFilter(listing, column: "n.nspname"))
                    AND \(PostgreSQLObjectQueries.membership("rc.relkind", in: kinds))\(fence)) c\(commentJoin)
            WHERE c.nspoid <> pg_catalog.pg_my_temp_schema()
              AND NOT pg_catalog.pg_is_other_temp_schema(c.nspoid)
              AND \(visibleRelation("c"))\(partitionExclusion)
            \(orderBy(listing))
            """
    }

    /// The last rung, for an engine missing a catalog, function or column the catalog form names.
    static func informationSchemaQuery(in listing: PostgreSQLTableListingScope) -> String {
        let schemaColumn = listing.projectsSchema ? ",\n       t.table_schema AS schema_name" : ""
        return """
            SELECT t.table_name, t.table_type AS table_type,
                   NULL::text AS table_comment,
                   NULL::bigint AS partition_count\(schemaColumn)
            FROM information_schema.tables t
            WHERE \(namespaceFilter(listing, column: "t.table_schema"))
              AND t.table_type IN ('BASE TABLE', 'VIEW')
            \(orderBy(listing))
            """
    }

    /// `information_schema.tables`' row test, so a relation is listed here exactly when that view
    /// would list it.
    static func visibleRelation(_ alias: String) -> String {
        """
        (pg_catalog.pg_has_role(\(alias).relowner, 'USAGE')
                   OR pg_catalog.has_table_privilege(\(alias).oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   OR pg_catalog.has_any_column_privilege(\(alias).oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
        """
    }

    /// The all-schema form filters by the schema list query itself, so a table is listed exactly
    /// when `fetchSchemas()` lists its schema, whatever rule `schemata` applies on that release.
    private static func namespaceFilter(_ listing: PostgreSQLTableListingScope, column: String) -> String {
        switch listing {
        case .schema(let schema):
            return "\(column) = \(PostgreSQLObjectQueries.quoteLiteral(schema))"
        case .schemas(let schemas):
            return PostgreSQLObjectQueries.membership(column, in: schemas)
        case .allSchemas:
            return "\(column) IN (\n\(visibleSchemas)\n)"
        }
    }

    private static func orderBy(_ listing: PostgreSQLTableListingScope) -> String {
        listing.projectsSchema ? "ORDER BY schema_name, table_name" : "ORDER BY table_name"
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
}
