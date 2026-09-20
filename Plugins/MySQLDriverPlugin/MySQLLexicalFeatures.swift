//
//  MySQLLexicalFeatures.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// How the engines this plugin serves lex a statement, for the statements the plugin reads itself.
///
/// The app's curated table is the authority for its gates; these are the same facts, held here because a plugin
/// cannot link the app's package, and `SQLLexicalFeatureMappingTests` holds the two equal.
enum MySQLLexicalFeatures {
    /// MySQL 8.4.11 and MariaDB 11.8.9, measured.
    static let mySQL: SQLLexicalFeatures = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .hashLineComments,
        .executableComments, .dashCommentsNeedWhitespace, .delimiterDirective,
    ]

    /// Databend, from its tokenizer.
    static let databend: SQLLexicalFeatures = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .untaggedDollarQuotes,
    ]

    static func features(for flavor: MySQLServerFlavor, noBackslashEscapes: Bool?) -> SQLLexicalFeatures {
        guard !flavor.isDatabend else { return databend }
        guard let state = sessionState(noBackslashEscapes: noBackslashEscapes) else { return mySQL }
        return mySQL.subtracting(state.determined).union(state.enabled)
    }

    /// What the status flags of the last reply settle. `NO_BACKSLASH_ESCAPES` turns the backslash off in both string
    /// quotes. With it off a double-quoted token is still a string or an identifier depending on `ANSI_QUOTES`, which
    /// MySQL reports nowhere, so only the single quote is settled then.
    static func sessionState(noBackslashEscapes: Bool?) -> PluginSessionLexicalState? {
        guard let noBackslashEscapes else { return nil }
        guard noBackslashEscapes else {
            return PluginSessionLexicalState(
                determined: .backslashEscapesInSingleQuotes,
                enabled: .backslashEscapesInSingleQuotes
            )
        }
        return PluginSessionLexicalState(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes],
            enabled: []
        )
    }
}
