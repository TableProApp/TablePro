import Foundation

public struct BigtableFilterSpec: Codable, Sendable, Equatable {
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

/// A page of one table as the grid asked for it. `after` is the last key of the page before, which
/// is how a page starts: Bigtable reads rows in key order and has no offset.
public struct BigtableBrowseSpec: Codable, Sendable, Equatable {
    public let table: String
    public let filters: [BigtableFilterSpec]
    public let logicMode: String
    public let descending: Bool
    /// The column the grid sorted by, kept so a sort Bigtable cannot do is refused rather than
    /// silently ignored. Rows only come in key order.
    public let sortColumn: String?
    public let limit: Int
    public let offset: Int

    public init(
        table: String,
        filters: [BigtableFilterSpec] = [],
        logicMode: String = "AND",
        descending: Bool = false,
        sortColumn: String? = nil,
        limit: Int,
        offset: Int
    ) {
        self.table = table
        self.filters = filters
        self.logicMode = logicMode
        self.descending = descending
        self.sortColumn = sortColumn
        self.limit = limit
        self.offset = offset
    }

    public var usesOr: Bool {
        logicMode.uppercased() == "OR"
    }

    /// The spec with the page left out, so pages of the same view share one cursor cache.
    public var viewKey: String {
        let filterText = filters.map { "\($0.column)\u{1}\($0.op)\u{1}\($0.value)\u{1}\($0.secondValue ?? "")" }.joined(separator: "\u{2}")
        return [table, logicMode.uppercased(), descending ? "desc" : "asc", filterText].joined(separator: "\u{3}")
    }
}

/// The bounds a row key may take: an interval, or a list of exact keys.
struct BigtableKeyBounds: Equatable {
    var start: (key: Data, closed: Bool)?
    var end: (key: Data, closed: Bool)?
    var exact: [Data]?

    static func == (lhs: BigtableKeyBounds, rhs: BigtableKeyBounds) -> Bool {
        lhs.start?.key == rhs.start?.key && lhs.start?.closed == rhs.start?.closed
            && lhs.end?.key == rhs.end?.key && lhs.end?.closed == rhs.end?.closed && lhs.exact == rhs.exact
    }

    mutating func raiseStart(_ key: Data, closed: Bool) {
        guard let current = start else { start = (key, closed); return }
        if current.key.lexicographicallyPrecedes(key) || (current.key == key && !closed) {
            start = (key, closed && current.closed)
        }
    }

    mutating func lowerEnd(_ key: Data, closed: Bool) {
        guard let current = end else { end = (key, closed); return }
        if key.lexicographicallyPrecedes(current.key) || (current.key == key && !closed) {
            end = (key, closed && current.closed)
        }
    }

    func admits(_ key: Data) -> Bool {
        if let start {
            if key.lexicographicallyPrecedes(start.key) || (key == start.key && !start.closed) { return false }
        }
        if let end {
            if end.key.lexicographicallyPrecedes(key) || (key == end.key && !end.closed) { return false }
        }
        return true
    }

    func json() -> [String: Any] {
        if let exact {
            return ["rowKeys": exact.filter(admits).map { $0.base64EncodedString() }]
        }
        var range: [String: Any] = [:]
        if let start { range[start.closed ? "startKeyClosed" : "startKeyOpen"] = start.key.base64EncodedString() }
        if let end { range[end.closed ? "endKeyClosed" : "endKeyOpen"] = end.key.base64EncodedString() }
        return range.isEmpty ? [:] : ["rowRanges": [range]]
    }
}

public enum BigtableReadRequest {
    public static let rawFilterColumn = "__RAW__"

