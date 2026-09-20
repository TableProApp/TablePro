import Foundation

/// Where one SQL engine ends a string, a quoted identifier and a comment, as plain data.
///
/// Every reader that walks SQL text takes one of these rather than an engine name, so the statement scanner, the
/// folding scanner, the import parser and the classifiers cannot disagree about where a literal ends. The value
/// carries no behaviour of its own: ``SQLNonCodeSpan`` reads it.
///
/// Which grammar an engine has is ``SQLLexicalProfile``'s question, and which one a gate must read is
/// ``SQLLexicalReadings``'s.
public struct SQLLexicalGrammar: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `'a\'b'` is one literal: a backslash keeps a single-quoted string open.
    public static let backslashEscapesInSingleQuotes = SQLLexicalGrammar(rawValue: 1 << 0)

    /// `"a\"b"` is one token: a backslash keeps a double-quoted string or identifier open.
    public static let backslashEscapesInDoubleQuotes = SQLLexicalGrammar(rawValue: 1 << 1)

    /// A backslash keeps a backtick-quoted identifier open.
    public static let backslashEscapesInBackticks = SQLLexicalGrammar(rawValue: 1 << 2)

    /// `` `name` `` is a quoted identifier.
    public static let backtickQuotes = SQLLexicalGrammar(rawValue: 1 << 3)

    /// `[name]` is a quoted identifier rather than an array or a subscript.
    public static let bracketQuotedIdentifiers = SQLLexicalGrammar(rawValue: 1 << 4)

    /// `'''...'''` and `"""..."""` are literals a lone quote inside cannot end.
    public static let tripleQuotedStrings = SQLLexicalGrammar(rawValue: 1 << 5)

    /// `E'...'` is a literal a backslash escapes in, whatever plain literals do.
    public static let escapeStringPrefix = SQLLexicalGrammar(rawValue: 1 << 6)

    /// Oracle's `q'[...]'` literal, whose body runs to the matching delimiter followed by a quote.
    public static let alternativeQuoting = SQLLexicalGrammar(rawValue: 1 << 7)

    /// `$$...$$` is a literal whose body nothing inside can end. `$name` stays a variable.
    public static let untaggedDollarQuotes = SQLLexicalGrammar(rawValue: 1 << 8)

    /// `$$...$$` and `$tag$...$tag$` are literals whose body nothing inside can end.
    public static let taggedDollarQuotes = SQLLexicalGrammar(rawValue: 1 << 9)

    /// `/* /* */ */` is one comment: a block comment closes only when every comment opened inside it has.
    public static let nestedBlockComments = SQLLexicalGrammar(rawValue: 1 << 10)

    /// `#` starts a comment that runs to the end of the line.
    public static let hashLineComments = SQLLexicalGrammar(rawValue: 1 << 11)

    /// `//` starts a comment that runs to the end of the line.
    public static let doubleSlashLineComments = SQLLexicalGrammar(rawValue: 1 << 12)

    /// MySQL's `/*! ... */` and `/*M! ... */`: the server runs the body, so it is code rather than a comment.
    public static let executableComments = SQLLexicalGrammar(rawValue: 1 << 13)

    /// A line holding only `/` ends the statement, as SQL*Plus reads it.
    public static let slashLineTerminators = SQLLexicalGrammar(rawValue: 1 << 14)

    /// `$` and `#` continue an identifier, so `V$SESSION` is one word, and `$` may start a conditional compilation
    /// directive such as `$IF`.
    public static let dollarAndHashInIdentifiers = SQLLexicalGrammar(rawValue: 1 << 15)

    /// A `;` inside a PL/SQL unit belongs to the unit, which ``PLSQLUnitTracker`` decides.
    public static let plsqlBlocks = SQLLexicalGrammar(rawValue: 1 << 16)

    /// A script line `DELIMITER //` changes the statement terminator, as the `mysql` client reads it.
    public static let delimiterDirective = SQLLexicalGrammar(rawValue: 1 << 17)

    /// `--` starts a comment only when a space or a control character follows it, so `1--1` is arithmetic.
    public static let dashCommentsNeedWhitespace = SQLLexicalGrammar(rawValue: 1 << 18)

    /// SQLite's Tcl-style parameter: `$name(...)` runs to the `)`, quotes and semicolons included.
    public static let parenthesizedParameterNames = SQLLexicalGrammar(rawValue: 1 << 19)

    /// `]]` inside `[...]` stands for one `]` rather than closing the identifier.
    public static let doubledClosingBracketEscapes = SQLLexicalGrammar(rawValue: 1 << 20)

    /// A carriage return on its own ends a line comment, as a line feed does.
    public static let carriageReturnEndsLineComments = SQLLexicalGrammar(rawValue: 1 << 21)

    /// Standard SQL: quotes close only on a doubled quote, `--` and flat `/* */` are the only comments.
    public static let ansi: SQLLexicalGrammar = []

    public var dollarQuoteStyle: SqlDollarQuote.Style? {
        if contains(.taggedDollarQuotes) { return .tagged }
        if contains(.untaggedDollarQuotes) { return .untagged }
        return nil
    }

    public func backslashEscapes(inQuote quote: UInt16) -> Bool {
        switch quote {
        case SqlLexer.singleQuote:
            return contains(.backslashEscapesInSingleQuotes)
        case SqlLexer.doubleQuote:
            return contains(.backslashEscapesInDoubleQuotes)
        case SqlLexer.backtick:
            return contains(.backslashEscapesInBackticks)
        default:
            return false
        }
    }

    public func isQuote(_ character: UInt16) -> Bool {
        character == SqlLexer.singleQuote
            || character == SqlLexer.doubleQuote
            || (character == SqlLexer.backtick && contains(.backtickQuotes))
    }
}
