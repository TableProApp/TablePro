import Foundation

/// One value bound to a `?` placeholder, in the three shapes a cell can arrive in.
public enum MSSQLParameter: Equatable, Sendable {
    case null
    case text(String)
    case bytes(Data)
}

/// Binds the values of a `?`-placeholder query the way SQL Server takes them, declaring each parameter as the type its
/// value actually is.
///
/// Every parameter used to be declared `NVARCHAR(MAX)` and assigned from the value's text. A
/// binary value has no text, so it was assigned `NULL`: a row matched on a `VARBINARY` column
/// found nothing, and the delete or update that followed reported success having touched no row.
/// A `VARBINARY(MAX)` parameter assigned a `0x…` literal is what that value is.
public enum MSSQLParameterBatch {
    public struct Statement: Equatable, Sendable {
        public let query: String
        public let declarations: String
        public let assignments: String

        public var isEmpty: Bool { declarations.isEmpty }

        /// The call that runs `query` with its parameters bound, one scope down from the batch that sends it.
        public var executeSqlText: String {
            "EXEC sp_executesql N'\(MSSQLStringLiteral.escaped(query))', N'\(declarations)', \(assignments)"
        }
    }

    /// The prefix of every generated parameter name. `sp_executesql` declares its parameters in the same scope as the
    /// text it runs, so a name the text declares itself collides: measured, a batch holding `DECLARE @p1 INT` failed
    /// with Msg 134 "The variable name '@p1' has already been declared" once the generated names were `@p1`.
    public static let parameterNamePrefix = "@__tablepro_p"

    public static func spExecuteSql(query: String, parameters: [MSSQLParameter]) -> Statement {
        let replaced = replacePlaceholders(in: query, limit: parameters.count)
        guard replaced.placeholderCount > 0 else {
            return Statement(query: replaced.query, declarations: "", assignments: "")
        }
        let used = parameters.prefix(replaced.placeholderCount)
        let declarations = used.enumerated()
            .map { "\(parameterName($0.offset)) \(declaredType(of: $0.element))" }
            .joined(separator: ", ")
        let assignments = used.enumerated()
            .map { "\(parameterName($0.offset)) = \(literal(for: $0.element))" }
            .joined(separator: ", ")
        return Statement(query: replaced.query, declarations: declarations, assignments: assignments)
    }

    /// What a batch run sends for `query` with `parameters` bound, or nil when it binds nothing.
    ///
    /// The values are declared at the head of the batch itself. `sp_executesql` runs its text one scope down, so a batch
    /// wrapped whole in it is a different batch: measured, a `BEGIN TRAN` inside it fails with Msg 266 because the
    /// transaction count changed across the call, and a `#temp` table, a `USE` or a `SET` made inside it are gone when
    /// it returns. A batch that can only run as the first statement of its batch (``needsBatchOfItsOwn(_:)``) would fail
    /// behind a declaration, so that one alone is still wrapped, where it is the first statement of the dynamic batch.
    ///
    /// The declaration shares the batch's first line. The server counts only a line feed as a new line (measured: a
    /// carriage return, U+2028, U+0085, a vertical tab and a form feed inside a literal leave the count where it was),
    /// so a value holding line feeds moves the batch down by ``BoundBatch/leadingLineFeeds`` lines.
    public static func boundBatch(query: String, parameters: [MSSQLParameter]) -> BoundBatch? {
        guard !needsBatchOfItsOwn(query) else {
            let statement = spExecuteSql(query: query, parameters: parameters)
            guard !statement.isEmpty else { return nil }
            return BoundBatch(text: statement.executeSqlText, leadingLineFeeds: 0, prependedStatementCount: 0)
        }
        let replaced = replacePlaceholders(in: query, limit: parameters.count)
        guard replaced.placeholderCount > 0 else { return nil }
        let initialized = parameters.prefix(replaced.placeholderCount).enumerated()
            .map { "\(parameterName($0.offset)) \(declaredType(of: $0.element)) = \(literal(for: $0.element))" }
            .joined(separator: ", ")
        let declaration = "DECLARE \(initialized); "
        let lineFeeds = declaration.utf16.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return BoundBatch(text: declaration + replaced.query, leadingLineFeeds: lineFeeds, prependedStatementCount: 1)
    }