    /// `after` continues a page past that key. `keysOnly` reads keys
    /// without values, which is how a page with no cursor yet skips the rows before it cheaply.
    public static func body(spec: BigtableBrowseSpec, limit: Int, after: Data?, keysOnly: Bool = false) throws -> [String: Any] {
        if (spec.sortColumn.map { $0 != BigtableRowSet.keyColumn } ?? false) || spec.descending {
            throw BigtableError.unsupported(String(localized: "The Bigtable REST API returns rows in ascending key order only."))
        }
        var bounds = BigtableKeyBounds()
        var rowFilters: [[String: Any]] = []
        var unions: [[String: Any]]?

        let keyFilters = spec.filters.filter { $0.column == BigtableRowSet.keyColumn && isRangeOperator($0.op) }
        if spec.usesOr, keyFilters.count == spec.filters.count, !keyFilters.isEmpty {
            unions = try keyFilters.map { filter in
                var single = BigtableKeyBounds()
                try applyKeyRange(filter, to: &single)
                return single.json()
            }
        } else {
            for filter in spec.filters {
                if filter.column == BigtableRowSet.keyColumn, isRangeOperator(filter.op), !spec.usesOr {
                    try applyKeyRange(filter, to: &bounds)
                } else {
                    rowFilters.append(try rowFilter(filter, insideOr: spec.usesOr))
                }
            }
        }
        if let after {
            bounds.raiseStart(after, closed: false)
        }

        var body: [String: Any] = [:]
        if let unions {
            body["rows"] = mergeUnions(unions, within: bounds)
        } else {
            let rows = bounds.json()
            if !rows.isEmpty { body["rows"] = rows }
            if let exact = rows["rowKeys"] as? [String], exact.isEmpty {
                body["rows"] = ["rowKeys": [String]()]
            }
        }
        var filters: [[String: Any]] = []
        switch rowFilters.count {
        case 0: break
        case 1: filters.append(rowFilters[0])
        default: filters.append([spec.usesOr ? "interleave" : "chain": ["filters": rowFilters]])
        }
        if keysOnly {
            filters += [["cellsPerRowLimitFilter": 1], ["stripValueTransformer": true]]
        } else {
            filters.append(["cellsPerColumnLimitFilter": 1])
        }
        body["filter"] = filters.count == 1 ? filters[0] : ["chain": ["filters": filters]]
        if limit > 0 { body["rowsLimit"] = String(limit) }
        return body
    }

    /// A list of exact keys or ranges asked for with no matching row is an empty `rowKeys`, which
    /// the API refuses, so the read is skipped by the caller when it would ask for nothing.
    public static func asksForNothing(_ body: [String: Any]) -> Bool {
        guard let rows = body["rows"] as? [String: Any] else { return false }
        let keys = rows["rowKeys"] as? [Any] ?? []
        let ranges = rows["rowRanges"] as? [Any] ?? []
        return keys.isEmpty && ranges.isEmpty
    }

    private static func mergeUnions(_ unions: [[String: Any]], within bounds: BigtableKeyBounds) -> [String: Any] {
        var keys: [String] = []
        var ranges: [[String: Any]] = []
        for union in unions {
            keys += union["rowKeys"] as? [String] ?? []
            ranges += union["rowRanges"] as? [[String: Any]] ?? []
        }
        var rows: [String: Any] = [:]
        let admitted = keys.compactMap { Data(base64Encoded: $0) }.filter(bounds.admits).map { $0.base64EncodedString() }
        if !admitted.isEmpty { rows["rowKeys"] = admitted }
        if !ranges.isEmpty {
            rows["rowRanges"] = ranges.map { range in clamp(range, to: bounds) }
        }
        return rows
    }

    /// A cursor cuts every range of an OR at the key the last page ended on.
    private static func clamp(_ range: [String: Any], to bounds: BigtableKeyBounds) -> [String: Any] {
        var single = BigtableKeyBounds()
        if let key = (range["startKeyClosed"] as? String).flatMap({ Data(base64Encoded: $0) }) { single.start = (key, true) }
        if let key = (range["startKeyOpen"] as? String).flatMap({ Data(base64Encoded: $0) }) { single.start = (key, false) }
        if let key = (range["endKeyClosed"] as? String).flatMap({ Data(base64Encoded: $0) }) { single.end = (key, true) }
        if let key = (range["endKeyOpen"] as? String).flatMap({ Data(base64Encoded: $0) }) { single.end = (key, false) }
        if let start = bounds.start { single.raiseStart(start.key, closed: start.closed) }
        if let end = bounds.end { single.lowerEnd(end.key, closed: end.closed) }
        return (single.json()["rowRanges"] as? [[String: Any]])?.first ?? [:]
    }

