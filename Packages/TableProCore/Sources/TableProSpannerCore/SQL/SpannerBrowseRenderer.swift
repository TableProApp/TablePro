import Foundation
import TableProGoogleCloud

public enum SpannerBrowseRenderer {
    public static let rawSQLColumn = "__RAW__"

    public static func select(_ request: SpannerBrowseRequest, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var parameters = SpannerParameterList(dialect: dialect)
        var sql = "SELECT * FROM " + dialect.qualifiedName(schema: request.schema, name: request.table)
        sql += whereClause(request, dialect: dialect, parameters: &parameters)
        sql += orderByClause(request.sorts, dialect: dialect)
        sql += " LIMIT \(max(0, request.limit)) OFFSET \(max(0, request.offset))"
        return statement(sql, parameters: parameters)
    }

    public static func count(_ request: SpannerBrowseRequest, dialect: SpannerDialect) -> SpannerRenderedStatement {
        var parameters = SpannerParameterList(dialect: dialect)
        var sql = "SELECT COUNT(*) FROM " + dialect.qualifiedName(schema: request.schema, name: request.table)
        sql += whereClause(request, dialect: dialect, parameters: &parameters)
        return statement(sql, parameters: parameters)
    }

    private static func statement(_ sql: String, parameters: SpannerParameterList) -> SpannerRenderedStatement {
        SpannerRenderedStatement(
            sql: sql,
            parameters: parameters.values,
            parameterTypes: parameters.values.isEmpty ? [] : nil
        )
    }

    private static func whereClause(
        _ request: SpannerBrowseRequest,
        dialect: SpannerDialect,
        parameters: inout SpannerParameterList
    ) -> String {
        guard !request.filters.isEmpty else { return "" }
        var builder = SpannerFilterClauseBuilder(dialect: dialect, parameters: parameters)
        let clauses = request.filters.map { builder.clause(for: $0) }
        parameters = builder.parameters
        let connective = request.matchAll ? " AND " : " OR "
        return " WHERE (" + clauses.joined(separator: connective) + ")"
    }

    private static func orderByClause(_ sorts: [SpannerBrowseSort], dialect: SpannerDialect) -> String {
        guard !sorts.isEmpty else { return "" }
        let terms = sorts.map { dialect.quoteIdentifier($0.column) + ($0.ascending ? " ASC" : " DESC") }
        return " ORDER BY " + terms.joined(separator: ", ")
    }
}

internal struct SpannerFilterClauseBuilder {
    private static let neverMatches = "FALSE"

    private let dialect: SpannerDialect
    private(set) var parameters: SpannerParameterList

    init(dialect: SpannerDialect, parameters: SpannerParameterList) {
        self.dialect = dialect
        self.parameters = parameters
    }

    mutating func clause(for filter: SpannerBrowseFilter) -> String {
        guard filter.column != SpannerBrowseRenderer.rawSQLColumn else { return rawClause(filter.value) }
        let column = dialect.quoteIdentifier(filter.column)
        switch filter.op.trimmingCharacters(in: .whitespaces).uppercased() {
        case "=":
            return equality(column, filter, operatorText: "=", nullTest: "IS NULL")
        case "!=", "<>":
            return equality(column, filter, operatorText: "!=", nullTest: "IS NOT NULL")
        case let comparison where ["<", "<=", ">", ">="].contains(comparison):
            return "\(column) \(comparison) \(parameters.bind(filter.value))"
        case "CONTAINS":
            return like(column, filter, pattern: "%\(patternBody(filter.value))%", negated: false)
        case "NOT CONTAINS":
            return like(column, filter, pattern: "%\(patternBody(filter.value))%", negated: true)
        case "STARTS WITH":
            return like(column, filter, pattern: "\(patternBody(filter.value))%", negated: false)
        case "ENDS WITH":
            return like(column, filter, pattern: "%\(patternBody(filter.value))", negated: false)
        case "IN":
            return membership(column, filter, negated: false)
        case "NOT IN":
            return membership(column, filter, negated: true)
        case "BETWEEN":
            return between(column, filter)
        case "IS NULL":
            return "\(column) IS NULL"
        case "IS NOT NULL":
            return "\(column) IS NOT NULL"
        case "IS EMPTY":
            return "(\(column) IS NULL OR \(textOf(column)) = '')"
        case "IS NOT EMPTY":
            return "(\(column) IS NOT NULL AND \(textOf(column)) != '')"
        case "REGEX":
            return regex(column, filter)
        default:
            return Self.neverMatches
        }
    }