    public struct BoundBatch: Equatable, Sendable {
        public let text: String

        /// Line feeds the binding put in front of the batch's own first line.
        public let leadingLineFeeds: Int

        /// Statements the binding ran ahead of the batch. The declaration reports a row count of 1 for its
        /// initializers, measured, so a reader that sums counts skips this many first.
        public let prependedStatementCount: Int

        /// The line of the batch as written, for a line the server reported against ``text`` outside any procedure.
        public func batchLine(forReportedLine line: Int) -> Int {
            max(line - leadingLineFeeds, 1)
        }
    }

    /// Whether `query` can only run as the first statement of its batch, so nothing may be put in front of it.
    public static func needsBatchOfItsOwn(_ query: String) -> Bool {
        mustStartBatch(query) || callsProcedureWithoutExec(query)
    }

    /// Whether `query` opens with a statement SQL Server accepts only as the first in its batch, which a declaration in
    /// front would turn into Msg 111. Read off its first words, past any comment.
    public static func mustStartBatch(_ query: String) -> Bool {
        let words = leadingWords(of: query, count: 4)
        guard let verb = words.first, verb == "CREATE" || verb == "ALTER" else { return false }
        let createsOrAlters = words.count > 2 && words[1] == "OR" && words[2] == "ALTER"
        let objectIndex = createsOrAlters ? 3 : 1
        guard words.indices.contains(objectIndex) else { return false }
        return batchLeadingObjects.contains(words[objectIndex])
    }

    /// Whether `query` opens with a procedure name rather than a statement, as `sp_help 't'` does, which the server runs
    /// as an `EXECUTE` only while it is the first statement of the batch. A quoted identifier there is one too.
    public static func callsProcedureWithoutExec(_ query: String) -> Bool {
        if let first = firstCodeCharacter(of: query), first == "[" || first == "\"" {
            return true
        }
        guard let word = leadingWords(of: query, count: 1).first else { return false }
        return !MSSQLStatementKeywords.leading.contains(word)
    }

    private static let batchLeadingObjects: Set<String> = [
        "PROCEDURE", "PROC", "FUNCTION", "VIEW", "TRIGGER", "SCHEMA", "DEFAULT", "RULE",
    ]

