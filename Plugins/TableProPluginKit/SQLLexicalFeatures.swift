//
//  SQLLexicalFeatures.swift
//  TableProPluginKit
//

import Foundation

/// How an engine ends a string, a quoted identifier and a comment, as a plugin declares it.
///
/// A plugin for an engine TablePro does not know declares this through ``SQLDialectDescriptor/lexicalFeatures`` so
/// the editor splits its scripts where the engine does, and so the Safe Mode and external gates read the statements
/// the engine will actually run. For an engine TablePro ships, the app's own curated table wins, because a registry
/// plugin may be built against an older kit. The bit values are ABI: a new feature takes a new bit.
public struct SQLLexicalFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `'a\'b'` is one literal.
    public static let backslashEscapesInSingleQuotes = SQLLexicalFeatures(rawValue: 1 << 0)

    /// `"a\"b"` is one token.
    public static let backslashEscapesInDoubleQuotes = SQLLexicalFeatures(rawValue: 1 << 1)

    /// A backslash keeps a backtick-quoted identifier open.
    public static let backslashEscapesInBackticks = SQLLexicalFeatures(rawValue: 1 << 2)

    /// `` `name` `` is a quoted identifier.
    public static let backtickQuotes = SQLLexicalFeatures(rawValue: 1 << 3)

    /// `[name]` is a quoted identifier rather than an array or a subscript.
    public static let bracketQuotedIdentifiers = SQLLexicalFeatures(rawValue: 1 << 4)

    /// `'''...'''` and `"""..."""` are literals a lone quote inside cannot end.
    public static let tripleQuotedStrings = SQLLexicalFeatures(rawValue: 1 << 5)

    /// `E'...'` is a literal a backslash escapes in.
    public static let escapeStringPrefix = SQLLexicalFeatures(rawValue: 1 << 6)

    /// Oracle's `q'[...]'` literal.
    public static let alternativeQuoting = SQLLexicalFeatures(rawValue: 1 << 7)

    /// `$$...$$` is a literal; `$name` stays a variable.
    public static let untaggedDollarQuotes = SQLLexicalFeatures(rawValue: 1 << 8)

    /// `$$...$$` and `$tag$...$tag$` are literals.
    public static let taggedDollarQuotes = SQLLexicalFeatures(rawValue: 1 << 9)

    /// `/* /* */ */` is one comment.
    public static let nestedBlockComments = SQLLexicalFeatures(rawValue: 1 << 10)

    /// `#` starts a line comment.
    public static let hashLineComments = SQLLexicalFeatures(rawValue: 1 << 11)

    /// `//` starts a line comment.
    public static let doubleSlashLineComments = SQLLexicalFeatures(rawValue: 1 << 12)

    /// MySQL's `/*! ... */`, whose body the server runs.
    public static let executableComments = SQLLexicalFeatures(rawValue: 1 << 13)

    /// A line holding only `/` ends a statement, as SQL*Plus reads it.
    public static let slashLineTerminators = SQLLexicalFeatures(rawValue: 1 << 14)

    /// `$` and `#` continue an identifier.
    public static let dollarAndHashInIdentifiers = SQLLexicalFeatures(rawValue: 1 << 15)

    /// A `;` inside a PL/SQL unit belongs to the unit.
    public static let plsqlBlocks = SQLLexicalFeatures(rawValue: 1 << 16)

    /// A script line `DELIMITER //` changes the statement terminator.
    public static let delimiterDirective = SQLLexicalFeatures(rawValue: 1 << 17)

    /// `--` starts a comment only when a space or a control character follows it.
    public static let dashCommentsNeedWhitespace = SQLLexicalFeatures(rawValue: 1 << 18)

    /// SQLite's `$name(...)` parameter, which runs to its `)`.
    public static let parenthesizedParameterNames = SQLLexicalFeatures(rawValue: 1 << 19)

    /// `]]` inside `[...]` stands for one `]`.
    public static let doubledClosingBracketEscapes = SQLLexicalFeatures(rawValue: 1 << 20)

    /// A carriage return on its own ends a line comment.
    public static let carriageReturnEndsLineComments = SQLLexicalFeatures(rawValue: 1 << 21)
}

/// The lexical facts a driver's session settled, such as MySQL's `NO_BACKSLASH_ESCAPES` from the status flags of the
/// last reply. A fact outside ``determined`` is left to the declared grammar.
public struct PluginSessionLexicalState: Sendable, Hashable {
    public let determined: SQLLexicalFeatures
    public let enabled: SQLLexicalFeatures

    public init(determined: SQLLexicalFeatures, enabled: SQLLexicalFeatures) {
        self.determined = determined
        self.enabled = enabled.intersection(determined)
    }
}
