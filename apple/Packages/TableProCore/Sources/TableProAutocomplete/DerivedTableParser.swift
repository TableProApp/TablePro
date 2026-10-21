import Foundation

struct DerivedTable: Equatable, Sendable {
    let alias: String
    let projection: DerivedProjection
    let isCommonTableExpression: Bool

    // What the statement text names, before the catalog expands a `*`.
    var columns: [String] {
        projection.columns { _ in nil }
    }
}

// A `*` stays a table until the provider can ask the catalog for its columns.
struct DerivedProjection: Hashable, Sendable {
    struct Table: Hashable, Sendable {
        let name: String
        let schema: String?
    }

    enum Entry: Hashable, Sendable {
        case column(String)
        case unnamed
        case allColumns(Table)
        case nested(DerivedProjection)
        // A USING join outputs its join columns once, ahead of what is left of each side.
        case excluding([String], DerivedProjection)
        // A NATURAL join does the same for the columns both sides share, which only the catalog can name.
        case natural(DerivedProjection, DerivedProjection)
    }

    var entries: [Entry]
    // `name (a, b) AS (...)` and `AS x(a, b)` rename the output by position and keep the rest.
    var declaredNames: [String] = []

    static let empty = DerivedProjection(entries: [])

    var tables: [Table] {
        entries.flatMap { entry -> [Table] in
            switch entry {
            case .allColumns(let table): return [table]
            case .nested(let projection), .excluding(_, let projection): return projection.tables
            case .natural(let left, let right): return left.tables + right.tables
            case .column, .unnamed: return []
            }
        }
    }

    func declaring(_ names: [String]) -> DerivedProjection {
        guard !names.isEmpty else { return self }
        guard declaredNames.isEmpty else { return DerivedProjection(entries: [.nested(self)], declaredNames: names) }
        return DerivedProjection(entries: entries, declaredNames: names)
    }

    // `expand` answers nil for a table it cannot read, whose width also hides where the declared names land. Names
    // stay case-sensitive, since `"Value"` and `"value"` are two columns.
    func columns(expanding expand: (Table) -> [String]?) -> [String] {
        var seen = Set<String>()
        return resolve(expand).names.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    private func resolve(_ expand: (Table) -> [String]?) -> (names: [String?], knownWidth: Int?) {
        var names: [String?] = []
        var knownWidth: Int?
        for entry in entries {
            switch entry {
            case .column(let name):
                names.append(name)
            case .unnamed:
                names.append(nil)
            case .allColumns(let table):
                if let columns = expand(table) {
                    names += columns.map { Optional($0) }
                } else if knownWidth == nil {
                    knownWidth = names.count
                }
            case .nested(let projection):
                let inner = projection.resolve(expand)
                if knownWidth == nil, let innerWidth = inner.knownWidth {
                    knownWidth = names.count + innerWidth
                }
                names += inner.names
            case .excluding(let excluded, let projection):
                let inner = projection.resolve(expand)
                let dropped = Set(excluded.map { $0.lowercased() })
                let keeps: (String?) -> Bool = { name in name.map { !dropped.contains($0.lowercased()) } ?? true }
                if knownWidth == nil, let innerWidth = inner.knownWidth {
                    knownWidth = names.count + inner.names[..<innerWidth].filter(keeps).count
                }
                names += inner.names.filter(keeps)
            case .natural(let left, let right):
                let lhs = left.resolve(expand)
                let rhs = right.resolve(expand)
                guard lhs.knownWidth == nil, rhs.knownWidth == nil else {
                    if knownWidth == nil { knownWidth = names.count }
                    names += lhs.names + rhs.names
                    continue
                }
                let rightNames = Set(rhs.names.compactMap { $0?.lowercased() })
                let shared = Set(lhs.names.compactMap { $0?.lowercased() }.filter { rightNames.contains($0) })
                let isShared: (String?) -> Bool = { name in name.map { shared.contains($0.lowercased()) } ?? false }
                names += lhs.names.filter(isShared) + lhs.names.filter { !isShared($0) } + rhs.names.filter { !isShared($0) }
            }
        }
        let known = knownWidth ?? names.count
        for (index, name) in declaredNames.enumerated() where index < known {
            names[index] = name
        }
        guard declaredNames.count > known else { return (names, knownWidth) }
        // A declared name past an unread `*` still names a column, only not which one it replaces.
        names.insert(contentsOf: declaredNames[known...].map { Optional($0) }, at: known)
        return (names, knownWidth.map { _ in declaredNames.count })
    }
}

// Read from the analyzer's code view, where comments and literal bodies are blank and quoted names are masked, so a
// parenthesis or quote inside one never counts, whatever the engine's quoting rules.
struct SQLTokenStream {
    enum Kind {
        case word, quoted, literal, number, openParen, closeParen, comma, dot, star, other
    }

    struct Token {
        let kind: Kind
        let range: NSRange
        let upper: String
        var partner: Int
    }

