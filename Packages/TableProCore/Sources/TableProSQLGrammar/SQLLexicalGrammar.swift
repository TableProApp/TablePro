import Foundation

/// Where one SQL engine ends a string, a quoted identifier and a comment, as plain data.
///
/// Every reader that walks SQL text takes one of these rather than an engine name, so the statement scanner, the
/// folding scanner, the import parser and the classifiers cannot disagree about where a literal ends. The value
/// carries no behaviour of its own: ``SqlLexer`` and ``SQLStatementScanner`` read it.
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

    /// `$$...$$` and `$tag$...$tag$` are literals whose body nothing inside can end.
    public static let taggedDollarQuotes = SQLLexicalGrammar(rawValue: 1 << 9)

    /// `#` starts a comment that runs to the end of the line.
    public static let hashLineComments = SQLLexicalGrammar(rawValue: 1 << 11)

    /// Oracle's `q'[...]'` literal, whose body runs to the matching delimiter followed by a quote.
    public static let alternativeQuoting = SQLLexicalGrammar(rawValue: 1 << 7)

    /// A line holding only `/` ends the statement, as SQL*Plus reads it.
    public static let slashLineTerminators = SQLLexicalGrammar(rawValue: 1 << 14)

    /// `$` and `#` continue an identifier, so `V$SESSION` is one word, and `$` may start a conditional compilation
    /// directive such as `$IF`.
    public static let dollarAndHashInIdentifiers = SQLLexicalGrammar(rawValue: 1 << 15)

    /// A `;` inside a PL/SQL unit belongs to the unit, which ``PLSQLUnitTracker`` decides.
    public static let plsqlBlocks = SQLLexicalGrammar(rawValue: 1 << 16)

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
