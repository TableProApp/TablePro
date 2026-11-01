import Foundation

public enum InfluxColumnKind: Sendable, Equatable, Hashable {
    case time
    case tag
    case text
    case number
    case boolean

    var holdsText: Bool { self == .tag || self == .text }
}

public struct InfluxFilter: Sendable, Equatable, Hashable {
    public let column: String
    public let op: String
    public let value: String
    public let secondValue: String?
    public let isCaseSensitive: Bool

    public init(column: String, op: String, value: String, secondValue: String? = nil, isCaseSensitive: Bool = true) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
        self.isCaseSensitive = isCaseSensitive
    }
}

public struct InfluxSort: Sendable, Equatable, Hashable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

// The data grid's page, count or export of one measurement, written in SQL on 3.x and InfluxQL on 1.x and 2.x. The
// statement opens with its language marker, so it routes the same when it is copied into the editor.
public struct InfluxGridQuery: Sendable, Equatable, Hashable {
    public enum Shape: Sendable, Equatable, Hashable {
        case page(limit: Int, offset: Int)
        case count
        case all
    }

    public let measurement: String
    public let projection: [String]
    public let filters: [InfluxFilter]
    public let matchesAll: Bool
    public let sorts: [InfluxSort]
    public let shape: Shape

    public init(
        measurement: String,
        projection: [String] = [],
        filters: [InfluxFilter] = [],
        matchesAll: Bool = true,
        sorts: [InfluxSort] = [],
        shape: Shape
    ) {
        self.measurement = measurement
        self.projection = projection
        self.filters = filters
        self.matchesAll = matchesAll
        self.sorts = sorts
        self.shape = shape
    }

    // Nil when a filter has no meaning in the language for that column, rather than a statement that answers wrong.
    // Unmarked, the statement is routed by its text: a driver asked before it knows the server version writes the
    // InfluxQL form, which a 3.x server also reads as SQL for a page without filters.
    public func statement(
        language: InfluxQueryLanguage,
        kinds: [String: InfluxColumnKind],
        marked: Bool = true
    ) -> String? {
        var conditions: [String] = []
        for filter in filters {
            guard let condition = Self.condition(for: filter, kind: kinds[filter.column], language: language) else {
                return nil
            }
            conditions.append(condition)
        }
        let table = Self.quoteIdentifier(measurement, language: language)
        var statement: String
        switch shape {
        case .count:
            statement = "SELECT COUNT(*) FROM \(table)"
        case .page, .all:
            let columns = language == .sql && !projection.isEmpty
                ? projection.map { Self.quoteIdentifier($0, language: language) }.joined(separator: ", ")
                : "*"
            statement = "SELECT \(columns) FROM \(table)"
        }
        if !conditions.isEmpty {
            statement += " WHERE " + conditions.joined(separator: matchesAll ? " AND " : " OR ")
        }
        if case .page(let limit, let offset) = shape {
            statement += " ORDER BY " + orderBy(language: language)
            statement += " LIMIT \(max(limit, 0)) OFFSET \(max(offset, 0))"
        }
        return marked ? InfluxStatement.marked(statement, language: language) : statement
    }

    // InfluxQL answers `COUNT(*)` with one `count_<field>` per field, the point count only when there is one field.
    public static func rowCount(from table: InfluxResultTable) -> Int? {
        guard let row = table.rows.first else { return 0 }
        return zip(table.columns, row).compactMap { column, value -> Int? in
            guard column.lowercased().hasPrefix("count"), let value else { return nil }
            return Int(value)
        }.max()
    }