    let tokens: [Token]
    let original: NSString

    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let newline: unichar = 0x0A
    private static let verticalTab: unichar = 0x0B
    private static let formFeed: unichar = 0x0C
    private static let cr: unichar = 0x0D
    private static let noBreakSpace: unichar = 0xA0
    private static let dollar: unichar = 0x24
    private static let openParen: unichar = 0x28
    private static let closeParen: unichar = 0x29
    private static let star: unichar = 0x2A
    private static let comma: unichar = 0x2C
    private static let dot: unichar = 0x2E
    private static let underscore: unichar = 0x5F
    private static let singleQuote: unichar = 0x27
    private static let doubleQuote: unichar = 0x22
    private static let backtick: unichar = 0x60
    private static let openBracket: unichar = 0x5B
    private static let closeBracket: unichar = 0x5D

    init(code: NSString, original: NSString, bracketQuotes: Bool) {
        self.original = original
        let length = min(code.length, original.length)
        var tokens: [Token] = []
        var openParens: [Int] = []
        var index = 0
        while index < length {
            let unit = code.character(at: index)
            if Self.isWhitespace(unit) {
                index += 1
                continue
            }
            let start = index
            let kind: Kind
            if Self.isWordStart(unit) {
                index += 1
                while index < length, Self.isWordPart(code.character(at: index)) { index += 1 }
                kind = .word
            } else if unit >= 0x30 && unit <= 0x39 {
                index += 1
                while index < length, Self.isWordPart(code.character(at: index)) || code.character(at: index) == Self.dot {
                    index += 1
                }
                kind = .number
            } else if unit == Self.doubleQuote || unit == Self.backtick || (bracketQuotes && unit == Self.openBracket) {
                index = Self.end(closing: unit == Self.openBracket ? Self.closeBracket : unit, in: code, from: index, length)
                kind = .quoted
            } else if unit == Self.singleQuote {
                index = Self.end(closing: Self.singleQuote, in: code, from: index, length)
                kind = .literal
            } else {
                index += 1
                switch unit {
                case Self.openParen: kind = .openParen
                case Self.closeParen: kind = .closeParen
                case Self.comma: kind = .comma
                case Self.dot: kind = .dot
                case Self.star: kind = .star
                default: kind = .other
                }
            }
            let range = NSRange(location: start, length: index - start)
            let upper = kind == .word ? original.substring(with: range).uppercased() : ""
            tokens.append(Token(kind: kind, range: range, upper: upper, partner: -1))
            if kind == .openParen {
                openParens.append(tokens.count - 1)
            } else if kind == .closeParen, let open = openParens.popLast() {
                tokens[open].partner = tokens.count - 1
                tokens[tokens.count - 1].partner = open
            }
        }
        for open in openParens {
            tokens[open].partner = tokens.count
        }
        self.tokens = tokens
    }

    var count: Int { tokens.count }

    func text(_ index: Int) -> String {
        original.substring(with: tokens[index].range)
    }

    func isWord(_ index: Int, _ upper: String) -> Bool {
        index >= 0 && index < tokens.count && tokens[index].kind == .word && tokens[index].upper == upper
    }

    func isWord(_ index: Int, in words: Set<String>) -> Bool {
        index >= 0 && index < tokens.count && tokens[index].kind == .word && words.contains(tokens[index].upper)
    }

    func kind(_ index: Int) -> Kind? {
        index >= 0 && index < tokens.count ? tokens[index].kind : nil
    }

    func isName(_ index: Int) -> Bool {
        kind(index) == .word || kind(index) == .quoted
    }

    func name(_ index: Int) -> String {
        Self.unquoted(text(index))
    }

    // The index after an open parenthesis's partner, or the end when it never closes.
    func after(_ open: Int) -> Int {
        min(tokens[open].partner, tokens.count - 1) + 1
    }

    func closeIndex(of open: Int) -> Int {
        min(tokens[open].partner, tokens.count)
    }

    // The open parentheses around `cursor`, outermost first.
    func enclosingParens(before cursor: Int) -> [Int] {
        var stack: [Int] = []
        for index in tokens.indices where tokens[index].range.location < cursor {
            switch tokens[index].kind {
            case .openParen: stack.append(index)
            case .closeParen: if tokens[index].partner >= 0 { stack.removeLast() }
            default: break
            }
        }
        return stack
    }

    func contains(_ cursor: Int, inside open: Int?) -> Bool {
        guard let open else { return true }
        guard cursor > tokens[open].range.location else { return false }
        let close = tokens[open].partner
        return close >= tokens.count || cursor <= tokens[close].range.location
    }

    static func unquoted(_ spelling: String) -> String {
        guard let first = spelling.first else { return spelling }
        let closing: Character
        switch first {
        case "\"", "`", "'": closing = first
        case "[": closing = "]"
        default: return spelling
        }
        var body = spelling.dropFirst()
        if body.last == closing {
            body = body.dropLast()
        }
        return String(body).replacingOccurrences(of: String(repeating: closing, count: 2), with: String(closing))
    }

