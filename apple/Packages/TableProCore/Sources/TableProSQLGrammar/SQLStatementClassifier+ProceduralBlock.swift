import Foundation

/// Tiering a statement that runs PL/SQL, or a SAP HANA SQLScript block, by what it runs rather than by its first word.
///
/// Once the editor keeps a unit whole, its leading keyword is all a keyword classifier would see: a `DROP` inside
/// `EXECUTE IMMEDIATE` would pass as a plain write in a block, and as a safe read in a query whose `WITH` clause
/// declares a function. Both run server-side code the moment they are sent, exactly as PostgreSQL's `DO` does, so both
/// carry the same flag that keeps them away from external clients, and their tier is the worst of the statements they
/// spell out and never below a write. Dynamic SQL built from variables cannot be read, which leaves it where a `CALL`
/// of a stored procedure is: a write whose effect the text does not show.
extension SQLStatementTiering {
    func proceduralBlockClassification(_ statement: String, grammar: SQLLexicalGrammar) -> StatementClassification {
        let code = StatementCode(statement, grammar: grammar)
        var tier: StatementTier = Self.firstKeyword(of: Self.dataDroppingWords, in: code.tokens, code: code) == nil
            ? .write
            : .destructive
        for dynamic in Self.dynamicStatements(in: code, grammar: grammar) {
            tier = StatementClassification.worse(tier, classify(dynamic).tier)
        }
        return StatementClassification(tier: tier, reachesFilesystemOrExecutesCode: true)
    }

    /// Whether the block deletes without a `WHERE`, in its own text or in a statement it builds from a literal.
    func proceduralBlockDeletesEveryRow(_ statement: String, grammar: SQLLexicalGrammar) -> Bool {
        let code = StatementCode(statement, grammar: grammar)
        let spelledOut = Self.segments(of: code.tokens).contains { Self.deletesWithoutWhere($0, code: code) }
        guard !spelledOut else { return true }
        return Self.dynamicStatements(in: code, grammar: grammar).contains { dynamic in
            let inner = StatementCode(dynamic, grammar: grammar)
            return Self.segments(of: inner.tokens).contains { Self.deletesWithoutWhere($0, code: inner) }
        }
    }

    /// The first of `keywords` that is a keyword rather than a member name: `v_list.DELETE` is a collection method,
    /// not a statement.
    private static func firstKeyword(
        of keywords: Set<String>,
        in tokens: ArraySlice<TSQLTokens.Token>,
        code: StatementCode
    ) -> Int? {
        tokens.indices.first { index in
            guard let word = tokens[index].word, keywords.contains(word) else { return false }
            return index == tokens.startIndex || !code.isSymbol(period, at: index - 1)
        }
    }

    private static func firstKeyword(
        of keywords: Set<String>,
        in tokens: [TSQLTokens.Token],
        code: StatementCode
    ) -> Int? {
        firstKeyword(of: keywords, in: tokens[...], code: code)
    }

    private static func segments(of tokens: [TSQLTokens.Token]) -> [ArraySlice<TSQLTokens.Token>] {
        tokens.split(whereSeparator: { $0.kind == .terminator })
    }

    private static func deletesWithoutWhere(_ segment: ArraySlice<TSQLTokens.Token>, code: StatementCode) -> Bool {
        guard let delete = firstKeyword(of: ["DELETE"], in: segment, code: code) else { return false }
        return !segment[delete...].contains { $0.word == "WHERE" }
    }

    /// The statements a block builds from a literal through the documented entry points that run SQL at run time:
    /// `EXECUTE IMMEDIATE`, `EXEC_DDL_STATEMENT(...)`, `DBMS_SQL.PARSE(cursor, ...)`, and SQLScript's `EXEC`. The
    /// statement is read only when it is written out as a literal, which is the only form the text can show.
    private static func dynamicStatements(in code: StatementCode, grammar: SQLLexicalGrammar) -> [String] {
        let tokens = code.tokens
        return tokens.indices.compactMap { index in
            guard let operand = dynamicOperand(at: index, in: code, grammar: grammar),
                  let start = literalStart(at: operand, in: code)
            else { return nil }
            return literal(in: code.text, at: start)
        }
    }

    // A national literal, `N'...'`, is the word `N` and the literal after it.
    private static func literalStart(at operand: Int, in code: StatementCode) -> Int? {
        let tokens = code.tokens
        guard tokens.indices.contains(operand) else { return nil }
        if tokens[operand].kind == .quoted { return tokens[operand].location }
        guard tokens[operand].word == "N", tokens.indices.contains(operand + 1), tokens[operand + 1].kind == .quoted,
              tokens[operand + 1].location == tokens[operand].location + 1
        else { return nil }
        return tokens[operand + 1].location
    }

    private static func dynamicOperand(at index: Int, in code: StatementCode, grammar: SQLLexicalGrammar) -> Int? {
        let tokens = code.tokens
        if code.spells(["EXECUTE", "IMMEDIATE"], at: index) { return code.operand(after: index + 1) }
        if grammar.contains(.sqlScriptBlocks), tokens[index].word == "EXEC" { return code.operand(after: index) }
        if tokens[index].word == "EXEC_DDL_STATEMENT", tokens.indices.contains(index + 1),
           tokens[index + 1].kind == .open {
            return index + 2
        }
        guard tokens[index].word == "DBMS_SQL", code.isSymbol(period, at: index + 1),
              tokens.indices.contains(index + 3), tokens[index + 2].word == "PARSE", tokens[index + 3].kind == .open
        else { return nil }
        let depth = tokens[index + 3].depth + 1
        let comma = tokens.indices.dropFirst(index + 4).first { candidate in
            tokens[candidate].kind == .terminator || (tokens[candidate].kind == .comma && tokens[candidate].depth == depth)
        }
        guard let comma, tokens[comma].kind == .comma else { return nil }
        return comma + 1
    }

    /// The body of the string literal starting at `offset`, either `'...'` with doubled quotes folded or Oracle's
    /// `q'[...]'`.
    private static func literal(in text: NSString, at offset: Int) -> String? {
        let length = text.length
        guard offset < length else { return nil }
        if text.character(at: offset) == SqlLexer.singleQuote {
            return quotedBody(in: text, from: offset + 1)
        }
        guard let literal = SqlLexer.skipAlternativeQuotedString(text, at: offset, length: length) else { return nil }
        return text.substring(with: NSRange(location: literal.bodyStart, length: literal.bodyEnd - literal.bodyStart))
    }

    private static func quotedBody(in text: NSString, from start: Int) -> String {
        let length = text.length
        var cursor = start
        while cursor < length {
            if text.character(at: cursor) == SqlLexer.singleQuote {
                guard cursor + 1 < length, text.character(at: cursor + 1) == SqlLexer.singleQuote else { break }
                cursor += 2
                continue
            }
            cursor += 1
        }
        return text.substring(with: NSRange(location: start, length: cursor - start))
            .replacingOccurrences(of: "''", with: "'", options: .literal)
    }
}
