import Foundation

public struct QdrantFilterSpec: Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String
    public let secondValue: String?

    public init(column: String, op: String, value: String, secondValue: String? = nil) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }
}

public enum QdrantFilterError: Error, LocalizedError, Equatable {
    case unsupportedOperator(String)
    case missingUpperBound(column: String)
    case notANumber(column: String, value: String)
    case notABoolean(column: String, value: String)
    case notAPointID(value: String)
    case emptyList(column: String)
    case comparisonNeedsNumberOrDate(column: String, op: String)
    case textMatchNeedsTextIndex(column: String, op: String)
    case vectorNotFilterable(column: String)
    case rawFilterNotAnObject

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperator(let op):
            return String(format: String(localized: "Qdrant cannot filter with %@."), op)
        case .missingUpperBound(let column):
            return String(format: String(localized: "BETWEEN on %@ needs an upper bound."), column)
        case .notANumber(let column, let value):
            return String(format: String(localized: "%@ holds numbers, and %@ is not a number."), column, value)
        case .notABoolean(let column, let value):
            return String(
                format: String(localized: "%@ holds booleans, so it matches only true or false, not %@."),
                column, value
            )
        case .notAPointID(let value):
            return String(
                format: String(localized: "%@ is not a point id. Qdrant ids are unsigned integers or UUIDs."),
                value
            )
        case .emptyList(let column):
            return String(format: String(localized: "IN on %@ needs at least one value."), column)
        case .comparisonNeedsNumberOrDate(let column, let op):
            return String(
                format: String(localized: "Qdrant compares only numbers and dates with %@, and %@ holds neither."),
                op, column
            )
        case .textMatchNeedsTextIndex(let column, let op):
            return String(
                format: String(localized: "%@ on %@ needs a full-text payload index on that field. Without one Qdrant matches nothing."),
                op, column
            )
        case .vectorNotFilterable(let column):
            return String(format: String(localized: "Qdrant cannot filter on %@."), column)
        case .rawFilterNotAnObject:
            return String(localized: "A raw filter for Qdrant is a JSON condition, such as {\"key\": \"city\", \"match\": {\"value\": \"Berlin\"}}.")
        }
    }
}

/// Turns the filter bar's rows into Qdrant's filter JSON. AND rows go under `must` and OR rows under
/// `should`; a negated row is a nested filter with `must_not`, which Qdrant accepts as a condition.
public enum QdrantFilterBuilder {
    public static let rawFilterColumn = "__RAW__"

    public static func filter(
        _ filters: [QdrantFilterSpec],
        logicMode: String,
        collection: QdrantCollection
    ) throws -> [String: Any]? {
        guard !filters.isEmpty else { return nil }
        let conditions = try filters.map { try condition(for: $0, collection: collection) }
        let clause = logicMode.uppercased() == "OR" ? "should" : "must"
        return [clause: conditions]
    }

