import Foundation

/// The character level pieces every SQL scanner is built from: which UTF-16 units matter, and how far one comment,
/// quoted string or dollar quoted body runs once its kind is known.
///
/// Which kind starts at an offset is ``SQLNonCodeSpan``'s decision, made from an ``SQLLexicalGrammar``; these
/// functions only run a span to its end. Offsets are UTF-16 units, so an `NSString` can be walked in constant time per
/// character.
public enum SqlLexer {
    public static let space = UInt16(UnicodeScalar(" ").value)
    public static let tab = UInt16(UnicodeScalar("\t").value)
    public static let newline = UInt16(UnicodeScalar("\n").value)
    public static let carriageReturn = UInt16(UnicodeScalar("\r").value)
    public static let singleQuote = UInt16(UnicodeScalar("'").value)
    public static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    public static let backtick = UInt16(UnicodeScalar("`").value)
    public static let backslash = UInt16(UnicodeScalar("\\").value)
    public static let dash = UInt16(UnicodeScalar("-").value)
    public static let slash = UInt16(UnicodeScalar("/").value)
    public static let star = UInt16(UnicodeScalar("*").value)
    public static let hash = UInt16(UnicodeScalar("#").value)
    public static let semicolon = UInt16(UnicodeScalar(";").value)
    public static let openParen = UInt16(UnicodeScalar("(").value)
    public static let closeParen = UInt16(UnicodeScalar(")").value)
    public static let exclamationMark = UInt16(UnicodeScalar("!").value)
    public static let smallQ = UInt16(UnicodeScalar("q").value)
    public static let capitalQ = UInt16(UnicodeScalar("Q").value)
    public static let smallN = UInt16(UnicodeScalar("n").value)
    public static let capitalN = UInt16(UnicodeScalar("N").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let openBrace = UInt16(UnicodeScalar("{").value)
    private static let closeBrace = UInt16(UnicodeScalar("}").value)
    private static let lessThan = UInt16(UnicodeScalar("<").value)
    private static let greaterThan = UInt16(UnicodeScalar(">").value)

    /// How far a scan ran, and how many lines it crossed. A caller that does not track lines ignores `newlines`.
    /// `isClosed` is false when the text ended before the closing delimiter.
    public struct Span: Sendable {
        public let next: Int
        public let newlines: Int
        public let isClosed: Bool

        public init(next: Int, newlines: Int, isClosed: Bool = true) {
            self.next = next
            self.newlines = newlines
            self.isClosed = isClosed
        }
    }

    public static func isWhitespace(_ character: UInt16) -> Bool {
        character == space || character == tab || character == newline || character == carriageReturn
    }

    public static func isQuote(_ character: UInt16) -> Bool {
        character == singleQuote || character == doubleQuote || character == backtick
    }

    public static func startsLineComment(_ text: NSString, at offset: Int, length: Int) -> Bool {
        text.character(at: offset) == dash && offset + 1 < length && text.character(at: offset + 1) == dash
    }

    public static func startsBlockComment(_ text: NSString, at offset: Int, length: Int) -> Bool {
        text.character(at: offset) == slash && offset + 1 < length && text.character(at: offset + 1) == star
    }

    /// A MySQL conditional comment, whose body is executed rather than ignored.
    public static func startsConditionalComment(_ text: NSString, at offset: Int, length: Int) -> Bool {
        startsBlockComment(text, at: offset, length: length)
            && offset + 2 < length
            && text.character(at: offset + 2) == exclamationMark
    }

    /// The offset of the newline that ends the line, or the end of the document.
    public static func endOfLine(_ text: NSString, from offset: Int, length: Int) -> Int {
        var cursor = min(offset, length)
        while cursor < length, text.character(at: cursor) != newline {
            cursor += 1
        }
        return cursor
    }

    /// Runs past `*/`, or to the end of the document when the comment is never closed.
    public static func skipBlockComment(_ text: NSString, from offset: Int, length: Int) -> Span {
        var cursor = offset + 2
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if character == star, cursor + 1 < length, text.character(at: cursor + 1) == slash {
                return Span(next: cursor + 2, newlines: newlines)
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines, isClosed: false)
    }

    public static func skipNestedBlockComment(_ text: NSString, from offset: Int, length: Int) -> Span {
        var cursor = offset + 2
        var depth = 1
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if startsBlockComment(text, at: cursor, length: length) {
                depth += 1
                cursor += 2
                continue
            }
            if character == star, cursor + 1 < length, text.character(at: cursor + 1) == slash {
                depth -= 1
                cursor += 2
                guard depth > 0 else { return Span(next: cursor, newlines: newlines) }
                continue
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines, isClosed: false)
    }

    /// Runs past the closing quote, or to the end of the document when the string is never closed.
    ///
    /// A doubled quote always escapes. A backslash only escapes where the grammar says it does, so `'a\'` ends the
    /// string on PostgreSQL and continues it on MySQL.
    public static func skipQuotedString(
        _ text: NSString,
        from offset: Int,
        quote: UInt16,
        length: Int,
        backslashEscapes: Bool
    ) -> Span {
        var cursor = offset + 1
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if backslashEscapes, character == backslash, cursor + 1 < length {
                cursor += 2
                continue
            }
            if character == quote {
                if cursor + 1 < length, text.character(at: cursor + 1) == quote {
                    cursor += 2
                    continue
                }
                return Span(next: cursor + 1, newlines: newlines)
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines, isClosed: false)
    }

    /// Runs past an Oracle `q'<delim>...<delim>'` literal, or its national form `nq'...'`, when one starts at
    /// `offset`.
    ///
    /// The body ends at the closing delimiter followed by a quote, so `q'[it's]'` is one literal although a plain scan
    /// would end it at `it'`. Bracket-like delimiters close with their partner. Returns nil when `offset` does not
    /// start one; a caller must only ask at the start of a word, because `xq'` is an identifier followed by a string.
    public static func skipAlternativeQuotedString(_ text: NSString, at offset: Int, length: Int) -> Span? {
        var cursor = offset
        let first = text.character(at: cursor)
        if first == smallN || first == capitalN {
            cursor += 1
        }
        guard cursor + 2 < length else { return nil }
        let prefix = text.character(at: cursor)
        guard prefix == smallQ || prefix == capitalQ, text.character(at: cursor + 1) == singleQuote else { return nil }
        let opener = text.character(at: cursor + 2)
        guard !isWhitespace(opener) else { return nil }
        let closer = alternativeQuoteCloser(for: opener)
        cursor += 3
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if character == closer, cursor + 1 < length, text.character(at: cursor + 1) == singleQuote {
                return Span(next: cursor + 2, newlines: newlines)
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines, isClosed: false)
    }

    private static func alternativeQuoteCloser(for opener: UInt16) -> UInt16 {
        switch opener {
        case openBracket: return closeBracket
        case openParen: return closeParen
        case openBrace: return closeBrace
        case lessThan: return greaterThan
        default: return opener
        }
    }

    /// Runs to the closing `$tag$`. `bodyEnd` is where the body stops, `next` is past the closing tag.
    public static func skipDollarQuotedBody(
        _ text: NSString,
        from bodyStart: Int,
        tag: String,
        length: Int
    ) -> (bodyEnd: Int, span: Span) {
        var cursor = bodyStart
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if character == SqlDollarQuote.dollar,
               SqlDollarQuote.matchesClose(at: cursor, tag: tag, in: text, bufLen: length) {
                let next = cursor + (tag as NSString).length + 2
                return (cursor, Span(next: next, newlines: newlines))
            }
            cursor += 1
        }
        return (length, Span(next: length, newlines: newlines, isClosed: false))
    }

