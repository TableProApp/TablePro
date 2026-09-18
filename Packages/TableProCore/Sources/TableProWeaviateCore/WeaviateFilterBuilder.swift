import Foundation

public enum WeaviateFilterError: Error, LocalizedError, Equatable {
    case unsupportedOperator(String)
    case missingUpperBound(column: String)
    case notANumber(column: String, value: String)
    case notABoolean(column: String, value: String)
    case notADate(column: String, value: String)
    case emptyList(column: String)
    case comparisonNeedsNumberOrDate(column: String, op: String)
    case textMatchNeedsText(column: String, op: String)
    case vectorNotFilterable(column: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperator(let op):
            return String(format: String(localized: "Weaviate cannot filter with %@."), op)
        case .missingUpperBound(let column):
            return String(format: String(localized: "BETWEEN on %@ needs an upper bound."), column)
        case .notANumber(let column, let value):
            return String(
                format: String(localized: "%@ is a numeric property, and %@ is not a number."),
                column, value
            )
        case .notABoolean(let column, let value):
            return String(
                format: String(localized: "%@ is a boolean property, so it matches only true or false, not %@."),
                column, value
            )
        case .notADate(let column, let value):
            return String(
                format: String(localized: "%@ is a date property, and %@ is not an RFC 3339 timestamp such as 2024-01-31T00:00:00Z."),
                column, value
            )
        case .emptyList(let column):
            return String(format: String(localized: "IN on %@ needs at least one value."), column)
        case .comparisonNeedsNumberOrDate(let column, let op):
            return String(
                format: String(localized: "Weaviate compares only numbers and dates with %@, and %@ is neither."),
                op, column
            )
        case .textMatchNeedsText(let column, let op):
            return String(
                format: String(localized: "Weaviate matches text with %@, and %@ is not a text property."),
                op, column
            )
        case .vectorNotFilterable(let column):
            return String(format: String(localized: "Weaviate cannot filter on %@."), column)
        }
    }
}

/// Weaviate has no array value field: an `int[]` property filters with `valueInt`, so the kind is
/// always the element's.
public enum WeaviateValueKind: String, Sendable, Equatable {
    case text
    case uuid
    case int
    case number
    case boolean
    case date

    public var graphQLField: String {
        switch self {
        case .text, .uuid: return "valueText"
        case .int: return "valueInt"
        case .number: return "valueNumber"
        case .boolean: return "valueBoolean"
        case .date: return "valueDate"
        }
    }

    public var isOrdered: Bool {
        self == .int || self == .number || self == .date
    }

    /// `Like` compiles to a regex over the inverted index, which Weaviate only builds for text.
    public var acceptsPatternMatch: Bool {
        self == .text
    }

    public static func forDataType(_ dataType: String) -> WeaviateValueKind {
        var name = dataType.trimmingCharacters(in: .whitespaces).lowercased()
        while name.hasSuffix("[]") {
            name = String(name.dropLast(2))
        }
        switch name {
        case "int": return .int
        case "number": return .number
        case "boolean", "bool": return .boolean
        case "date": return .date
        case "uuid": return .uuid
        default: return .text
        }
    }
}

public enum WeaviateFilterBuilder {
    public static func graphQLWhere(
        filters: [WeaviateFilterSpec],
        logicMode: String,
        types: [String: String]
    ) throws -> String? {
        guard !filters.isEmpty else { return nil }
        let operands = try filters.map { try operand(for: $0, types: types) }
        guard operands.count > 1 else { return operands[0] }
        let op = logicMode.uppercased() == "OR" ? "Or" : "And"
        return "{ operator: \(op) operands: [\(operands.joined(separator: " "))] }"
    }

    public static func operand(for filter: WeaviateFilterSpec, types: [String: String]) throws -> String {
        let column = filter.column
        guard column != WeaviateSchema.vectorColumn else {
            throw WeaviateFilterError.vectorNotFilterable(column: column)
        }
        let path = column == WeaviateSchema.uuidColumn ? WeaviateSchema.uuidGraphQLPath : column
        let kind = column == WeaviateSchema.uuidColumn
            ? WeaviateValueKind.text
            : WeaviateValueKind.forDataType(types[column] ?? "text")
        let op = filter.op.uppercased()

        switch op {
        case "=":
            return try comparison("Equal", path: path, column: column, value: filter.value, kind: kind)
        case "!=", "<>":
            return try comparison("NotEqual", path: path, column: column, value: filter.value, kind: kind)
        case ">", ">=", "<", "<=":
            guard kind.isOrdered else {
                throw WeaviateFilterError.comparisonNeedsNumberOrDate(column: column, op: op)
            }
            return try comparison(orderedOperator(op), path: path, column: column, value: filter.value, kind: kind)
        case "CONTAINS":
            return try like(pattern: "*\(filter.value)*", path: path, column: column, kind: kind, op: op)
        case "NOT CONTAINS":
            return negated(try like(pattern: "*\(filter.value)*", path: path, column: column, kind: kind, op: op))
        case "STARTS WITH":
            return try like(pattern: "\(filter.value)*", path: path, column: column, kind: kind, op: op)
        case "ENDS WITH":
            return try like(pattern: "*\(filter.value)", path: path, column: column, kind: kind, op: op)
        case "IN":
            return try containsList("ContainsAny", filter.value, path: path, column: column, kind: kind)
        case "NOT IN":
            return try containsList("ContainsNone", filter.value, path: path, column: column, kind: kind)
        case "BETWEEN":
            return try between(filter, path: path, column: column, kind: kind)
        case "IS NULL":
            return "{ path: [\"\(escape(path))\"] operator: IsNull valueBoolean: true }"
        case "IS NOT NULL":
            return "{ path: [\"\(escape(path))\"] operator: IsNull valueBoolean: false }"
        case "IS EMPTY":
            return try emptiness("Equal", path: path, column: column, kind: kind, op: op)
        case "IS NOT EMPTY":
            return try emptiness("GreaterThan", path: path, column: column, kind: kind, op: op)
        default:
            throw WeaviateFilterError.unsupportedOperator(op)
        }
    }

