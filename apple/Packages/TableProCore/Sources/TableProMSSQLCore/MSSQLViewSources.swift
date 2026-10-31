import Foundation

/// What SQL Server says about writing through one view. `INFORMATION_SCHEMA.VIEWS.IS_UPDATABLE`
/// is always NO, so both answers come from `sys.dm_exec_describe_first_result_set`, which compiles
/// a statement without running it: no trigger fires and no session setting changes.
public enum MSSQLViewSources {
    /// "Cannot update the view ... because it contains aggregates, or a DISTINCT or GROUP BY clause",
    /// and the like. The server raises them while it compiles a DELETE through the view.
    public static func compileErrorsQuery(schema: String, view: String) -> String {
        let probe = "DELETE FROM \(MSSQLSchemaQueries.bracketed(schema: schema, table: view)) WHERE 1 = 0"
        return """
        SELECT error_number FROM sys.dm_exec_describe_first_result_set(\(MSSQLStringLiteral.quoted(probe)), NULL, 0)
        WHERE error_number IS NOT NULL
        """
    }

    /// Browse mode 1 names the base table and column behind each view column, NULL for a computed
    /// one, and adds hidden key columns the view does not show. A view may read another database,
    /// so the database comes along; a column from a linked server is left without a source.
    public static func columnSourcesQuery(schema: String, view: String) -> String {
        let probe = "SELECT * FROM \(MSSQLSchemaQueries.bracketed(schema: schema, table: view))"
        return """
        SELECT name, COALESCE(source_database, DB_NAME()), source_schema, source_table, source_column
        FROM sys.dm_exec_describe_first_result_set(\(MSSQLStringLiteral.quoted(probe)), NULL, 1)
        WHERE is_hidden = 0 AND source_server IS NULL
        ORDER BY column_ordinal
        """
    }

    /// Read from the base table's own database: the same name in the current one can be another table.
    public static func primaryKeyQuery(_ table: BaseTable) -> String {
        let database = "[\(MSSQLSchemaQueries.escapeBracket(table.database))]"
        let object = MSSQLStringLiteral.quoted(
            "\(database).\(MSSQLSchemaQueries.bracketed(schema: table.schema, table: table.name))"
        )
        return """
        SELECT c.name
        FROM \(database).sys.indexes i
        JOIN \(database).sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        JOIN \(database).sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE i.object_id = OBJECT_ID(\(object)) AND i.is_primary_key = 1
        ORDER BY ic.key_ordinal
        """
    }

    /// 11501 only says the batch failed to compile and comes with the real error.
    public static func isUpdatable(compileErrors: [Int]) -> Bool {
        Set(compileErrors).subtracting([joinsTablesError, 11_501]).isEmpty
    }

    /// 4405: the modification would touch more than one base table. A join showing only one
    /// table's columns raises it too, and a DELETE through it always fails.
    public static func baseTableCount(_ summary: Summary, compileErrors: [Int]) -> Int {
        compileErrors.contains(joinsTablesError) ? max(2, summary.baseTables.count) : summary.baseTables.count
    }

    private static let joinsTablesError = 4_405

    public struct BaseTable: Hashable, Sendable {
        public let database: String
        public let schema: String
        public let name: String

        public init(database: String, schema: String, name: String) {
            self.database = database
            self.schema = schema
            self.name = name
        }
    }

    public struct Origin: Equatable, Sendable {
        public let viewColumn: String
        public let baseColumn: String
    }

    public struct Summary: Equatable, Sendable {
        /// Every base table a shown column comes from, in the order the columns name them.
        public let baseTables: [BaseTable]
        public let origins: [Origin]
    }

    /// Rows of `columnSourcesQuery`: name, source database, schema, table and column.
    public static func summarize(rows: [[String?]]) -> Summary {
        var baseTables: [BaseTable] = []
        var columns: [(viewColumn: String, table: BaseTable, column: String)] = []
        for row in rows {
            guard row.count >= 5, let name = row[0], let database = row[1],
                  let schema = row[2], let table = row[3], let column = row[4]
            else { continue }
            let base = BaseTable(database: database, schema: schema, name: table)
            if !baseTables.contains(base) { baseTables.append(base) }
            columns.append((name, base, column))
        }
        let origins = baseTables.count == 1
            ? columns.map { Origin(viewColumn: $0.viewColumn, baseColumn: $0.column) }
            : []
        return Summary(baseTables: baseTables, origins: origins)
    }
}