    private func rawClause(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.neverMatches : "(\(trimmed)\n)"
    }

    private func textOf(_ column: String) -> String {
        "CAST(\(column) AS \(dialect.textCastType))"
    }

    private func patternBody(_ value: String) -> String {
        GoogleSQLLiteral.likePatternBody(value)
    }

    private mutating func equality(
        _ column: String,
        _ filter: SpannerBrowseFilter,
        operatorText: String,
        nullTest: String
    ) -> String {
        if filter.value.trimmingCharacters(in: .whitespaces).uppercased() == "NULL" {
            return "\(column) \(nullTest)"
        }
        guard !filter.caseSensitive else {
            return "\(column) \(operatorText) \(parameters.bind(filter.value))"
        }
        return "LOWER(\(textOf(column))) \(operatorText) LOWER(\(parameters.bind(filter.value)))"
    }

    private mutating func like(_ column: String, _ filter: SpannerBrowseFilter, pattern: String, negated: Bool) -> String {
        let keyword = negated ? "NOT LIKE" : "LIKE"
        let placeholder = parameters.bind(pattern)
        guard !filter.caseSensitive else {
            return "\(textOf(column)) \(keyword) \(placeholder)"
        }
        return "LOWER(\(textOf(column))) \(keyword) LOWER(\(placeholder))"
    }

    private mutating func membership(_ column: String, _ filter: SpannerBrowseFilter, negated: Bool) -> String {
        let items = filter.value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let includesNull = items.contains { $0.uppercased() == "NULL" }
        let values = items.filter { $0.uppercased() != "NULL" }
        var conditions: [String] = []
        if !values.isEmpty {
            conditions.append(valueList(column, values, caseSensitive: filter.caseSensitive, negated: negated))
        }
        if includesNull {
            conditions.append(negated ? "\(column) IS NOT NULL" : "\(column) IS NULL")
        }
        guard !conditions.isEmpty else { return Self.neverMatches }
        guard conditions.count > 1 else { return conditions[0] }
        return "(\(conditions.joined(separator: negated ? " AND " : " OR ")))"
    }

    private mutating func valueList(_ column: String, _ values: [String], caseSensitive: Bool, negated: Bool) -> String {
        let keyword = negated ? "NOT IN" : "IN"
        guard !caseSensitive else {
            let placeholders = values.map { parameters.bind($0) }
            return "\(column) \(keyword) (\(placeholders.joined(separator: ", ")))"
        }
        let placeholders = values.map { "LOWER(\(parameters.bind($0)))" }
        return "LOWER(\(textOf(column))) \(keyword) (\(placeholders.joined(separator: ", ")))"
    }

    private mutating func between(_ column: String, _ filter: SpannerBrowseFilter) -> String {
        guard let bounds = Self.betweenBounds(filter) else { return Self.neverMatches }
        return "\(column) BETWEEN \(parameters.bind(bounds.lower)) AND \(parameters.bind(bounds.upper))"
    }

    private static func betweenBounds(_ filter: SpannerBrowseFilter) -> (lower: String, upper: String)? {
        if let upper = filter.secondValue {
            let joinedSuffix = "," + upper
            let lower = filter.value.hasSuffix(joinedSuffix) ? String(filter.value.dropLast(joinedSuffix.count)) : filter.value
            return (lower, upper)
        }
        guard let comma = filter.value.firstIndex(of: ",") else { return nil }
        let lower = filter.value[..<comma].trimmingCharacters(in: .whitespaces)
        let upper = filter.value[filter.value.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (lower, upper)
    }

    private mutating func regex(_ column: String, _ filter: SpannerBrowseFilter) -> String {
        let placeholder = parameters.bind(filter.value)
        switch dialect {
        case .googleSQL:
            let pattern = filter.caseSensitive ? placeholder : "CONCAT('(?i)', \(placeholder))"
            return "REGEXP_CONTAINS(\(textOf(column)), \(pattern))"
        case .postgreSQL:
            let pattern = filter.caseSensitive ? placeholder : "('(?i)' || \(placeholder))"
            return "\(textOf(column)) ~ \(pattern)"
        }
    }
}
