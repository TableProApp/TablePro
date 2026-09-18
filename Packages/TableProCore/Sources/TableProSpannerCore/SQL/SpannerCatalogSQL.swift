import Foundation

public enum SpannerCatalogSQL {
    public static func schemas(dialect: SpannerDialect) -> SpannerRenderedStatement {
        SpannerRenderedStatement(
            sql: "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name",
            parameters: [],
            parameterTypes: []
        )
    }

    public static func tables(schema: String, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var scope = SpannerCatalogScope(dialect: dialect)
        let predicate = scope.predicate(schemaColumn: "table_schema", tableColumn: "table_name", schema: schema, table: nil)
        return scope.statement(
            "SELECT table_schema, table_name, table_type FROM information_schema.tables"
                + " WHERE \(predicate) AND table_type IN ('BASE TABLE', 'VIEW')"
                + " ORDER BY table_name"
        )
    }

    public static func columns(schema: String, table: String?, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var scope = SpannerCatalogScope(dialect: dialect)
        let predicate = scope.predicate(schemaColumn: "c.table_schema", tableColumn: "c.table_name", schema: schema, table: table)
        let hidden = dialect == .googleSQL ? "c.is_hidden" : "'NO'"
        return scope.statement(
            "SELECT c.table_schema, c.table_name, c.column_name, c.spanner_type, c.is_nullable, c.column_default,"
                + " c.is_generated, c.generation_expression, c.is_stored, c.is_identity, c.identity_generation,"
                + " \(hidden), k.ordinal_position"
                + " FROM information_schema.columns AS c"
                + " LEFT JOIN information_schema.index_columns AS k"
                + " ON k.table_schema = c.table_schema AND k.table_name = c.table_name"
                + " AND k.column_name = c.column_name AND k.index_type = 'PRIMARY_KEY'"
                + " WHERE \(predicate)"
                + " ORDER BY c.table_name, c.ordinal_position"
        )
    }

    public static func indexes(schema: String, table: String?, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var scope = SpannerCatalogScope(dialect: dialect)
        let predicate = scope.predicate(schemaColumn: "i.table_schema", tableColumn: "i.table_name", schema: schema, table: table)
        return scope.statement(
            "SELECT i.table_schema, i.table_name, i.index_name, i.index_type, i.is_unique, i.spanner_is_managed,"
                + " ic.column_name, ic.ordinal_position"
                + " FROM information_schema.indexes AS i"
                + " JOIN information_schema.index_columns AS ic"
                + " ON ic.table_schema = i.table_schema AND ic.table_name = i.table_name AND ic.index_name = i.index_name"
                + " WHERE \(predicate) AND ic.ordinal_position IS NOT NULL"
                + " ORDER BY i.table_name, i.index_name, ic.ordinal_position"
        )
    }

    public static func foreignKeys(schema: String, table: String?, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var scope = SpannerCatalogScope(dialect: dialect)
        let predicate = scope.predicate(schemaColumn: "c.table_schema", tableColumn: "c.table_name", schema: schema, table: table)
        return scope.statement(
            "SELECT c.table_schema, c.table_name, c.constraint_name, c.column_name,"
                + " p.table_schema, p.table_name, p.column_name, r.delete_rule"
                + " FROM information_schema.key_column_usage AS c"
                + " JOIN information_schema.referential_constraints AS r"
                + " ON r.constraint_schema = c.constraint_schema AND r.constraint_name = c.constraint_name"
                + " JOIN information_schema.key_column_usage AS p"
                + " ON p.constraint_schema = r.unique_constraint_schema AND p.constraint_name = r.unique_constraint_name"
                + " AND p.ordinal_position = c.position_in_unique_constraint"
                + " WHERE \(predicate)"
                + " ORDER BY c.table_name, c.constraint_name, c.ordinal_position"
        )
    }

    public static func interleaveParents(schema: String, table: String?, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var scope = SpannerCatalogScope(dialect: dialect)
        let predicate = scope.predicate(schemaColumn: "t.table_schema", tableColumn: "t.table_name", schema: schema, table: table)
        return scope.statement(
            "SELECT t.table_schema, t.table_name, t.parent_table_name, t.on_delete_action, t.interleave_type, k.column_name"
                + " FROM information_schema.tables AS t"
                + " JOIN information_schema.index_columns AS k"
                + " ON k.table_schema = t.table_schema AND k.table_name = t.parent_table_name"
                + " AND k.index_type = 'PRIMARY_KEY'"
                + " WHERE \(predicate) AND t.parent_table_name IS NOT NULL"
                + " ORDER BY t.table_name, k.ordinal_position"
        )
    }

    public static func viewDefinition(schema: String, name: String, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var scope = SpannerCatalogScope(dialect: dialect)
        let predicate = scope.predicate(schemaColumn: "table_schema", tableColumn: "table_name", schema: schema, table: name)
        return scope.statement("SELECT view_definition FROM information_schema.views WHERE \(predicate)")
    }
}

internal struct SpannerCatalogScope {
    private static let stringType = SpannerType(code: "STRING")

    private var parameters: SpannerParameterList

    init(dialect: SpannerDialect) {
        self.parameters = SpannerParameterList(dialect: dialect)
    }

    mutating func predicate(schemaColumn: String, tableColumn: String, schema: String, table: String?) -> String {
        let schemaTerm = "\(schemaColumn) = \(parameters.bind(schema))"
        guard let table else { return schemaTerm }
        return schemaTerm + " AND \(tableColumn) = \(parameters.bind(table))"
    }

    func statement(_ sql: String) -> SpannerRenderedStatement {
        SpannerRenderedStatement(
            sql: sql,
            parameters: parameters.values,
            parameterTypes: Array(repeating: Self.stringType, count: parameters.values.count)
        )
    }
}
