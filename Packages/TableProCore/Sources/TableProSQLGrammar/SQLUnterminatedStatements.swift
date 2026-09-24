import Foundation

/// The statements an engine that needs no `;` between them runs from one scanned statement.
///
/// ``SQLStatementScanner`` ends a statement at a terminator, so on SQL Server `SELECT 1` followed by `DROP TABLE t` on
/// the next line reaches a gate as one statement, and the server runs it as two. This finds every word inside it that
/// begins a statement and returns the text from each one to the next at its own depth, less the statements nested in
/// it, so a gate can tier each of them the way it tiers a statement written first. What it relies on was measured on
/// Azure SQL Edge 15.0, and `scripts/check-mssql-unterminated-statements.sh` measures it again:
///
/// - Only a reserved keyword begins a statement without a `;` before it. `DISABLE TRIGGER`, `RECEIVE`, `SEND` and
///   `THROW` answer Msg 102 there, and a `WITH` that opens a common table expression answers Msg 319.
/// - A keyword is spelled in ASCII. A dotless i, a long s or a Kelvin sign never make one, however Unicode cases them.
/// - A keyword glued to a number is a word of its own: `1DELETE`, `1.DELETE`, `1e1DELETE`, `1E+DELETE` and
///   `$1DELETE` each run the `DELETE`. `0xDELETE` does not, because the literal takes the hex digits `DE`.
/// - `$`, `#` and `@` continue a word, and so does a letter outside ASCII, so `a$DELETE` and `éDELETE` are names. A
///   space outside ASCII, a zero-width space and a control character each end a word.
/// - A procedure, function or trigger runs to the end of its batch, so storing one runs nothing written after it.
public enum SQLUnterminatedStatements {
    /// Every text a gate has to tier for `statement`: the statement itself, then, when `grammar` needs no terminator,
    /// the text of each statement that begins inside it, less the statements nested in that one, which come on their
    /// own.
    public static func runnable(in statement: String, grammar: SQLLexicalGrammar) -> [String] {
        guard grammar.contains(.unterminatedStatements) else { return [statement] }
        let text = statement as NSString
        let tokens = TSQLTokens.read(text, grammar: grammar)
        guard !definesRoutine(tokens) else { return [statement] }
        return [statement] + ownTexts(of: statementSpans(in: tokens, length: text.length), in: text)
    }

    /// The reserved keywords that begin a T-SQL statement. `ELSE` and `FETCH` are left out because they also continue
    /// a `CASE` and an `OFFSET` clause, and the statement after an `ELSE` begins with a keyword of its own. `WITH` is
    /// left out because a common table expression cannot follow a statement without a `;`, and the word also opens
    /// table hints.
    private static let statementKeywords: Set<String> = [
        "ALTER", "BACKUP", "BEGIN", "BREAK", "BULK", "CHECKPOINT", "CLOSE", "COMMIT", "CONTINUE", "CREATE", "DBCC",
        "DEALLOCATE", "DECLARE", "DELETE", "DENY", "DROP", "DUMP", "END", "EXEC", "EXECUTE", "GOTO", "GRANT", "IF",
        "INSERT", "KILL", "LINENO", "LOAD", "MERGE", "OPEN", "PRINT", "RAISERROR", "READTEXT", "RECONFIGURE",
        "RESTORE", "RETURN", "REVERT", "REVOKE", "ROLLBACK", "SAVE", "SELECT", "SET", "SETUSER", "SHUTDOWN",
        "TRUNCATE", "UPDATE", "UPDATETEXT", "USE", "WAITFOR", "WHILE", "WRITETEXT",
    ]

    private static let routineKinds: Set<String> = ["PROC", "PROCEDURE", "FUNCTION", "TRIGGER"]

    /// The statement keywords that are also permissions. Followed by a comma, `ON` or `TO`, as in
    /// `GRANT SELECT, DELETE ON t TO u`, one names a permission, and no statement ever begins that way.
    private static let permissionKeywords: Set<String> = [
        "ALTER", "CHECKPOINT", "DELETE", "EXECUTE", "INSERT", "SELECT", "SHUTDOWN", "UPDATE",
    ]

