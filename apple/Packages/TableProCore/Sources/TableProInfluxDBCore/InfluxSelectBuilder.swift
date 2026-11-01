import Foundation

public struct InfluxFilter: Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String
    public let secondValue: String?
    public let isCaseSensitive: Bool
    public let isText: Bool

    public init(
        column: String,
        op: String,
        value: String,
        secondValue: String? = nil,
        isCaseSensitive: Bool = true,
        isText: Bool = false
    ) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
        self.isCaseSensitive = isCaseSensitive
        self.isText = isText
    }
}

public struct InfluxSort: Sendable, Equatable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// Writes the grid's `SELECT` in SQL (3.x) or InfluxQL (1.x, 2.x). The two share the shape
/// `SELECT ... FROM "m" WHERE ... ORDER BY time DESC LIMIT n OFFSET m`, so a query built before
/// the server version is known runs on either. They differ in literals, regex syntax and in what
/// InfluxQL leaves out: no `IN`, no `IS NULL`, and `ORDER BY time` only.
public enum InfluxSelectBuilder {
    public static func select(
        measurement: String,
        columns: [String],
        filters: [InfluxFilter] = [],
        logicMode: String = "and",
        sorts: [InfluxSort] = [],
        limit: Int,
        offset: Int,
        language: InfluxQueryLanguage
    ) -> String {
        let projection = language == .sql && !columns.isEmpty
            ? columns.map { quoteIdentifier($0, language: language) }.joined(separator: ", ")
            : "*"
        var statement = "SELECT \(projection) FROM \(quoteIdentifier(measurement, language: language))"
        statement += whereClause(filters, logicMode: logicMode, language: language)
        statement += " ORDER BY " + orderBy(sorts, language: language)
        statement += " LIMIT \(max(limit, 0)) OFFSET \(max(offset, 0))"
        return statement
    }

    /// InfluxQL answers `COUNT(*)` with one `count_<field>` column per field, which is the point
    /// count only for a measurement with one field; the caller decides whether to ask.
    public static func count(
        measurement: String,
        filters: [InfluxFilter] = [],
        logicMode: String = "and",
        language: InfluxQueryLanguage
    ) -> String {
        "SELECT COUNT(*) FROM \(quoteIdentifier(measurement, language: language))"
            + whereClause(filters, logicMode: logicMode, language: language)
    }

    public static func rowCount(from table: InfluxResultTable) -> Int? {
        guard let row = table.rows.first else { return 0 }
        let counts = zip(table.columns, row).compactMap { column, value -> Int? in
            guard column.lowercased().hasPrefix("count"), let value else { return nil }
            return Int(value)
        }
        return counts.max()
    }

    static func whereClause(_ filters: [InfluxFilter], logicMode: String, language: InfluxQueryLanguage) -> String {
        let conditions = filters.compactMap { condition(for: $0, language: language) }
        guard !conditions.isEmpty else { return "" }
        let joiner = logicMode.lowercased() == "or" ? " OR " : " AND "
        return " WHERE " + conditions.joined(separator: joiner)
    }

    static func orderBy(_ sorts: [InfluxSort], language: InfluxQueryLanguage) -> String {
        let timeFirst = "time DESC"
        switch language {
        case .sql:
            guard !sorts.isEmpty else { return timeFirst }
            return sorts
                .map { "\(quoteIdentifier($0.column, language: language)) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
        case .influxQL, .flux:
            guard let time = sorts.first(where: { $0.column == InfluxTypeName.timeColumn }) else {
                return timeFirst
            }
            return time.ascending ? "time ASC" : timeFirst
        }
    }

    // MARK: - Conditions

    static func condition(for filter: InfluxFilter, language: InfluxQueryLanguage) -> String? {
        let column = quoteIdentifier(filter.column, language: language)
        let op = filter.op.uppercased()
        switch op {
        case "=", "!=", "<>", "<", ">", "<=", ">=":
            let sqlOp = op == "<>" ? "!=" : op
            return "\(column) \(sqlOp) \(literal(filter.value, filter: filter, language: language))"
        case "CONTAINS":
            return regex(column, escapedRegex(filter.value), filter, language)
        case "NOT CONTAINS":
            return regex(column, escapedRegex(filter.value), filter, language, negated: true)
        case "STARTS WITH":
            return regex(column, "^" + escapedRegex(filter.value), filter, language)
        case "ENDS WITH":
            return regex(column, escapedRegex(filter.value) + "$", filter, language)
        case "REGEX":
            return regex(column, filter.value, filter, language)
        case "IN", "NOT IN":
            let values = filter.value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { return nil }
            let negated = op == "NOT IN"
            let parts = values.map {
                "\(column) \(negated ? "!=" : "=") \(literal($0, filter: filter, language: language))"
            }
            return "(" + parts.joined(separator: negated ? " AND " : " OR ") + ")"
        case "BETWEEN":
            guard let upper = filter.secondValue else { return nil }
            let low = literal(filter.value, filter: filter, language: language)
            let high = literal(upper, filter: filter, language: language)
            return "(\(column) >= \(low) AND \(column) <= \(high))"
        case "IS NULL":
            return language == .sql ? "\(column) IS NULL" : "\(column) = ''"
        case "IS NOT NULL":
            return language == .sql ? "\(column) IS NOT NULL" : "\(column) != ''"
        case "IS EMPTY":
            return "\(column) = ''"
        case "IS NOT EMPTY":
            return "\(column) != ''"
        default:
            return nil
        }
    }

    /// Escapes the metacharacters RE2 and the Rust regex crate share. `NSRegularExpression`'s
    /// escaper also escapes `/`, which InfluxQL's `/.../` literal would then escape twice.
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
        _ filter: InfluxFilter,
        _ language: InfluxQueryLanguage,
        negated: Bool = false
    ) -> String {
        let flagged = filter.isCaseSensitive ? pattern : "(?i)" + pattern
        switch language {
        case .sql:
            return "\(column) \(negated ? "!~" : "~") \(stringLiteral(flagged, language: language))"
        case .influxQL, .flux:
            let delimited = flagged.replacingOccurrences(of: "/", with: "\\/")
            return "\(column) \(negated ? "!~" : "=~") /\(delimited)/"
        }
    }

    static func literal(_ value: String, filter: InfluxFilter, language: InfluxQueryLanguage) -> String {
        if filter.column == InfluxTypeName.timeColumn || filter.isText {
            return stringLiteral(value, language: language)
        }
        if Double(value) != nil, value.rangeOfCharacter(from: .letters) == nil {
            return value
        }
        if value == "true" || value == "false" {
            return value
        }
        return stringLiteral(value, language: language)
    }

    // MARK: - Quoting

    public static func quoteIdentifier(_ name: String, language: InfluxQueryLanguage) -> String {
        switch language {
        case .sql:
            return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .influxQL, .flux:
            let escaped = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }
    }

    public static func stringLiteral(_ value: String, language: InfluxQueryLanguage) -> String {
        switch language {
        case .sql:
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        case .influxQL, .flux:
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'" + escaped + "'"
        }
    }
}
