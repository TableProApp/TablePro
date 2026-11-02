import Foundation

// Catalog text a generator writes back as SQL, such as a column default, a check or a type, can only be
// spliced when it cannot end the clause it lands in. It must read the same way under every way the engine
// may lex it: every literal and quoted name closed, no comment, brackets balanced, no `;`, one statement,
// and for an expression or a type no comma outside brackets.
public enum SQLExpressionFragment {
    private enum Shape {
        case expression
        case type
        // A type on an engine that writes type arguments in `<>`, as in `map<text, int>`.
        case angleBracketedType
        // A body that ends the statement, such as a view or a table macro's query: a top-level comma is ordinary
        // and a comment is allowed.
        case query
    }

    // Engines with `<…>` types whose column takes no bare expression after its type. Elsewhere `<` can compare, and
    // pairing it would hide the comma in `1 < 2, extra BOOLEAN DEFAULT 3 > 2`: StarRocks (`AS expr`) and BigQuery
    // (`DEFAULT expr`) write `<…>` types too and stay out.
    private static let angleBracketedTypeEngines: Set<String> = ["Cassandra", "ScyllaDB", "Cloudflare R2 SQL"]

    private static let semicolon = UInt16(UnicodeScalar(";").value)
    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let openAngle = UInt16(UnicodeScalar("<").value)
    private static let closeAngle = UInt16(UnicodeScalar(">").value)
    private static let closers: [UInt16: UInt16] = [
        openParen: UInt16(UnicodeScalar(")").value),
        openBracket: UInt16(UnicodeScalar("]").value),
        UInt16(UnicodeScalar("{").value): UInt16(UnicodeScalar("}").value),
        openAngle: closeAngle,
    ]
    private static let closing = Set(closers.values)

    public static func isSingleExpression(_ text: String, databaseTypeId: String) -> Bool {
        isSingle(text, shape: .expression, readings: readings(for: databaseTypeId))
    }

    public static func isSingleExpression(_ text: String, readings: [SQLLexicalGrammar]) -> Bool {
        isSingle(text, shape: .expression, readings: readings)
    }

    public static func isSingleExpression(_ text: String, grammar: SQLLexicalGrammar) -> Bool {
        isSingle(text, shape: .expression, grammar: grammar)
    }

    public static func isSingleType(_ text: String, databaseTypeId: String) -> Bool {
        let shape: Shape = angleBracketedTypeEngines.contains(databaseTypeId) ? .angleBracketedType : .type
        return isSingle(text, shape: shape, readings: readings(for: databaseTypeId))
    }

    public static func isSingleQuery(_ text: String, databaseTypeId: String) -> Bool {
        isSingle(text, shape: .query, readings: readings(for: databaseTypeId))
    }

