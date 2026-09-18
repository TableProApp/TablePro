import Foundation

internal enum SchemaQualifiedName {
    internal static func render(
        name: String,
        schema: String?,
        implicitSchemaName: String?,
        quote: (String) -> String
    ) -> String {
        guard let schema = explicitSchema(schema, implicitSchemaName: implicitSchemaName) else {
            return quote(name)
        }
        return "\(quote(schema)).\(quote(name))"
    }

    internal static func render(
        name: String,
        schema: String?,
        databaseType: DatabaseType,
        quote: (String) -> String
    ) -> String {
        render(name: name, schema: schema, implicitSchemaName: databaseType.implicitSchemaName, quote: quote)
    }

    internal static func explicitSchema(_ schema: String?, implicitSchemaName: String?) -> String? {
        guard let schema, !schema.isEmpty, schema != implicitSchemaName else { return nil }
        return schema
    }

    internal static func explicitSchema(_ schema: String?, databaseType: DatabaseType) -> String? {
        explicitSchema(schema, implicitSchemaName: databaseType.implicitSchemaName)
    }
}
