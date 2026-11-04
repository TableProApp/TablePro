import Foundation

// SurrealQL runs a statement wherever it takes a value, CockroachDB one in brackets as a table. Not measured.
enum SQLEmbeddedStatements {
    // A bare statement has no end a reader can find, so it is its first word alone.
    static func texts(in statement: String, grammar: SQLLexicalGrammar) -> [String] {
        guard !grammar.isDisjoint(with: [.statementsAsValues, .bracketedStatementSources]) else { return [] }
        let text = statement as NSString
        let tokens = TSQLTokens.read(text, grammar: grammar)
        guard let first = tokens.firstIndex(where: { $0.kind != .open }) else { return [] }
        var spans: [SQLUnterminatedStatements.StatementSpan] = []
        var open: [(span: Int, depth: Int)] = []
        var bare: [String] = []
        var depth = 0
        var isListed = false
        func close(at location: Int, while isClosed: (Int) -> Bool) {
            while let last = open.last, isClosed(last.depth) {
                spans[last.span].range.length = location - spans[last.span].range.location
                open.removeLast()
            }
        }
        for index in tokens.indices {
            let token = tokens[index]
            let previous = index > 0 ? tokens[index - 1] : nil
            if opener(token, in: text) != nil {
                depth += 1
            } else if closes(token, in: text) {
                depth = max(0, depth - 1)
                close(at: token.location) { $0 > depth }
            }
            guard let word = token.word else {
                isListed = isListed && token.kind == .comma
                continue
            }
            isListed = previous?.word.map(namingWords.contains) == true || (isListed && previous?.kind == .comma)
            let group = previous.flatMap { opener($0, in: text) }
            guard index > first, begins(word, at: token.location, in: text, group: group, grammar: grammar),
                  !isListed
            else { continue }
            guard group != nil else {
                if !bare.contains(word) { bare.append(word) }
                continue
            }
            let range = NSRange(location: token.location, length: 0)
            spans.append(SQLUnterminatedStatements.StatementSpan(range: range, parent: open.last?.span))
            open.append((span: spans.count - 1, depth: depth))
        }
        close(at: text.length) { _ in true }
        return SQLUnterminatedStatements.ownTexts(of: spans, in: text) + bare
    }

    // The words the SurrealDB plugin's SurrealRawCondition refuses in a raw filter.
    private static let surrealQLStatementWords: Set<String> = [
        "ACCESS", "ALTER", "CREATE", "DEFINE", "DELETE", "INSERT", "KILL", "LIVE", "OPTION",
        "REBUILD", "RELATE", "REMOVE", "UPDATE", "UPSERT", "USE",
    ]

    // CockroachDB's row_source_extension_stmt, less SELECT and SHOW.
    private static let bracketedStatementWords: Set<String> = [
        "DELETE", "EXPLAIN", "INSERT", "UPDATE", "UPSERT", "WITH",
    ]

    // SurrealQL takes no value after these: `PERMISSIONS FOR delete`, `ON DELETE CASCADE`.
    private static let namingWords: Set<String> = ["FOR", "ON"]

    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let openBrace = UInt16(UnicodeScalar("{").value)
    private static let closers: Set<UInt16> = [UInt16(UnicodeScalar("]").value), UInt16(UnicodeScalar("}").value)]
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let colon = UInt16(UnicodeScalar(":").value)

    private static func begins(
        _ word: String,
        at location: Int,
        in text: NSString,
        group: UInt16?,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        if grammar.contains(.bracketedStatementSources), group == openBracket, bracketedStatementWords.contains(word) {
            return true
        }
        return grammar.contains(.statementsAsValues) && surrealQLStatementWords.contains(word)
            && !namesParameterFieldOrFunction(at: location, in: text)
    }

    // `$update`, `row.update` and `array::insert` are names; `1..DELETE` ends in a statement.
    private static func namesParameterFieldOrFunction(at location: Int, in text: NSString) -> Bool {
        guard location > 0 else { return false }
        switch text.character(at: location - 1) {
        case dollar:
            return true
        case period:
            return location >= 2 && text.character(at: location - 2) != period
        case colon:
            return location >= 3 && text.character(at: location - 2) == colon
                && SqlDollarQuote.isIdentifierPart(text.character(at: location - 3))
        default:
            return false
        }
    }

    private static func opener(_ token: TSQLTokens.Token, in text: NSString) -> UInt16? {
        guard token.kind == .open || token.kind == .other else { return nil }
        let unit = text.character(at: token.location)
        return unit == SqlLexer.openParen || unit == openBracket || unit == openBrace ? unit : nil
    }

    private static func closes(_ token: TSQLTokens.Token, in text: NSString) -> Bool {
        token.kind == .close || (token.kind == .other && closers.contains(text.character(at: token.location)))
    }
}
