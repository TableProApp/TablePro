import Foundation

public enum TrinoIntrospectionSQL {
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
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

    public static func tableComment(catalog: String, schema: String, table: String) -> String {
        """
        SELECT comment FROM system.metadata.table_comments \
        WHERE catalog_name = \(quoteLiteral(catalog)) AND schema_name = \(quoteLiteral(schema)) \
        AND table_name = \(quoteLiteral(table))
        """
    }

    public static func listMaterializedViews(catalog: String, schema: String) -> String {
        """
        SELECT name FROM system.metadata.materialized_views \
        WHERE catalog_name = \(quoteLiteral(catalog)) AND schema_name = \(quoteLiteral(schema))
        """
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
}
