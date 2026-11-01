//
//  MySQLViewRowEditing.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum MySQLViewRowEditing {
    static let maximumDepth = 8

    struct Relation: Hashable {
        let database: String
        let name: String
    }

    struct View: Equatable {
        let relation: Relation
        let isUpdatable: Bool
        let definition: String
    }

    struct Level: Equatable {
        let base: Relation
        let columns: [String]
        // Per view column, the column of `base` it shows; nil for a computed one.
        let sources: [String?]

        func source(of column: String) -> String? {
            guard let index = columns.firstIndex(where: { MySQLViewRowEditing.sameName($0, column) }) else {
                return nil
            }
            return sources[index]
        }
    }

    enum Step: Equatable {
        case readOnly(PluginViewReadOnlyReason)
        case reads(Level)
    }

    enum Select: Equatable {
        case oneTable(Relation, sources: [String?])
        case severalTables
        case noTable
    }

    struct ColumnCountMismatch: Error, Equatable {
        let view: Relation
        let items: Int
        let columns: Int
    }

    struct Token: Equatable {
        enum Kind: Equatable {
            case word
            case quoted
            case literal
            case symbol
        }

        let kind: Kind
        let text: String
        let depth: Int

        func isWord(_ word: String) -> Bool {
            kind == .word && text.lowercased() == word
        }

        func isWord(in words: Set<String>) -> Bool {
            kind == .word && words.contains(text.lowercased())
        }

        func isSymbol(_ symbol: String) -> Bool {
            kind == .symbol && text == symbol
        }

        var identifier: String? {
            switch kind {
            case .quoted:
                return text
            case .word:
                guard let first = text.unicodeScalars.first, !(48...57).contains(first.value) else { return nil }
                return text
            case .literal, .symbol:
                return nil
            }
        }
    }

    static func viewQuery(database: String?, name: String, escape: (String) -> String) -> String {
        let schema = database.map { "'\(escape($0))'" } ?? "DATABASE()"
        return """
            SELECT TABLE_SCHEMA, TABLE_NAME, IS_UPDATABLE, VIEW_DEFINITION FROM information_schema.VIEWS \
            WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = '\(escape(name))'
            """
    }

    static func columnsQuery(_ relation: Relation, escape: (String) -> String) -> String {
        """
        SELECT COLUMN_NAME, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_TYPE FROM information_schema.COLUMNS \
        WHERE TABLE_SCHEMA = '\(escape(relation.database))' AND TABLE_NAME = '\(escape(relation.name))' \
        ORDER BY ORDINAL_POSITION
        """
    }

    // STATISTICS, not KEY_COLUMN_USAGE: MySQL drops key columns the user holds no column grant on from the latter.
    static func primaryKeyQuery(_ relation: Relation, escape: (String) -> String) -> String {
        """
        SELECT COLUMN_NAME FROM information_schema.STATISTICS \
        WHERE TABLE_SCHEMA = '\(escape(relation.database))' AND TABLE_NAME = '\(escape(relation.name))' \
        AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX
        """
    }

    // The user's own column grants on the base table: COLUMNS then lists only the columns they cover.
    static func columnGrantsQuery(_ relation: Relation, escape: (String) -> String) -> String {
        """
        SELECT COUNT(*) FROM information_schema.COLUMN_PRIVILEGES \
        WHERE TABLE_SCHEMA = '\(escape(relation.database))' AND TABLE_NAME = '\(escape(relation.name))' \
        AND GRANTEE = CONCAT('''', SUBSTRING_INDEX(CURRENT_USER(), '@', 1), '''@''', \
        SUBSTRING_INDEX(CURRENT_USER(), '@', -1), '''')
        """
    }

    static func hasColumnGrants(rows: [[String?]]) -> Bool {
        (rows.first.flatMap { cell($0, 0) }.flatMap { Int($0) } ?? 0) > 0
    }

    static func view(rows: [[String?]]) -> View? {
        guard let row = rows.first, let database = cell(row, 0), let name = cell(row, 1) else { return nil }
        return View(
            relation: Relation(database: database, name: name),
            isUpdatable: cell(row, 2)?.uppercased() == "YES",
            definition: cell(row, 3) ?? ""
        )
    }

    static func step(view: View, columnRows: [[String?]]) throws -> Step {
        guard view.isUpdatable else { return .readOnly(.notUpdatable) }
        // The server sends an empty definition to a user without the SHOW VIEW privilege.
        guard !view.definition.isEmpty else { return .readOnly(.baseTableHidden) }
        switch select(definition: view.definition) {
        case .severalTables:
            return .readOnly(.readsSeveralTables)
        case .noTable:
            return .readOnly(.notUpdatable)
        case .oneTable(let base, let sources):
            // By position: MySQL keeps a CREATE VIEW column list apart from the AS aliases it stores.
            let columns = columnRows.compactMap { cell($0, 0) }
            guard sources.count == columns.count else {
                throw ColumnCountMismatch(view: view.relation, items: sources.count, columns: columns.count)
            }
            return .reads(Level(base: base, columns: columns, sources: sources))
        }
    }

    static func baseColumn(row: [String?], quotesDefaults: Bool) -> PluginViewBaseColumn? {
        guard let name = cell(row, 0) else { return nil }
        let isNullable = cell(row, 1)?.uppercased() == "YES"
        let extra = cell(row, 3)
        let catalogDefault: MySQLCatalogDefault = quotesDefaults ? .quoted(cell(row, 2)) : .bare(cell(row, 2))
        return PluginViewBaseColumn(
            name: name,
            isNullable: isNullable,
            defaultValue: mysqlColumnDefault(
                catalogDefault,
                extra: extra,
                dataType: cell(row, 4) ?? "",
                isNullable: isNullable
            ),
            assignsValue: mysqlIdentityKind(extra: extra) != nil,
            acceptsWrites: !mysqlColumnIsGenerated(extra: extra)
        )
    }

    static func answer(
        levels: [Level],
        keyRows: [[String?]],
        columnRows: [[String?]],
        quotesDefaults: Bool,
        insertNeedsPlainColumns: Bool,
        hasColumnGrants: Bool
    ) -> PluginViewRowEditing {
        guard let top = levels.first, let base = levels.last?.base else { return .readOnly(.notUpdatable) }
        let baseColumns = columnRows.compactMap { baseColumn(row: $0, quotesDefaults: quotesDefaults) }
        let keyColumns = keyRows.compactMap { cell($0, 0) }
        let isVisible = !baseColumns.isEmpty
        // Column grants hide the columns they leave out, so a key column missing here means the list is partial.
        let isComplete = keyColumns.allSatisfy { key in baseColumns.contains { sameName($0.name, key) } }

        var sources = top.sources
        for level in levels.dropFirst() {
            sources = sources.map { $0.flatMap(level.source(of:)) }
        }
        if isVisible {
            sources = sources.map { source in
                source.flatMap { name in baseColumns.first { sameName($0.name, name) }?.name }
            }
        }

        var operations: PluginViewWriteOperations = [.update, .delete]
        // MySQL refuses an INSERT (1471) once a view column is not a base column or shows one twice;
        // MariaDB 11.8 takes one that leaves those columns out, as the grid does.
        let shown = sources.compactMap { $0?.lowercased() }
        if !insertNeedsPlainColumns || (shown.count == sources.count && Set(shown).count == shown.count) {
            operations.insert(.insert)
        }

        return PluginViewRowEditing.resolve(
            operations: operations,
            baseTable: PluginViewBaseTable(database: base.database, name: base.name),
            columns: zip(top.columns, sources).map {
                PluginViewColumn(name: $0, baseColumn: $1, acceptsWrites: $1 != nil)
            },
            baseKeyColumns: isVisible || !keyColumns.isEmpty ? keyColumns : nil,
            baseColumns: isVisible && isComplete && !hasColumnGrants ? baseColumns : nil
        )
    }

    static func select(definition: String) -> Select {
        var tokens = unwrapped(tokenize(definition))
        if tokens.first?.isWord("with") == true {
            guard let main = tokens.firstIndex(where: { $0.depth == 0 && $0.isWord("select") }) else {
                return .noTable
            }
            tokens = Array(tokens[main...])
        }
        guard tokens.first?.isWord("select") == true else { return .noTable }

        var listStart = 1
        while listStart < tokens.count, tokens[listStart].isWord(in: selectModifiers) {
            listStart += 1
        }
        guard let from = tokens[listStart...].firstIndex(where: { $0.depth == 0 && $0.isWord("from") }) else {
            return .noTable
        }

        let base: Relation
        let alias: String?
        switch fromClause(tokens[(from + 1)...]) {
        case .severalTables:
            return .severalTables
        case .noTable:
            return .noTable
        case .table(let relation, let tableAlias):
            base = relation
            alias = tableAlias
        }

        let sources = items(tokens[listStart..<from]).map { item -> String? in
            guard let reference = columnReference(item),
                  namesBase(reference.qualifier, base: base, alias: alias)
            else { return nil }
            return reference.column
        }
        return .oneTable(base, sources: sources)
    }

    // Scalar by scalar: a backquote followed by a combining mark is one Character but still opens a name.
    static func tokenize(_ text: String) -> [Token] {
        let scalars = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var depth = 0
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "`":
                var name = String.UnicodeScalarView()
                index += 1
                while index < scalars.count {
                    if scalars[index] == "`" {
                        guard index + 1 < scalars.count, scalars[index + 1] == "`" else { break }
                        index += 1
                    }
                    name.append(scalars[index])
                    index += 1
                }
                index += 1
                tokens.append(Token(kind: .quoted, text: String(name), depth: depth))
            case "'", "\"":
                let start = index
                index += 1
                while index < scalars.count {
                    if scalars[index] == "\\" {
                        index += 2
                        continue
                    }
                    if scalars[index] == scalar {
                        guard index + 1 < scalars.count, scalars[index + 1] == scalar else { break }
                        index += 1
                    }
                    index += 1
                }
                index = min(index + 1, scalars.count)
                let literal = String(String.UnicodeScalarView(scalars[start..<index]))
                tokens.append(Token(kind: .literal, text: literal, depth: depth))
            case "(":
                tokens.append(Token(kind: .symbol, text: "(", depth: depth))
                depth += 1
                index += 1
            case ")":
                depth -= 1
                tokens.append(Token(kind: .symbol, text: ")", depth: depth))
                index += 1
            case _ where scalar.properties.isWhitespace:
                index += 1
            case _ where isWordScalar(scalar):
                var word = String.UnicodeScalarView()
                while index < scalars.count, isWordScalar(scalars[index]) {
                    word.append(scalars[index])
                    index += 1
                }
                tokens.append(Token(kind: .word, text: String(word), depth: depth))
            default:
                tokens.append(Token(kind: .symbol, text: String(scalar), depth: depth))
                index += 1
            }
        }
        return tokens
    }

    private static let selectModifiers: Set<String> = [
        "all", "distinct", "distinctrow", "high_priority", "straight_join", "sql_small_result",
        "sql_big_result", "sql_buffer_result", "sql_cache", "sql_no_cache", "sql_calc_found_rows",
    ]

    private static let clauseEnds: Set<String> = [
        "where", "group", "having", "order", "limit", "window", "union", "except", "intersect",
        "for", "lock", "into", "procedure",
    ]

    private enum FromClause {
        case table(Relation, alias: String?)
        case severalTables
        case noTable
    }

    private static func fromClause(_ tokens: ArraySlice<Token>) -> FromClause {
        let clause = Array(tokens.prefix { !($0.depth == 0 && $0.isWord(in: clauseEnds)) })
        if let reference = tableReference(clause) { return reference }
        return joinsTables(clause) ? .severalTables : .noTable
    }

    private static func tableReference(_ clause: [Token]) -> FromClause? {
        var names: [String] = []
        var index = 0
        while index < clause.count, names.count < 3, let name = clause[index].identifier {
            names.append(name)
            index += 1
            guard index < clause.count, clause[index].isSymbol(".") else { break }
            index += 1
        }
        guard (1...2).contains(names.count) else { return nil }
        if index < clause.count, clause[index].isWord("as") { index += 1 }
        var alias: String?
        if index < clause.count {
            guard let name = clause[index].identifier else { return nil }
            alias = name
            index += 1
        }
        guard index == clause.count else { return nil }
        // The server qualifies every table it stores, so a bare name is a common table expression.
        guard names.count == 2 else { return .noTable }
        return .table(Relation(database: names[0], name: names[1]), alias: alias)
    }

    private static func joinsTables(_ clause: [Token]) -> Bool {
        var subqueryDepths: [Int] = []
        var previous: Token?
        for token in clause {
            defer { previous = token }
            if let open = previous, open.isSymbol("("), token.isWord("select") || token.isWord("with") {
                subqueryDepths.append(open.depth)
            }
            if token.isSymbol(")"), subqueryDepths.last == token.depth {
                subqueryDepths.removeLast()
                continue
            }
            guard subqueryDepths.isEmpty else { continue }
            if token.isWord("join") || token.isWord("straight_join") { return true }
            if token.depth == 0, token.isSymbol(",") { return true }
        }
        return false
    }

    private static func items(_ tokens: ArraySlice<Token>) -> [[Token]] {
        var items: [[Token]] = [[]]
        for token in tokens {
            if token.depth == 0, token.isSymbol(",") {
                items.append([])
            } else {
                items[items.count - 1].append(token)
            }
        }
        return items
    }

    private static func columnReference(_ item: [Token]) -> (qualifier: [String], column: String)? {
        var tokens = item[...]
        if tokens.count >= 3, tokens[tokens.endIndex - 2].isWord("as"), tokens.last?.identifier != nil {
            tokens = tokens.dropLast(2)
        }
        guard tokens.count % 2 == 1, tokens.count <= 5 else { return nil }
        var names: [String] = []
        for (offset, token) in tokens.enumerated() {
            if offset.isMultiple(of: 2) {
                guard let name = token.identifier else { return nil }
                names.append(name)
            } else if !token.isSymbol(".") {
                return nil
            }
        }
        guard let column = names.popLast() else { return nil }
        return (names, column)
    }

    // MariaDB leaves the database out of a reference to an inner view; MySQL writes `db`.`alias`
    // for an aliased one. The server qualifies every column, so a bare name is a keyword.
    private static func namesBase(_ qualifier: [String], base: Relation, alias: String?) -> Bool {
        let table = alias ?? base.name
        switch qualifier.count {
        case 1:
            return sameName(qualifier[0], table)
        case 2:
            return sameName(qualifier[0], base.database) && sameName(qualifier[1], table)
        default:
            return false
        }
    }

    private static func unwrapped(_ tokens: [Token]) -> [Token] {
        var tokens = tokens
        while tokens.count >= 2, tokens[0].isSymbol("("),
              tokens.dropFirst().firstIndex(where: { $0.depth == 0 && $0.isSymbol(")") }) == tokens.count - 1 {
            tokens = tokens.dropFirst().dropLast().map { Token(kind: $0.kind, text: $0.text, depth: $0.depth - 1) }
        }
        return tokens
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return !scalar.properties.isWhitespace }
        return scalar.properties.isAlphabetic || (48...57).contains(scalar.value) || scalar == "_" || scalar == "$"
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func cell(_ row: [String?], _ index: Int) -> String? {
        row.indices.contains(index) ? row[index] : nil
    }
}