    public static func condition(for filter: QdrantFilterSpec, collection: QdrantCollection) throws -> [String: Any] {
        if filter.column == rawFilterColumn {
            return try raw(filter.value)
        }
        guard !QdrantSchema.isVectorColumn(filter.column) else {
            throw QdrantFilterError.vectorNotFilterable(column: filter.column)
        }
        let op = filter.op.uppercased()
        if filter.column == QdrantSchema.idColumn {
            return try idCondition(op: op, filter: filter)
        }
        let type = collection.fieldType(of: filter.column) ?? .json
        let column = QdrantSchema.payloadKey(forColumn: filter.column)

        switch op {
        case "=":
            return try equality(column: column, value: filter.value, type: type)
        case "!=", "<>":
            return negated(try equality(column: column, value: filter.value, type: type))
        case ">", ">=", "<", "<=":
            return try range(column: column, type: type, op: op, bounds: [rangeKey(op): filter.value])
        case "BETWEEN":
            guard let upper = filter.secondValue, !upper.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw QdrantFilterError.missingUpperBound(column: column)
            }
            let lower = lowerBound(of: filter.value, upperBound: upper)
            return try range(column: column, type: type, op: op, bounds: ["gte": lower, "lte": upper])
        case "IN":
            return ["key": column, "match": ["any": try list(filter.value, column: column, type: type)]]
        case "NOT IN":
            return ["key": column, "match": ["except": try list(filter.value, column: column, type: type)]]
        case "CONTAINS":
            return try textMatch(column: column, value: filter.value, type: type, op: op)
        case "NOT CONTAINS":
            return negated(try textMatch(column: column, value: filter.value, type: type, op: op))
        case "IS NULL":
            return ["is_null": ["key": column]]
        case "IS NOT NULL":
            return negated(["is_null": ["key": column]])
        case "IS EMPTY":
            return ["is_empty": ["key": column]]
        case "IS NOT EMPTY":
            return negated(["is_empty": ["key": column]])
        default:
            throw QdrantFilterError.unsupportedOperator(op)
        }
    }

    private static func raw(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw QdrantFilterError.rawFilterNotAnObject }
        return object
    }

    private static func idCondition(op: String, filter: QdrantFilterSpec) throws -> [String: Any] {
        func ids(_ text: String) throws -> [Any] {
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { throw QdrantFilterError.emptyList(column: QdrantSchema.idColumn) }
            return try parts.map { part in
                guard let id = QdrantPointID.json(from: part) else { throw QdrantFilterError.notAPointID(value: part) }
                return id
            }
        }
        switch op {
        case "=", "IN":
            return ["has_id": try ids(filter.value)]
        case "!=", "<>", "NOT IN":
            return negated(["has_id": try ids(filter.value)])
        default:
            throw QdrantFilterError.unsupportedOperator(op)
        }
    }

    /// `match.value` takes a string, an integer or a boolean. A float has no exact match in Qdrant,
    /// so equality on one is the closed range around it.
    private static func equality(column: String, value: String, type: QdrantFieldType) throws -> [String: Any] {
        switch type {
        case .float, .datetime:
            return try range(column: column, type: type, op: "=", bounds: ["gte": value, "lte": value])
        default:
            return ["key": column, "match": ["value": try scalar(value, column: column, type: type)]]
        }
    }

    private static func range(
        column: String,
        type: QdrantFieldType,
        op: String,
        bounds: [String: String]
    ) throws -> [String: Any] {
        guard type.isOrdered || type == .json else {
            throw QdrantFilterError.comparisonNeedsNumberOrDate(column: column, op: op)
        }
        var range: [String: Any] = [:]
        for (key, text) in bounds {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if type == .datetime {
                range[key] = trimmed
            } else if let number = Double(trimmed) {
                range[key] = number
            } else if type == .json {
                range[key] = trimmed
            } else {
                throw QdrantFilterError.notANumber(column: column, value: text)
            }
        }
        return ["key": column, "range": range]
    }

    private static func textMatch(column: String, value: String, type: QdrantFieldType, op: String) throws -> [String: Any] {
        guard type == .text else {
            throw QdrantFilterError.textMatchNeedsTextIndex(column: column, op: op)
        }
        return ["key": column, "match": ["text": value]]
    }

    private static func list(_ value: String, column: String, type: QdrantFieldType) throws -> [Any] {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw QdrantFilterError.emptyList(column: column) }
        return try parts.map { try scalar($0, column: column, type: type) }
    }

    private static func scalar(_ value: String, column: String, type: QdrantFieldType) throws -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch type {
        case .integer:
            guard let number = Int64(trimmed) else { throw QdrantFilterError.notANumber(column: column, value: value) }
            return NSNumber(value: number)
        case .bool:
            switch trimmed.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: throw QdrantFilterError.notABoolean(column: column, value: value)
            }
        case .json:
            if let number = Int64(trimmed) { return NSNumber(value: number) }
            if trimmed == "true" { return true }
            if trimmed == "false" { return false }
            return value
        default:
            return value
        }
    }

    private static func rangeKey(_ op: String) -> String {
        switch op {
        case ">": return "gt"
        case ">=": return "gte"
        case "<": return "lt"
        default: return "lte"
        }
    }

    private static func lowerBound(of joinedValue: String, upperBound: String) -> String {
        let suffix = "," + upperBound
        guard joinedValue.hasSuffix(suffix) else { return joinedValue }
        return String(joinedValue.dropLast(suffix.count))
    }

    private static func negated(_ condition: [String: Any]) -> [String: Any] {
        ["must_not": [condition]]
    }
}
