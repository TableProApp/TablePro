import Foundation

public struct R2SQLColumnDescription: Sendable, Equatable {
    public let name: String
    public let typeName: String
    public let isNullable: Bool
    public let comment: String?

    public init(name: String, typeName: String, isNullable: Bool, comment: String?) {
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
        self.comment = comment
    }
}

/// The catalog statements R2 SQL answers without scanning data, and how their results are read.
///
/// Every result is read by column name. DESCRIBE's columns are documented (`column_name`, `type`,
/// `required`, `initial_default`, `write_default`, `doc`); SHOW's are not, and the engines R2 SQL
/// resembles disagree on the order (Spark leads with the namespace, DataFusion with the catalog),
/// so the first column is not the name. A result carrying none of the known name columns is
/// reported rather than guessed at.
public enum R2SQLIntrospectionSQL {
    public static let showNamespaces = "SHOW NAMESPACES"

    public static func showTables(namespace: String) -> String {
        "SHOW TABLES IN \(quoteIdentifier(namespace))"
    }

    public static func describe(namespace: String, table: String) -> String {
        "DESCRIBE \(quoteIdentifier(namespace)).\(quoteIdentifier(table))"
    }

    public static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static let namespaceColumns = ["namespace", "namespace_name", "database_name", "schema_name", "databaseName"]
    static let tableColumns = ["table_name", "tableName", "name"]

    public static func namespaces(from result: R2SQLResult) throws -> [String] {
        try names(in: result, column: namespaceColumns, statement: showNamespaces)
    }

    public static func tables(from result: R2SQLResult) throws -> [String] {
        try names(in: result, column: tableColumns, statement: "SHOW TABLES")
    }

    public static func columns(from result: R2SQLResult) throws -> [R2SQLColumnDescription] {
        let available = Set(result.schema.map(\.name))
        guard available.contains("column_name"), available.contains("type") else {
            throw R2SQLError.unexpectedResult(unexpectedColumnsMessage("DESCRIBE", result))
        }
        return result.rows.compactMap { row in
            guard case .string(let name)? = row["column_name"], !name.isEmpty else { return nil }
            return R2SQLColumnDescription(
                name: name,
                typeName: text(row["type"]) ?? "",
                isNullable: !isTrue(row["required"]),
                comment: text(row["doc"]).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    private static func names(in result: R2SQLResult, column candidates: [String], statement: String) throws -> [String] {
        let available = result.schema.map(\.name)
        let column = candidates.first(where: available.contains) ?? (available.count == 1 ? available[0] : nil)
        guard let column else {
            throw R2SQLError.unexpectedResult(unexpectedColumnsMessage(statement, result))
        }
        return result.rows
            .compactMap { text($0[column]) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func text(_ value: R2SQLJSONValue?) -> String? {
        switch value {
        case .string(let text)?:
            return text
        case .number(let number)?:
            return number.description
        case .bool(let flag)?:
            return flag ? "true" : "false"
        default:
            return nil
        }
    }

    private static func isTrue(_ value: R2SQLJSONValue?) -> Bool {
        switch value {
        case .bool(let flag)?:
            return flag
        case .string(let text)?:
            return text.lowercased() == "true"
        default:
            return false
        }
    }

    private static func unexpectedColumnsMessage(_ statement: String, _ result: R2SQLResult) -> String {
        let names = result.schema.map(\.name).joined(separator: ", ")
        return "\(statement) returned columns TablePro does not recognize: \(names)."
    }
}
