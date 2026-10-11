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
        return "COMMENT ON COLUMN \(reference) IS \(commentValue(comment))"
    }

    public static func setTableComment(qualifiedTable: String, comment: String?) -> String {
        "COMMENT ON TABLE \(qualifiedTable) IS \(commentValue(comment))"
    }

    public static func setViewComment(qualifiedView: String, comment: String?) -> String {
        "COMMENT ON VIEW \(qualifiedView) IS \(commentValue(comment))"
    }

    public static func objectComment(qualifiedName: String, objectType: String, comment: String?) -> String? {
        switch objectType.uppercased() {
        case "TABLE":
            return setTableComment(qualifiedTable: qualifiedName, comment: comment)
        case "VIEW":
            return setViewComment(qualifiedView: qualifiedName, comment: comment)
        default:
            return nil
        }
    }

    private static func commentValue(_ comment: String?) -> String {
        guard let comment, !comment.isEmpty else { return "NULL" }
        return TrinoIntrospectionSQL.quoteLiteral(comment)
    }
}
