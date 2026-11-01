import Foundation

/// The one lexer: where a comment, a literal or a quoted identifier that starts at an offset ends, read by an engine's
/// ``SQLLexicalGrammar``.
///
/// Everything that has to know where code stops asks here: the statement scanner, the folding scanner, the token
/// cursor, the row-limit detector, the code-only projection the classifiers read, and the diagnostics. Two readers
/// that disagree about where a string ends can disagree about where a statement ends, and the gate that tiers one
/// statement would then let the engine run two.
public enum SQLNonCodeSpan {
    public enum Kind: Sendable, Equatable {
        case lineComment
        case blockComment

        /// MySQL's `/*! ... */`, whose body the server runs. It is code to a reader of statements, and one opaque
        /// token to a reader of boundaries.
        case executableComment

        /// A string, a dollar-quoted body, or a quoted identifier: one token nothing inside can end early.
        case quoted

        /// SQLite's `$name(...)` parameter, which swallows quotes and semicolons up to its `)`.
        case parameter

        public var isComment: Bool {
            self == .lineComment || self == .blockComment
        }
    }

    public struct Span: Sendable, Equatable {
        public let kind: Kind
        public let start: Int

        /// Past the closing delimiter, or the end of the text when the span never closes.
        public let end: Int

        /// Where the body stops, before the closing delimiter.
        public let contentEnd: Int

        /// Line feeds inside the span. A line comment ends at its line feed and does not count it.
        public let newlines: Int

        /// False when the text ended before the span's closing delimiter, so everything after its start is inside it.
        public let isTerminated: Bool

        public init(kind: Kind, start: Int, end: Int, contentEnd: Int, newlines: Int, isTerminated: Bool) {
            self.kind = kind
            self.start = start
            self.end = end
            self.contentEnd = contentEnd
            self.newlines = newlines
            self.isTerminated = isTerminated
        }
    }

    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let capitalE = UInt16(UnicodeScalar("E").value)
    private static let smallE = UInt16(UnicodeScalar("e").value)
    private static let smallB = UInt16(UnicodeScalar("b").value)

    /// The comment, literal or quoted identifier starting at `index`, or nil when `index` starts code.
    public static func span(at index: Int, in text: NSString, grammar: SQLLexicalGrammar) -> Span? {
        let length = text.length
        guard index >= 0, index < length else { return nil }
        let character = text.character(at: index)

        if let comment = commentSpan(at: index, character: character, in: text, length: length, grammar: grammar) {
            return comment
        }
        if grammar.isQuote(character) {
            return quotedSpan(at: index, quote: character, in: text, length: length, grammar: grammar)
        }
        if grammar.contains(.bracketQuotedIdentifiers), character == openBracket {
            let span = SqlLexer.skipBracketedIdentifier(
                text,
                from: index,
                length: length,
                doubledCloseEscapes: grammar.contains(.doubledClosingBracketEscapes)
            )
            return closedSpan(.quoted, at: index, span, closerLength: 1)
        }
        if grammar.contains(.angleQuotedIdentifiers), character == SqlLexer.openAngleQuote {
            let span = SqlLexer.skipAngleQuotedIdentifier(
                text,
                from: index,
                length: length,
                backslashEscapes: grammar.contains(.backslashEscapesInAngleQuotes)
            )
            return closedSpan(.quoted, at: index, span, closerLength: 1)
        }
        if let prefixed = prefixedLiteralSpan(at: index, character: character, in: text, length: length, grammar: grammar) {
            return prefixed
        }
        if character == SqlDollarQuote.dollar, let dollar = dollarQuotedSpan(at: index, in: text, grammar: grammar) {
            return dollar
        }
        guard grammar.contains(.parenthesizedParameterNames),
              let parameter = SqlLexer.skipParenthesizedParameterName(text, at: index, length: length)
        else {
            return nil
        }
        return Span(
            kind: .parameter,
            start: index,
            end: parameter.next,
            contentEnd: parameter.next,
            newlines: 0,
            isTerminated: parameter.isClosed
        )
    }

    /// Where the span starting at `index` ends, or nil when `index` starts code. An executable comment is code, so it
    /// answers nil: the reader walks into it and reads its body.
    public static func end(at index: Int, in text: NSString, grammar: SQLLexicalGrammar) -> Int? {
        guard let span = span(at: index, in: text, grammar: grammar), span.kind != .executableComment else {
            return nil
        }
        return span.end
    }