    private static let permissionFollowers: Set<String> = ["ON", "TO"]

    /// What a foreign key does on a `DELETE` or an `UPDATE`: `ON DELETE CASCADE`, `SET NULL`, `SET DEFAULT` or
    /// `NO ACTION`. A statement cannot follow either keyword with these, and `DELETE no ACTION` answers Msg 102.
    private static let referentialActions: Set<String> = ["CASCADE", "SET"]

    private static let dataChangeKeywords: Set<String> = ["DELETE", "UPDATE"]

    private static func beginsStatement(at index: Int, in tokens: [TSQLTokens.Token]) -> Bool {
        guard let keyword = tokens[index].word, statementKeywords.contains(keyword) else { return false }
        let previous = index > 0 ? tokens[index - 1].word : nil
        let next = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
        let following = tokens.indices.contains(index + 2) ? tokens[index + 2].word : nil
        if previous == "THEN" { return false }
        if permissionKeywords.contains(keyword), namesPermission(followedBy: next) { return false }
        if dataChangeKeywords.contains(keyword), namesReferentialAction(next?.word, following) { return false }
        switch keyword {
        case "SET":
            return previous.map { !dataChangeKeywords.contains($0) } ?? true
        case "MERGE":
            return next?.word != "JOIN" && next?.word != "UNION"
        case "USE":
            return tokens[index].depth == 0 || (next?.word != "HINT" && next?.word != "PLAN")
        case "END":
            return next?.word == "CONVERSATION"
        default:
            return true
        }
    }

    private static func namesPermission(followedBy next: TSQLTokens.Token?) -> Bool {
        guard let next else { return false }
        return next.kind == .comma || next.word.map(permissionFollowers.contains) == true
    }

    private static func namesReferentialAction(_ next: String?, _ following: String?) -> Bool {
        guard let next else { return false }
        return referentialActions.contains(next) || (next == "NO" && following == "ACTION")
    }

    /// Whether the statement beginning at `index` is an `UPDATE` whose `SET` clause is still to come, which every
    /// `UPDATE` but `UPDATE STATISTICS` has.
    private static func awaitsSetClause(at index: Int, in tokens: [TSQLTokens.Token]) -> Bool {
        guard tokens[index].word == "UPDATE" else { return false }
        return !tokens.indices.contains(index + 1) || tokens[index + 1].word != "STATISTICS"
    }

    /// Whether the statement stores a procedure, function or trigger, whose body runs to the end of the batch.
    private static func definesRoutine(_ tokens: [TSQLTokens.Token]) -> Bool {
        let words = tokens.prefix(4).map { $0.word ?? "" }
        guard let first = words.first, first == "CREATE" || first == "ALTER" else { return false }
        let rest = words.dropFirst()
        let kind = first == "CREATE" && rest.starts(with: ["OR", "ALTER"]) ? rest.dropFirst(2).first : rest.first
        return kind.map(routineKinds.contains) ?? false
    }

    private struct StatementSpan {
        var range: NSRange
        let parent: Int?
    }

    private struct OpenStatement {
        let span: Int
        let depth: Int
        var awaitsSetClause: Bool
    }