    // InfluxQL orders by `time` only; another column's sort cannot be expressed and the page stays newest first.
    private func orderBy(language: InfluxQueryLanguage) -> String {
        let newestFirst = "time DESC"
        switch language {
        case .sql:
            guard !sorts.isEmpty else { return newestFirst }
            return sorts
                .map { "\(Self.quoteIdentifier($0.column, language: language)) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
        case .influxQL, .flux:
            guard let time = sorts.first(where: { $0.column == InfluxTypeName.timeColumn }) else { return newestFirst }
            return time.ascending ? "time ASC" : newestFirst
        }
    }

    static func condition(for filter: InfluxFilter, kind: InfluxColumnKind?, language: InfluxQueryLanguage) -> String? {
        let column = quoteIdentifier(filter.column, language: language)
        let op = filter.op.uppercased()
        switch op {
        case "=", "!=", "<>", "<", ">", "<=", ">=":
            return "\(column) \(op == "<>" ? "!=" : op) \(literal(filter.value, kind: kind, language: language))"
        case "CONTAINS", "NOT CONTAINS", "STARTS WITH", "ENDS WITH", "REGEX":
            guard kind?.holdsText ?? true else { return nil }
            let escaped = escapedRegex(filter.value)
            let pattern: String
            switch op {
            case "STARTS WITH": pattern = "^" + escaped
            case "ENDS WITH": pattern = escaped + "$"
            case "REGEX": pattern = filter.value
            default: pattern = escaped
            }
            return regex(column, pattern, filter: filter, language: language, negated: op == "NOT CONTAINS")
        case "IN", "NOT IN":
            let values = filter.value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { return nil }
            let negated = op == "NOT IN"
            let literals = values.map { literal($0, kind: kind, language: language) }
            if language == .sql {
                return "\(column) \(negated ? "NOT IN" : "IN") (\(literals.joined(separator: ", ")))"
            }
            let parts = literals.map { "\(column) \(negated ? "!=" : "=") \($0)" }
            return "(" + parts.joined(separator: negated ? " AND " : " OR ") + ")"
        case "BETWEEN":
            guard let upper = filter.secondValue else { return nil }
            let low = literal(filter.value, kind: kind, language: language)
            let high = literal(upper, kind: kind, language: language)
            return "(\(column) >= \(low) AND \(column) <= \(high))"
        case "IS NULL", "IS NOT NULL":
            let negated = op == "IS NOT NULL"
            if language == .sql { return "\(column) \(op)" }
            // InfluxQL matches a missing tag with `= ''` and has no test at all for a missing field.
            guard kind == nil || kind == .tag else { return nil }
            return "\(column) \(negated ? "!=" : "=") ''"
        case "IS EMPTY", "IS NOT EMPTY":
            guard kind?.holdsText ?? true else { return nil }
            return "\(column) \(op == "IS EMPTY" ? "=" : "!=") ''"
        default:
            return nil
        }
    }

    // The metacharacters RE2 and the Rust regex crate share. NSRegularExpression's escaper also escapes `/`, which
    // InfluxQL's `/.../` literal would then escape twice.
    static func escapedRegex(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\^$.|?*+()[]{}".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func regex(
        _ column: String,
        _ pattern: String,
        filter: InfluxFilter,
        language: InfluxQueryLanguage,
        negated: Bool
    ) -> String {
        let flagged = filter.isCaseSensitive ? pattern : "(?i)" + pattern
        switch language {
        case .sql:
            return "\(column) \(negated ? "!~" : "~") \(stringLiteral(flagged, language: language))"
        case .influxQL, .flux:
            return "\(column) \(negated ? "!~" : "=~") /\(influxQLRegexBody(flagged))/"
        }
    }

    // InfluxQL reads `\/` as an escaped slash even after another backslash, so a value ending in `\` would run the
    // literal past its closing `/`. A slash or a backslash of the pattern goes out as a hex escape instead.
    static func influxQLRegexBody(_ pattern: String) -> String {
        var body = ""
        var characters = pattern[...]
        while let character = characters.popFirst() {
            switch character {
            case "/":
                body += "\\x2f"
            case "\\":
                switch characters.first {
                case "/"?:
                    characters.removeFirst()
                    body += "\\x2f"
                case "\\"?, nil:
                    if characters.first != nil { characters.removeFirst() }
                    body += "\\x5c"
                case let escaped?:
                    characters.removeFirst()
                    body += "\\" + String(escaped)
                }
            default:
                body.append(character)
            }
        }
        return body
    }

    static func literal(_ value: String, kind: InfluxColumnKind?, language: InfluxQueryLanguage) -> String {
        switch kind {
        case .time, .tag, .text:
            return stringLiteral(value, language: language)
        case .number:
            return isNumber(value) ? value : stringLiteral(value, language: language)
        case .boolean:
            let lowered = value.lowercased()
            return lowered == "true" || lowered == "false" ? lowered : stringLiteral(value, language: language)
        case nil:
            if isNumber(value) || value == "true" || value == "false" { return value }
            return stringLiteral(value, language: language)
        }
    }

    private static func isNumber(_ value: String) -> Bool {
        Double(value) != nil && value.rangeOfCharacter(from: .letters) == nil
    }

    public static func quoteIdentifier(_ name: String, language: InfluxQueryLanguage) -> String {
        switch language {
        case .sql:
            return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .influxQL, .flux:
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }
    }

    public static func stringLiteral(_ value: String, language: InfluxQueryLanguage) -> String {
        switch language {
        case .sql:
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        case .influxQL, .flux:
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            return "'" + escaped + "'"
        }
    }
}
