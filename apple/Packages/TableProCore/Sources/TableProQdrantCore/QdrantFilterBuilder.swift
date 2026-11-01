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

public enum QdrantFilterError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedOperator(String)
    case missingUpperBound(column: String)
    case notAPointID(value: String)
    case emptyList(column: String)
    case vectorNotFilterable(column: String)
    case keyNotAddressable(column: String)
    case boundNotExact(column: String, value: String)
    case rawFilterNotAnObject

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperator(let op):
            return String(format: String(localized: "Qdrant cannot filter with %@."), op)
        case .missingUpperBound(let column):
            return String(format: String(localized: "BETWEEN on %@ needs an upper bound."), column)
        case .notAPointID(let value):
            return String(
                format: String(localized: "%@ is not a point id. Qdrant ids are unsigned integers or UUIDs."),
                value
            )
        case .emptyList(let column):
            return String(format: String(localized: "IN on %@ needs at least one value."), column)
        case .vectorNotFilterable(let column):
            return String(format: String(localized: "Qdrant cannot filter on %@."), column)
        case .keyNotAddressable(let column):
            return String(
                format: String(localized: "Qdrant cannot filter on %@, because a key holding a double quote has no path it accepts."),
                column
            )
        case .boundNotExact(let column, let value):
            return String(
                format: String(localized: "Qdrant compares %@ as a 64-bit float, which cannot hold %@ exactly."),
                column, value
            )
        case .rawFilterNotAnObject:
            return String(localized: "A raw filter for Qdrant is a JSON condition, such as {\"key\": \"city\", \"match\": {\"value\": \"Berlin\"}}.")
        }
    }
}

// AND rows go under `must` and OR rows under `should`. A negated row is a nested filter with `must_not`,
// which, like `$ne` in a document store, also matches a point the key is missing from.
//
// A payload index does not constrain what points store, and a sample cannot prove it does, so a value
// matches every type its text can spell: `42` finds "42", 42, 42.0 and a list holding either. The
// index still serves the branch of its own type.
public enum QdrantFilterBuilder {
    public static let rawFilterColumn = "__RAW__"

    public static func filter(_ filters: [QdrantFilterSpec], logicMode: String) throws -> [String: Any]? {
        guard !filters.isEmpty else { return nil }
        let conditions = try filters.map(condition(for:))
        return [logicMode.uppercased() == "OR" ? "should" : "must": conditions]
    }