    private static func firstCodeCharacter(of query: String) -> Character? {
        var state = ScanState.code
        let characters = Array(query)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let pair = next, let entered = state.enteringComment(character, pair) {
                state = entered
                index += 2
                continue
            }
            guard state == .code else {
                state = state.after(character)
                index += 1
                continue
            }
            guard character.isWhitespace else { return character }
            index += 1
        }
        return nil
    }

    private static func leadingWords(of query: String, count: Int) -> [String] {
        var words: [String] = []
        var current = ""
        var state = ScanState.code
        let characters = Array(query)
        var index = 0
        while index < characters.count, words.count < count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let pair = next, let entered = state.enteringComment(character, pair) {
                state = entered
                index += 2
                continue
            }
            guard state == .code else {
                state = state.after(character)
                index += 1
                continue
            }
            if character.isLetter || character == "_" || (!current.isEmpty && continuesIdentifier(character)) {
                current.append(character)
            } else {
                if !current.isEmpty { words.append(current.uppercased()) }
                current = ""
                guard character.isWhitespace else { break }
            }
            index += 1
        }
        if !current.isEmpty, words.count < count { words.append(current.uppercased()) }
        return words
    }

    private static func continuesIdentifier(_ character: Character) -> Bool {
        character.isNumber || character == "@" || character == "#" || character == "$"
    }

    private static func parameterName(_ offset: Int) -> String {
        "\(parameterNamePrefix)\(offset + 1)"
    }

    private static func declaredType(of parameter: MSSQLParameter) -> String {
        switch parameter {
        case .bytes:
            return "VARBINARY(MAX)"
        case .text, .null:
            return "NVARCHAR(MAX)"
        }
    }

    private static func literal(for parameter: MSSQLParameter) -> String {
        switch parameter {
        case .null:
            return "NULL"
        case .text(let value):
            return MSSQLStringLiteral.quoted(value)
        case .bytes(let data):
            return hexLiteral(data)
        }
    }

    /// `0x` on its own is the empty binary, which is what SQL Server writes for one and what it
    /// reads back. There is no zero-length form to special-case.
    private static func hexLiteral(_ data: Data) -> String {
        var literal = "0x"
        literal.reserveCapacity(2 + data.count * 2)
        for byte in data {
            literal.append(String(format: "%02X", byte))
        }
        return literal
    }

    /// A `?` inside a string literal, a quoted identifier or a comment is not a placeholder, and the doubled `''`, `""`
    /// and `]]` that carry a delimiter have to be stepped over rather than read as the end of the literal.
    ///
    /// The bracket is the one T-SQL spells differently from everything else, and it was missing: a column named
    /// `[we?ird]` took the first parameter, which shifted every parameter after it by one and sent the values to the
    /// wrong placeholders. Comments were missing too: an apostrophe in `-- customer's orders` opened a string that
    /// hid every real placeholder after it, and a `?` in `-- why?` took a value meant for the query.
    ///
    /// The `?` marks and their values come from the app's parameter scanner, which turned each `:name` it read as code
    /// into one, so this has to read comments exactly as that scanner does or the k-th value lands on the wrong mark.
    /// It ends a block comment at the first `*/`, although SQL Server nests them: in `/* a /* b */ ? */ ... = ?` it
    /// wrote both marks and sent a value for each, and the server ignoring the first one is harmless where binding the
    /// second one's value to the first is not.
    private static func replacePlaceholders(in query: String, limit: Int) -> (query: String, placeholderCount: Int) {
        var converted = ""
        var count = 0
        var state = ScanState.code
        let characters = Array(query)

        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if let doubled = state.doubledDelimiter, character == doubled, next == doubled {
                converted.append(doubled)
                converted.append(doubled)
                index += 2
                continue
            }

            if let pair = next, let entered = state.enteringComment(character, pair) {
                converted.append(character)
                converted.append(pair)
                state = entered
                index += 2
                continue
            }

            state = state.after(character)

            if character == "?", state == .code, count < limit {
                count += 1
                converted.append(parameterName(count - 1))
            } else {
                converted.append(character)
            }
            index += 1
        }

        return (converted, count)
    }

    private enum ScanState: Equatable {
        case code
        case singleQuote
        case doubleQuote
        case bracket
        case lineComment
        case blockComment

        /// What a doubled occurrence of this state's own delimiter escapes. A bracket identifier
        /// escapes its closing `]`, not the `[` that opened it.
        var doubledDelimiter: Character? {
            switch self {
            case .singleQuote: return "'"
            case .doubleQuote: return "\""
            case .bracket: return "]"
            case .code, .lineComment, .blockComment: return nil
            }
        }

        /// The state two characters move to when they open or close a comment, or nil when they do neither.
        func enteringComment(_ first: Character, _ second: Character) -> ScanState? {
            switch self {
            case .code:
                if first == "-", second == "-" { return .lineComment }
                if first == "/", second == "*" { return .blockComment }
                return nil
            case .blockComment:
                return first == "*" && second == "/" ? .code : nil
            case .singleQuote, .doubleQuote, .bracket, .lineComment:
                return nil
            }
        }

        /// A line comment ends where the app's scanner ends one, at a line feed and nowhere else, so a CRLF ends it
        /// and a lone carriage return, U+2028 or U+0085 does not. `"\r\n"` is one `Character` equal to neither `"\n"`
        /// nor `"\r"`, so the test is whether the character holds a line feed.
        ///
        /// Brackets still read differently: this treats `[...]` as a quoted identifier and the app's scanner does not, so
        /// a `:name` inside brackets is a placeholder to one and not the other. That predates batches.
        func after(_ character: Character) -> ScanState {
            switch self {
            case .code:
                switch character {
                case "'": return .singleQuote
                case "\"": return .doubleQuote
                case "[": return .bracket
                default: return .code
                }
            case .singleQuote:
                return character == "'" ? .code : self
            case .doubleQuote:
                return character == "\"" ? .code : self
            case .bracket:
                return character == "]" ? .code : self
            case .lineComment:
                return character.unicodeScalars.contains("\n") ? .code : self
            case .blockComment:
                return self
            }
        }
    }
}
