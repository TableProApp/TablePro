import Foundation

public struct TrinoColumnValue: Sendable, Equatable {
    public let name: String
    public let value: TrinoValue
    public let typeName: String
    // SQL the host vetted, such as `current_timestamp`, written as it is instead of the value.
    public let expression: String?

    public init(name: String, value: TrinoValue, typeName: String, expression: String? = nil) {
        self.name = name
        self.value = value
        self.typeName = typeName
        self.expression = expression
    }

    // Nil when the value cannot be written for its column's type.
    public var sql: String? {
        expression ?? TrinoLiteral.render(value, typeName: typeName)
    }
}

public enum TrinoRowEditSQL {
    public static func insert(qualifiedTable: String, columns: [TrinoColumnValue]) -> String? {
        let values = columns.compactMap(\.sql)
        guard !columns.isEmpty, values.count == columns.count else { return nil }
        let names = columns.map { TrinoIntrospectionSQL.quoteIdentifier($0.name) }.joined(separator: ", ")
        return "INSERT INTO \(qualifiedTable) (\(names)) VALUES (\(values.joined(separator: ", ")))"
    }

    public static func update(
        qualifiedTable: String,
        assignments: [TrinoColumnValue],
        keyColumns: [TrinoColumnValue]
    ) -> String? {
        let values = assignments.compactMap(\.sql)
        guard !assignments.isEmpty, values.count == assignments.count, let predicate = predicate(keyColumns) else {
            return nil
        }
        let sets = zip(assignments, values)
            .map { "\(TrinoIntrospectionSQL.quoteIdentifier($0.name)) = \($1)" }
            .joined(separator: ", ")
        return "UPDATE \(qualifiedTable) SET \(sets) WHERE \(predicate)"
    }

    public static func delete(qualifiedTable: String, keyColumns: [TrinoColumnValue]) -> String? {
        guard let predicate = predicate(keyColumns) else { return nil }
        return "DELETE FROM \(qualifiedTable) WHERE \(predicate)"
    }

    // Finds at most two of the rows a write with these key columns would reach.
    public static func lookup(qualifiedTable: String, keyColumns: [TrinoColumnValue]) -> String? {
        guard let predicate = predicate(keyColumns) else { return nil }
        return "SELECT 1 FROM \(qualifiedTable) WHERE \(predicate) LIMIT 2"
    }

    static func predicate(_ keyColumns: [TrinoColumnValue]) -> String? {
        var conditions: [String] = []
        for key in keyColumns where TrinoTypeMapper.category(forRawType: key.typeName) != .structured {
            let quoted = TrinoIntrospectionSQL.quoteIdentifier(key.name)
            if case .null = key.value {
                conditions.append("\(quoted) IS NULL")
            } else {
                guard let literal = TrinoLiteral.render(key.value, typeName: key.typeName) else { return nil }
                conditions.append("\(quoted) = \(literal)")
            }
        }
        return conditions.isEmpty ? nil : conditions.joined(separator: " AND ")
    }
}