    /// Whether `unit` continues a word, so a prefix like `E` or `q` glued to it is part of an identifier rather than
    /// the start of a literal.
    public static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit < 0x80 {
            return SqlDollarQuote.isIdentifierPart(unit)
        }
        return !SQLSeparatingCharacter.isSeparating(unit)
    }

    // MARK: - Comments

    private static func commentSpan(
        at index: Int,
        character: UInt16,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> Span? {
        if startsLineComment(at: index, character: character, in: text, length: length, grammar: grammar) {
            let end = SqlLexer.endOfLineComment(
                text,
                from: index,
                length: length,
                carriageReturnEnds: grammar.contains(.carriageReturnEndsLineComments),
                formFeedEnds: grammar.contains(.formFeedEndsLineComments)
            )
            return Span(kind: .lineComment, start: index, end: end, contentEnd: end, newlines: 0, isTerminated: true)
        }
        guard SqlLexer.startsBlockComment(text, at: index, length: length) else { return nil }
        if grammar.contains(.executableComments),
           let opener = SqlLexer.executableCommentOpenerLength(text, at: index, length: length) {
            return executableCommentSpan(at: index, openerLength: opener, in: text, length: length, grammar: grammar)
        }
        let comment = plainBlockComment(at: index, in: text, length: length, grammar: grammar)
        return closedSpan(.blockComment, at: index, comment, closerLength: 2)
    }

    private static func plainBlockComment(
        at index: Int,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> SqlLexer.Span {
        grammar.contains(.nestedBlockComments)
            ? SqlLexer.skipNestedBlockComment(text, from: index, length: length)
            : SqlLexer.skipBlockComment(text, from: index, length: length)
    }

    // The server lexes a run body as code, comments included, and a nested opener opens no second level: the first
    // `*/` read as code closes the comment. Measured on MySQL 8.0 and 8.4 and MariaDB 10.11 and 11.4.
    private static func executableCommentSpan(
        at index: Int,
        openerLength: Int,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> Span {
        var cursor = index + openerLength
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == SqlLexer.star, cursor + 1 < length, text.character(at: cursor + 1) == SqlLexer.slash {
                return Span(
                    kind: .executableComment,
                    start: index,
                    end: cursor + 2,
                    contentEnd: cursor,
                    newlines: newlines,
                    isTerminated: true
                )
            }
            if SqlLexer.startsBlockComment(text, at: cursor, length: length) {
                if let nested = SqlLexer.executableCommentOpenerLength(text, at: cursor, length: length) {
                    cursor += nested
                    continue
                }
                let comment = plainBlockComment(at: cursor, in: text, length: length, grammar: grammar)
                newlines += comment.newlines
                cursor = comment.next
                continue
            }
            if let inner = span(at: cursor, in: text, grammar: grammar) {
                newlines += inner.newlines
                cursor = max(inner.end, cursor + 1)
                continue
            }
            if character == SqlLexer.newline {
                newlines += 1
            }
            cursor += 1
        }
        return Span(
            kind: .executableComment,
            start: index,
            end: length,
            contentEnd: length,
            newlines: newlines,
            isTerminated: false
        )
    }

    private static func startsLineComment(
        at index: Int,
        character: UInt16,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        if character == SqlLexer.dash {
            guard !grammar.contains(.withoutDashComments), SqlLexer.startsDashComment(
                text,
                at: index,
                length: length,
                needsWhitespace: grammar.contains(.dashCommentsNeedWhitespace)
            ) else { return false }
            return !grammar.contains(.exponentSignsNeedNoDigits) || !TSQLTokens.signsExponent(at: index, in: text)
        }
        if character == SqlLexer.hash {
            return grammar.contains(.hashLineComments)
        }
        guard character == SqlLexer.slash, grammar.contains(.doubleSlashLineComments) else { return false }
        return SqlLexer.startsDoubleSlash(text, at: index, length: length)
    }

    // MARK: - Literals

    private static func quotedSpan(
        at index: Int,
        quote: UInt16,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> Span {
        let backslashEscapes = grammar.backslashEscapes(inQuote: quote)
        if grammar.contains(.tripleQuotedStrings), SqlLexer.startsTripleQuote(text, at: index, length: length) {
            let span = SqlLexer.skipTripleQuotedString(
                text,
                from: index,
                length: length,
                backslashEscapes: backslashEscapes
            )
            return closedSpan(.quoted, at: index, span, closerLength: 3)
        }
        let span = SqlLexer.skipQuotedString(
            text,
            from: index,
            quote: quote,
            length: length,
            backslashEscapes: backslashEscapes
        )
        return closedSpan(.quoted, at: index, span, closerLength: 1)
    }

    /// `E'...'`, `b'...'` and `q'[...]'`, which only start where a word could: `xE'` is an identifier followed by a
    /// string.
    private static func prefixedLiteralSpan(
        at index: Int,
        character: UInt16,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> Span? {
        guard index == 0 || !isWordUnit(text.character(at: index - 1)) else { return nil }
        let startsEscapeString = grammar.contains(.escapeStringPrefix) && (character == capitalE || character == smallE)
        let startsEscapeBytes = grammar.contains(.escapeBytesPrefix) && character == smallB
        if startsEscapeString || startsEscapeBytes,
           index + 1 < length,
           text.character(at: index + 1) == SqlLexer.singleQuote {
            let span = SqlLexer.skipQuotedString(
                text,
                from: index + 1,
                quote: SqlLexer.singleQuote,
                length: length,
                backslashEscapes: true
            )
            return closedSpan(.quoted, at: index, span, closerLength: 1)
        }
        guard grammar.contains(.alternativeQuoting),
              let literal = SqlLexer.skipAlternativeQuotedString(text, at: index, length: length)
        else {
            return nil
        }
        return Span(
            kind: .quoted,
            start: index,
            end: literal.span.next,
            contentEnd: literal.bodyEnd,
            newlines: literal.span.newlines,
            isTerminated: literal.span.isClosed
        )
    }

    private static func dollarQuotedSpan(at index: Int, in text: NSString, grammar: SQLLexicalGrammar) -> Span? {
        let length = text.length
        guard let style = grammar.dollarQuoteStyle,
              case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(
                  at: index,
                  in: text,
                  bufLen: length,
                  style: style
              )
        else {
            return nil
        }
        let body = SqlLexer.skipDollarQuotedBody(text, from: index + openerLength, tag: tag, length: length)
        return Span(
            kind: .quoted,
            start: index,
            end: body.span.next,
            contentEnd: body.bodyEnd,
            newlines: body.span.newlines,
            isTerminated: body.span.isClosed
        )
    }

    /// A span whose closer is `closerLength` units long. One that ran to the end of the text without a closer runs its
    /// content to the end of the text.
    private static func closedSpan(_ kind: Kind, at start: Int, _ span: SqlLexer.Span, closerLength: Int) -> Span {
        Span(
            kind: kind,
            start: start,
            end: span.next,
            contentEnd: span.isClosed ? max(start, span.next - closerLength) : span.next,
            newlines: span.newlines,
            isTerminated: span.isClosed
        )
    }
}