    // Catalog text without its comments, read by the engine's own grammar: Oracle keeps a comment written after a
    // default in the stored text. A line comment leaves its line break, so nothing joins the next line.
    public static func strippingComments(_ text: String, databaseTypeId: String) -> String {
        let grammar = SQLLexicalProfile.curated(forDatabaseTypeId: databaseTypeId)?.grammar ?? .ansi
        let source = text as NSString
        var kept: [UInt16] = []
        var index = 0
        while index < source.length {
            guard let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) else {
                kept.append(source.character(at: index))
                index += 1
                continue
            }
            let end = max(span.end, index + 1)
            if span.kind.isComment {
                kept.append(SqlLexer.space)
            } else {
                for offset in index..<end { kept.append(source.character(at: offset)) }
            }
            index = end
        }
        return String(utf16CodeUnits: kept, count: kept.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Whether catalog text is one whole string literal, `'…'` or `N'…'`, under every reading of the engine.
    public static func isSingleStringLiteral(_ text: String, databaseTypeId: String) -> Bool {
        let source = text as NSString
        let length = source.length
        guard length > 0, source.character(at: length - 1) == singleQuote else { return false }
        let opener = source.character(at: 0)
        guard opener == singleQuote || (length > 1 && isPrefix(opener) && source.character(at: 1) == singleQuote) else {
            return false
        }
        let start = opener == singleQuote ? 0 : 1
        return readings(for: databaseTypeId).allSatisfy { grammar in
            let span = SQLNonCodeSpan.span(at: 0, in: source, grammar: grammar)
                ?? SQLNonCodeSpan.span(at: start, in: source, grammar: grammar)
            guard let span else { return false }
            return span.kind == .quoted && span.isTerminated && span.end == length
        }
    }

    private static func readings(for databaseTypeId: String) -> [SQLLexicalGrammar] {
        SQLLexicalProfile.curated(forDatabaseTypeId: databaseTypeId)?.readings ?? SQLLexicalProfile.everyKnownReading
    }

    // National, escape, hex and bit string prefixes.
    private static func isPrefix(_ unit: UInt16) -> Bool {
        Set("NnEeXxBb".utf16).contains(unit)
    }

    private static func isSingle(_ text: String, shape: Shape, readings: [SQLLexicalGrammar]) -> Bool {
        guard !readings.isEmpty else { return false }
        return readings.allSatisfy { isSingle(text, shape: shape, grammar: $0) }
    }

    private static func isSingle(_ text: String, shape: Shape, grammar: SQLLexicalGrammar) -> Bool {
        let source = text as NSString
        let length = source.length
        var open: [UInt16] = []
        var firstCode: UInt16?
        var outerGroupClosed = false
        var wrapped = true
        var index = 0
        while index < length {
            if let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) {
                guard span.isTerminated else { return false }
                // A stored view or macro body may carry comments; one running to the end of the text would swallow
                // whatever the caller writes after it.
                if shape == .query, span.kind.isComment {
                    guard span.kind == .blockComment || span.end < length else { return false }
                    index = max(span.end, index + 1)
                    continue
                }
                guard span.kind == .quoted else { return false }
                if firstCode == nil || outerGroupClosed { wrapped = false }
                firstCode = firstCode ?? source.character(at: index)
                index = max(span.end, index + 1)
                continue
            }
            let unit = source.character(at: index)
            index += 1
            if SqlLexer.isWhitespace(unit) { continue }
            if firstCode == nil, unit != openParen { wrapped = false }
            if outerGroupClosed { wrapped = false }
            firstCode = firstCode ?? unit
            if unit == semicolon { return false }
            // `DEFAULT 0x00, DROP COLUMN secret` adds an action to the ALTER it lands in.
            if unit == comma, open.isEmpty, shape != .query { return false }
            if isOpener(unit, shape: shape, grammar: grammar) {
                open.append(unit)
            } else if isCloser(unit, shape: shape, grammar: grammar) {
                guard let opener = open.popLast(), closers[opener] == unit else { return false }
                if open.isEmpty { outerGroupClosed = true }
            }
        }
        guard firstCode != nil, open.isEmpty else { return false }
        // T-SQL runs a second statement with no `;` before it, so there only one parenthesised group is one
        // expression.
        if shape != .query, grammar.contains(.unterminatedStatements), !wrapped { return false }
        // A `GO` or `/` line ends a batch even when one statement comes before it, so the one statement has to run
        // to the end of the text.
        let statements = SQLStatementScanner.locatedStatements(in: text, grammar: grammar).filter(\.hasContent)
        guard statements.count == 1 else { return false }
        var end = length
        while end > 0, SqlLexer.isWhitespace(source.character(at: end - 1)) { end -= 1 }
        return NSMaxRange(statements[0].contentRange) >= end
    }

    private static func isOpener(_ unit: UInt16, shape: Shape, grammar: SQLLexicalGrammar) -> Bool {
        if unit == openAngle { return shape == .angleBracketedType }
        // Where `[name]` quotes an identifier the lexer already read it as one token.
        if unit == openBracket { return !grammar.contains(.bracketQuotedIdentifiers) }
        return closers[unit] != nil
    }

    private static func isCloser(_ unit: UInt16, shape: Shape, grammar: SQLLexicalGrammar) -> Bool {
        if unit == closeAngle { return shape == .angleBracketedType }
        if unit == UInt16(UnicodeScalar("]").value) { return !grammar.contains(.bracketQuotedIdentifiers) }
        return closing.contains(unit)
    }
}