    private static func orderedOperator(_ op: String) -> String {
        switch op {
        case ">": return "GreaterThan"
        case ">=": return "GreaterThanEqual"
        case "<": return "LessThan"
        default: return "LessThanEqual"
        }
    }

    private static func comparison(
        _ operatorName: String,
        path: String,
        column: String,
        value: String,
        kind: WeaviateValueKind
    ) throws -> String {
        let literal = try literal(value, column: column, kind: kind)
        return "{ path: [\"\(escape(path))\"] operator: \(operatorName) \(kind.graphQLField): \(literal) }"
    }

    /// Weaviate compiles a `Like` value into a regex over the inverted index. An int, number or
    /// date property crashes that compile, and a uuid property is refused outright.
    private static func like(
        pattern: String,
        path: String,
        column: String,
        kind: WeaviateValueKind,
        op: String
    ) throws -> String {
        guard kind.acceptsPatternMatch else {
            throw WeaviateFilterError.textMatchNeedsText(column: column, op: op)
        }
        return "{ path: [\"\(escape(path))\"] operator: Like valueText: \"\(escape(pattern))\" }"
    }

    private static func containsList(
        _ operatorName: String,
        _ value: String,
        path: String,
        column: String,
        kind: WeaviateValueKind
    ) throws -> String {
        let parts = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw WeaviateFilterError.emptyList(column: column)
        }
        let literals = try parts.map { try literal($0, column: column, kind: kind) }
        return "{ path: [\"\(escape(path))\"] operator: \(operatorName) \(kind.graphQLField): [\(literals.joined(separator: ", "))] }"
    }

    /// Weaviate has no "is empty": it counts with `len(prop)`, which needs `indexPropertyLength` on
    /// the collection and answers with what to turn on when it is off. There is no `len(id)`, and a
    /// uuid property has no length either.
    private static func emptiness(
        _ operatorName: String,
        path: String,
        column: String,
        kind: WeaviateValueKind,
        op: String
    ) throws -> String {
        guard kind == .text, column != WeaviateSchema.uuidColumn else {
            throw WeaviateFilterError.textMatchNeedsText(column: column, op: op)
        }
        return "{ path: [\"len(\(escape(path)))\"] operator: \(operatorName) valueInt: 0 }"
    }

    private static func between(
        _ filter: WeaviateFilterSpec,
        path: String,
        column: String,
        kind: WeaviateValueKind
    ) throws -> String {
        guard kind.isOrdered else {
            throw WeaviateFilterError.comparisonNeedsNumberOrDate(column: column, op: "BETWEEN")
        }
        guard let upperBound = filter.secondValue, !upperBound.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WeaviateFilterError.missingUpperBound(column: column)
        }
        let lower = try comparison(
            "GreaterThanEqual", path: path, column: column, value: filter.value, kind: kind
        )
        let upper = try comparison(
            "LessThanEqual", path: path, column: column, value: upperBound, kind: kind
        )
        return "{ operator: And operands: [\(lower) \(upper)] }"
    }

    private static func negated(_ operand: String) -> String {
        "{ operator: Not operands: [\(operand)] }"
    }

    private static func literal(_ value: String, column: String, kind: WeaviateValueKind) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .text, .uuid:
            return "\"\(escape(value))\""
        case .int:
            guard let number = Int(trimmed) else {
                throw WeaviateFilterError.notANumber(column: column, value: value)
            }
            return String(number)
        case .number:
            guard let number = Double(trimmed) else {
                throw WeaviateFilterError.notANumber(column: column, value: value)
            }
            return String(number)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1": return "true"
            case "false", "0": return "false"
            default: throw WeaviateFilterError.notABoolean(column: column, value: value)
            }
        case .date:
            guard WeaviateDateLiteral.isRFC3339(trimmed) else {
                throw WeaviateFilterError.notADate(column: column, value: value)
            }
            return "\"\(escape(trimmed))\""
        }
    }

    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }
}

/// Weaviate parses a `valueDate` with Go's RFC 3339 layout and answers
/// `trying parse time as RFC3339 string` for anything else, including a bare `2024-01-31`.
public enum WeaviateDateLiteral {
    public static func isRFC3339(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }
}