    /// The span of each statement that begins inside the text, in the order they begin, with the statement it is
    /// nested in. One ends at the next statement at its depth or shallower, at a `;` there, or at the `)` that closes
    /// the parentheses it began in. The statements still open always sit at increasing depths, so each token closes
    /// them from the top of a stack and the whole walk is linear however many statements a script holds.
    private static func statementSpans(in tokens: [TSQLTokens.Token], length: Int) -> [StatementSpan] {
        var spans: [StatementSpan] = []
        var open: [OpenStatement] = []
        func close(at location: Int, while isClosed: (Int) -> Bool) {
            while let last = open.last, isClosed(last.depth) {
                spans[last.span].range.length = location - spans[last.span].range.location
                open.removeLast()
            }
        }
        for index in tokens.indices {
            let token = tokens[index]
            switch token.kind {
            case .close:
                close(at: token.location) { $0 > token.depth }
            case .terminator:
                close(at: token.location) { $0 >= token.depth }
            default:
                if token.word == "SET", let last = open.last, last.depth == token.depth, last.awaitsSetClause {
                    open[open.count - 1].awaitsSetClause = false
                    continue
                }
                guard beginsStatement(at: index, in: tokens) else { continue }
                close(at: token.location) { $0 >= token.depth }
                let range = NSRange(location: token.location, length: 0)
                spans.append(StatementSpan(range: range, parent: open.last?.span))
                open.append(OpenStatement(
                    span: spans.count - 1,
                    depth: token.depth,
                    awaitsSetClause: awaitsSetClause(at: index, in: tokens)
                ))
            }
        }
        close(at: length) { _ in true }
        return spans
    }

    /// Each statement's text without the statements nested in it, so every character is tiered once however deep the
    /// nesting goes. Read whole at every level, 100 KB of nested `SELECT`s took 45 seconds to classify.
    private static func ownTexts(of spans: [StatementSpan], in text: NSString) -> [String] {
        var nested = [[NSRange]](repeating: [], count: spans.count)
        for span in spans {
            guard let parent = span.parent else { continue }
            nested[parent].append(span.range)
        }
        return spans.indices.map { index in
            let range = spans[index].range
            var own = ""
            var cursor = range.location
            for child in nested[index] {
                own += text.substring(with: NSRange(location: cursor, length: child.location - cursor))
                cursor = NSMaxRange(child)
            }
            return own + text.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
    }
}

/// T-SQL's words, literals, parentheses and terminators. A comment is nothing, as it is to the server.
enum TSQLTokens {
    struct Token {
        enum Kind: Equatable {
            case word(String)
            case name

            /// A string or a quoted identifier. It stands between the words on either side, so `UPDATE [t] SET` is
            /// never read as the `UPDATE SET` of a foreign key, nor `SELECT [a], [b]` as a list of permissions.
            case quoted
            case open
            case close
            case terminator
            case comma
            case other
        }

        let kind: Kind
        let location: Int

        /// How many parentheses are open around the token. A `(` counts the ones outside it, a `)` the ones left open
        /// once it closes.
        let depth: Int

        var word: String? {
            guard case .word(let text) = kind else { return nil }
            return text
        }
    }

    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let plus = UInt16(UnicodeScalar("+").value)
    private static let at = UInt16(UnicodeScalar("@").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let smallE = UInt16(UnicodeScalar("e").value)
    private static let capitalE = UInt16(UnicodeScalar("E").value)
    private static let smallX = UInt16(UnicodeScalar("x").value)
    private static let capitalX = UInt16(UnicodeScalar("X").value)
    private static let digitZero = UInt16(UnicodeScalar("0").value)
    private static let hexLetters = Set("abcdefABCDEF".utf16)

    /// Words and numbers are read from the code projection, where every comment and literal is blank, so none runs
    /// into a span ``SQLNonCodeSpan`` found.
    static func read(_ text: NSString, grammar: SQLLexicalGrammar) -> [Token] {
        let code = SQLCodeProjection.code(of: text as String, grammar: grammar) as NSString
        let length = code.length
        var tokens: [Token] = []
        var depth = 0
        var index = 0
        while index < length {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                if span.kind == .quoted {
                    tokens.append(Token(kind: .quoted, location: index, depth: depth))
                }
                index = max(span.end, index + 1)
                continue
            }
            let blank = StatementBlank.blankLength(in: code, at: index)
            if blank > 0 {
                index += blank
                continue
            }
            let unit = code.character(at: index)
            if unit == SqlLexer.openParen {
                tokens.append(Token(kind: .open, location: index, depth: depth))
                depth += 1
                index += 1
            } else if unit == SqlLexer.closeParen {
                depth = max(0, depth - 1)
                tokens.append(Token(kind: .close, location: index, depth: depth))
                index += 1
            } else if startsNumber(code, at: index, length: length) {
                tokens.append(Token(kind: .other, location: index, depth: depth))
                index = endOfNumber(code, from: index, length: length)
            } else if startsWord(code, at: index) {
                let end = endOfWord(code, from: index, length: length)
                let word = code.substring(with: NSRange(location: index, length: end - index))
                tokens.append(Token(kind: wordKind(word), location: index, depth: depth))
                index = end
            } else {
                tokens.append(Token(kind: symbolKind(unit), location: index, depth: depth))
                index += StatementBlank.scalar(in: code, at: index).map { $0.utf16.count } ?? 1
            }
        }
        return tokens
    }

