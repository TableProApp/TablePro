import Foundation

/// Turns one filter bar row into a `RowFilter` that passes a whole row or none of it.
enum BigtableRowFilter {
    static let rawColumn = "__RAW__"

    static func make(_ filter: BigtableFilterSpec, insideOr: Bool) throws -> [String: Any] {
        if filter.column == rawColumn {
            return try raw(filter.value)
        }
        if filter.column == BigtableRowSet.keyColumn {
            return try keyFilter(filter, insideOr: insideOr)
        }
        return try columnFilter(filter)
    }

    private static func keyFilter(_ filter: BigtableFilterSpec, insideOr: Bool) throws -> [String: Any] {
        guard let match = try textPattern(filter) else {
            throw BigtableError.unsupported(insideOr
                ? String(localized: "A key range cannot be ORed with a column filter. Use =, STARTS WITH or REGEX on _key, or AND.")
                : unsupportedMessage(filter.op))
        }
        let test: [String: Any] = ["rowKeyRegexFilter": match.pattern.base64EncodedString()]
        return match.isNegated ? drop(test) : keep(test)
    }

    private static func columnFilter(_ filter: BigtableFilterSpec) throws -> [String: Any] {
        let column = try BigtableColumn(name: filter.column)
        let base: [[String: Any]] = [
            ["familyNameRegexFilter": "^" + BigtableBytes.regexText(Data(column.family.utf8)) + "$"],
            ["columnQualifierRegexFilter": (Data("(?s)^".utf8) + BigtableBytes.regexLiteral(column.qualifier) + Data("$".utf8)).base64EncodedString()],
            ["cellsPerColumnLimitFilter": 1]
        ]
        func cellIn(_ test: [String: Any]?) -> [String: Any] {
            ["chain": ["filters": base + (test.map { [$0] } ?? [])]]
        }
        let present = keep(cellIn(nil))

        if let match = try textPattern(filter) {
            let test = cellIn(["valueRegexFilter": match.pattern.base64EncodedString()])
            return match.isNegated ? ["chain": ["filters": [present, drop(test)]]] : keep(test)
        }
        switch filter.op {
        case "IS NULL":
            return drop(cellIn(nil))
        case "IS NOT NULL":
            return present
        case "IS EMPTY":
            return keep(cellIn(["valueRegexFilter": Data("^$".utf8).base64EncodedString()]))
        case "IS NOT EMPTY":
            return ["chain": ["filters": [present, drop(cellIn(["valueRegexFilter": Data("^$".utf8).base64EncodedString()]))]]]
        case ">", ">=", "<", "<=", "BETWEEN":
            return keep(cellIn(["valueRangeFilter": try valueRange(filter)]))
        default:
            throw BigtableError.unsupported(unsupportedMessage(filter.op))
        }
    }

    /// The regex a text comparison matches, for a key or a value alike. Nil for an operator that is
    /// not a text comparison.
    private static func textPattern(_ filter: BigtableFilterSpec) throws -> (pattern: Data, isNegated: Bool)? {
        let anyText = Data(".*".utf8)
        let flags = Data((filter.isCaseSensitive ? "(?s)" : "(?is)").utf8)
        func literal() throws -> Data {
            BigtableBytes.regexLiteral(try BigtableBytes.parse(filter.value))
        }
        func alternatives() throws -> Data {
            let items = try listItems(filter.value).map { BigtableBytes.regexText(try BigtableBytes.parse($0)) }
            return flags + Data(("^(" + items.joined(separator: "|") + ")$").utf8)
        }
        switch filter.op {
        case "=": return (flags + Data("^".utf8) + (try literal()) + Data("$".utf8), false)
        case "!=", "<>": return (flags + Data("^".utf8) + (try literal()) + Data("$".utf8), true)
        case "STARTS WITH": return (flags + Data("^".utf8) + (try literal()) + anyText, false)
        case "ENDS WITH": return (flags + anyText + (try literal()) + Data("$".utf8), false)
        case "CONTAINS": return (flags + anyText + (try literal()) + anyText, false)
        case "NOT CONTAINS": return (flags + anyText + (try literal()) + anyText, true)
        case "IN": return (try alternatives(), false)
        case "NOT IN": return (try alternatives(), true)
        case "REGEX": return ((filter.isCaseSensitive ? Data() : Data("(?i)".utf8)) + (try BigtableBytes.parse(filter.value)), false)
        default: return nil
        }
    }

    private static func valueRange(_ filter: BigtableFilterSpec) throws -> [String: Any] {
        let value = try BigtableBytes.parse(filter.value).base64EncodedString()
        switch filter.op {
        case ">": return ["startValueOpen": value]
        case ">=": return ["startValueClosed": value]
        case "<": return ["endValueOpen": value]
        case "<=": return ["endValueClosed": value]
        default:
            guard let upper = filter.secondValue else {
                throw BigtableError.configuration(String(localized: "BETWEEN needs two values."))
            }
            return ["startValueClosed": value, "endValueClosed": try BigtableBytes.parse(upper).base64EncodedString()]
        }
    }

    private static func keep(_ predicate: [String: Any]) -> [String: Any] {
        ["condition": ["predicateFilter": predicate, "trueFilter": ["passAllFilter": true]]]
    }

    private static func drop(_ predicate: [String: Any]) -> [String: Any] {
        ["condition": ["predicateFilter": predicate, "falseFilter": ["passAllFilter": true]]]
    }

    /// The raw filter row takes a `RowFilter` as written in the Bigtable REST reference, with bytes
    /// in base64, which reaches every filter the filter bar cannot draw.
    private static func raw(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object.count == 1 else {
            throw BigtableError.configuration(String(localized: "A raw Bigtable filter is a JSON RowFilter, such as {\"rowKeyRegexFilter\": \"<base64>\"}."))
        }
        return object
    }

    static func listItems(_ text: String) -> [String] {
        if let data = text.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return array
        }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func unsupportedMessage(_ op: String) -> String {
        String(format: String(localized: "Bigtable cannot filter with %@."), op)
    }
}
