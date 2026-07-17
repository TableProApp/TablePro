import Foundation

public enum TeradataSchemaQueries {
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func qualifiedName(database: String?, table: String) -> String {
        guard let database, !database.isEmpty else { return quoteIdentifier(table) }
        return quoteIdentifier(database) + "." + quoteIdentifier(table)
    }

    public static func listDatabases() -> String {
        "SELECT DatabaseName, DBKind FROM DBC.DatabasesV ORDER BY DatabaseName"
    }

    public static func listTables(database: String) -> String {
        """
        SELECT TableName, TableKind FROM DBC.TablesV \
        WHERE DatabaseName = \(quoteLiteral(database)) \
        AND TableKind IN ('T', 'O', 'Q', 'V') \
        ORDER BY TableName
        """
    }

    public static func columns(database: String, table: String) -> String {
        """
        SELECT ColumnName, ColumnType, ColumnLength, DecimalTotalDigits, \
        DecimalFractionalDigits, Nullable, DefaultValue, ColumnId \
        FROM DBC.ColumnsV \
        WHERE DatabaseName = \(quoteLiteral(database)) AND TableName = \(quoteLiteral(table)) \
        ORDER BY ColumnId
        """
    }

    public static func indexes(database: String, table: String) -> String {
        """
        SELECT IndexName, IndexType, UniqueFlag, ColumnName, ColumnPosition \
        FROM DBC.IndicesV \
        WHERE DatabaseName = \(quoteLiteral(database)) AND TableName = \(quoteLiteral(table)) \
        ORDER BY IndexNumber, ColumnPosition
        """
    }

    public static func showTableDDL(database: String?, table: String) -> String {
        "SHOW TABLE \(qualifiedName(database: database, table: table))"
    }

    public static func viewDefinition(database: String, view: String) -> String {
        """
        SELECT RequestText FROM DBC.TablesV \
        WHERE DatabaseName = \(quoteLiteral(database)) AND TableName = \(quoteLiteral(view)) \
        AND TableKind = 'V'
        """
    }

    public static func currentDatabase() -> String {
        "SELECT DATABASE"
    }

    public static func setDatabase(_ database: String) -> String {
        "DATABASE \(quoteIdentifier(database))"
    }

    public static func browse(
        database: String?, table: String,
        columns: [String]?, sortColumns: [(name: String, ascending: Bool)],
        limit: Int, offset: Int
    ) -> String {
        let target = qualifiedName(database: database, table: table)
        let projection = selectList(columns)
        let orderClause = orderBy(sortColumns, fallbackColumns: columns)

        if offset <= 0 {
            let top = limit > 0 ? "TOP \(limit) " : ""
            let order = orderClause.map { " \($0)" } ?? ""
            return "SELECT \(top)\(projection) FROM \(target)\(order)"
        }

        let window = orderClause ?? "ORDER BY 1"
        let lower = offset + 1
        let upper = offset + max(limit, 1)
        return "SELECT \(projection) FROM \(target) "
            + "QUALIFY ROW_NUMBER() OVER (\(window)) BETWEEN \(lower) AND \(upper)"
    }

    private static func selectList(_ columns: [String]?) -> String {
        guard let columns, !columns.isEmpty else { return "*" }
        return columns.map(quoteIdentifier).joined(separator: ", ")
    }

    private static func orderBy(
        _ sortColumns: [(name: String, ascending: Bool)], fallbackColumns: [String]?
    ) -> String? {
        if !sortColumns.isEmpty {
            let terms = sortColumns.map { "\(quoteIdentifier($0.name)) \($0.ascending ? "ASC" : "DESC")" }
            return "ORDER BY " + terms.joined(separator: ", ")
        }
        guard let first = fallbackColumns?.first else { return nil }
        return "ORDER BY " + quoteIdentifier(first)
    }
}
