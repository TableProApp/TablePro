import Foundation

public enum Neo4jEntityKind: String, Sendable, CaseIterable {
    case node
    case relationship

    /// The sidebar groups labels and relationship types as two schemas with these names.
    public var schemaName: String {
        switch self {
        case .node: "Labels"
        case .relationship: "Relationship Types"
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

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperator(let op):
            return String(format: String(localized: "The %@ filter is not available for Neo4j."), op)
        case .unquotableName(let name):
            return String(format: String(localized: "Neo4j cannot query the name %@ because it contains \\u."), name)
        }
    }
}

public enum Neo4jCypher {
    public static let idColumn = "<id>"
    public static let labelsColumn = "<labels>"
    public static let startColumn = "<start>"
    public static let endColumn = "<end>"
    public static let rawFilterColumn = "__RAW__"

    /// A browse query starts with this comment. It stays valid Cypher, so a browse query pasted
    /// into the editor still runs, and it tells the driver to spread the entity into columns.
    public static let browseMarker = "// TablePro browse: "

    /// Neo4j decodes `\uXXXX` before it reads a query, inside backticks too, so a name holding
    /// one could close its own quotes. No spelling survives that decoding: such a name becomes an
    /// escape the server rejects, and the query builders refuse it up front.
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

    private static func whereClause(_ filters: [Neo4jFilter], matchesAll: Bool, usesElementId: Bool) throws -> String? {
        let clauses = try filters.map { try condition(for: $0, usesElementId: usesElementId) }
        guard !clauses.isEmpty else { return nil }
        let joined = clauses.count == 1
            ? clauses[0]
            : clauses.map { "(\($0))" }.joined(separator: matchesAll ? " AND " : " OR ")
        return "WHERE " + joined
    }

    /// Property keys and one sample value each, from the first `sampleSize` entities. Bounded so
    /// the Structure tab stays fast on a large graph, unlike `db.schema.nodeTypeProperties()`.
    public static func propertySampleQuery(kind: Neo4jEntityKind, name: String, sampleSize: Int = 1_000) -> String {
        pattern(for: kind, name: name)
            + " WITH n LIMIT \(sampleSize) UNWIND keys(n) AS key"
            + " RETURN key, head(collect(n[key])) AS sample ORDER BY key"
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

    static func condition(for filter: Neo4jFilter, usesElementId: Bool) throws -> String {
        if filter.column == rawFilterColumn { return filter.value }
        try requireQuotable([filter.column])
        let target = expression(for: filter.column, usesElementId: usesElementId)
        let isIdentifier = [idColumn, startColumn, endColumn].contains(filter.column) && usesElementId
        let ignoresCase = !filter.isCaseSensitive && !isIdentifier
        let value = filter.value
        let needle = literal(ignoresCase ? value.lowercased() : value)

        switch filter.op.uppercased() {
        case "=":
            if ignoresCase { return foldedEquality(target, [value]) }
            return isIdentifier ? "\(target) = \(literal(value))" : equality(target, value)
        case "!=", "<>":
            if ignoresCase { return "NOT (\(foldedEquality(target, [value])))" }
            return isIdentifier ? "\(target) <> \(literal(value))" : "NOT (\(equality(target, value)))"
        case ">", ">=", "<", "<=":
            return "\(target) \(filter.op) \(typedLiteral(value))"
        case "BETWEEN":
            let upper = filter.secondValue ?? ""
            return "\(target) >= \(typedLiteral(value)) AND \(target) <= \(typedLiteral(upper))"
        case "CONTAINS":
            return textMatch(filter.column, target, "CONTAINS", needle, ignoresCase: ignoresCase)
        case "NOT CONTAINS":
            return "NOT (\(textMatch(filter.column, target, "CONTAINS", needle, ignoresCase: ignoresCase)))"
        case "STARTS WITH", "ENDS WITH":
            return textMatch(filter.column, target, filter.op.uppercased(), needle, ignoresCase: ignoresCase)
        case "IS NULL":
            return "\(target) IS NULL"
        case "IS NOT NULL":
            return "\(target) IS NOT NULL"
        case "IS EMPTY":
            return "(\(target) IS NULL OR \(target) = '')"
        case "IS NOT EMPTY":
            return "(\(target) IS NOT NULL AND \(target) <> '')"
        case "IN", "NOT IN":
            let raw = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let list: String
            if ignoresCase {
                list = foldedEquality(target, raw)
            } else {
                let items = isIdentifier ? raw.map(literal) : raw.flatMap(spellings)
                list = "\(target) IN [\(items.joined(separator: ", "))]"
            }
            return filter.op.uppercased() == "IN" ? list : "NOT (\(list))"
        case "REGEX":
            return "\(target) =~ \(literal(filter.isCaseSensitive ? value : "(?i)" + value))"
        default:
            throw Neo4jCypherError.unsupportedOperator(filter.op)
        }
    }

    /// A property can hold any type, so the value is read as text first: a number, a list or a
    /// point is then a non-match rather than a type error that fails the whole page. Labels match
    /// when any one of them does.
    private static func textMatch(_ column: String, _ target: String, _ op: String, _ needle: String, ignoresCase: Bool) -> String {
        if column == labelsColumn {
            let label = ignoresCase ? "toLower(label)" : "label"
            return "any(label IN labels(n) WHERE \(label) \(op) \(needle))"
        }
        let text = "toStringOrNull(\(target))"
        return "\((ignoresCase ? "toLower(\(text))" : text)) \(op) \(needle)"
    }

    /// Case folding applies to text only, so a typed number or boolean still compares as one:
    /// `30.0` keeps matching `= 30`.
    private static func foldedEquality(_ target: String, _ values: [String]) -> String {
        let folded = "toLower(toStringOrNull(\(target))) IN [\(values.map { literal($0.lowercased()) }.joined(separator: ", "))]"
        let typed = values.map(typedLiteral).filter { !$0.hasPrefix("'") }
        guard !typed.isEmpty else { return folded }
        return "(\(target) IN [\(typed.joined(separator: ", "))] OR \(folded))"
    }

    /// A property has no declared type, so a value that reads as a number or a boolean also
    /// matches the same text stored as a string.
    private static func equality(_ target: String, _ value: String) -> String {
        let forms = spellings(value)
        guard forms.count > 1 else { return "\(target) = \(forms[0])" }
        return "(" + forms.map { "\(target) = \($0)" }.joined(separator: " OR ") + ")"
    }

    private static func spellings(_ value: String) -> [String] {
        let typed = typedLiteral(value)
        return typed == literal(value) ? [typed] : [typed, literal(value)]
    }

    /// A number literal only in the form Cypher reads back as the same number: `012` would be
    /// octal and a 20-digit integer overflows, so those stay text.
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
