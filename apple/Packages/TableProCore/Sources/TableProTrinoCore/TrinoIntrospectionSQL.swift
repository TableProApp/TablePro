import Foundation

public enum TrinoIntrospectionSQL {
    // `.literal` matches code units; the default skips a quote that a combining mark follows.
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
    }

    public static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''", options: .literal) + "'"
    }

    // `IN ()` does not parse.
    private static func membership(_ column: String, in values: [String]) -> String {
        guard !values.isEmpty else { return "false" }
        return "\(column) IN (\(values.map(quoteLiteral).joined(separator: ", ")))"
    }

    public static func qualifiedName(catalog: String?, schema: String?, table: String) -> String {
        var parts: [String] = []
        if let catalog, !catalog.isEmpty {
            parts.append(quoteIdentifier(catalog))
        }
        if let schema, !schema.isEmpty {
            parts.append(quoteIdentifier(schema))
        }
        parts.append(quoteIdentifier(table))
        return parts.joined(separator: ".")
    }

    public static func showCatalogs() -> String {
        "SHOW CATALOGS"
    }

    public static func showSchemas(catalog: String) -> String {
        "SHOW SCHEMAS FROM \(quoteIdentifier(catalog))"
    }

    public static func listTables(catalog: String, schema: String) -> String {
        """
        SELECT table_name, table_type FROM \(quoteIdentifier(catalog)).information_schema.tables \
        WHERE table_schema = \(quoteLiteral(schema)) ORDER BY table_name
        """
    }

    public static func listTables(catalog: String, inSchemas schemas: [String]) -> String {
        """
        SELECT table_name, table_type, table_schema FROM \(quoteIdentifier(catalog)).information_schema.tables \
        WHERE \(membership("table_schema", in: schemas)) ORDER BY table_schema, table_name
        """
    }

    public static func listColumns(catalog: String, schema: String, table: String) -> String {
        """
        SELECT column_name, data_type, is_nullable, column_default, comment, ordinal_position \
        FROM \(quoteIdentifier(catalog)).information_schema.columns \
        WHERE table_schema = \(quoteLiteral(schema)) AND table_name = \(quoteLiteral(table)) \
        ORDER BY ordinal_position
        """
    }

    public static func listAllColumns(catalog: String, schema: String) -> String {
        """
        SELECT table_name, column_name, data_type, is_nullable, column_default, comment, ordinal_position \
        FROM \(quoteIdentifier(catalog)).information_schema.columns \
        WHERE table_schema = \(quoteLiteral(schema)) ORDER BY table_name, ordinal_position
        """
    }

    // Presto has no `system.metadata.table_comments` and no other table that carries the comment.
    public static func tableComment(
        catalog: String,
        schema: String,
        table: String,
        flavor: TrinoServerFlavor
    ) -> String? {
        guard flavor == .trino else { return nil }
        return """
            SELECT comment FROM system.metadata.table_comments \
            WHERE catalog_name = \(quoteLiteral(catalog)) AND schema_name = \(quoteLiteral(schema)) \
            AND table_name = \(quoteLiteral(table))
            """
    }

    public static func listMaterializedViews(catalog: String, schema: String, flavor: TrinoServerFlavor) -> String {
        switch flavor {
        case .trino:
            return """
                SELECT name FROM system.metadata.materialized_views \
                WHERE catalog_name = \(quoteLiteral(catalog)) AND schema_name = \(quoteLiteral(schema))
                """
        case .presto:
            return """
                SELECT table_name FROM \(quoteIdentifier(catalog)).information_schema.materialized_views \
                WHERE table_schema = \(quoteLiteral(schema))
                """
        }
    }

    public static func listMaterializedViews(
        catalog: String,
        inSchemas schemas: [String],
        flavor: TrinoServerFlavor
    ) -> String {
        switch flavor {
        case .trino:
            return """
                SELECT name, schema_name FROM system.metadata.materialized_views \
                WHERE catalog_name = \(quoteLiteral(catalog)) AND \(membership("schema_name", in: schemas))
                """
        case .presto:
            return """
                SELECT table_name, table_schema FROM \(quoteIdentifier(catalog)).information_schema.materialized_views \
                WHERE \(membership("table_schema", in: schemas))
                """
        }
    }

    /// One relation's `table_type`, which says `VIEW` for a view. A materialized view is not told
    /// apart here: ``materializedView(catalog:schema:name:flavor:)`` answers for it.
    public static func relationType(catalog: String, schema: String, table: String) -> String {
        """
        SELECT table_type FROM \(quoteIdentifier(catalog)).information_schema.tables \
        WHERE table_schema = \(quoteLiteral(schema)) AND table_name = \(quoteLiteral(table))
        """
    }

    public static func materializedView(
        catalog: String,
        schema: String,
        name: String,
        flavor: TrinoServerFlavor
    ) -> String {
        let nameColumn = flavor == .trino ? "name" : "table_name"
        return listMaterializedViews(catalog: catalog, schema: schema, flavor: flavor)
            + " AND \(nameColumn) = \(quoteLiteral(name))"
    }

    public static func approximateRowCount(catalog: String?, schema: String?, table: String) -> String {
        "SHOW STATS FOR \(qualifiedName(catalog: catalog, schema: schema, table: table))"
    }

    public static func showCreateTable(catalog: String?, schema: String?, table: String) -> String {
        "SHOW CREATE TABLE \(qualifiedName(catalog: catalog, schema: schema, table: table))"
    }

    public static func showCreateView(catalog: String?, schema: String?, view: String) -> String {
        "SHOW CREATE VIEW \(qualifiedName(catalog: catalog, schema: schema, table: view))"
    }

    public static func showCreateMaterializedView(catalog: String?, schema: String?, view: String) -> String {
        "SHOW CREATE MATERIALIZED VIEW \(qualifiedName(catalog: catalog, schema: schema, table: view))"
    }
}