    static func isRangeOperator(_ op: String) -> Bool {
        ["=", "IN", "STARTS WITH", ">", ">=", "<", "<=", "BETWEEN"].contains(op.uppercased())
    }

    static func applyKeyRange(_ filter: BigtableFilterSpec, to bounds: inout BigtableKeyBounds) throws {
        let key = try BigtableBytes.parse(filter.value)
        switch filter.op.uppercased() {
        case "=":
            bounds.exact = (bounds.exact ?? [key]).filter { $0 == key }
        case "IN":
            let keys = try listItems(filter.value).map(BigtableBytes.parse)
            bounds.exact = bounds.exact.map { existing in existing.filter(keys.contains) } ?? keys
        case "STARTS WITH":
            bounds.raiseStart(key, closed: true)
            if let end = BigtableBytes.prefixEnd(key) { bounds.lowerEnd(end, closed: false) }
        case ">": bounds.raiseStart(key, closed: false)
        case ">=": bounds.raiseStart(key, closed: true)
        case "<": bounds.lowerEnd(key, closed: false)
        case "<=": bounds.lowerEnd(key, closed: true)
        case "BETWEEN":
            guard let upper = filter.secondValue else {
                throw BigtableError.configuration(String(localized: "BETWEEN needs two values."))
            }
            bounds.raiseStart(key, closed: true)
            bounds.lowerEnd(try BigtableBytes.parse(upper), closed: true)
        default:
            throw unsupported(filter.op)
        }
    }

    // MARK: - Row filters

    static func rowFilter(_ filter: BigtableFilterSpec, insideOr: Bool) throws -> [String: Any] {
        if filter.column == rawFilterColumn {
            return try rawFilter(filter.value)
        }
        if filter.column == BigtableRowSet.keyColumn {
            return try keyRegexFilter(filter, insideOr: insideOr)
        }
        let column = try BigtableColumn(name: filter.column)
        let base: [[String: Any]] = [
            ["familyNameRegexFilter": "^" + BigtableBytes.regexText(Data(column.family.utf8)) + "$"],
            ["columnQualifierRegexFilter": anchored(column.qualifier).base64EncodedString()],
            ["cellsPerColumnLimitFilter": 1]
        ]
        let value = try BigtableBytes.parse(filter.value)
        func predicate(_ extra: [String: Any]?) -> [String: Any] {
            ["chain": ["filters": base + (extra.map { [$0] } ?? [])]]
        }
        func regex(_ pattern: Data) -> [String: Any] {
            ["valueRegexFilter": pattern.base64EncodedString()]
        }
        let literal = BigtableBytes.regexLiteral(value)
        let anyText = Data("(?s).*".utf8)
        switch filter.op.uppercased() {
        case "=": return keep(predicate(regex(Data("(?s)^".utf8) + literal + Data("$".utf8))))
        case "!=", "<>": return drop(predicate(regex(Data("(?s)^".utf8) + literal + Data("$".utf8))))
        case "CONTAINS": return keep(predicate(regex(anyText + literal + anyText)))
        case "NOT CONTAINS": return drop(predicate(regex(anyText + literal + anyText)))
        case "STARTS WITH": return keep(predicate(regex(Data("(?s)^".utf8) + literal + anyText)))
        case "ENDS WITH": return keep(predicate(regex(anyText + literal + Data("$".utf8))))
        case "REGEX": return keep(predicate(regex(value)))
        case "IS EMPTY": return keep(predicate(regex(Data("^$".utf8))))
        case "IS NOT EMPTY": return drop(predicate(regex(Data("^$".utf8))))
        case "IS NULL": return drop(predicate(nil))
        case "IS NOT NULL": return keep(predicate(nil))
        case ">": return keep(predicate(["valueRangeFilter": ["startValueOpen": value.base64EncodedString()]]))
        case ">=": return keep(predicate(["valueRangeFilter": ["startValueClosed": value.base64EncodedString()]]))
        case "<": return keep(predicate(["valueRangeFilter": ["endValueOpen": value.base64EncodedString()]]))
        case "<=": return keep(predicate(["valueRangeFilter": ["endValueClosed": value.base64EncodedString()]]))
        case "BETWEEN":
            guard let upper = filter.secondValue else {
                throw BigtableError.configuration(String(localized: "BETWEEN needs two values."))
            }
            return keep(predicate(["valueRangeFilter": [
                "startValueClosed": value.base64EncodedString(),
                "endValueClosed": try BigtableBytes.parse(upper).base64EncodedString()
            ]]))
        case "IN":
            let alternatives = try listItems(filter.value).map { BigtableBytes.regexText(try BigtableBytes.parse($0)) }
            return keep(predicate(regex(Data(("(?s)^(" + alternatives.joined(separator: "|") + ")$").utf8))))
        default:
            throw unsupported(filter.op)
        }
    }

