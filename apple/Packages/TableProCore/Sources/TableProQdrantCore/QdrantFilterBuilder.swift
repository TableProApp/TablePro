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
    case comparisonNeedsNumberOrDate(column: String, op: String)
    case textMatchNeedsText(column: String, type: String)
    case wholeValueNotMatchable(column: String, type: String)
    case vectorNotFilterable(column: String)
    case keyNotAddressable(column: String)
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
        case .comparisonNeedsNumberOrDate(let column, let op):
            return String(
                format: String(localized: "Qdrant compares only numbers and dates with %@, and %@ holds neither."),
                op, column
            )
        case .textMatchNeedsText(let column, let type):
            return String(format: String(localized: "%@ holds %@ values, and Qdrant matches words only in text."), column, type)
        case .wholeValueNotMatchable(let column, let type):
            return String(
                format: String(localized: "Qdrant cannot match a whole %@ value in %@. Use a raw filter on one of its fields."),
                type, column
            )
        case .vectorNotFilterable(let column):
            return String(format: String(localized: "Qdrant cannot filter on %@."), column)
        case .keyNotAddressable(let column):
            return String(
                format: String(localized: "Qdrant cannot filter on %@, because a key holding a double quote has no path it accepts."),
                column
            )
        case .rawFilterNotAnObject:
            return String(localized: "A raw filter for Qdrant is a JSON condition, such as {\"key\": \"city\", \"match\": {\"value\": \"Berlin\"}}.")
        }
    }
}

// AND rows go under `must` and OR rows under `should`. A negated row is a nested filter with `must_not`,
// which, like `$ne` in a document store, also matches a point the key is missing from.
public enum QdrantFilterBuilder {
    public static let rawFilterColumn = "__RAW__"

    public static func filter(
        _ filters: [QdrantFilterSpec],
        logicMode: String,
        collection: QdrantCollection
    ) throws -> [String: Any]? {
        guard !filters.isEmpty else { return nil }
        let conditions = try filters.map { try condition(for: $0, collection: collection) }
        return [logicMode.uppercased() == "OR" ? "should" : "must": conditions]
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
            if op == "CONTAINS" || op == "NOT CONTAINS" {
                return idContains(op: op, value: filter.value)
            }
            return try idCondition(op: op, value: filter.value)
        }
        guard let key = QdrantKeyPath.quoted(QdrantSchema.payloadKey(forColumn: filter.column)) else {
            throw QdrantFilterError.keyNotAddressable(column: filter.column)
        }
        let field = Field(column: filter.column, key: key, type: collection.indexType(ofColumn: filter.column))

        switch op {
        case "=":
            return try field.equality(filter.value)
        case "!=", "<>":
            return negated([try field.equality(filter.value)])
        case ">", ">=", "<", "<=":
            return try field.range(op: op, bounds: [rangeKey(op): filter.value])
        case "BETWEEN":
            guard let upper = filter.secondValue, !upper.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw QdrantFilterError.missingUpperBound(column: filter.column)
            }
            return try field.range(op: op, bounds: ["gte": lowerBound(of: filter.value, upperBound: upper), "lte": upper])
        case "IN":
            return try field.anyOf(list(filter.value, column: filter.column))
        case "NOT IN":
            return negated(try field.anyOfConditions(list(filter.value, column: filter.column)))
        case "CONTAINS":
            return try field.textMatch(filter.value)
        case "NOT CONTAINS":
            return negated([try field.textMatch(filter.value)])
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
        // The payload index's type. Nil for a field nobody indexed, whose points may hold `"42"`, `42`
        // or a list of either, so a value there matches every type its text can spell.
        let type: QdrantFieldType?

        func equality(_ value: String) throws -> [String: Any] {
            guard let type else { return anyType(equalTo: value) }
            switch type {
            case .keyword, .text, .string, .uuid:
                return match(value)
            case .integer:
                guard let number = QdrantValue.integer(value) else {
                    throw QdrantValueError.notAnInteger(column: column, value: value)
                }
                return match(NSNumber(value: number))
            case .bool:
                guard let flag = QdrantValue.bool(value) else {
                    throw QdrantValueError.notABoolean(column: column, value: value)
                }
                return match(flag)
            case .float, .datetime:
                return try range(op: "=", bounds: ["gte": value, "lte": value])
            case .array, .json:
                return anyType(equalTo: value)
            case .geo, .object:
                throw QdrantFilterError.wholeValueNotMatchable(column: column, type: type.rawValue)
            }
        }

        private func anyType(equalTo value: String) -> [String: Any] {
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

        // Qdrant's `match.any` takes strings alone or integers alone; anything else is one `should`.
        func anyOf(_ values: [String]) throws -> [String: Any] {
            let conditions = try anyOfConditions(values)
            let matched = conditions.compactMap { ($0["match"] as? [String: Any])?["value"] }
            if matched.count == conditions.count {
                if matched.allSatisfy({ $0 is String }) || matched.allSatisfy(isInteger) {
                    return ["key": key, "match": ["any": matched]]
                }
            }
            return ["should": conditions]
        }

        func anyOfConditions(_ values: [String]) throws -> [[String: Any]] {
            try values.map(equality)
        }

        func range(op: String, bounds: [String: String]) throws -> [String: Any] {
            if let type, !type.isOrdered, type != .json, type != .array {
                throw QdrantFilterError.comparisonNeedsNumberOrDate(column: column, op: op)
            }
            var range: [String: Any] = [:]
            for (bound, text) in bounds {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if type == .datetime {
                    range[bound] = trimmed
                } else if let number = QdrantValue.number(trimmed) {
                    range[bound] = NSNumber(value: number)
                } else if type?.isOrdered == true {
                    throw QdrantValueError.notANumber(column: column, value: text)
                } else {
                    range[bound] = trimmed
                }
            }
            return ["key": key, "range": range]
        }

        // Without a full-text index Qdrant still matches the words, lowercased.
        func textMatch(_ value: String) throws -> [String: Any] {
            if let type, !type.holdsText {
                throw QdrantFilterError.textMatchNeedsText(column: column, type: type.rawValue)
            }
            return ["key": key, "match": ["text": value]]
        }

        // `is_empty` covers a missing key, null and []; `is_null` would miss the missing key the grid shows as NULL.
        var isEmpty: [String: Any] {
            ["is_empty": ["key": key]]
        }

        var isBlank: [String: Any] {
            if let type, !type.holdsText { return isEmpty }
            return ["should": [isEmpty, match("")]]
        }

        private func match(_ value: Any) -> [String: Any] {
            ["key": key, "match": ["value": value]]
        }

        private func isInteger(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return !QdrantJSON.isBoolean(number) && !CFNumberIsFloatType(number)
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