    /// Whether `--` at `offset` starts a comment. MySQL and MariaDB read `--` as a comment only when a space or a
    /// control character follows it, measured on 8.4 and 11.8 as `SELECT 1--1` returning 2.
    public static func startsDashComment(_ text: NSString, at offset: Int, length: Int, needsWhitespace: Bool) -> Bool {
        guard startsLineComment(text, at: offset, length: length) else { return false }
        guard needsWhitespace, offset + 2 < length else { return true }
        return text.character(at: offset + 2) <= space
    }

    /// Whether `//` starts at `offset`.
    public static func startsDoubleSlash(_ text: NSString, at offset: Int, length: Int) -> Bool {
        text.character(at: offset) == slash && offset + 1 < length && text.character(at: offset + 1) == slash
    }

    /// The offset of the line break that ends a line comment, or the end of the document.
    public static func endOfLineComment(
        _ text: NSString,
        from offset: Int,
        length: Int,
        carriageReturnEnds: Bool
    ) -> Int {
        var cursor = min(offset, length)
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline || (carriageReturnEnds && character == carriageReturn) {
                return cursor
            }
            cursor += 1
        }
        return cursor
    }

    /// The length of a MySQL `/*!NNNNN` or MariaDB `/*M!NNNNN` opener at `offset`, or nil when none starts there.
    public static func executableCommentOpenerLength(_ text: NSString, at offset: Int, length: Int) -> Int? {
        guard startsBlockComment(text, at: offset, length: length) else { return nil }
        var cursor = offset + 2
        if cursor < length, text.character(at: cursor) == capitalM || text.character(at: cursor) == smallM {
            cursor += 1
        }
        guard cursor < length, text.character(at: cursor) == exclamationMark else { return nil }
        cursor += 1
        while cursor < length, isDigit(text.character(at: cursor)) {
            cursor += 1
        }
        return cursor - offset
    }

    /// Runs past a `[...]` identifier. With `doubledCloseEscapes`, `]]` stands for one `]`, as T-SQL reads it; SQLite
    /// ends the identifier at the first `]`.
    public static func skipBracketedIdentifier(
        _ text: NSString,
        from offset: Int,
        length: Int,
        doubledCloseEscapes: Bool
    ) -> Span {
        var cursor = offset + 1
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            guard character == closeBracket else {
                cursor += 1
                continue
            }
            guard doubledCloseEscapes, cursor + 1 < length, text.character(at: cursor + 1) == closeBracket else {
                return Span(next: cursor + 1, newlines: newlines)
            }
            cursor += 2
        }
        return Span(next: length, newlines: newlines, isClosed: false)
    }

    /// Whether three of `quote` start at `offset`, which opens a GoogleSQL triple-quoted literal.
    public static func startsTripleQuote(_ text: NSString, at offset: Int, length: Int) -> Bool {
        let quote = text.character(at: offset)
        guard quote == singleQuote || quote == doubleQuote, offset + 2 < length else { return false }
        return text.character(at: offset + 1) == quote && text.character(at: offset + 2) == quote
    }

    /// Runs past a triple-quoted literal starting at `offset`, which only three of its own quote end.
    public static func skipTripleQuotedString(
        _ text: NSString,
        from offset: Int,
        length: Int,
        backslashEscapes: Bool
    ) -> Span {
        let quote = text.character(at: offset)
        var cursor = offset + 3
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if backslashEscapes, character == backslash, cursor + 1 < length {
                cursor += 2
                continue
            }
            if character == quote, cursor + 2 < length,
               text.character(at: cursor + 1) == quote, text.character(at: cursor + 2) == quote {
                return Span(next: cursor + 3, newlines: newlines)
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines, isClosed: false)
    }

    /// Runs past SQLite's Tcl-style parameter `$name(...)`, `@name(...)`, `:name(...)` or `#name(...)` starting at
    /// `offset`, or returns nil when none starts there.
    ///
    /// SQLite's tokenizer takes everything from the `(` to the first `)` or whitespace as part of the name, quotes
    /// and semicolons included, so `$a('); DROP TABLE t; --'` is the parameter `$a(')` followed by a `DROP` the server
    /// runs, measured on 3.54 for all four prefixes. A name that meets whitespace first is an illegal token, which ends
    /// where the whitespace starts. `::` continues a name, as in `$a::b(...)`.
    public static func skipParenthesizedParameterName(_ text: NSString, at offset: Int, length: Int) -> Span? {
        guard parameterPrefixes.contains(text.character(at: offset)) else { return nil }
        var cursor = offset + 1
        while cursor < length {
            let character = text.character(at: cursor)
            if isSQLiteIdentifierCharacter(character) {
                cursor += 1
                continue
            }
            guard character == colonUnit, cursor + 1 < length, text.character(at: cursor + 1) == colonUnit else { break }
            cursor += 2
        }
        guard cursor > offset + 1, cursor < length, text.character(at: cursor) == openParen else { return nil }
        cursor += 1
        while cursor < length {
            let character = text.character(at: cursor)
            if character == closeParen {
                return Span(next: cursor + 1, newlines: 0)
            }
            if character <= space {
                return Span(next: cursor, newlines: 0, isClosed: false)
            }
            cursor += 1
        }
        return Span(next: length, newlines: 0, isClosed: false)
    }

    /// Runs past a MySQL executable comment whose opener is `openerLength` long. The server lexes the body as SQL, so
    /// a `*/` inside a quoted string does not close it, measured on 8.4 and 11.8 with `/*! , '*/' */`.
    public static func skipExecutableComment(
        _ text: NSString,
        from offset: Int,
        openerLength: Int,
        length: Int,
        backslashEscapes: (UInt16) -> Bool
    ) -> Span {
        var cursor = offset + openerLength
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if character == star, cursor + 1 < length, text.character(at: cursor + 1) == slash {
                return Span(next: cursor + 2, newlines: newlines)
            }
            if character == singleQuote || character == doubleQuote || character == backtick {
                let quoted = skipQuotedString(
                    text,
                    from: cursor,
                    quote: character,
                    length: length,
                    backslashEscapes: backslashEscapes(character)
                )
                newlines += quoted.newlines
                cursor = quoted.next
                continue
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines, isClosed: false)
    }

    private static let smallM = UInt16(UnicodeScalar("m").value)
    private static let capitalM = UInt16(UnicodeScalar("M").value)
    private static let digitZero = UInt16(UnicodeScalar("0").value)
    private static let digitNine = UInt16(UnicodeScalar("9").value)
    private static let colonUnit = UInt16(UnicodeScalar(":").value)
    private static let parameterPrefixes: Set<UInt16> = [
        SqlDollarQuote.dollar,
        UInt16(UnicodeScalar("@").value),
        UInt16(UnicodeScalar(":").value),
        UInt16(UnicodeScalar("#").value),
    ]

    private static func isDigit(_ character: UInt16) -> Bool {
        character >= digitZero && character <= digitNine
    }

    /// SQLite's `IdChar`: ASCII letters, digits, `_`, `$`, and every unit from 0x80 up.
    private static func isSQLiteIdentifierCharacter(_ character: UInt16) -> Bool {
        SqlDollarQuote.isIdentifierPart(character) || character == SqlDollarQuote.dollar || character >= 0x80
    }
}
