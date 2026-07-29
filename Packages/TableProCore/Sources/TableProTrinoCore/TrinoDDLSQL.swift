import Foundation

public struct TrinoColumnSpec: Sendable, Equatable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let comment: String?

    public init(name: String, type: String, nullable: Bool, comment: String?) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.comment = comment
    }
}

public enum TrinoDDLSQL {
    public static func columnDefinition(_ column: TrinoColumnSpec) -> String {
        var definition = "\(TrinoIntrospectionSQL.quoteIdentifier(column.name)) \(column.type)"
        if !column.nullable {
            definition += " NOT NULL"
        }
        if let comment = column.comment, !comment.isEmpty {
            definition += " COMMENT \(TrinoIntrospectionSQL.quoteLiteral(comment))"
        }
        return definition
    }

    public static func createTable(
        qualifiedTable: String,
        columns: [TrinoColumnSpec],
        tableComment: String?,
        ifNotExists: Bool
    ) -> String? {
        guard !columns.isEmpty else { return nil }
        let existsClause = ifNotExists ? "IF NOT EXISTS " : ""
        let body = columns.map(columnDefinition).joined(separator: ",\n  ")
        var statement = "CREATE TABLE \(existsClause)\(qualifiedTable) (\n  \(body)\n)"
        if let tableComment, !tableComment.isEmpty {
            statement += " COMMENT \(TrinoIntrospectionSQL.quoteLiteral(tableComment))"
        }
        return statement
    }

    public static func addColumn(qualifiedTable: String, column: TrinoColumnSpec) -> String {
        "ALTER TABLE \(qualifiedTable) ADD COLUMN \(columnDefinition(column))"
    }

    public static func dropColumn(qualifiedTable: String, name: String) -> String {
        "ALTER TABLE \(qualifiedTable) DROP COLUMN \(TrinoIntrospectionSQL.quoteIdentifier(name))"
    }

    public static func renameColumn(qualifiedTable: String, from: String, to: String) -> String {
        "ALTER TABLE \(qualifiedTable) RENAME COLUMN "
            + "\(TrinoIntrospectionSQL.quoteIdentifier(from)) TO \(TrinoIntrospectionSQL.quoteIdentifier(to))"
    }

    public static func setColumnType(qualifiedTable: String, name: String, type: String) -> String {
        "ALTER TABLE \(qualifiedTable) ALTER COLUMN \(TrinoIntrospectionSQL.quoteIdentifier(name)) SET DATA TYPE \(type)"
    }

    public static func setColumnComment(qualifiedTable: String, name: String, comment: String?) -> String {
        let reference = "\(qualifiedTable).\(TrinoIntrospectionSQL.quoteIdentifier(name))"
        let value = comment.flatMap { $0.isEmpty ? nil : $0 }
        guard let value else {
            return "COMMENT ON COLUMN \(reference) IS NULL"
        }
        return "COMMENT ON COLUMN \(reference) IS \(TrinoIntrospectionSQL.quoteLiteral(value))"
    }

    public static func setTableComment(qualifiedTable: String, comment: String?) -> String {
        let value = comment.flatMap { $0.isEmpty ? nil : $0 }
        guard let value else {
            return "COMMENT ON TABLE \(qualifiedTable) IS NULL"
        }
        return "COMMENT ON TABLE \(qualifiedTable) IS \(TrinoIntrospectionSQL.quoteLiteral(value))"
    }
}
