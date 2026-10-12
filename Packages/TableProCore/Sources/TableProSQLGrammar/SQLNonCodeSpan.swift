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
                carriageReturnEnds: grammar.contains(.carriageReturnEndsLineComments)
            )
            return Span(kind: .lineComment, start: index, end: end, contentEnd: end, newlines: 0, isTerminated: true)
        }
        guard SqlLexer.startsBlockComment(text, at: index, length: length) else { return nil }
        if grammar.contains(.executableComments),
           let opener = SqlLexer.executableCommentOpenerLength(text, at: index, length: length) {
            let span = SqlLexer.skipExecutableComment(
                text,
                from: index,
                openerLength: opener,
                length: length,
                backslashEscapes: grammar.backslashEscapes(inQuote:)
            )
            return closedSpan(.executableComment, at: index, span, closerLength: 2)
        }
        let span = grammar.contains(.nestedBlockComments)
            ? SqlLexer.skipNestedBlockComment(text, from: index, length: length)
            : SqlLexer.skipBlockComment(text, from: index, length: length)
        return closedSpan(.blockComment, at: index, span, closerLength: 2)
    }

    private static func startsLineComment(
        at index: Int,
        character: UInt16,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        if character == SqlLexer.dash {
            return SqlLexer.startsDashComment(
                text,
                at: index,
                length: length,
                needsWhitespace: grammar.contains(.dashCommentsNeedWhitespace)
            )
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

    /// `E'...'` and `q'[...]'`, which only start where a word could: `xE'` is an identifier followed by a string.
    private static func prefixedLiteralSpan(
        at index: Int,
        character: UInt16,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> Span? {
        guard index == 0 || !isWordUnit(text.character(at: index - 1)) else { return nil }
        if grammar.contains(.escapeStringPrefix),
           character == capitalE || character == smallE,
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
              let span = SqlLexer.skipAlternativeQuotedString(text, at: index, length: length)
        else {
            return nil
        }
        return closedSpan(.quoted, at: index, span, closerLength: 2)
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