    /// A key test that no row range can express, or one inside an OR with column tests, runs as a
    /// key regex instead.
    private static func keyRegexFilter(_ filter: BigtableFilterSpec, insideOr: Bool) throws -> [String: Any] {
        let literal = BigtableBytes.regexLiteral(try BigtableBytes.parse(filter.value))
        let anyText = Data("(?s).*".utf8)
        let pattern: Data
        var negate = false
        switch filter.op.uppercased() {
        case "=": pattern = Data("(?s)^".utf8) + literal + Data("$".utf8)
        case "!=", "<>": pattern = Data("(?s)^".utf8) + literal + Data("$".utf8); negate = true
        case "STARTS WITH": pattern = Data("(?s)^".utf8) + literal + anyText
        case "ENDS WITH": pattern = anyText + literal + Data("$".utf8)
        case "CONTAINS": pattern = anyText + literal + anyText
        case "NOT CONTAINS": pattern = anyText + literal + anyText; negate = true
        case "REGEX": pattern = try BigtableBytes.parse(filter.value)
        default:
            throw BigtableError.unsupported(insideOr
                ? String(localized: "A key range cannot be ORed with a column filter. Use =, STARTS WITH or REGEX on _key, or AND.")
                : unsupportedMessage(filter.op))
        }
        let test: [String: Any] = ["rowKeyRegexFilter": pattern.base64EncodedString()]
        return negate ? drop(test) : keep(test)
    }

    private static func keep(_ predicate: [String: Any]) -> [String: Any] {
        ["condition": ["predicateFilter": predicate, "trueFilter": ["passAllFilter": true]]]
    }

    private static func drop(_ predicate: [String: Any]) -> [String: Any] {
        ["condition": ["predicateFilter": predicate, "falseFilter": ["passAllFilter": true]]]
    }

    private static func anchored(_ qualifier: Data) -> Data {
        Data("(?s)^".utf8) + BigtableBytes.regexLiteral(qualifier) + Data("$".utf8)
    }

    /// The raw filter row takes a `RowFilter` as written in the Bigtable REST reference, with bytes
    /// in base64, which reaches every filter the filter bar cannot draw.
    private static func rawFilter(_ text: String) throws -> [String: Any] {
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

    private static func unsupported(_ op: String) -> BigtableError {
        .unsupported(unsupportedMessage(op))
    }

    private static func unsupportedMessage(_ op: String) -> String {
        String(format: String(localized: "Bigtable cannot filter with %@."), op)
    }
}