    private static func end(closing: unichar, in code: NSString, from start: Int, _ length: Int) -> Int {
        var index = start + 1
        while index < length {
            if code.character(at: index) == closing {
                if closing != closeBracket, index + 1 < length, code.character(at: index + 1) == closing {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return length
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == space || unit == tab || unit == newline || unit == cr || unit == verticalTab || unit == formFeed
            || unit == noBreakSpace
    }

    private static func isWordStart(_ unit: unichar) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == underscore || unit >= 0x80
    }

    private static func isWordPart(_ unit: unichar) -> Bool {
        isWordStart(unit) || (unit >= 0x30 && unit <= 0x39) || unit == dollar
    }
}

// Reads the derived tables and CTEs a statement defines, what each outputs, and the query level around the cursor.
struct DerivedTableParser {
    private struct Source {
        let exposedName: String
        let tableName: String?
        let projection: DerivedProjection
    }

    private enum ItemOutput {
        case named(String, spelling: String, isAlias: Bool)
        case allColumns(qualifier: String?)
        case unnamed
    }

    private struct Statement {
        let keyword: Int
        let ctes: [String: DerivedProjection]
    }

    private struct FromItems {
        var sources: [Source] = []
        var star: [DerivedProjection.Entry] = []

        init(sources: [Source] = [], star: [DerivedProjection.Entry] = []) {
            self.sources = sources
            self.star = star
        }

        init(source: Source) {
            self.init(sources: [source], star: DerivedTableParser.spread(source.projection))
        }

        func joining(_ next: FromItems, using columns: [String]?, natural: Bool) -> FromItems {
            if natural, !star.isEmpty {
                let merged = DerivedProjection.Entry.natural(
                    DerivedProjection(entries: star), DerivedProjection(entries: next.star)
                )
                return FromItems(sources: sources + next.sources, star: [merged])
            }
            guard let columns, !columns.isEmpty, !star.isEmpty else {
                return FromItems(sources: sources + next.sources, star: star + next.star)
            }
            let merged = columns.map { DerivedProjection.Entry.column($0) } + [
                .excluding(columns, DerivedProjection(entries: star)),
                .excluding(columns, DerivedProjection(entries: next.star)),
            ]
            return FromItems(sources: sources + next.sources, star: merged)
        }
    }

    private struct CommonTableExpression {
        let name: String
        let open: Int
        let projection: DerivedProjection
    }

    private typealias Found = [(table: DerivedTable, depth: Int)]

    private typealias Scope = [String: DerivedProjection]

    private static let queryBodyWords: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE"]
    private static let modifyingBodyWords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]
    private static let fromListOpeners: Set<String> = ["FROM", "JOIN", "USING", "APPLY", "STRAIGHT_JOIN"]
    private static let fromListBreakers: Set<String> = [
        "SELECT", "WHERE", "SET", "GROUP", "ORDER", "HAVING", "VALUES", "RETURNING", "INTO", "WINDOW", "LIMIT",
        "OFFSET", "BY", "UPDATE", "DELETE", "INSERT", "MERGE", "WITH", "WHEN", "THEN", "ELSE", "CASE", "QUALIFY"
    ]
    private static let joinWords: Set<String> = ["JOIN", "APPLY", "STRAIGHT_JOIN"]
    private static let selectListEnders: Set<String> = [
        "FROM", "INTO", "WHERE", "GROUP", "HAVING", "WINDOW", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR",
        "UNION", "INTERSECT", "EXCEPT", "MINUS", "QUALIFY"
    ]
    private static let fromListEnders: Set<String> = [
        "WHERE", "GROUP", "HAVING", "WINDOW", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR", "UNION", "INTERSECT",
        "EXCEPT", "MINUS", "RETURNING", "QUALIFY", "CONNECT", "START"
    ]
    private static let selectModifiers: Set<String> = [
        "DISTINCT", "DISTINCTROW", "ALL", "HIGH_PRIORITY", "STRAIGHT_JOIN", "SQL_SMALL_RESULT", "SQL_BIG_RESULT",
        "SQL_BUFFER_RESULT", "SQL_NO_CACHE", "SQL_CACHE", "SQL_CALC_FOUND_ROWS"
    ]
    private static let nonAliasWords: Set<String> = [
        "ON", "USING", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "FOR", "UNION",
        "INTERSECT", "EXCEPT", "MINUS", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL",
        "APPLY", "STRAIGHT_JOIN", "AS", "SET", "RETURNING", "WINDOW", "LATERAL", "TABLESAMPLE", "WITH", "USE",
        "FORCE", "IGNORE", "PARTITION", "INTO", "VALUES", "SELECT", "DEFAULT", "WHEN", "QUALIFY", "PIVOT",
        "UNPIVOT", "CONNECT", "START", "OVERRIDING"
    ]
    // A bare word that ends an expression even though it is a keyword, as `CASE ... END total` does.
    private static let valueKeywords: Set<String> = ["END", "TRUE", "FALSE", "NULL"]
    private static let notImplicitAliases: Set<String> = SQLKeywords.keywordSet.union([
        "day", "hour", "minute", "second", "month", "week", "zone", "precision", "varying", "escape", "interval",
        "array", "row", "only", "ties", "percent"
    ])

    // Innermost first, so a nearer definition shadows an outer one of the same name.
    func visibleTables(in stream: SQLTokenStream, cursor: Int) -> [DerivedTable] {
        var found: Found = []
        collect(from: 0, to: stream.count, depth: 0, scope: [:], cursor: cursor, in: stream, into: &found)
        var seen = Set<String>()
        return found.enumerated()
            .sorted { lhs, rhs in
                lhs.element.depth == rhs.element.depth ? lhs.offset < rhs.offset : lhs.element.depth > rhs.element.depth
            }
            .map(\.element.table)
            .filter { seen.insert($0.alias.lowercased()).inserted }
    }

    // ORDER BY may name these; inside a call's or a window's parentheses it orders that call's input instead.
    func outputAliases(in stream: SQLTokenStream, cursor: Int) -> [String] {
        var start = 0
        var end = stream.count
        if let innermost = stream.enclosingParens(before: cursor).last {
            guard isQueryBody(innermost, in: stream) else { return [] }
            start = innermost + 1
            end = stream.closeIndex(of: innermost)
        }
        guard let select = firstSelect(from: start, to: end, in: stream) else { return [] }
        let listStart = selectListStart(after: select, to: end, in: stream)
        let listEnd = firstTopLevel(Self.selectListEnders, from: listStart, to: end, in: stream) ?? end
        return topLevelItems(from: listStart, to: listEnd, in: stream).compactMap { item in
            guard case .named(_, let spelling, true) = output(of: item, in: stream) else { return nil }
            return spelling
        }
    }

    // The table an INSERT, UPDATE, DELETE or MERGE writes at the cursor's query level.
    func targetTable(in stream: SQLTokenStream, cursor: Int) -> TableReference? {
        var start = 0
        var end = stream.count
        if let open = stream.enclosingParens(before: cursor).last(where: { isStatementBody($0, in: stream) }) {
            start = open + 1
            end = stream.closeIndex(of: open)
        }
        guard let statement = mainStatement(from: start, to: end, in: stream, scope: [:]),
              let target = modifiedTable(of: statement.keyword, to: end, in: stream) else { return nil }
        return target.reference
    }

    // MARK: - Definitions

    // One query level. A CTE of its WITH list is in scope from the next definition on, and only a level that holds the
    // cursor is read further, since what it defines is out of the cursor's reach otherwise.
    private func collect(
        from start: Int, to end: Int, depth: Int, scope: Scope, cursor: Int,
        in stream: SQLTokenStream, into found: inout Found
    ) {
        let ctes = withList(from: start, to: end, in: stream, scope: scope)?.ctes ?? []
        var scope = scope
        var nextCTE = 0
        var index = start
        while index < end {
            guard stream.tokens[index].kind == .openParen else {
                index += 1
                continue
            }
            if nextCTE < ctes.count, ctes[nextCTE].open == index {
                let cte = ctes[nextCTE]
                found.append((DerivedTable(alias: cte.name, projection: cte.projection, isCommonTableExpression: true), depth))
            } else if let table = definition(at: index, in: stream, scope: scope) {
                found.append((table, depth))
            }
            if stream.contains(cursor, inside: index) {
                collect(
                    from: index + 1, to: stream.closeIndex(of: index), depth: depth + 1, scope: scope, cursor: cursor,
                    in: stream, into: &found
                )
            }
            index = stream.after(index)
            while nextCTE < ctes.count, ctes[nextCTE].open < index {
                scope[ctes[nextCTE].name.lowercased()] = ctes[nextCTE].projection
                nextCTE += 1
            }
        }
    }

    private func definition(at open: Int, in stream: SQLTokenStream, scope: Scope) -> DerivedTable? {
        guard isStatementBody(open, in: stream) else { return nil }
        if let asIndex = cteKeyword(before: open, in: stream) {
            var nameEnd = asIndex - 1
            var declared: [String] = []
            if stream.kind(nameEnd) == .closeParen, stream.tokens[nameEnd].partner >= 0 {
                let listOpen = stream.tokens[nameEnd].partner
                declared = nameList(at: listOpen, in: stream)
                nameEnd = listOpen - 1
            }
            guard stream.isName(nameEnd) else { return nil }
            return DerivedTable(
                alias: stream.name(nameEnd),
                projection: projection(ofBodyAt: open, in: stream, scope: scope).declaring(declared),
                isCommonTableExpression: true
            )
        }
        guard isQueryBody(open, in: stream), opensFromItem(open, in: stream),
              let alias = alias(after: stream.after(open) - 1, in: stream) else { return nil }
        return DerivedTable(
            alias: alias.name,
            projection: projection(ofBodyAt: open, in: stream, scope: scope).declaring(alias.declared),
            isCommonTableExpression: false
        )
    }

    // `AS (`, `AS MATERIALIZED (` or `AS NOT MATERIALIZED (`.
    private func cteKeyword(before open: Int, in stream: SQLTokenStream) -> Int? {
        var index = open - 1
        if stream.isWord(index, "MATERIALIZED") {
            index -= 1
            if stream.isWord(index, "NOT") { index -= 1 }
        }
        return stream.isWord(index, "AS") ? index : nil
    }

    private func opensFromItem(_ open: Int, in stream: SQLTokenStream) -> Bool {
        var index = open - 1
        if stream.isWord(index, "LATERAL") { index -= 1 }
        if stream.isWord(index, in: Self.fromListOpeners) { return true }
        guard stream.kind(index) == .comma else { return false }
        // A comma continues a FROM list only when FROM or a join is the nearest clause word behind it.
        index -= 1
        while index >= 0 {
            let token = stream.tokens[index]
            switch token.kind {
            case .closeParen where token.partner >= 0:
                index = token.partner - 1
                continue
            case .openParen:
                return false
            case .word:
                if Self.fromListOpeners.contains(token.upper) { return true }
                if Self.fromListBreakers.contains(token.upper) { return false }
            default:
                break
            }
            index -= 1
        }
        return false
    }

    private func isQueryBody(_ open: Int, in stream: SQLTokenStream) -> Bool {
        let first = open + 1
        if stream.kind(first) == .openParen { return isQueryBody(first, in: stream) }
        return stream.isWord(first, in: Self.queryBodyWords)
    }

    private func isStatementBody(_ open: Int, in stream: SQLTokenStream) -> Bool {
        isQueryBody(open, in: stream) || stream.isWord(open + 1, in: Self.modifyingBodyWords)
    }

    // MARK: - Projections

    private func projection(ofBodyAt open: Int, in stream: SQLTokenStream, scope: Scope) -> DerivedProjection {
        projection(from: open + 1, to: stream.closeIndex(of: open), in: stream, scope: scope)
    }

    private func projection(from start: Int, to end: Int, in stream: SQLTokenStream, scope: Scope) -> DerivedProjection {
        guard let statement = mainStatement(from: start, to: end, in: stream, scope: scope) else { return .empty }
        let keyword = statement.keyword
        let scope = scope.merging(statement.ctes) { _, inner in inner }
        if stream.kind(keyword) == .openParen {
            return projection(ofBodyAt: keyword, in: stream, scope: scope)
        }
        switch stream.tokens[keyword].upper {
        case "SELECT":
            return selectProjection(at: keyword, to: end, in: stream, scope: scope)
        case "VALUES":
            var row = keyword + 1
            if stream.isWord(row, "ROW") { row += 1 }
            guard stream.kind(row) == .openParen else { return .empty }
            let width = topLevelItems(from: row + 1, to: stream.closeIndex(of: row), in: stream).count
            return DerivedProjection(entries: Array(repeating: .unnamed, count: width))
        case "TABLE":
            guard let path = path(at: keyword + 1, to: end, in: stream) else { return .empty }
            return tableProjection(path.table, schema: path.schema, scope: scope)
        default:
            return modifyingProjection(at: keyword, to: end, in: stream, scope: scope)
        }
    }

    // Each CTE reads the ones before it in the list.
    private func withList(
        from start: Int, to end: Int, in stream: SQLTokenStream, scope: Scope
    ) -> (ctes: [CommonTableExpression], next: Int)? {
        guard stream.isWord(start, "WITH") else { return nil }
        var index = start + 1
        if stream.isWord(index, "RECURSIVE") { index += 1 }
        var ctes: [CommonTableExpression] = []
        var visible = scope
        while index < end, stream.isName(index) {
            let name = stream.name(index)
            index += 1
            var declared: [String] = []
            if stream.kind(index) == .openParen {
                declared = nameList(at: index, in: stream)
                index = stream.after(index)
            }
            guard stream.isWord(index, "AS") else { break }
            index += 1
            if stream.isWord(index, "NOT") { index += 1 }
            if stream.isWord(index, "MATERIALIZED") { index += 1 }
            guard stream.kind(index) == .openParen else { break }
            let projection = projection(ofBodyAt: index, in: stream, scope: visible).declaring(declared)
            ctes.append(CommonTableExpression(name: name, open: index, projection: projection))
            visible[name.lowercased()] = projection
            index = stream.after(index)
            guard stream.kind(index) == .comma else { break }
            index += 1
        }
        return (ctes, index)
    }

    private func mainStatement(from start: Int, to end: Int, in stream: SQLTokenStream, scope: Scope) -> Statement? {
        var index = start
        var ctes: Scope = [:]
        if let list = withList(from: start, to: end, in: stream, scope: scope) {
            index = list.next
            for cte in list.ctes {
                ctes[cte.name.lowercased()] = cte.projection
            }
        }
        guard index < end else { return nil }
        if stream.kind(index) == .openParen || stream.isWord(index, in: Self.queryBodyWords)
            || stream.isWord(index, in: Self.modifyingBodyWords) {
            return Statement(keyword: index, ctes: ctes)
        }
        return nil
    }

    private func firstSelect(from start: Int, to end: Int, in stream: SQLTokenStream) -> Int? {
        guard let statement = mainStatement(from: start, to: end, in: stream, scope: [:]) else { return nil }
        let keyword = statement.keyword
        if stream.kind(keyword) == .openParen {
            return firstSelect(from: keyword + 1, to: stream.closeIndex(of: keyword), in: stream)
        }
        return stream.isWord(keyword, "SELECT") ? keyword : nil
    }

    private func selectProjection(at select: Int, to end: Int, in stream: SQLTokenStream, scope: Scope) -> DerivedProjection {
        let listStart = selectListStart(after: select, to: end, in: stream)
        let listEnd = firstTopLevel(Self.selectListEnders, from: listStart, to: end, in: stream) ?? end
        let outputs = topLevelItems(from: listStart, to: listEnd, in: stream).map { output(of: $0, in: stream) }
        var items = FromItems()
        // A set operation ends the branch, so the next branch's FROM never feeds this one's `*`.
        if outputs.contains(where: { if case .allColumns = $0 { return true } else { return false } }),
           let from = firstTopLevel(Self.selectListEnders.subtracting(["INTO"]), from: listEnd, to: end, in: stream),
           stream.isWord(from, "FROM") {
            let fromEnd = firstTopLevel(Self.fromListEnders, from: from + 1, to: end, in: stream) ?? end
            items = fromItems(from: from + 1, to: fromEnd, in: stream, scope: scope)
        }
        return DerivedProjection(entries: entries(for: outputs, from: items, writtenTable: nil))
    }

    private func selectListStart(after select: Int, to end: Int, in stream: SQLTokenStream) -> Int {
        var index = select + 1
        while index < end {
            if stream.isWord(index, "DISTINCT"), stream.isWord(index + 1, "ON"), stream.kind(index + 2) == .openParen {
                index = stream.after(index + 2)
            } else if stream.isWord(index, in: Self.selectModifiers) {
                index += 1
            } else if stream.isWord(index, "TOP"), stream.kind(index + 1) == .number || stream.kind(index + 1) == .openParen {
                index += 1
                index = stream.kind(index) == .openParen ? stream.after(index) : index + 1
                if stream.isWord(index, "PERCENT") { index += 1 }
                if stream.isWord(index, "WITH"), stream.isWord(index + 1, "TIES") { index += 2 }
            } else {
                break
            }
        }
        return index
    }

    // RETURNING `*` reads the written table and the tables the statement joins to it; MERGE lists its source first.
    private func modifyingProjection(at keyword: Int, to end: Int, in stream: SQLTokenStream, scope: Scope) -> DerivedProjection {
        guard let written = modifiedTable(of: keyword, to: end, in: stream),
              let returning = firstTopLevel(["RETURNING"], from: written.end, to: end, in: stream) else { return .empty }
        let target = Source(
            exposedName: written.reference.identifier,
            tableName: written.reference.tableName,
            projection: tableProjection(written.reference.tableName, schema: written.reference.schema, scope: scope)
        )
        var items = FromItems(sources: [target], star: Self.spread(target.projection))
        switch stream.tokens[keyword].upper {
        case "UPDATE", "DELETE":
            let opener = stream.tokens[keyword].upper == "UPDATE" ? "FROM" : "USING"
            if let listStart = firstTopLevel([opener], from: written.end, to: returning, in: stream) {
                let listEnd = firstTopLevel(["WHERE", "RETURNING"], from: listStart + 1, to: end, in: stream) ?? end
                let joined = fromItems(from: listStart + 1, to: listEnd, in: stream, scope: scope)
                items = FromItems(sources: items.sources + joined.sources, star: items.star + joined.star)
            }
        case "MERGE":
            if stream.isWord(written.end, "USING") {
                let listEnd = firstTopLevel(["ON"], from: written.end + 1, to: end, in: stream) ?? end
                let source = fromItems(from: written.end + 1, to: listEnd, in: stream, scope: scope)
                items = FromItems(sources: source.sources + items.sources, star: source.star + items.star)
            }
        default:
            break
        }
        let outputs = topLevelItems(from: returning + 1, to: end, in: stream).map { output(of: $0, in: stream) }
        return DerivedProjection(entries: entries(for: outputs, from: items, writtenTable: target))
    }

    private func modifiedTable(
        of keyword: Int, to end: Int, in stream: SQLTokenStream
    ) -> (reference: TableReference, end: Int)? {
        var index = keyword + 1
        switch stream.tokens[keyword].upper {
        case "INSERT", "MERGE":
            guard stream.isWord(index, "INTO") else { return nil }
            index += 1
        case "DELETE":
            guard stream.isWord(index, "FROM") else { return nil }
            index += 1
        case "UPDATE":
            break
        default:
            return nil
        }
        if stream.isWord(index, "ONLY") { index += 1 }
        guard let path = path(at: index, to: end, in: stream) else { return nil }
        index = path.end
        if stream.kind(index) == .star { index += 1 }
        var alias: (name: String, isQuoted: Bool)?
        let explicitAlias = stream.isWord(index, "AS")
        let aliasIndex = explicitAlias ? index + 1 : index
        // INSERT takes an alias only after AS, so `INSERT INTO t VALUES` never reads VALUES as one.
        if stream.isName(aliasIndex), explicitAlias || stream.tokens[keyword].upper != "INSERT",
           stream.kind(aliasIndex) == .quoted || !Self.nonAliasWords.contains(stream.tokens[aliasIndex].upper) {
            alias = (stream.name(aliasIndex), stream.kind(aliasIndex) == .quoted)
            index = aliasIndex + 1
        }
        let reference = TableReference(
            tableName: path.table,
            alias: alias?.name,
            schema: path.schema,
            isIdentifierQuoted: alias?.isQuoted ?? path.isQuoted
        )
        return (reference, index)
    }

    // `*` reads the items in order, except that a USING join merges its join columns.
    private func fromItems(from start: Int, to end: Int, in stream: SQLTokenStream, scope: Scope) -> FromItems {
        var items = FromItems()
        var index = start
        var isNatural = false
        while index < end {
            while stream.isWord(index, "LATERAL") || stream.isWord(index, "ONLY") { index += 1 }
            guard index < end else { break }
            var factor = FromItems()
            if stream.kind(index) == .openParen {
                let close = stream.after(index) - 1
                if isQueryBody(index, in: stream) {
                    let body = projection(ofBodyAt: index, in: stream, scope: scope)
                    if let alias = alias(after: close, in: stream) {
                        factor = FromItems(source: Source(
                            exposedName: alias.name, tableName: nil, projection: body.declaring(alias.declared)
                        ))
                        index = alias.end
                    } else {
                        index = close + 1
                    }
                } else {
                    factor = fromItems(from: index + 1, to: min(close, end), in: stream, scope: scope)
                    index = close + 1
                }
            } else if let path = path(at: index, to: end, in: stream) {
                index = path.end
                if stream.kind(index) == .openParen {
                    let close = stream.after(index) - 1
                    index = close + 1
                    if let alias = alias(after: close, in: stream) {
                        let output = DerivedProjection(entries: [], declaredNames: alias.declared)
                        factor = FromItems(source: Source(exposedName: alias.name, tableName: nil, projection: output))
                        index = alias.end
                    }
                } else {
                    if stream.kind(index) == .star { index += 1 }
                    let alias = alias(after: index - 1, in: stream)
                    let table = tableProjection(path.table, schema: path.schema, scope: scope)
                    factor = FromItems(source: Source(
                        exposedName: alias?.name ?? path.table,
                        tableName: path.table,
                        projection: table.declaring(alias?.declared ?? [])
                    ))
                    index = alias?.end ?? index
                }
            }
            var using: [String]?
            if stream.isWord(index, "USING"), stream.kind(index + 1) == .openParen {
                using = nameList(at: index + 1, in: stream)
            }
            items = items.joining(factor, using: using, natural: isNatural)
            (index, isNatural) = nextFromItem(after: index, to: end, in: stream)
        }
        return items
    }

    // The next item starts after a comma or a join word; ON and USING conditions in between are skipped.
    private func nextFromItem(after start: Int, to end: Int, in stream: SQLTokenStream) -> (index: Int, isNatural: Bool) {
        var index = start
        var isNatural = false
        while index < end {
            switch stream.tokens[index].kind {
            case .openParen:
                index = stream.after(index)
                continue
            case .comma:
                return (index + 1, false)
            case .word where Self.joinWords.contains(stream.tokens[index].upper):
                return (index + 1, isNatural)
            case .word where stream.tokens[index].upper == "NATURAL":
                isNatural = true
            default:
                break
            }
            index += 1
        }
        return (end, false)
    }

    private func tableProjection(_ table: String, schema: String?, scope: Scope) -> DerivedProjection {
        if schema == nil, let cte = scope[table.lowercased()] {
            return DerivedProjection(entries: [.nested(cte)])
        }
        return DerivedProjection(entries: [.allColumns(DerivedProjection.Table(name: table, schema: schema))])
    }

    private func entries(for outputs: [ItemOutput], from items: FromItems, writtenTable: Source?) -> [DerivedProjection.Entry] {
        var entries: [DerivedProjection.Entry] = []
        for output in outputs {
            switch output {
            case .named(let name, _, _):
                entries.append(.column(name))
            case .unnamed:
                entries.append(.unnamed)
            case .allColumns(nil):
                entries += items.star
            case .allColumns(let qualifier?):
                entries += Self.spread(source(named: qualifier, in: items.sources, writtenTable: writtenTable))
            }
        }
        return entries
    }

    private static func spread(_ projection: DerivedProjection) -> [DerivedProjection.Entry] {
        projection.declaredNames.isEmpty ? projection.entries : [.nested(projection)]
    }

    private func source(named qualifier: String, in sources: [Source], writtenTable: Source?) -> DerivedProjection {
        if let match = sources.first(where: { $0.exposedName.caseInsensitiveCompare(qualifier) == .orderedSame })
            ?? sources.first(where: { $0.tableName?.caseInsensitiveCompare(qualifier) == .orderedSame }) {
            return match.projection
        }
        // PostgreSQL 18 names the written row OLD and NEW in RETURNING.
        if let writtenTable, ["OLD", "NEW"].contains(qualifier.uppercased()) {
            return writtenTable.projection
        }
        return DerivedProjection(entries: [.allColumns(DerivedProjection.Table(name: qualifier, schema: nil))])
    }

    // MARK: - Items

    private func output(of item: Range<Int>, in stream: SQLTokenStream) -> ItemOutput {
        let start = item.lowerBound
        let end = item.upperBound
        guard start < end else { return .unnamed }
        let last = end - 1
        if stream.kind(last) == .star {
            if start == last { return .allColumns(qualifier: nil) }
            if stream.kind(last - 1) == .dot, isPath(start..<(last - 1), in: stream) {
                return .allColumns(qualifier: stream.name(last - 2))
            }
            return .unnamed
        }
        if end - start >= 3, stream.isWord(last - 1, "AS"), stream.isName(last) || stream.kind(last) == .literal {
            let name = stream.name(last)
            return name.isEmpty ? .unnamed : .named(name, spelling: stream.text(last), isAlias: true)
        }
        if isPath(item, in: stream) {
            return .named(stream.name(last), spelling: stream.text(last), isAlias: false)
        }
        if end - start >= 2, isImplicitAlias(last, in: stream), endsExpression(last - 1, in: stream) {
            return .named(stream.name(last), spelling: stream.text(last), isAlias: true)
        }
        return .unnamed
    }

    private func isPath(_ range: Range<Int>, in stream: SQLTokenStream) -> Bool {
        guard !range.isEmpty, range.count % 2 == 1 else { return false }
        return range.enumerated().allSatisfy { offset, index in
            offset % 2 == 0 ? stream.isName(index) : stream.kind(index) == .dot
        }
    }

    private func isImplicitAlias(_ index: Int, in stream: SQLTokenStream) -> Bool {
        switch stream.kind(index) {
        case .quoted: return true
        case .word: return !Self.notImplicitAliases.contains(stream.tokens[index].upper.lowercased())
        default: return false
        }
    }

    private func endsExpression(_ index: Int, in stream: SQLTokenStream) -> Bool {
        switch stream.kind(index) {
        case .closeParen, .literal, .number, .quoted:
            return true
        case .word:
            let upper = stream.tokens[index].upper
            return Self.valueKeywords.contains(upper) || !Self.notImplicitAliases.contains(upper.lowercased())
        case .other:
            return stream.text(index) == "]"
        default:
            return false
        }
    }

    // MARK: - Scanning

    private func path(
        at start: Int, to end: Int, in stream: SQLTokenStream
    ) -> (table: String, schema: String?, isQuoted: Bool, end: Int)? {
        guard start < end, stream.isName(start) else { return nil }
        guard stream.kind(start) == .quoted || !Self.nonAliasWords.contains(stream.tokens[start].upper) else { return nil }
        var segments = [start]
        var index = start + 1
        while index + 1 < end, stream.kind(index) == .dot, stream.isName(index + 1) {
            segments.append(index + 1)
            index += 2
        }
        let table = segments[segments.count - 1]
        let schema = segments.count >= 2 ? stream.name(segments[segments.count - 2]) : nil
        return (stream.name(table), schema, stream.kind(table) == .quoted, index)
    }

    private func alias(after close: Int, in stream: SQLTokenStream) -> (name: String, declared: [String], end: Int)? {
        var index = close + 1
        if stream.isWord(index, "AS") { index += 1 }
        guard stream.isName(index),
              stream.kind(index) == .quoted || !Self.nonAliasWords.contains(stream.tokens[index].upper) else { return nil }
        let name = stream.name(index)
        guard !name.isEmpty else { return nil }
        guard stream.kind(index + 1) == .openParen else { return (name, [], index + 1) }
        return (name, nameList(at: index + 1, in: stream), stream.after(index + 1))
    }

    private func nameList(at open: Int, in stream: SQLTokenStream) -> [String] {
        topLevelItems(from: open + 1, to: stream.closeIndex(of: open), in: stream).compactMap { item in
            guard let first = item.first, stream.isName(first) else { return nil }
            let name = stream.name(first)
            return name.isEmpty ? nil : name
        }
    }

    private func firstTopLevel(_ words: Set<String>, from start: Int, to end: Int, in stream: SQLTokenStream) -> Int? {
        var index = start
        while index < end {
            let token = stream.tokens[index]
            if token.kind == .openParen {
                index = stream.after(index)
                continue
            }
            if token.kind == .word, words.contains(token.upper) { return index }
            index += 1
        }
        return nil
    }

    private func topLevelItems(from start: Int, to end: Int, in stream: SQLTokenStream) -> [Range<Int>] {
        guard start < end else { return [] }
        var items: [Range<Int>] = []
        var itemStart = start
        var index = start
        while index < end {
            switch stream.tokens[index].kind {
            case .openParen:
                index = min(stream.after(index), end)
                continue
            case .comma:
                items.append(itemStart..<index)
                itemStart = index + 1
            default:
                break
            }
            index += 1
        }
        items.append(itemStart..<end)
        return items
    }
}
