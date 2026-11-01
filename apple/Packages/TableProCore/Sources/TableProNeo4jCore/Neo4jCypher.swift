import Foundation

public enum Neo4jEntityKind: String, Sendable, CaseIterable {
    case node
    case relationship

    public var schemaName: String {
        switch self {
        case .node: "Labels"
        case .relationship: "Relationship Types"
        }
    }

    public var entityType: String {
        switch self {
        case .node: "NODE"
        case .relationship: "RELATIONSHIP"
        }
    }

    public init?(schemaName: String?) {
        guard let match = Self.allCases.first(where: { $0.schemaName == schemaName }) else { return nil }
        self = match
    }
}

public struct Neo4jFilter: Sendable, Equatable {
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

public enum Neo4jCypherError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedOperator(String)
    case unquotableName(String)
    case incompleteRange

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperator(let op):
            return String(format: String(localized: "The %@ filter is not available for Neo4j."), op)
        case .unquotableName(let name):
            return String(format: String(localized: "Neo4j cannot query the name %@ because it contains \\u."), name)
        case .incompleteRange:
            return String(localized: "Enter both bounds to filter with BETWEEN.")
        }
    }
}

public enum Neo4jCypher {
    public static let idColumn = "<id>"
    public static let labelsColumn = "<labels>"
    public static let startColumn = "<start>"
    public static let endColumn = "<end>"
    public static let rawFilterColumn = "__RAW__"

    // A comment keeps a browse query valid Cypher when pasted into the editor.
    public static let browseMarker = "// TablePro browse: "

    // Neo4j decodes `\uXXXX` before parsing, inside backticks too, so no spelling of `\u` stays inside its quotes.
    // `\uZZZZ` is an escape the server rejects; the query builders refuse such a name before it gets that far.
    public static func quote(_ identifier: String) -> String {
        let escaped = identifier
            .replacingOccurrences(of: "\\u", with: "\\uZZZZ")
            .replacingOccurrences(of: "`", with: "``")
        return "`" + escaped + "`"
    }

    public static func isQuotable(_ name: String) -> Bool {
        !name.contains("\\u")
    }

    static func requireQuotable(_ names: [String]) throws {
        if let name = names.first(where: { !isQuotable($0) }) { throw Neo4jCypherError.unquotableName(name) }
    }