    /// A word in capitals when it is spelled in ASCII, which a keyword always is. A word with a letter outside ASCII
    /// is a name and is never compared with one, because Swift reads `CHEC\u{212A}POINT` as equal to `CHECKPOINT`.
    private static func wordKind(_ text: String) -> Token.Kind {
        text.utf16.allSatisfy { $0 < 0x80 } ? .word(text.uppercased()) : .name
    }

    private static func symbolKind(_ unit: UInt16) -> Token.Kind {
        switch unit {
        case SqlLexer.semicolon: return .terminator
        case comma: return .comma
        default: return .other
        }
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= digitZero && unit <= digitZero + 9
    }

    private static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || hexLetters.contains(unit)
    }

    private static func startsNumber(_ code: NSString, at index: Int, length: Int) -> Bool {
        let unit = code.character(at: index)
        if isDigit(unit) { return true }
        return unit == period && index + 1 < length && isDigit(code.character(at: index + 1))
    }

    /// A number runs as T-SQL reads one: `0x` and its hex digits, or digits, a `.` and digits, then an `e` with an
    /// optional sign and digits. The exponent's digits are optional, which is why `1EXEC` is a number and a name.
    private static func endOfNumber(_ code: NSString, from start: Int, length: Int) -> Int {
        var cursor = start
        func advance(while matches: (UInt16) -> Bool) {
            while cursor < length, matches(code.character(at: cursor)) {
                cursor += 1
            }
        }
        if code.character(at: cursor) == digitZero, cursor + 1 < length,
           [smallX, capitalX].contains(code.character(at: cursor + 1)) {
            cursor += 2
            advance(while: isHexDigit)
            return cursor
        }
        advance(while: isDigit)
        if cursor < length, code.character(at: cursor) == period {
            cursor += 1
            advance(while: isDigit)
        }
        guard cursor < length, [smallE, capitalE].contains(code.character(at: cursor)) else { return cursor }
        cursor += 1
        if cursor < length, [plus, SqlLexer.dash].contains(code.character(at: cursor)) {
            cursor += 1
        }
        advance(while: isDigit)
        return cursor
    }

    private static func startsWord(_ code: NSString, at index: Int) -> Bool {
        let unit = code.character(at: index)
        return SqlDollarQuote.isIdentifierStart(unit) || unit == at || unit == SqlLexer.hash
            || isLetterOutsideASCII(code, at: index)
    }

    private static func endOfWord(_ code: NSString, from start: Int, length: Int) -> Int {
        var cursor = start
        while cursor < length {
            let unit = code.character(at: cursor)
            if SqlDollarQuote.isIdentifierPart(unit) || unit == at || unit == SqlLexer.hash || unit == dollar {
                cursor += 1
                continue
            }
            guard isLetterOutsideASCII(code, at: cursor), let scalar = StatementBlank.scalar(in: code, at: cursor)
            else { break }
            cursor += scalar.utf16.count
        }
        return cursor
    }

    private static func isLetterOutsideASCII(_ code: NSString, at index: Int) -> Bool {
        guard code.character(at: index) >= 0x80, let scalar = StatementBlank.scalar(in: code, at: index) else {
            return false
        }
        return scalar.properties.isAlphabetic
    }
}