    public static func condition(for filter: QdrantFilterSpec) throws -> [String: Any] {
        if filter.column == rawFilterColumn {
            return try raw(filter.value)
        }
        let op = filter.op.uppercased()
        guard !QdrantSchema.isVectorColumn(filter.column) else {
            // Search All Rows asks every column; a vector holds no text, so it finds nothing there.
            if op == "CONTAINS" { return ["has_id": [Any]()] }
            if op == "NOT CONTAINS" { return negated([["has_id": [Any]()]]) }
            throw QdrantFilterError.vectorNotFilterable(column: filter.column)
        }
        if filter.column == QdrantSchema.idColumn {
            if op == "CONTAINS" || op == "NOT CONTAINS" {
                return idContains(op: op, value: filter.value)
            }
            return try idCondition(op: op, value: filter.value)
        }
        guard let key = QdrantKeyPath.quoted(QdrantSchema.payloadKey(forColumn: filter.column)) else {
            throw QdrantFilterError.keyNotAddressable(column: filter.column)
        }
        let field = Field(column: filter.column, key: key)

        switch op {
        case "=":
            return field.equality(filter.value)
        case "!=", "<>":
            return negated([field.equality(filter.value)])
        case ">", ">=", "<", "<=":
            return try field.range([rangeKey(op): filter.value])
        case "BETWEEN":
            guard let upper = filter.secondValue, !upper.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw QdrantFilterError.missingUpperBound(column: filter.column)
            }
            return try field.range(["gte": lowerBound(of: filter.value, upperBound: upper), "lte": upper])
        case "IN":
            return field.anyOf(try list(filter.value, column: filter.column))
        case "NOT IN":
            return negated(try list(filter.value, column: filter.column).map(field.equality))
        case "CONTAINS":
            return field.textMatch(filter.value)
        case "NOT CONTAINS":
            return negated([field.textMatch(filter.value)])
        case "IS NULL":
            return field.isEmpty
        case "IS NOT NULL":
            return negated([field.isEmpty])
        case "IS EMPTY":
            return field.isBlank
        case "IS NOT EMPTY":
            return negated([field.isBlank])
        default:
            throw QdrantFilterError.unsupportedOperator(op)
        }
    }

    private struct Field {
        let column: String
        let key: String

        func equality(_ value: String) -> [String: Any] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            var options = [match(value)]
            // A range also finds 42.0, but a double rounds an integer past 2^53, so a larger one matches exactly.
            if let integer = QdrantValue.integer(trimmed), integer.magnitude > 1 << 53 {
                options.append(match(NSNumber(value: integer)))
            } else if let number = QdrantValue.number(trimmed) {
                options.append(["key": key, "range": ["gte": NSNumber(value: number), "lte": NSNumber(value: number)]])
            }
            if let flag = QdrantValue.bool(trimmed) {
                options.append(match(flag))
            }
            return options.count == 1 ? options[0] : ["should": options]
        }

        // Qdrant's `match.any` takes strings alone, so it collapses only a list of plain text.
        func anyOf(_ values: [String]) -> [String: Any] {
            let conditions = values.map(equality)
            let texts = conditions.compactMap { ($0["match"] as? [String: Any])?["value"] as? String }
            if texts.count == conditions.count {
                return ["key": key, "match": ["any": texts]]
            }
            return ["should": conditions]
        }

        // A number bounds numbers; any other text is a date, which Qdrant parses. Qdrant reads a bound as
        // a 64-bit float, so an integer past 2^53 would be rounded to a different cutoff.
        func range(_ bounds: [String: String]) throws -> [String: Any] {
            var range: [String: Any] = [:]
            for (bound, text) in bounds {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if let integer = QdrantValue.integer(trimmed), integer.magnitude > 1 << 53 {
                    throw QdrantFilterError.boundNotExact(column: column, value: trimmed)
                }
                range[bound] = QdrantValue.number(trimmed).map { NSNumber(value: $0) as Any } ?? trimmed
            }
            return ["key": key, "range": range]
        }

        // Without a full-text index Qdrant still matches the words, lowercased, and a value that is not
        // text matches nothing rather than failing, so Search All Rows can ask every column.
        func textMatch(_ value: String) -> [String: Any] {
            ["key": key, "match": ["text": value]]
        }

        // `is_empty` covers a missing key, null and []; `is_null` would miss the missing key the grid shows as NULL.
        var isEmpty: [String: Any] {
            ["is_empty": ["key": key]]
        }

        var isBlank: [String: Any] {
            ["should": [isEmpty, match("")]]
        }

        private func match(_ value: Any) -> [String: Any] {
            ["key": key, "match": ["value": value]]
        }
    }

    private static func raw(_ text: String) throws -> [String: Any] {
        guard let object = QdrantJSON.parse(text) as? [String: Any] else {
            throw QdrantFilterError.rawFilterNotAnObject
        }
        return object
    }

    private static func idCondition(op: String, value: String) throws -> [String: Any] {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw QdrantFilterError.emptyList(column: QdrantSchema.idColumn) }
        let ids = try parts.map { part -> Any in
            guard let id = QdrantPointID.json(from: part) else { throw QdrantFilterError.notAPointID(value: part) }
            return id
        }
        switch op {
        case "=", "IN":
            return ["has_id": ids]
        case "!=", "<>", "NOT IN":
            return negated([["has_id": ids]])
        default:
            throw QdrantFilterError.unsupportedOperator(op)
        }
    }

    // Ids have no substring search, so only a whole id is found; Search All Rows still runs on the other columns.
    private static func idContains(op: String, value: String) -> [String: Any] {
        let found: [Any] = QdrantPointID.json(from: value).map { [$0] } ?? []
        return op == "NOT CONTAINS" ? negated([["has_id": found]]) : ["has_id": found]
    }

    private static func list(_ value: String, column: String) throws -> [String] {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw QdrantFilterError.emptyList(column: column) }
        return parts
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

    static func negated(_ conditions: [[String: Any]]) -> [String: Any] {
        ["must_not": conditions]
    }

    static func allOf(_ filter: [String: Any]?, _ condition: [String: Any]) -> [String: Any] {
        guard let filter else { return ["must": [condition]] }
        return ["must": [filter, condition]]
    }
}