    public static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'" + escaped + "'"
    }

    public static func browseKind(of query: String) -> Neo4jEntityKind? {
        let trimmed = query.drop { $0.isWhitespace }
        guard trimmed.hasPrefix(browseMarker) else { return nil }
        let rest = trimmed.dropFirst(browseMarker.count).prefix { !$0.isNewline }
        return Neo4jEntityKind(rawValue: rest.trimmingCharacters(in: .whitespaces))
    }

    public static func browsedName(in query: String) -> String? {
        guard browseKind(of: query) != nil, let start = query.range(of: ":`") else { return nil }
        var name = ""
        var index = start.upperBound
        while index < query.endIndex {
            let character = query[index]
            let next = query.index(after: index)
            guard character == "`" else {
                name.append(character)
                index = next
                continue
            }
            guard next < query.endIndex, query[next] == "`" else { return name }
            name.append("`")
            index = query.index(after: next)
        }
        return nil
    }

    public static func fixedColumns(for kind: Neo4jEntityKind) -> [String] {
        switch kind {
        case .node: [idColumn, labelsColumn]
        case .relationship: [idColumn, startColumn, endColumn]
        }
    }

    public static func pattern(for kind: Neo4jEntityKind, name: String) -> String {
        switch kind {
        case .node: "MATCH (n:\(quote(name)))"
        case .relationship: "MATCH ()-[n:\(quote(name))]->()"
        }
    }

    public static func browseQuery(
        kind: Neo4jEntityKind,
        name: String,
        filters: [Neo4jFilter] = [],
        matchesAll: Bool = true,
        sort: [(column: String, ascending: Bool)] = [],
        limit: Int,
        offset: Int,
        usesElementId: Bool = true
    ) throws -> String {
        try requireQuotable([name] + sort.map(\.column))
        var lines = [browseMarker + kind.rawValue, pattern(for: kind, name: name)]
        if let filter = try whereClause(filters, matchesAll: matchesAll, usesElementId: usesElementId) {
            lines.append(filter)
        }
        lines.append("RETURN n")
        if !sort.isEmpty {
            let keys = sort.map { expression(for: $0.column, usesElementId: usesElementId) + ($0.ascending ? " ASC" : " DESC") }
            lines.append("ORDER BY " + keys.joined(separator: ", "))
        }
        lines.append("SKIP \(max(0, offset)) LIMIT \(max(0, limit))")
        return lines.joined(separator: "\n")
    }

    public static func exportQuery(kind: Neo4jEntityKind, name: String) throws -> String {
        try requireQuotable([name])
        return [browseMarker + kind.rawValue, pattern(for: kind, name: name), "RETURN n"].joined(separator: "\n")
    }

    public static func countQuery(
        kind: Neo4jEntityKind,
        name: String,
        filters: [Neo4jFilter] = [],
        matchesAll: Bool = true,
        usesElementId: Bool = true
    ) throws -> String {
        try requireQuotable([name])
        var lines = [pattern(for: kind, name: name)]
        if let filter = try whereClause(filters, matchesAll: matchesAll, usesElementId: usesElementId) {
            lines.append(filter)
        }
        lines.append("RETURN count(n) AS count")
        return lines.joined(separator: "\n")
    }

    // Bounded so the Structure tab stays fast on a large graph, unlike `db.schema.nodeTypeProperties()`.
    public static func propertySampleQuery(kind: Neo4jEntityKind, name: String, sampleSize: Int = 1_000) -> String {
        pattern(for: kind, name: name)
            + " WITH n LIMIT \(sampleSize) UNWIND keys(n) AS key"
            + " RETURN key, head(collect(n[key])) AS sample ORDER BY key"
    }

    public static func propertyKeysQuery(kind: Neo4jEntityKind, name: String) throws -> String {
        try requireQuotable([name])
        return pattern(for: kind, name: name) + " UNWIND keys(n) AS key RETURN DISTINCT key ORDER BY key"
    }

    public static func expression(for column: String, usesElementId: Bool) -> String {
        let idFunction = usesElementId ? "elementId" : "id"
        switch column {
        case idColumn: return "\(idFunction)(n)"
        case labelsColumn: return "labels(n)"
        case startColumn: return "\(idFunction)(startNode(n))"
        case endColumn: return "\(idFunction)(endNode(n))"
        default: return "n." + quote(column)
        }
    }

    private static func whereClause(_ filters: [Neo4jFilter], matchesAll: Bool, usesElementId: Bool) throws -> String? {
        let clauses = try filters.map { try condition(for: $0, usesElementId: usesElementId) }
        guard !clauses.isEmpty else { return nil }
        let joined = clauses.count == 1
            ? clauses[0]
            : clauses.map { "(\($0))" }.joined(separator: matchesAll ? " AND " : " OR ")
        return "WHERE " + joined
    }

    private static let negations = ["!=": "=", "<>": "=", "NOT CONTAINS": "CONTAINS", "NOT IN": "IN"]

    static func condition(for filter: Neo4jFilter, usesElementId: Bool) throws -> String {
        if filter.column == rawFilterColumn { return filter.value }
        try requireQuotable([filter.column])
        let op = filter.op.uppercased()
        if let presence = presence(op, column: filter.column, usesElementId: usesElementId) { return presence }

        let subject = Subject(filter: filter, usesElementId: usesElementId)
        var predicate = try positive(negations[op] ?? op, filter: filter, subject: subject)
        // `labels(n)` is a list, so a label filter matches when any one label does.
        if filter.column == labelsColumn { predicate = "any(label IN labels(n) WHERE \(predicate))" }
        return negations[op] == nil ? predicate : "NOT (\(predicate))"
    }

    private struct Subject {
        let expression: String
        // An element id or a label is always a string, so it never compares as a number.
        let isText: Bool
        let foldsCase: Bool

        init(filter: Neo4jFilter, usesElementId: Bool) {
            let isLabel = filter.column == labelsColumn
            let isElementId = usesElementId && [idColumn, startColumn, endColumn].contains(filter.column)
            expression = isLabel ? "label" : Neo4jCypher.expression(for: filter.column, usesElementId: usesElementId)
            isText = isLabel || isElementId
            foldsCase = !filter.isCaseSensitive && !isElementId
        }
    }

    private static func presence(_ op: String, column: String, usesElementId: Bool) -> String? {
        let target = expression(for: column, usesElementId: usesElementId)
        switch op {
        case "IS NULL": return "\(target) IS NULL"
        case "IS NOT NULL": return "\(target) IS NOT NULL"
        case "IS EMPTY" where column == labelsColumn: return "size(labels(n)) = 0"
        case "IS NOT EMPTY" where column == labelsColumn: return "size(labels(n)) > 0"
        case "IS EMPTY": return "(\(target) IS NULL OR \(target) = '')"
        case "IS NOT EMPTY": return "(\(target) IS NOT NULL AND \(target) <> '')"
        default: return nil
        }
    }

    private static func positive(_ op: String, filter: Neo4jFilter, subject: Subject) throws -> String {
        let target = subject.expression
        switch op {
        case "=":
            return matchesAny(subject, [filter.value])
        case "IN":
            return matchesAny(subject, filter.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        case ">", ">=", "<", "<=":
            return "\(target) \(op) \(bound(filter.value, subject))"
        case "BETWEEN":
            let range = try bounds(of: filter)
            return "\(target) >= \(bound(range.lower, subject)) AND \(target) <= \(bound(range.upper, subject))"
        case "CONTAINS", "STARTS WITH", "ENDS WITH":
            let needle = literal(subject.foldsCase ? filter.value.lowercased() : filter.value)
            return "\(text(subject, folded: subject.foldsCase)) \(op) \(needle)"
        case "REGEX":
            let pattern = subject.foldsCase ? "(?i)" + filter.value : filter.value
            return "\(text(subject, folded: false)) =~ \(literal(pattern))"
        default:
            throw Neo4jCypherError.unsupportedOperator(filter.op)
        }
    }

    // A property can hold any type, so text operators read it as text first: a number or a list is then a
    // non-match rather than a type error that fails the whole page.
    private static func text(_ subject: Subject, folded: Bool) -> String {
        let text = subject.isText ? subject.expression : "toStringOrNull(\(subject.expression))"
        return folded ? "toLower(\(text))" : text
    }

    private static func bound(_ value: String, _ subject: Subject) -> String {
        subject.isText ? literal(value) : typedLiteral(value)
    }

    private static func matchesAny(_ subject: Subject, _ values: [String]) -> String {
        let target = subject.expression
        if subject.isText {
            let items = values.map { literal(subject.foldsCase ? $0.lowercased() : $0) }
            let lhs = subject.foldsCase ? "toLower(\(target))" : target
            return items.count == 1 ? "\(lhs) = \(items[0])" : "\(lhs) IN [\(items.joined(separator: ", "))]"
        }
        if subject.foldsCase {
            // Case folding applies to text only, so `30.0` still matches `= 30`.
            let folded = "\(text(subject, folded: true)) IN [\(values.map { literal($0.lowercased()) }.joined(separator: ", "))]"
            let typed = values.map(typedLiteral).filter { !$0.hasPrefix("'") }
            guard !typed.isEmpty else { return folded }
            return "(\(target) IN [\(typed.joined(separator: ", "))] OR \(folded))"
        }
        // A property has no declared type, so `123` also matches the text '123'.
        let forms = values.flatMap(spellings)
        if forms.count == 1 { return "\(target) = \(forms[0])" }
        if values.count == 1 { return "(" + forms.map { "\(target) = \($0)" }.joined(separator: " OR ") + ")" }
        return "\(target) IN [\(forms.joined(separator: ", "))]"
    }

    private static func spellings(_ value: String) -> [String] {
        let typed = typedLiteral(value)
        return typed == literal(value) ? [typed] : [typed, literal(value)]
    }

    // The host sends BETWEEN's value as "lower,upper" and the upper bound again on its own.
    private static func bounds(of filter: Neo4jFilter) throws -> (lower: String, upper: String) {
        let lower: String
        let upper: String
        if let second = filter.secondValue {
            let suffix = "," + second
            lower = filter.value.hasSuffix(suffix) ? String(filter.value.dropLast(suffix.count)) : filter.value
            upper = second
        } else if let comma = filter.value.firstIndex(of: ",") {
            lower = String(filter.value[..<comma])
            upper = String(filter.value[filter.value.index(after: comma)...])
        } else {
            throw Neo4jCypherError.incompleteRange
        }
        let range = (lower.trimmingCharacters(in: .whitespaces), upper.trimmingCharacters(in: .whitespaces))
        guard !range.0.isEmpty, !range.1.isEmpty else { throw Neo4jCypherError.incompleteRange }
        return range
    }

    // Only the forms Cypher reads back as the same number: `012` would be octal and a 20-digit integer overflows.
    static func typedLiteral(_ value: String) -> String {
        if let integer = Int64(value), String(integer) == value { return value }
        if value.range(of: #"^-?(0|[1-9][0-9]*)\.[0-9]+([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
           let number = Double(value), number.isFinite {
            return value
        }
        switch value.lowercased() {
        case "true", "false": return value.lowercased()
        default: return literal(value)
        }
    }
}
